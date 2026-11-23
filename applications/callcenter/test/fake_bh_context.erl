%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `bh_context' for `platform_fakes': a context is the errors added to it.
-module(fake_bh_context).

-export([new/0, add_error/2, errors/1, success/1]).

new() -> {'bh_context', []}.

add_error({'bh_context', Errors}, Error) -> {'bh_context', Errors ++ [Error]}.

errors({'bh_context', Errors}) -> Errors.

success({'bh_context', Errors}) -> Errors =:= [].
