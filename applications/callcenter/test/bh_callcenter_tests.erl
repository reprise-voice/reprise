%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `bh_callcenter', the WebSocket side: what it advertises, which
%% subscriptions it takes, and that every key it hands blackhole is the
%% socket's own account's, whatever the subscription says.
%%
%% The account is not in a subscription. Blackhole puts the socket's -- its
%% token's, or the descendant `bh_authz_subscribe' allowed -- in the map it
%% hands this module as `account_id', and that is the account of every key.
-module(bh_callcenter_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ACCOUNT, <<"4b1f0c2d7e8a9b0c1d2e3f4051627384">>).
-define(OTHER_ACCOUNT, <<"0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e">>).

with_platform(Tests) ->
    {'setup', fun platform_fakes:start/0, fun platform_fakes:stop/1, Tests}.

%% --- What is advertised -----------------------------------------------------

init_test_() ->
    with_platform(
      fun() ->
              platform_fakes:clear(),
              _ = bh_callcenter:init(),
              ?assertEqual([{'set_default', [<<"blackhole">>
                                            ,[<<"bindings">>, <<"callcenter">>]
                                            ,[<<"callcenter.agent.{AGENT_ID}">>
                                             ,<<"callcenter.queue.{QUEUE_ID}">>
                                             ,<<"callcenter.call.{CALL_ID}">>
                                             ]
                                            ]}]
                          ,platform_fakes:calls('kapps_config')
                          ),
              ?assertEqual([{'bind', [<<"blackhole.events.validate.callcenter">>, 'bh_callcenter', 'validate']}
                           ,{'bind', [<<"blackhole.events.bindings.callcenter">>, 'bh_callcenter', 'bindings']}
                           ]
                          ,platform_fakes:calls('blackhole_bindings')
                          )
      end).

%% --- Which subscriptions are taken ------------------------------------------

validate_test_() ->
    with_platform(
      [{"each family, and all three, by id or every id"
       ,fun() ->
                [?assertEqual([], errors(validate(Keys)))
                 || Keys <- [[<<"agent">>, <<"f2a1c66b">>]
                            ,[<<"queue">>, <<"*">>]
                            ,[<<"call">>, <<"6bd2b8e2-7b5a">>]
                            ,[<<"*">>, <<"*">>]
                            ,[<<"*">>, <<"f2a1c66b">>]
                            ]
                ]
        end}
      ,{"a call id with dots in it, split as blackhole splits it"
       ,?_assertEqual([], errors(validate([<<"call">>, <<"abc@10">>, <<"0">>, <<"0">>, <<"1">>])))}
      ,{"a family it does not serve"
       ,?_assertEqual([<<"call center event conference not supported">>]
                     ,errors(validate([<<"conference">>, <<"*">>]))
                     )}
      ,{"no id at all"
       ,fun() ->
                ?assertMatch([<<"invalid format for call center subscription : agent">>]
                            ,errors(validate([<<"agent">>]))
                            ),
                ?assertMatch([<<"invalid format for call center subscription : ">>]
                            ,errors(validate([]))
                            )
        end}
      ]).

%% --- Account scoping --------------------------------------------------------

%% Whatever a subscription names, every key it becomes has the socket's own
%% account in it: a subscription cannot name an account at all, and a word
%% where the account would be is read as the id.
scoping_test_() ->
    with_platform(
      [{"every subscribed key and every listener is the socket's account"
       ,fun() ->
                [begin
                     #{subscribed := Subscribed, listeners := Listeners} =
                         bindings(?ACCOUNT, Keys),
                     [?assertMatch([<<"callcenter">>, _, ?ACCOUNT | _], words(Key)) || Key <- Subscribed],
                     [?assertEqual(?ACCOUNT, proplists:get_value('account_id', Props))
                      || {'amqp', 'callcenter', Props} <- Listeners
                     ],
                     %% What the listener binds is what the socket is matched on.
                     ?assertEqual(Subscribed
                                 ,lists:append([kapi_callcenter:binding_keys(Props)
                                                || {'amqp', 'callcenter', Props} <- Listeners
                                               ])
                                 )
                 end
                 || Keys <- [[<<"agent">>, <<"*">>]
                            ,[<<"queue">>, <<"37139638">>]
                            ,[<<"call">>, <<"abc@10">>, <<"0">>, <<"0">>, <<"1">>]
                            ,[<<"*">>, <<"*">>]
                            ]
                ]
        end}
      ,{"another account's id in the subscription is an id, in this account"
       ,fun() ->
                #{requested := Requested, subscribed := Subscribed} =
                    bindings(?ACCOUNT, [<<"agent">>, ?OTHER_ACCOUNT]),
                ?assertEqual(<<"callcenter.agent.", ?OTHER_ACCOUNT/binary>>, Requested),
                ?assertEqual([<<"callcenter.agent.", ?ACCOUNT/binary, ".", ?OTHER_ACCOUNT/binary>>], Subscribed)
        end}
      ,{"the same subscription on two sockets is two accounts' keys"
       ,fun() ->
                #{subscribed := Ours} = bindings(?ACCOUNT, [<<"queue">>, <<"*">>]),
                #{subscribed := Theirs} = bindings(?OTHER_ACCOUNT, [<<"queue">>, <<"*">>]),
                ?assertEqual([], [K || K <- Ours, lists:member(K, Theirs)])
        end}
      ,{"a wildcard family is one listener per family, each with only its own family"
       ,fun() ->
                #{listeners := Listeners} = bindings(?ACCOUNT, [<<"*">>, <<"*">>]),
                ?assertEqual([['agent'], ['queue'], ['call']]
                            ,[proplists:get_value('restrict_to', Props) || {'amqp', 'callcenter', Props} <- Listeners]
                            )
        end}
      ,{"the rest of the map blackhole handed over is kept"
       ,fun() ->
                Map = bh_callcenter:bindings(fake_bh_context:new()
                                            ,#{account_id => ?ACCOUNT
                                              ,keys => [<<"agent">>, <<"*">>]
                                              ,key => <<"callcenter">>
                                              }
                                            ),
                ?assertEqual(<<"callcenter">>, maps:get('key', Map))
        end}
      ]).

%% --- Helpers ----------------------------------------------------------------

validate(Keys) ->
    bh_callcenter:validate(fake_bh_context:new(), #{account_id => ?ACCOUNT, keys => Keys}).

bindings(AccountId, Keys) ->
    bh_callcenter:bindings(fake_bh_context:new(), #{account_id => AccountId, keys => Keys}).

errors(Context) -> fake_bh_context:errors(Context).

words(Key) -> binary:split(Key, <<".">>, ['global']).
