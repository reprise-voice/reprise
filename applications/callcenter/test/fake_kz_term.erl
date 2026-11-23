%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `kz_term' for `platform_fakes'.
-module(fake_kz_term).

-export([is_ne_binary/1, is_ne_binaries/1, is_empty/1, to_binary/1, identity/1]).

is_ne_binary(Value) -> is_binary(Value) andalso Value =/= <<>>.

is_ne_binaries([]) -> 'true';
is_ne_binaries(Values) when is_list(Values) -> lists:all(fun is_ne_binary/1, Values);
is_ne_binaries(_) -> 'false'.

is_empty('undefined') -> 'true';
is_empty(<<>>) -> 'true';
is_empty([]) -> 'true';
is_empty({[]}) -> 'true';
is_empty(_) -> 'false'.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, 'utf8');
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value).

identity(Value) -> Value.
