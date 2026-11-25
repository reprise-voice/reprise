%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc A resumed callflow runs, in an executor of its own that is reached at
%%% this node's queue and hears its call's events.
%%%
%%% `callflow.resume' is how a call held by something else -- a conference, a
%%% konami metaflow, a call centre whose callflow node died -- is handed back
%%% to a callflow. It never ran: the listener the shared queue forwards it to
%%% matched a state key it does not have, the handler answered `ok' where
%%% the executor starts only on `{ok, Call}', and it checked a worker out of
%%% an AMQP pool that no longer exists.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
-module(cf_route_resume_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CALL_ID, <<"resumed-call">>).
-define(QUEUE, <<"callflow_route_1">>).
-define(OLD_CONTROLLER, <<"pid://<0.1.0>/callflow_route_9">>).

resume_test_() ->
    {'foreach'
    ,fun setup/0
    ,fun(_) -> meck:unload() end
    ,[{"a resume with the channel up runs the flow", fun runs_the_flow/0}
     ,{"the resumed flow is reached at this node's queue", fun own_controller_queue/0}
     ,{"without a queue named the call's own stands", fun no_queue_named/0}
     ,{"the resumed flow hears its call's events", fun binds_the_call/0}
     ,{"a channel that is gone is not resumed", fun channel_gone/0}
     ,{"a status nobody answered is not a crash", fun status_unanswered/0}
     ,{"a resume needs no AMQP worker pool", fun no_worker_pool/0}
     ]
    }.

forward_test_() ->
    {'setup'
    ,fun() ->
             meck:new('cf_exe_sup', ['non_strict']),
             meck:expect('cf_exe_sup', 'new', fun(_JObj, _Props, _Fun) -> {'ok', self()} end),
             meck:new('kz_amqp_channel', ['passthrough']),
             meck:expect('kz_amqp_channel', 'consumer_channel', fun() -> 'channel' end)
     end
    ,fun(_) -> meck:unload() end
    ,[{"a forwarded resume starts an executor at this instance's queue", fun forwarded/0}]
    }.

setup() ->
    %% As on a node: `callflow_sup' starts no pool, and a checkout from one
    %% fails.
    meck:new('kz_amqp_worker', ['non_strict']),
    meck:expect('kz_amqp_worker', 'worker_pool', fun(_) -> 'ok' end),
    meck:expect('kz_amqp_worker', 'checkout_worker', fun() -> {'error', 'poolboy_fault'} end),
    meck:expect('kz_amqp_worker', 'cast', fun(_, _) -> 'ok' end),
    meck:new('kz_events', ['non_strict']),
    meck:expect('kz_events', 'bind_call_id', fun(_) -> 'ok' end),
    meck:new('kapps_call_command', ['non_strict']),
    meck:expect('kapps_call_command', 'b_channel_status', fun(_) -> {'ok', kz_json:new()} end),
    meck:new('cf_util', ['non_strict']),
    meck:expect('cf_util', 'flush_control_queue', fun(_) -> 'ok' end),
    meck:new('cf_route_win', ['non_strict']),
    meck:expect('cf_route_win', 'execute_callflow', fun(Call) -> {'ok', Call} end),
    meck:new('kapi_callflow', ['passthrough']),
    meck:expect('kapi_callflow', 'resume_v', fun(_) -> 'true' end).

flow() ->
    kz_json:from_list([{<<"module">>, <<"user">>}
                      ,{<<"data">>, kz_json:from_list([{<<"id">>, <<"user-1">>}])}
                      ,{<<"children">>, kz_json:new()}
                      ]).

resume() ->
    Call = kz_json:from_list([{<<"Call-ID">>, ?CALL_ID}
                             ,{<<"Control-Queue">>, <<"control-queue">>}
                             ,{<<"Controller-Queue">>, ?OLD_CONTROLLER}
                             ,{<<"Account-ID">>, <<"account0000000000000000000000001">>}
                             ]),
    kz_json:from_list([{<<"Call">>, Call}
                      ,{<<"Flow">>, flow()}
                      ,{<<"Event-Category">>, <<"callflow">>}
                      ,{<<"Event-Name">>, <<"resume">>}
                      ]).

runs_the_flow() ->
    {'ok', Call} = cf_route_resume:handle_req(resume(), [{'queue', ?QUEUE}]),
    ?assertEqual(?CALL_ID, kapps_call:call_id(Call)),
    ?assertEqual(flow(), kapps_call:kvs_fetch('cf_flow', Call)),
    ?assert(meck:called('cf_util', 'flush_control_queue', '_')),
    ?assert(meck:called('cf_route_win', 'execute_callflow', '_')).

own_controller_queue() ->
    {'ok', Call} = cf_route_resume:handle_req(resume(), [{'queue', ?QUEUE}]),
    ?assertEqual(kapi:encode_pid(?QUEUE), kapps_call:controller_queue(Call)),
    ?assertNotEqual(?OLD_CONTROLLER, kapps_call:controller_queue(Call)).

no_queue_named() ->
    {'ok', Call} = cf_route_resume:handle_req(resume(), []),
    ?assertEqual(?OLD_CONTROLLER, kapps_call:controller_queue(Call)).

binds_the_call() ->
    {'ok', _Call} = cf_route_resume:handle_req(resume(), [{'queue', ?QUEUE}]),
    ?assert(meck:called('kz_events', 'bind_call_id', [?CALL_ID])).

channel_gone() ->
    meck:expect('kapps_call_command', 'b_channel_status', fun(_) -> {'error', 'not_found'} end),
    ?assertEqual({'error', 'not_found'}, cf_route_resume:handle_req(resume(), [{'queue', ?QUEUE}])),
    ?assertNot(meck:called('cf_route_win', 'execute_callflow', '_')).

status_unanswered() ->
    meck:expect('kapps_call_command', 'b_channel_status', fun(_) -> {'error', 'timeout'} end),
    ?assertEqual({'error', 'timeout'}, cf_route_resume:handle_req(resume(), [{'queue', ?QUEUE}])),
    ?assertNot(meck:called('cf_route_win', 'execute_callflow', '_')).

no_worker_pool() ->
    {'ok', _Call} = cf_route_resume:handle_req(resume(), [{'queue', ?QUEUE}]),
    ?assertNot(meck:called('kz_amqp_worker', 'checkout_worker', '_')),
    ?assertNot(meck:called('kz_amqp_worker', 'cast', '_')).

forwarded() ->
    State = #{instance_queue => ?QUEUE, instance => 1, shared => 'true'},
    Msg = {{<<"kapps">>, <<"callflow.resume">>, 'delivery'}, {'callflow', 'resume'}, resume()},
    ?assertEqual({'noreply', State}, cf_listener:handle_info({'forward', Msg}, State)),
    [{_Pid, {'cf_exe_sup', 'new', [_JObj, Props, _Fun]}, _Result}] = meck:history('cf_exe_sup'),
    ?assertEqual(?QUEUE, props:get_value('queue', Props)).
