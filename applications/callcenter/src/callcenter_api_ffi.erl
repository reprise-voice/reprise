%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc Registering the call center's own CouchDB views.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% Two calls in one: read every design document in `priv/couchdb/views' into
%%% `system_data', and bind so that the next `kapps_maintenance refresh' or
%%% `migrate' reads them again. That is `bind_and_register_views/3', which
%%% needs a module and a function it can apply by name -- hence
%%% `register_views/0' being exported here rather than being a closure.
%%%
%%% Like every FFI module in the release's Gleam applications this is
%%% compiled by the Gleam compiler, so: no parse transform, no Kazoo header,
%%% and every call guarded with `code:ensure_loaded/1' so the test suite runs
%%% with no release around it.
%%% @end
%%%-----------------------------------------------------------------------------
-module(callcenter_api_ffi).

-export([register_views/0
        ,register_views_now/0
        ]).

-define(APP, 'callcenter').

%%------------------------------------------------------------------------------
%% @doc Register the views now, and again on every refresh.
%% @end
%%------------------------------------------------------------------------------
-spec register_views() -> 'nil'.
register_views() ->
    _ = case loaded('kapps_maintenance') of
            'false' -> 'ok';
            'true' ->
                try kapps_maintenance:bind_and_register_views(?APP, ?MODULE, 'register_views_now')
                catch
                    _E:_R -> 'ok'
                end
        end,
    'nil'.

%% @doc What `bind_and_register_views/3' calls, now and on every refresh.
-spec register_views_now() -> 'ok'.
register_views_now() ->
    case loaded('kz_datamgr') of
        'false' -> 'ok';
        'true' ->
            try kz_datamgr:register_views_from_folder(?APP)
            catch
                _E:_R -> 'ok'
            end
    end.

-spec loaded(atom()) -> boolean().
loaded(Module) ->
    case code:ensure_loaded(Module) of
        {'module', Module} -> 'true';
        {'error', _Reason} -> 'false'
    end.
