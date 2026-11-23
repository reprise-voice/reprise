%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `kz_api' for `platform_fakes'.
%%
%% `validate/4' is `kz_api''s: the default headers every message carries,
%% then the definition's required headers, then the values it restricts and
%% the types it checks, a header that is absent passing the last two. That
%% is the whole of what a `kapi_callcenter' validator does, so a test of one
%% against this is a test of the definition's own lists.
%%
%% `build_message/3' keeps what `kz_api' keeps -- the default headers, the
%% required ones and the optional ones -- and hands back the object rather
%% than its JSON, so a test can read what would have been published.
-module(fake_kz_api).

-export([validate/4, validate_message/4
        ,build_message/3
        ,prepare_api_payload/3
        ,event_name/1, event_category/1
        ,default_headers/0, default_headers/4, optional_default_headers/0
        ]).

default_headers() ->
    [<<"App-Name">>, <<"App-Version">>, <<"Event-Category">>, <<"Event-Name">>, <<"Msg-ID">>].

%% What `kazoo/amqp.default_headers' asks for.
default_headers(Category, Name, AppName, AppVersion) ->
    [{<<"Event-Category">>, Category}
    ,{<<"Event-Name">>, Name}
    ,{<<"App-Name">>, AppName}
    ,{<<"App-Version">>, AppVersion}
    ,{<<"Node">>, atom_to_binary(node(), 'utf8')}
    ].

optional_default_headers() ->
    [<<"Access-Group">>, <<"Defer-Response">>, <<"Destination-Server">>, <<"Geo-Location">>
    ,<<"Log-ID">>, <<"API-Account-ID">>, <<"API-Call-ID">>, <<"Node">>, <<"Server-ID">>
    ].

validate([_ | _] = Props, ReqH, Values, Types) ->
    has_all(Props, default_headers())
        andalso validate_message(Props, ReqH, Values, Types);
validate([], _ReqH, _Values, _Types) -> 'false';
validate(JObj, ReqH, Values, Types) ->
    validate(kz_json:to_proplist(JObj), ReqH, Values, Types).

validate_message(Props, ReqH, Values, Types) when is_list(Props) ->
    has_all(Props, ReqH)
        andalso lists:all(fun(Value) -> value_ok(Props, Value) end, Values)
        andalso lists:all(fun(Type) -> type_ok(Props, Type) end, Types);
validate_message(JObj, ReqH, Values, Types) ->
    validate_message(kz_json:to_proplist(JObj), ReqH, Values, Types).

has_all(Props, Headers) ->
    lists:all(fun(Header) when is_list(Header) ->
                      lists:any(fun(H) -> props:is_defined(H, Props) end, Header);
                 (Header) -> props:is_defined(Header, Props)
              end
             ,Headers
             ).

value_ok(Props, {Key, Allowed}) when is_list(Allowed) ->
    case props:get_value(Key, Props) of
        'undefined' -> 'true';
        Value -> lists:member(Value, Allowed)
    end;
value_ok(Props, {Key, Allowed}) ->
    case props:get_value(Key, Props) of
        'undefined' -> 'true';
        Value -> Value =:= Allowed
    end.

type_ok(Props, {Key, Fun}) ->
    case props:get_value(Key, Props) of
        'undefined' -> 'true';
        Value ->
            try Fun(Value) of
                'true' -> 'true';
                _ -> 'false'
            catch
                _:_ -> 'false'
            end
    end.

build_message(Props, ReqH, OptH) when is_list(Props) ->
    Keep = default_headers() ++ optional_default_headers() ++ ReqH ++ OptH,
    case has_all(Props, default_headers() ++ ReqH) of
        'false' -> {'error', "missing headers"};
        'true' -> {'ok', kz_json:from_list([KV || {K, _} = KV <- Props, lists:member(K, Keep)])}
    end;
build_message(JObj, ReqH, OptH) ->
    build_message(kz_json:to_proplist(JObj), ReqH, OptH).

%% The payload a publisher sends: empty values dropped, `Node' and `Msg-ID'
%% filled in, the definition's fixed values (its event category and name)
%% set where the request left them out, and the build function over the
%% lot.
prepare_api_payload(Req, HeaderValues, BuildFun) when is_list(Req) ->
    Cleaned = [KV || {_K, V} = KV <- Req, not kz_term:is_empty(V)],
    Defaults = [{<<"Node">>, atom_to_binary(node(), 'utf8')}
               ,{<<"Msg-ID">>, kz_binary:rand_hex(16)}
               ],
    Filled = lists:foldl(fun({_K, V}, Acc) when is_list(V) -> Acc;
                            ({K, _} = KV, Acc) ->
                                 case props:get_value(K, Acc) of
                                     'undefined' -> [KV | Acc];
                                     _ -> Acc
                                 end
                         end
                        ,Cleaned
                        ,Defaults ++ HeaderValues
                        ),
    BuildFun(Filled);
prepare_api_payload(JObj, HeaderValues, BuildFun) ->
    prepare_api_payload(kz_json:to_proplist(JObj), HeaderValues, BuildFun).

event_name(Props) when is_list(Props) -> props:get_value(<<"Event-Name">>, Props);
event_name(JObj) -> kz_json:get_value(<<"Event-Name">>, JObj).

event_category(Props) when is_list(Props) -> props:get_value(<<"Event-Category">>, Props);
event_category(JObj) -> kz_json:get_value(<<"Event-Category">>, JObj).
