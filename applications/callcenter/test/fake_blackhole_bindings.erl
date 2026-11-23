%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `blackhole_bindings' for `platform_fakes': a binding is recorded.
-module(fake_blackhole_bindings).

-export([bind/3]).

bind(Binding, Module, Function) ->
    platform_fakes:record('blackhole_bindings', 'bind', [Binding, Module, Function]).
