%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `kz_binary' for `platform_fakes'.
-module(fake_kz_binary).

-export([join/1, join/2, rand_hex/1]).

join(Bins) -> join(Bins, <<", ">>).

join(Bins, Separator) ->
    iolist_to_binary(lists:join(Separator, [kz_term:to_binary(Bin) || Bin <- Bins])).

rand_hex(Bytes) ->
    binary:encode_hex(<< <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, Bytes) >>, 'lowercase').
