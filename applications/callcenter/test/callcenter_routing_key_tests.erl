%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% The routing keys of the `callcenter' exchange, from both ends.
%%
%% A key is `callcenter.<family>.<account>.<id>': four words, whatever the
%% id is. A call id is whatever the switch or the far end chose, and a SIP
%% Call-ID has dots and an `@' in it; unescaped, `abc@10.0.0.1' made the key
%% seven words, which neither the webhooks binding `callcenter.call.*.*' nor
%% a socket's `callcenter.call.<account>.*' matches, so `member_connected',
%% `member_position' and `member_result' for such a caller reached nobody,
%% and a socket asking for that caller by id was refused outright.
%%
%% Every key below is built the way its user builds it -- the publisher
%% through `kapi_callcenter:publish_*', the bindings through
%% `kapi_callcenter:binding_keys/1', a socket through `bh_callcenter', and
%% blackhole's lookup through `kapi_callcenter:event_routing_keys/2' -- and
%% they have to meet.
-module(callcenter_routing_key_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ACCOUNT, <<"4b1f0c2d7e8a9b0c1d2e3f4051627384">>).
-define(OTHER_ACCOUNT, <<"0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e">>).
-define(QUEUE, <<"37139638ff5b68f155d8445178524df1">>).
-define(AGENT, <<"f2a1c66b6d2e1f6a4dcd6fa2b45c5a91">>).

%% Call ids as they come: a UUID the switch made, SIP Call-IDs from phones
%% and carriers, and the odd one with characters a key cannot carry.
-define(CALL_IDS, [<<"6bd2b8e2-7b5a-4a4e-9d7b-0c1f2e3d4a5b">>
                  ,<<"abc@10.0.0.1">>
                  ,<<"3c2a1f.9e@pbx.example.com">>
                  ,<<"a2f4.5c01.e7@192.168.1.20:5060">>
                  ,<<"with space and %25 and * and #">>
                  ]).

%% --- One word each ----------------------------------------------------------

%% Escaped as `kz_amqp_util:encode/1' escapes a call id in `kapi_call''s keys,
%% so a call id is spelled the same on both exchanges.
segment_test_() ->
    [?_assertEqual(<<"abc%4010%2E0%2E0%2E1">>, kapi_callcenter:segment(<<"abc@10.0.0.1">>))
    ,?_assertEqual(?ACCOUNT, kapi_callcenter:segment(?ACCOUNT))
    ,?_assertEqual(<<"6bd2b8e2-7b5a_x~y">>, kapi_callcenter:segment(<<"6bd2b8e2-7b5a_x~y">>))
    ,?_assertEqual(<<"a+b">>, kapi_callcenter:segment(<<"a b">>))
    ,?_assertEqual(<<"100%25">>, kapi_callcenter:segment(<<"100%">>))
    ,?_assertEqual(<<"a%2Ab%23c">>, kapi_callcenter:segment(<<"a*b#c">>))
    ,?_assertEqual(<<"%3A5060%2F">>, kapi_callcenter:segment(<<":5060/">>))
    ,?_assertEqual(<<"%C3%A9">>, kapi_callcenter:segment(<<"é"/utf8>>))
     %% The wildcards stay wildcards, and nothing is every id.
    ,?_assertEqual(<<"*">>, kapi_callcenter:segment(<<"*">>))
    ,?_assertEqual(<<"#">>, kapi_callcenter:segment(<<"#">>))
    ,?_assertEqual(<<"*">>, kapi_callcenter:segment('undefined'))
    ,?_assertEqual(<<"*">>, kapi_callcenter:segment(<<>>))
    ].

every_key_is_four_words_test_() ->
    [?_assertEqual(4, length(words(kapi_callcenter:call_routing_key(?ACCOUNT, CallId))))
     || CallId <- ?CALL_IDS
    ].

%% Hex ids go through as they are, so a key a client has seen before the
%% escaping is still the key.
hex_ids_are_unchanged_test_() ->
    [?_assertEqual(<<"callcenter.agent.", ?ACCOUNT/binary, ".", ?AGENT/binary>>
                  ,kapi_callcenter:agent_routing_key(?ACCOUNT, ?AGENT)
                  )
    ,?_assertEqual(<<"callcenter.queue.", ?ACCOUNT/binary, ".", ?QUEUE/binary>>
                  ,kapi_callcenter:queue_routing_key(?ACCOUNT, ?QUEUE)
                  )
    ,?_assertEqual(<<"callcenter.status.", ?ACCOUNT/binary>>
                  ,kapi_callcenter:status_routing_key(?ACCOUNT)
                  )
    ,?_assertEqual(<<"callcenter.call.", ?ACCOUNT/binary, ".6bd2b8e2-7b5a-4a4e-9d7b-0c1f2e3d4a5b">>
                  ,kapi_callcenter:call_routing_key(?ACCOUNT, <<"6bd2b8e2-7b5a-4a4e-9d7b-0c1f2e3d4a5b">>)
                  )
    ].

%% --- Publisher and binders --------------------------------------------------

publisher_and_binders_agree_test_() ->
    {'setup'
    ,fun platform_fakes:start/0
    ,fun platform_fakes:stop/1
    ,[{"call id " ++ binary_to_list(CallId), fun() -> meet(CallId) end}
      || CallId <- ?CALL_IDS
     ]
    }.

%% One caller's `member_position', published, and every binding that should
%% carry it.
meet(CallId) ->
    platform_fakes:clear(),
    'ok' = kapi_callcenter:publish_member_position(position(?ACCOUNT, CallId)),
    [{<<"callcenter">>, Published}] = platform_fakes:published(),
    ?assertEqual(4, length(words(Published))),
    ?assertEqual(kapi_callcenter:call_routing_key(?ACCOUNT, CallId), Published),

    %% A listener bound to that one call binds exactly that key.
    ?assertEqual([Published]
                ,kapi_callcenter:binding_keys([{'restrict_to', ['call']}
                                              ,{'account_id', ?ACCOUNT}
                                              ,{'call_id', CallId}
                                              ])
                ),

    %% Webhooks' one listener, every account and every call.
    {[{'callcenter', HookProps}], _Responders} = webhooks_callcenter:bindings_and_responders(),
    HookKeys = kapi_callcenter:binding_keys(HookProps),
    ?assert(lists:member(<<"callcenter.call.*.*">>, HookKeys)),
    ?assert(lists:any(fun(Key) -> topic_matches(Key, Published) end, HookKeys)),

    %% A socket subscribing to the call by the id the events carry, split on
    %% its dots as blackhole splits it.
    Keys = [<<"call">> | binary:split(CallId, <<".">>, ['global'])],
    ?assertEqual([], errors(bh_callcenter:validate(fake_bh_context:new(), #{keys => Keys}))),
    {Requested, Subscribed, Bound} = bh_callcenter:subscription(?ACCOUNT, Keys),
    ?assertEqual(<<"callcenter.call.", CallId/binary>>, Requested),
    ?assertEqual([Published], Subscribed),
    ?assertEqual([Published], Bound),

    %% A socket subscribing to every call of the account.
    {_, [AccountWide], [AccountWide]} = bh_callcenter:subscription(?ACCOUNT, [<<"call">>, <<"*">>]),
    ?assert(topic_matches(AccountWide, Published)),

    %% Blackhole finds both subscribers from the event itself.
    Found = kapi_callcenter:event_routing_keys(<<"member_position">>, event(position(?ACCOUNT, CallId))),
    ?assert(lists:member(Published, Found)),
    ?assert(lists:member(AccountWide, Found)),

    %% And nobody of another account: the socket's key has its own account in
    %% it, and so does the event's.
    {_, [Theirs], _} = bh_callcenter:subscription(?OTHER_ACCOUNT, [<<"call">>, <<"*">>]),
    ?assertNot(topic_matches(Theirs, Published)),
    ?assertNot(lists:member(Theirs, Found)).

%% The agent and queue families go the same way, and their ids are hex.
other_families_test_() ->
    {'setup'
    ,fun platform_fakes:start/0
    ,fun platform_fakes:stop/1
    ,fun() ->
             platform_fakes:clear(),
             'ok' = kapi_callcenter:publish_queue_stats(stats(?ACCOUNT)),
             'ok' = kapi_callcenter:publish_agent_offer(offer(?ACCOUNT, <<"abc@10.0.0.1">>)),
             [{_, QueueKey}, {_, AgentKey}] = platform_fakes:published(),
             ?assertEqual([QueueKey]
                         ,kapi_callcenter:binding_keys([{'restrict_to', [<<"queue">>]}
                                                       ,{'account_id', ?ACCOUNT}
                                                       ,{'queue_id', ?QUEUE}
                                                       ])
                         ),
             ?assertEqual({<<"callcenter.queue.", ?QUEUE/binary>>, [QueueKey], [QueueKey]}
                         ,bh_callcenter:subscription(?ACCOUNT, [<<"queue">>, ?QUEUE])
                         ),
             %% An agent event is the agent's, whatever call it is about.
             ?assertEqual({<<"callcenter.agent.", ?AGENT/binary>>, [AgentKey], [AgentKey]}
                         ,bh_callcenter:subscription(?ACCOUNT, [<<"agent">>, ?AGENT])
                         ),
             ?assert(lists:member(AgentKey
                                 ,kapi_callcenter:event_routing_keys(<<"agent_offer">>
                                                                    ,event(offer(?ACCOUNT, <<"abc@10.0.0.1">>))
                                                                    )
                                 ))
     end
    }.

%% --- Helpers ----------------------------------------------------------------

position(AccountId, CallId) ->
    [{<<"Account-ID">>, AccountId}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Call-ID">>, CallId}
    ,{<<"Position">>, 1}
    ,{<<"Waiting">>, 1}
    ,{<<"Agents-Available">>, 0}
    ,{<<"Timestamp">>, 63900000000}
     | headers(<<"member_position">>)
    ].

stats(AccountId) ->
    [{<<"Account-ID">>, AccountId}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Waiting">>, 2}
    ,{<<"Longest-Wait">>, 30}
    ,{<<"Agents-Available">>, 1}
    ,{<<"Timestamp">>, 63900000000}
     | headers(<<"queue_stats">>)
    ].

offer(AccountId, CallId) ->
    [{<<"Account-ID">>, AccountId}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Agent-ID">>, ?AGENT}
    ,{<<"Call-ID">>, CallId}
    ,{<<"Offer-Timeout">>, 15}
     | headers(<<"agent_offer">>)
    ].

headers(EventName) ->
    [{<<"Event-Category">>, <<"callcenter">>}
    ,{<<"Event-Name">>, EventName}
    ,{<<"App-Name">>, <<"callcenter">>}
    ,{<<"App-Version">>, <<"0.1.0">>}
    ].

%% The event as a listener receives it: an object.
event(Props) -> {Props}.

errors({'bh_context', Errors}) -> Errors.

words(Key) -> binary:split(Key, <<".">>, ['global']).

%% An AMQP topic match: `*' is one word, `#' any number.
topic_matches(Pattern, Key) -> match(words(Pattern), words(Key)).

match([], []) -> 'true';
match([<<"#">> | Pattern], Key) ->
    match(Pattern, Key)
        orelse (Key =/= [] andalso match([<<"#">> | Pattern], tl(Key)));
match([<<"*">> | Pattern], [_ | Key]) -> match(Pattern, Key);
match([Word | Pattern], [Word | Key]) -> match(Pattern, Key);
match(_, _) -> 'false'.

%% The matcher itself, on the keys that were the bug.
topic_match_test_() ->
    [?_assert(topic_matches(<<"callcenter.call.*.*">>, <<"callcenter.call.a.b">>))
    ,?_assertNot(topic_matches(<<"callcenter.call.*.*">>, <<"callcenter.call.a.abc@10.0.0.1">>))
    ,?_assert(topic_matches(<<"callcenter.#">>, <<"callcenter.call.a.b.c">>))
    ,?_assertNot(topic_matches(<<"callcenter.call.a.*">>, <<"callcenter.call.b.x">>))
    ].
