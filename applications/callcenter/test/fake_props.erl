%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `props' for `platform_fakes', with `props''s own meaning: a bare atom in
%% the list is that key set to `true'.
-module(fake_props).

-export([get_value/2, get_value/3, is_defined/2, get_is_true/3]).

get_value(Key, Props) -> get_value(Key, Props, 'undefined').

get_value(_Key, [], Default) -> Default;
get_value(Key, Props, Default) when is_list(Props) ->
    case lists:keyfind(Key, 1, Props) of
        {Key, Value} -> Value;
        'false' ->
            case lists:member(Key, Props) of
                'true' -> 'true';
                'false' -> Default
            end;
        _Other -> Default
    end.

is_defined(Key, Props) -> get_value(Key, Props) =/= 'undefined'.

get_is_true(Key, Props, Default) -> get_value(Key, Props, Default) =:= 'true'.
