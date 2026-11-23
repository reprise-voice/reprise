%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc Call center events over a WebSocket.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% Three subscriptions, one per family of `kapi_callcenter' topic event:
%%%
%%% <ul>
%%% <li>`callcenter.agent.{AGENT_ID}' -- availability, activity, offers,
%%% answers and wrap-ups for one agent, or for every agent with `*'.</li>
%%% <li>`callcenter.queue.{QUEUE_ID}' -- a queue's waiting count and longest
%%% wait, published whenever they change.</li>
%%% <li>`callcenter.call.{CALL_ID}' -- what the dispatcher did with one
%%% waiting caller.</li>
%%% </ul>
%%%
%%% The id is the one the events carry, as they carry it. Blackhole splits a
%%% subscription on its dots before this module sees it, and a SIP Call-ID
%%% such as `abc@10.0.0.1' has dots in it, so everything after the family is
%%% the id, joined back together; `kapi_callcenter:routing_key/3' escapes it
%%% into one word of the key the same way the published event's key was.
%%%
%%% `callcenter.*.{ID}' is all three, which is how a wallboard opens one
%%% subscription for an account rather than three.
%%%
%%% The account id is not in the subscription: it comes from the socket's
%%% token, or from `data.account_id' when a reseller asks about a
%%% descendant, and `bh_authz_subscribe' decides whether that is allowed.
%%% This module only puts it in the routing key, which is why the key has it:
%%% every published event carries the account so that one binding per account
%%% is possible at all.
%%%
%%% Nothing here queries. A live view of who is waiting is a `status_req' to
%%% the node holding the account's shard, and that is Crossbar's job; this
%%% module relays the events the dispatcher publishes as it goes.
%%%
%%% Emission is `bh_events:event/3', the default handler, so what reaches the
%%% socket is the event's public fields with normalised names: `account_id',
%%% `agent_id', `availability' and so on.
%%%
%%% This module has no `-include' and no `lager' macro, for the reason given
%%% at the top of `kapi_callcenter': it lives in a gleam package's `src' and
%%% is compiled without an include path or the parse transform.
%%% @end
%%%-----------------------------------------------------------------------------
-module(bh_callcenter).

-export([init/0
        ,validate/2
        ,bindings/2

        ,families/0
        ]).

%% Exported for the application's own tests, which run under `gleam test'
%% with none of the platform on the code path. See `subscription/2'.
-export([subscription/2]).

-define(CONFIG_CAT, <<"blackhole">>).

%% The key every subscription starts with, and the second half of the
%% blackhole binding names this module answers to.
-define(KEY, <<"callcenter">>).

-define(AGENT, <<"agent">>).
-define(QUEUE, <<"queue">>).
-define(CALL, <<"call">>).

-define(FAMILIES, [?AGENT, ?QUEUE, ?CALL]).

-define(ANY, <<"*">>).

%% What the client subscribes to.
-define(BINDING(Family, Id), <<"callcenter.", Family/binary, ".", Id/binary>>).

%%------------------------------------------------------------------------------
%% @doc Advertise the subscriptions and answer for them.
%% @end
%%------------------------------------------------------------------------------
-spec init() -> any().
init() ->
    init_bindings(),
    _ = blackhole_bindings:bind(<<"blackhole.events.validate.", ?KEY/binary>>, ?MODULE, 'validate'),
    blackhole_bindings:bind(<<"blackhole.events.bindings.", ?KEY/binary>>, ?MODULE, 'bindings').

-spec init_bindings() -> 'ok'.
init_bindings() ->
    DefaultBindings = [advertised(Family) || Family <- ?FAMILIES],
    case kapps_config:set_default(?CONFIG_CAT, [<<"bindings">>, ?KEY], DefaultBindings) of
        {'ok', _} ->
            lager:log('debug', self(), "initialized call center bindings", []);
        {'error', _E} ->
            lager:log('info', self(), "failed to initialize call center bindings: ~p", [_E])
    end.

%%------------------------------------------------------------------------------
%% @doc The families a subscription can name.
%% @end
%%------------------------------------------------------------------------------
-spec families() -> kz_term:ne_binaries().
families() -> ?FAMILIES.

%%------------------------------------------------------------------------------
%% @doc Is this a subscription this module knows how to serve?
%%
%% The id half is not checked: an id that matches nothing is a subscription
%% that receives nothing, which is a legitimate thing to ask for -- a
%% wallboard subscribes to a queue before the first caller of the day. Nor
%% is how many words it came in: a call id may have dots in it.
%% @end
%%------------------------------------------------------------------------------
-spec validate(bh_context:context(), map()) -> bh_context:context().
validate(Context, #{keys := [Family, _Id | _MoreOfTheId]}) ->
    case lists:member(Family, [?ANY | ?FAMILIES]) of
        'true' -> Context;
        'false' ->
            bh_context:add_error(Context
                                ,<<"call center event ", Family/binary, " not supported">>
                                )
    end;
validate(Context, #{keys := Keys}) ->
    bh_context:add_error(Context
                        ,<<"invalid format for call center subscription : "
                          ,(kz_binary:join(Keys))/binary
                         >>
                        ).

%%------------------------------------------------------------------------------
%% @doc Turn a subscription into the routing keys it listens on and the AMQP
%% bindings that carry them.
%%
%% `requested' is echoed back to the client as it was asked for, `subscribed'
%% is what the emitted events are matched against, and `listeners' is what
%% `blackhole_listener' hands to `gen_listener', which reaches
%% `kapi_callcenter:bind_q/2'. The last two describe the same keys, from the
%% two ends; `subscription/2' asserts that they do.
%% @end
%%------------------------------------------------------------------------------
-spec bindings(bh_context:context(), map()) -> map().
bindings(_Context, #{account_id := AccountId
                    ,keys := [Family | IdWords]
                    }=Map
        ) ->
    Id = id(IdWords),
    Families = families(Family),
    Map#{requested => ?BINDING(Family, Id)
        ,subscribed => [routing_key(F, AccountId, Id) || F <- Families]
        ,listeners => [listener(F, AccountId, Id) || F <- Families]
        }.

%%------------------------------------------------------------------------------
%% @doc The same mapping `bindings/2' makes, reduced to the three lists of
%% strings worth asserting on, and reachable from a test.
%%
%% The third element is each listener's binding read back out of its
%% properties: it is the routing key `kapi_callcenter' will bind for that
%% listener, and it has to equal the matching entry of `subscribed' or the
%% socket subscribes to one key and the broker delivers another.
%% @end
%%------------------------------------------------------------------------------
-spec subscription(kz_term:ne_binary(), kz_term:ne_binaries()) ->
          {kz_term:ne_binary(), kz_term:ne_binaries(), kz_term:ne_binaries()}.
subscription(AccountId, Keys) ->
    #{requested := Requested
     ,subscribed := Subscribed
     ,listeners := Listeners
     } = bindings('undefined', #{account_id => AccountId, keys => Keys}),
    {Requested, Subscribed, [listener_routing_key(Listener) || Listener <- Listeners]}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% The id as the client wrote it, which blackhole split on its dots.
-spec id(kz_term:ne_binaries()) -> kz_term:ne_binary().
id(Words) -> iolist_to_binary(lists:join(<<".">>, Words)).

-spec families(kz_term:ne_binary()) -> kz_term:ne_binaries().
families(?ANY) -> ?FAMILIES;
families(Family) -> [Family].

%% What a subscription becomes on the broker, which `kapi_callcenter' spells.
-spec routing_key(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()) ->
          kz_term:ne_binary().
routing_key(Family, AccountId, Id) -> kapi_callcenter:routing_key(Family, AccountId, Id).

-spec listener(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'amqp', 'callcenter', kz_term:proplist()}.
listener(Family, AccountId, Id) ->
    {'amqp'
    ,'callcenter'
    ,[{'restrict_to', [restriction(Family)]}
     ,{'account_id', AccountId}
     ,{id_key(Family), Id}
     ]
    }.

-spec listener_routing_key({'amqp', 'callcenter', kz_term:proplist()}) -> kz_term:ne_binary().
listener_routing_key({'amqp', 'callcenter', Props}) ->
    {'restrict_to', [Restriction]} = lists:keyfind('restrict_to', 1, Props),
    {'account_id', AccountId} = lists:keyfind('account_id', 1, Props),
    Family = family(Restriction),
    {_, Id} = lists:keyfind(id_key(Family), 1, Props),
    routing_key(Family, AccountId, Id).

%% `kapi_callcenter's `restrict_to' names, which are atoms.
-spec restriction(kz_term:ne_binary()) -> atom().
restriction(?AGENT) -> 'agent';
restriction(?QUEUE) -> 'queue';
restriction(?CALL) -> 'call'.

-spec family(atom()) -> kz_term:ne_binary().
family('agent') -> ?AGENT;
family('queue') -> ?QUEUE;
family('call') -> ?CALL.

%% Which of `kapi_callcenter's binding properties narrows this family.
-spec id_key(kz_term:ne_binary()) -> atom().
id_key(?AGENT) -> 'agent_id';
id_key(?QUEUE) -> 'queue_id';
id_key(?CALL) -> 'call_id'.

%% One family's subscription as `system_config/blackhole' advertises it, with
%% the placeholder a client replaces with an id or a `*'.
-spec advertised(kz_term:ne_binary()) -> kz_term:ne_binary().
advertised(Family) ->
    Placeholder = placeholder(Family),
    ?BINDING(Family, Placeholder).

-spec placeholder(kz_term:ne_binary()) -> kz_term:ne_binary().
placeholder(?AGENT) -> <<"{AGENT_ID}">>;
placeholder(?QUEUE) -> <<"{QUEUE_ID}">>;
placeholder(?CALL) -> <<"{CALL_ID}">>.
