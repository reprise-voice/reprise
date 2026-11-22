%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc What `kz_monitor' does with the processes it is asked to track.
%%%
%%% Tracking is asked for with a cast, so a process can be gone before the
%%% server hears of it. The server must shrug at that: crashing on a dead pid
%%% loses every process it was tracking, which a broker restart brought
%%% about on a lab -- refused consumers ended within their own init, each
%%% having just asked to be tracked.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_monitor_tests).

-include_lib("eunit/include/eunit.hrl").

track_test_() ->
    {'setup'
    ,fun start/0
    ,fun stop/1
    ,fun(_Monitor) ->
             [{"a live process is tracked", fun a_live_process_is_tracked/0}
             ,{"a process gone before it is tracked is left alone", fun a_dead_process_is_left_alone/0}
             ]
     end
    }.

start() ->
    {'ok', Monitor} = kz_monitor:start_link(),
    Monitor.

stop(Monitor) ->
    'true' = erlang:unlink(Monitor),
    gen_server:stop(Monitor).

a_live_process_is_tracked() ->
    Pid = spawn(fun() -> receive 'stop' -> 'ok' end end),
    'ok' = kz_monitor:track_pid(Pid),
    %% A call, so the cast before it has been handled by the time it answers.
    ?assert(lists:keymember(Pid, 1, kz_monitor:tracked_pids())),
    Pid ! 'stop'.

a_dead_process_is_left_alone() ->
    Monitor = whereis('kz_monitor'),
    {Pid, Ref} = spawn_monitor(fun() -> 'ok' end),
    receive {'DOWN', Ref, 'process', Pid, _} -> 'ok' end,
    'ok' = kz_monitor:track_pid(Pid),
    ?assertNot(lists:keymember(Pid, 1, kz_monitor:tracked_pids())),
    ?assert(erlang:is_process_alive(Monitor)),
    ?assertEqual(Monitor, whereis('kz_monitor')).
