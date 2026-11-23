%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc Register the call center's modules with the applications that host
%%% them.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% `bh_callcenter' and `webhooks_callcenter' ship in this application, not
%%% in blackhole or webhooks, so somebody has to tell those two that the
%%% modules exist. `skel_app' does it with `kz_module:application_integrations/1'
%%% at application start; this is the same list, callable from Gleam, because
%%% the application's start callback is `callcenter@app'.
%%%
%%% Two differences from skel. Each entry is skipped when its host is not in
%%% the release: a release built without blackhole should not have the call
%%% center trying to register with it. And the work happens in a process of
%%% its own, because registering costs an AMQP request and a collect of every
%%% node's answer -- blocking `application:start/1' on the broker would mean a
%%% node that cannot reach it does not start, when what it should do is start
%%% and register when the broker comes back. Both hosts also re-read their
%%% module lists themselves at start, so a missed registration is not
%%% permanent.
%%%
%%% Webhooks does not strictly need this: `webhooks_init:existing_modules/0'
%%% finds any module in any loaded application exporting `init/0' and
%%% `bindings_and_responders/0'. It is here for the case that matters, which
%%% is the call center being started -- or restarted -- after webhooks.
%%%
%%% No `-include' and no `lager' macro: gleam package. See `kapi_callcenter'.
%%% @end
%%%-----------------------------------------------------------------------------
-module(callcenter_edges).

-export([start/0
        ,integrate/0
        ,integrations/0
        ]).

%% `{Module, HostMaintenance, Function}', the shape
%% `kz_module:application_integrations/1' takes.
-define(INTEGRATIONS
       ,[{'bh_callcenter', 'blackhole_maintenance', 'start_module'}
        ,{'webhooks_callcenter', 'webhooks_maintenance', 'start_module'}
        ]
       ).

%%------------------------------------------------------------------------------
%% @doc Register the edges, without waiting for them.
%%
%% Called once from the application's start callback.
%% @end
%%------------------------------------------------------------------------------
-spec start() -> 'ok'.
start() ->
    _Pid = erlang:spawn(fun integrate/0),
    'ok'.

%%------------------------------------------------------------------------------
%% @doc Register the edges now, and return when every host has answered.
%%
%% Separate from `start/0' so that `sup' can redo it on a node where
%% blackhole or webhooks was started afterwards.
%% @end
%%------------------------------------------------------------------------------
-spec integrate() -> 'ok'.
integrate() -> lists:foreach(fun integrate/1, ?INTEGRATIONS).

%%------------------------------------------------------------------------------
%% @doc The modules this application asks other applications to load.
%% @end
%%------------------------------------------------------------------------------
-spec integrations() -> [{module(), module(), atom()}].
integrations() -> ?INTEGRATIONS.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

-spec integrate({module(), module(), atom()}) -> 'ok'.
integrate({Module, Maintenance, Function}) ->
    case is_loadable(Module)
        andalso is_loadable(Maintenance)
        andalso is_loadable('kz_module')
    of
        'true' -> kz_module:application_integrations([{Module, Maintenance, Function}]);
        'false' -> 'ok'
    end.

-spec is_loadable(module()) -> boolean().
is_loadable(Module) ->
    case code:ensure_loaded(Module) of
        {'module', Module} -> 'true';
        {'error', _Reason} -> 'false'
    end.
