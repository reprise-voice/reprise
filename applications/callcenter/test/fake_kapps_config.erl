%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `kapps_config' for `platform_fakes': a default set is recorded.
-module(fake_kapps_config).

-export([set_default/3]).

set_default(Category, Key, Value) ->
    platform_fakes:record('kapps_config', 'set_default', [Category, Key, Value]),
    {'ok', Value}.
