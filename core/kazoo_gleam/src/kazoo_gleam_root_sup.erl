%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The root of a Gleam application's supervision tree.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% `kz_nodes' reads an application's start time from the process dictionary
%%% of whatever process its `start/2' returned (`$startup', which
%%% `kz_process:set_startup/0' writes and every Erlang application's top
%%% supervisor sets in `init/1'). A Gleam supervisor's `init' is the
%%% library's, so nothing writes it there and `kz_nodes status' shows the
%%% application with no run time. This supervisor sits above the Gleam tree,
%%% sets the key in its own `init/1', and is the pid the application returns.
%%%
%%% It restarts nothing: when the Gleam tree exhausts its own restart
%%% tolerance and gives up, this exits with it and the application stops,
%%% which is what happened when the Gleam tree was the root.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_root_sup).
-behaviour(supervisor).

-export([start_link/1
        ,started_at/1
        ]).
-export([init/1
        ,start_tree/1
        ]).

%% @doc Start the root, with `Start' the function that starts the Gleam tree
%% under it. `Start' returns what `gleam/otp/static_supervisor.start' does:
%% `{ok, {started, Pid, Data}}' or `{error, Reason}'.
-spec start_link(fun(() -> term())) -> {'ok', pid()} | {'error', term()}.
start_link(Start) when is_function(Start, 0) ->
    supervisor:start_link(?MODULE, Start).

%% @doc When the tree under `Pid' started, in gregorian seconds -- the unit
%% `kz_time:now_s/0' uses and `kz_nodes' expects. `none' for a process that is
%% not one of these roots.
-spec started_at(pid()) -> {'some', pos_integer()} | 'none'.
started_at(Pid) ->
    case erlang:process_info(Pid, 'dictionary') of
        {'dictionary', Dictionary} ->
            case lists:keyfind('$startup', 1, Dictionary) of
                {'$startup', Startup} when is_integer(Startup) -> {'some', Startup};
                _Else -> 'none'
            end;
        _Gone -> 'none'
    end.

-spec init(fun(() -> term())) -> {'ok', {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Start) ->
    _ = put('$startup', calendar:datetime_to_gregorian_seconds(calendar:universal_time())),
    Flags = #{'strategy' => 'one_for_one', 'intensity' => 0, 'period' => 1},
    Tree = #{'id' => 'tree'
            ,'start' => {?MODULE, 'start_tree', [Start]}
            ,'restart' => 'permanent'
            ,'shutdown' => 'infinity'
            ,'type' => 'supervisor'
            },
    {'ok', {Flags, [Tree]}}.

%% @doc The child start: the Gleam tree's `Started' record, reduced to the
%% `{ok, Pid}' a supervisor child has to return.
-spec start_tree(fun(() -> term())) -> {'ok', pid()} | {'error', term()}.
start_tree(Start) ->
    case Start() of
        {'ok', {'started', Pid, _Data}} when is_pid(Pid) -> {'ok', Pid};
        {'error', Reason} -> {'error', Reason};
        Other -> {'error', {'bad_return', Other}}
    end.
