%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The small things Gleam cannot do on its own.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% A content digest, a constant-time comparison, an instant back to unix
%%% seconds, and a registered name built from a literal. None of these touch
%%% Kazoo, so all of them work in a bare test node.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_util_ffi).

-export([digest/1
        ,secure_compare/2
        ,from_iso8601/1
        ,atom_name/1
        ]).

%% @doc A short content digest, for a revision a client can cache on.
-spec digest(binary()) -> binary().
digest(Content) ->
    <<Head:4/binary, _/binary>> = crypto:hash('md5', Content),
    string:lowercase(binary:encode_hex(Head)).

%% @doc Compare two secrets in time that depends on their length but not on
%% where they first differ.
-spec secure_compare(binary(), binary()) -> boolean().
secure_compare(A, B) when is_binary(A), is_binary(B) ->
    Size = max(byte_size(A), byte_size(B)),
    Padded = fun(Bin) -> <<Bin/binary, 0:((Size - byte_size(Bin)) * 8)>> end,
    Diff = crypto:exor(Padded(A), Padded(B)),
    byte_size(A) =:= byte_size(B)
        andalso lists:all(fun(Byte) -> Byte =:= 0 end, binary_to_list(Diff)).

%% @doc An RFC 3339 instant back to unix seconds.
-spec from_iso8601(binary()) -> {'ok', integer()} | {'error', 'nil'}.
from_iso8601(Text) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Text), [{'unit', 'second'}]) of
        Seconds -> {'ok', Seconds}
    catch
        _E:_R -> {'error', 'nil'}
    end.

%% @doc A registered name, as an atom. Gleam's `process:new_name/1' mints a
%% fresh atom on every call, which is not what a name has to be when a caller
%% holding nothing but a string must find the process. Call this with
%% literals only: every distinct string is one more atom, for good.
-spec atom_name(binary()) -> atom().
atom_name(Name) -> erlang:binary_to_atom(Name, 'utf8').
