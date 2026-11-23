%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `kapi_definition' for `platform_fakes': a definition is a map of what its
%% setters set, and validating and building go to `kz_api' as they do in
%% the platform.
-module(fake_kapi_definition).

-export([setters/1
        ,set_name/2, set_friendly_name/2, set_description/2, set_category/2
        ,set_build_fun/2, set_validate_fun/2, set_publish_fun/2
        ,set_binding/2, set_restrict_to/2
        ,set_required_headers/2, set_optional_headers/2
        ,set_values/2, set_types/2
        ,name/1, friendly_name/1, description/1, category/1
        ,build_fun/1, validate_fun/1, publish_fun/1
        ,required_headers/1, optional_headers/1, values/1, types/1
        ,event_type_headers/2
        ,validate/2, build_message/2
        ]).

setters(Routines) ->
    lists:foldl(fun({Setter, Value}, Definition) -> Setter(Definition, Value) end
               ,#{'required_headers' => []
                 ,'optional_headers' => []
                 ,'values' => []
                 ,'types' => []
                 }
               ,Routines
               ).

set_name(D, V) -> D#{'name' => V}.
set_friendly_name(D, V) -> D#{'friendly_name' => V}.
set_description(D, V) -> D#{'description' => V}.
set_category(D, V) -> D#{'category' => V}.
set_build_fun(D, V) -> D#{'build_fun' => V}.
set_validate_fun(D, V) -> D#{'validate_fun' => V}.
set_publish_fun(D, V) -> D#{'publish_fun' => V}.
set_binding(D, V) -> D#{'binding' => V}.
set_restrict_to(D, V) -> D#{'restrict_to' => V}.
set_required_headers(D, V) -> D#{'required_headers' => V}.
set_optional_headers(D, V) -> D#{'optional_headers' => V}.
set_values(D, V) -> D#{'values' => V}.
set_types(D, V) -> D#{'types' => V}.

name(D) -> maps:get('name', D, 'undefined').
friendly_name(D) -> maps:get('friendly_name', D, 'undefined').
description(D) -> maps:get('description', D, 'undefined').
category(D) -> maps:get('category', D, 'undefined').
build_fun(D) -> maps:get('build_fun', D, 'undefined').
validate_fun(D) -> maps:get('validate_fun', D, 'undefined').
publish_fun(D) -> maps:get('publish_fun', D, 'undefined').
required_headers(D) -> maps:get('required_headers', D).
optional_headers(D) -> maps:get('optional_headers', D).
values(D) -> maps:get('values', D).
types(D) -> maps:get('types', D).

event_type_headers(Category, EventName) ->
    [{<<"Event-Category">>, Category}
    ,{<<"Event-Name">>, EventName}
    ].

validate(Api, D) ->
    kz_api:validate(Api, required_headers(D), values(D), types(D)).

build_message(Props, D) when is_list(Props) ->
    ValidateFun = validate_fun(D),
    case ValidateFun(Props) of
        'true' -> kz_api:build_message(Props, required_headers(D), optional_headers(D));
        'false' -> {'error', "failed validation"}
    end;
build_message(JObj, D) ->
    build_message(kz_json:to_proplist(JObj), D).
