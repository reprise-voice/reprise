%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `kz_json' for `platform_fakes': the `{Proplist}' object and the handful
%% of functions the call center's Erlang modules call, with `kz_json''s own
%% meaning.
-module(fake_kz_json).

-export([new/0, from_list/1, from_map/1, to_proplist/1
        ,get_value/2, get_value/3
        ,get_ne_binary_value/2, get_ne_binary_value/3
        ,get_binary_value/2
        ,set_value/3
        ,delete_key/2, delete_keys/2
        ,is_json_object/1, is_empty/1
        ,normalize_jobj/1, normalize_jobj/3
        ]).

new() -> {[]}.

from_list(Props) when is_list(Props) -> {[{K, V} || {K, V} <- Props, V =/= 'undefined']}.

from_map(Map) when is_map(Map) ->
    {[{K, from_map(V)} || {K, V} <- lists:sort(maps:to_list(Map))]};
from_map(List) when is_list(List) -> [from_map(V) || V <- List];
from_map(Value) -> Value.

to_proplist({Props}) when is_list(Props) -> Props;
to_proplist(Props) when is_list(Props) -> Props.

get_value(Key, JObj) -> get_value(Key, JObj, 'undefined').

get_value([], JObj, _Default) -> JObj;
get_value([Key | Keys], {Props}, Default) ->
    case lists:keyfind(Key, 1, Props) of
        {Key, Value} -> get_value(Keys, Value, Default);
        'false' -> Default
    end;
get_value([_ | _], _NotAnObject, Default) -> Default;
get_value(Key, JObj, Default) -> get_value([Key], JObj, Default).

get_ne_binary_value(Key, JObj) -> get_ne_binary_value(Key, JObj, 'undefined').

get_ne_binary_value(Key, JObj, Default) ->
    case get_value(Key, JObj) of
        <<_, _/binary>> = Value -> Value;
        _ -> Default
    end.

get_binary_value(Key, JObj) ->
    case get_value(Key, JObj) of
        Value when is_binary(Value) -> Value;
        _ -> 'undefined'
    end.

set_value([Key], Value, JObj) -> set_value(Key, Value, JObj);
set_value([Key | Keys], Value, {Props}) ->
    Inner = case lists:keyfind(Key, 1, Props) of
                {Key, {_} = Object} -> Object;
                _ -> new()
            end,
    {lists:keystore(Key, 1, Props, {Key, set_value(Keys, Value, Inner)})};
set_value(Key, Value, {Props}) ->
    {lists:keystore(Key, 1, Props, {Key, Value})}.

delete_key(Key, {Props}) -> {lists:keydelete(Key, 1, Props)}.

delete_keys(Keys, JObj) -> lists:foldl(fun delete_key/2, JObj, Keys).

is_json_object({Props}) when is_list(Props) -> 'true';
is_json_object(_) -> 'false'.

is_empty({[]}) -> 'true';
is_empty(_) -> 'false'.

%% Keys lower-cased with `-' as `_', undefined and null values dropped, all
%% the way down.
normalize_jobj({Props}) ->
    {[{normalize_key(K), normalize_value(V)}
      || {K, V} <- Props,
         V =/= 'undefined',
         V =/= 'null'
     ]}.

normalize_jobj(JObj, RemoveKeys, []) -> normalize_jobj(delete_keys(RemoveKeys, JObj)).

normalize_value([_ | _] = Values) -> [normalize_value(V) || V <- Values];
normalize_value({Props} = Object) when is_list(Props) -> normalize_jobj(Object);
normalize_value(Value) -> Value.

normalize_key(Key) when is_binary(Key) -> << <<(normalize_char(C))>> || <<C>> <= Key >>.

normalize_char($-) -> $_;
normalize_char(C) when C >= $A, C =< $Z -> C + 32;
normalize_char(C) -> C.
