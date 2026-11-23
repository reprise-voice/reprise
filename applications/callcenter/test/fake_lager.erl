%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `lager' for `platform_fakes': every line is dropped.
-module(fake_lager).

-compile({'no_auto_import', [error/1, error/2]}).

-export([log/3, log/4, log/5
        ,debug/1, debug/2, info/1, info/2, warning/1, warning/2, error/1, error/2
        ]).

log(_Level, _Pid, _Message) -> 'ok'.
log(_Level, _Pid, _Format, _Args) -> 'ok'.
log(_Level, _Metadata, _Format, _Args, _Extra) -> 'ok'.

debug(_) -> 'ok'.
debug(_, _) -> 'ok'.
info(_) -> 'ok'.
info(_, _) -> 'ok'.
warning(_) -> 'ok'.
warning(_, _) -> 'ok'.
error(_) -> 'ok'.
error(_, _) -> 'ok'.
