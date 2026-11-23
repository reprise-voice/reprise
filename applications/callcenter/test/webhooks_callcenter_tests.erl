%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `webhooks_callcenter': what the shared webhooks listener binds for the
%% call center, which account's hooks an event fires, and what a hook's URL
%% receives.
-module(webhooks_callcenter_tests).

-include_lib("eunit/include/eunit.hrl").

-import(callcenter_messages, [full/1]).

-define(ACCOUNT, (callcenter_messages:account())).
-define(OTHER_ACCOUNT, <<"0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e">>).

-define(HOOKED, [<<"member_connected">>, <<"member_position">>, <<"member_result">>
                ,<<"agent_availability">>, <<"agent_activity">>, <<"agent_offer">>
                ,<<"agent_answered">>, <<"agent_wrapup">>, <<"queue_stats">>
                ]).

with_platform(Tests) ->
    {'setup', fun platform_fakes:start/0, fun platform_fakes:stop/1, Tests}.

%% --- What is bound ----------------------------------------------------------

%% The call, agent and queue families of every account, and no status
%% query: nothing on the status key is an event anybody hooks.
bindings_test_() ->
    with_platform(
      fun() ->
              {[{'callcenter', Props}], Responders} = webhooks_callcenter:bindings_and_responders(),
              ?assertEqual([<<"callcenter.call.*.*">>, <<"callcenter.agent.*.*">>, <<"callcenter.queue.*.*">>]
                          ,kapi_callcenter:binding_keys(Props)
                          ),
              ?assertEqual([{{'webhooks_callcenter', 'handle'}, [{<<"callcenter">>, <<"*">>}]}]
                          ,Responders
                          )
      end).

%% --- The hooks on offer -----------------------------------------------------

events_test_() ->
    [?_assertEqual(?HOOKED, webhooks_callcenter:events())
    ,?_assertEqual(<<"callcenter_member_result">>, webhooks_callcenter:hook_name(<<"member_result">>))
     %% `webhooks' takes the hook name from the metadata id by dropping
     %% `webhooks_', so the two agree.
    ,[?_assertEqual(<<"webhooks_", (webhooks_callcenter:hook_name(E))/binary>>
                   ,webhooks_callcenter:hook_id(E)
                   )
      || E <- ?HOOKED
     ]
     %% Every hooked event is one `kapi_callcenter' defines and publishes on
     %% the exchange: the work queue and the status query are not events.
    ,[?_assert(lists:member(E, callcenter_messages:events())) || E <- ?HOOKED]
    ,?_assertNot(lists:member(<<"member_call">>, ?HOOKED))
    ,?_assertNot(lists:member(<<"member_cancel">>, ?HOOKED))
    ,?_assertNot(lists:member(<<"status_req">>, ?HOOKED))
    ].

%% One metadata document per hook, which is what lists it for an account.
init_test_() ->
    with_platform(
      fun() ->
              platform_fakes:clear(),
              'ok' = webhooks_callcenter:init(),
              Metadata = [{Id, JObj} || {'init_metadata', [Id, JObj]} <- platform_fakes:calls('webhooks_util')],
              ?assertEqual([webhooks_callcenter:hook_id(E) || E <- ?HOOKED], [Id || {Id, _} <- Metadata]),
              [begin
                   ?assertEqual(Id, kz_json:get_value(<<"_id">>, JObj)),
                   ?assert(is_binary(kz_json:get_value(<<"name">>, JObj))),
                   ?assert(is_binary(kz_json:get_value(<<"description">>, JObj)))
               end
               || {Id, JObj} <- Metadata
              ]
      end).

%% --- Which account's hooks fire ---------------------------------------------

handle_test_() ->
    with_platform(
      [{"every hooked event fires its own hook, in the event's account"
       ,fun() ->
                platform_fakes:clear(),
                [begin
                     Hook = webhooks_callcenter:hook_name(E),
                     hooks(Hook, ?ACCOUNT, ['hook_a']),
                     handle(full(E)),
                     ?assertEqual([{Hook, ?ACCOUNT}], looked_up()),
                     [{V1, V2, ['hook_a']}] = fired(),
                     ?assertEqual(Hook, kz_json:get_value(<<"hook_event">>, V1)),
                     ?assertEqual(Hook, kz_json:get_value(<<"name">>, V2))
                 end
                 || E <- ?HOOKED
                ]
        end}
      ,{"a hook of another account does not fire"
       ,fun() ->
                platform_fakes:clear(),
                Hook = webhooks_callcenter:hook_name(<<"member_position">>),
                hooks(Hook, ?OTHER_ACCOUNT, ['theirs']),
                handle(full(<<"member_position">>)),
                ?assertEqual([{Hook, ?ACCOUNT}], looked_up()),
                ?assertEqual([], fired())
        end}
      ,{"the other account's own event fires only its own hook"
       ,fun() ->
                platform_fakes:clear(),
                Hook = webhooks_callcenter:hook_name(<<"agent_offer">>),
                hooks(Hook, ?ACCOUNT, ['ours']),
                hooks(Hook, ?OTHER_ACCOUNT, ['theirs']),
                Theirs = lists:keystore(<<"Account-ID">>, 1, full(<<"agent_offer">>), {<<"Account-ID">>, ?OTHER_ACCOUNT}),
                handle(Theirs),
                ?assertMatch([{_, _, ['theirs']}], fired())
        end}
      ,{"a hook for one event does not fire for another"
       ,fun() ->
                platform_fakes:clear(),
                hooks(webhooks_callcenter:hook_name(<<"member_result">>), ?ACCOUNT, ['results']),
                handle(full(<<"member_position">>)),
                ?assertEqual([], fired())
        end}
      ,{"the work queue and the status query are nobody's hook"
       ,fun() ->
                platform_fakes:clear(),
                [begin
                     handle(full(E)),
                     ?assertEqual([], looked_up()),
                     ?assertEqual([], fired())
                 end
                 || E <- [<<"member_call">>, <<"member_cancel">>, <<"status_req">>, <<"status_resp">>
                         ,<<"pickup_req">>, <<"pickup_resp">>
                         ]
                ]
        end}
      ,{"an event its definition refuses fires nothing"
       ,fun() ->
                platform_fakes:clear(),
                hooks(webhooks_callcenter:hook_name(<<"member_result">>), ?ACCOUNT, ['results']),
                Refused = lists:keydelete(<<"Result">>, 1, full(<<"member_result">>)),
                ?assertError({'badmatch', 'false'}, webhooks_callcenter:handle({Refused}, [])),
                ?assertEqual([], fired()),
                %% Nor one with no account to look hooks up in.
                NoAccount = lists:keydelete(<<"Account-ID">>, 1, full(<<"member_result">>)),
                ?assertError({'badmatch', 'false'}, webhooks_callcenter:handle({NoAccount}, [])),
                ?assertEqual([], looked_up())
        end}
      ]).

%% --- What a hook receives ---------------------------------------------------

payload_test_() ->
    with_platform(
      fun() ->
              platform_fakes:clear(),
              Hook = webhooks_callcenter:hook_name(<<"member_position">>),
              hooks(Hook, ?ACCOUNT, ['hook_a']),
              handle(full(<<"member_position">>) ++ [{<<"Server-ID">>, <<"some-queue">>}
                                                    ,{<<"Node">>, <<"kazoo_apps@one">>}
                                                    ]),
              [{V1, V2, _Hooks}] = fired(),

              %% The v1 body: the event's own fields, named as the WebSocket
              %% names them, with the AMQP plumbing gone.
              {V1Props} = V1,
              ?assertEqual(lists:sort([<<"hook_event">>, <<"account_id">>, <<"queue_id">>, <<"call_id">>
                                      ,<<"position">>, <<"waiting">>, <<"agents_available">>
                                      ,<<"timestamp">>, <<"caller_id_name">>, <<"caller_id_number">>
                                      ,<<"joined_timestamp">>, <<"media_node">>, <<"offered">>
                                      ])
                          ,lists:sort(proplists:get_keys(V1Props))
                          ),
              ?assertEqual(Hook, kz_json:get_value(<<"hook_event">>, V1)),
              ?assertEqual(?ACCOUNT, kz_json:get_value(<<"account_id">>, V1)),
              ?assertEqual(callcenter_messages:call(), kz_json:get_value(<<"call_id">>, V1)),
              ?assertEqual(1, kz_json:get_value(<<"position">>, V1)),

              %% The v2 body: the event named, and its data.
              ?assertEqual(<<"event">>, kz_json:get_value(<<"action">>, V2)),
              ?assertEqual(Hook, kz_json:get_value(<<"name">>, V2)),
              ?assertEqual(?ACCOUNT, kz_json:get_value([<<"data">>, <<"account_id">>], V2))
      end).

%% --- Helpers ----------------------------------------------------------------

hooks(HookName, AccountId, Hooks) ->
    platform_fakes:set({'hooks', HookName, AccountId}, Hooks).

handle(Props) ->
    platform_fakes:clear_calls(),
    'ok' = webhooks_callcenter:handle({Props}, []).

looked_up() ->
    [{Hook, Account} || {'find_webhooks', [Hook, Account]} <- platform_fakes:calls('webhooks_util')].

fired() ->
    [{V1, V2, Hooks} || {'fire_hooks', [V1, V2, Hooks]} <- platform_fakes:calls('webhooks_util')].
