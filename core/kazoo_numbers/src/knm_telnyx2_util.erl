%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2014-2025, 2600Hz
%%% (C) 2026, Vonix LLC
%%% @doc Shared HTTP plumbing for the Telnyx API v2 carrier modules.
%%%
%%% v2 differs from the `knm_telnyx' (v1) modules in three ways that matter
%%% here: it is rooted at `/v2' instead of `/origination', it authenticates
%%% with a bearer token instead of the `x-api-user'/`x-api-token' pair, and
%%% every response wraps its payload in a top-level `data' key.
%%% @end
%%%-----------------------------------------------------------------------------
-module(knm_telnyx2_util).

-export([did/1]).
-export([number_id/1]).
-export([req/2, req/3, req/4]).
-export([query_string/1]).
-export([maybe_add_connection/1]).
-export([maybe_add_messaging_profile/1]).

-include("knm.hrl").

-define(MOD_CONFIG_CAT, <<(?KNM_CONFIG_CAT)/binary, ".telnyx2">>).

-define(CARRIER, 'knm_telnyx2').

-ifdef(TEST).
-define(DEBUG_APPEND(_Format, _Args), 'ok').
-else.
-define(DEBUG, kapps_config:get_is_true(?MOD_CONFIG_CAT, <<"debug">>, 'false')).
-define(DEBUG_FILE, "/tmp/telnyx2.json").
-define(DEBUG_APPEND(Format, Args),
        _ = ?DEBUG
        andalso file:write_file(?DEBUG_FILE, io_lib:format(Format, Args), ['append'])
       ).
-endif.

-define(SHOULD_FILTER_RATES
       ,kapps_config:get_is_true(?MOD_CONFIG_CAT, <<"should_filter_rates">>, 'false')
       ).

-define(CONNECTION_ID
       ,kapps_config:get_ne_binary(?MOD_CONFIG_CAT, <<"connection_id">>)
       ).

-define(MESSAGING_PROFILE_ID
       ,kapps_config:get_ne_binary(?MOD_CONFIG_CAT, <<"messaging_profile_id">>)
       ).

-define(TOKEN, kapps_config:get_ne_binary(?MOD_CONFIG_CAT, <<"token">>)).

-define(DOMAIN, "api.telnyx.com").
-define(URL(Path), "https://" ?DOMAIN "/v2/" ++ filename:join(Path)).

%%------------------------------------------------------------------------------
%% @doc Turns +13129677542 into %2B13129677542.
%% @end
%%------------------------------------------------------------------------------
-spec did(knm_phone_number:pn_record()) -> nonempty_string().
did(PN) ->
    binary_to_list(
      kz_http_util:urlencode(
        knm_phone_number:number(PN)
       )
     ).

%%------------------------------------------------------------------------------
%% @doc Resolve a number to the opaque id Telnyx uses to address it.
%%
%% Unlike v1, the v2 per-number endpoints (`/phone_numbers/{id}/voice',
%% `/phone_numbers/{id}/actions/enable_emergency', …) will not accept an E.164
%% number in place of the id, so every write against a number costs an extra
%% lookup through the collection endpoint's `filter[phone_number]'.
%% @end
%%------------------------------------------------------------------------------
-spec number_id(knm_phone_number:pn_record()) -> kz_term:ne_binary().
number_id(PN) ->
    Num = knm_phone_number:number(PN),
    Query = [{<<"filter">>, [{<<"phone_number">>, Num}]}],
    Rep = req('get', ["phone_numbers"], Query, kz_json:new()),
    case kz_json:get_list_value(<<"data">>, Rep, []) of
        [Data|_] ->
            case kz_json:get_ne_binary_value(<<"id">>, Data) of
                'undefined' ->
                    lager:debug("telnyx record for ~s carries no id: ~s", [Num, kz_json:encode(Data)]),
                    knm_errors:by_carrier(?CARRIER, <<"number_not_found">>, Num);
                Id -> Id
            end;
        [] ->
            lager:debug("no telnyx phone number record for ~s", [Num]),
            knm_errors:by_carrier(?CARRIER, <<"number_not_found">>, Num)
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec req(atom(), [nonempty_string()]) -> kz_json:object().
req(Method, Path) ->
    req(Method, Path, [], kz_json:new()).

-spec req(atom(), [nonempty_string()], kz_json:object()) -> kz_json:object().
req(Method, Path, JObj) ->
    req(Method, Path, [], JObj).

-ifdef(TEST).

-spec req(atom(), [nonempty_string()], kz_term:proplist(), kz_json:object()) -> kz_json:object().
req('get', ["available_phone_numbers"], Query, _) ->
    Filter = props:get_value(<<"filter">>, Query),
    %% every search must bound its result set and say what it is looking for
    'true' = is_integer(props:get_value(<<"limit">>, Filter)),
    case {props:get_value(<<"phone_number_type">>, Filter)
         ,props:get_value(<<"country_code">>, Filter)
         }
    of
        {<<"toll_free">>, _} -> rep_fixture("telnyx2_tollfree_search.json");
        {<<"local">>, _} -> rep_fixture("telnyx2_npa_search.json");
        {'undefined', <<"GB">>} -> rep_fixture("telnyx2_international_search.json")
    end;
req('get', ["phone_numbers"], Query, _) ->
    Filter = props:get_value(<<"filter">>, Query),
    ?TEST_TELNYX2_NUM = props:get_value(<<"phone_number">>, Filter),
    rep_fixture("telnyx2_list_phone_numbers.json");
req('get', ["number_orders", "12ade33a-21c0-473b-b055-b3c836e1c292"], [], _) ->
    rep_fixture("telnyx2_check_order.json");
req('post', ["number_orders"], [], Body) ->
    [PhoneNumber] = kz_json:get_list_value(<<"phone_numbers">>, Body),
    ?TEST_TELNYX2_NUM = kz_json:get_ne_binary_value(<<"phone_number">>, PhoneNumber),
    rep_fixture("telnyx2_order.json");
req('patch', ["phone_numbers", "1293384261075731499", "voice"], [], Body) ->
    case kz_json:get_ne_binary_value([<<"cnam_listing">>, <<"cnam_listing_details">>], Body) of
        'undefined' ->
            %% inbound-only toggles must not disturb the outbound listing
            'undefined' = kz_json:get_value(<<"cnam_listing">>, Body),
            'true' = is_boolean(kz_json:get_value(<<"caller_id_name_enabled">>, Body));
        Details ->
            %% "Must be alphanumeric characters or spaces with a maximum
            %% length of 15. Requires cnam_listing_enabled to also be set."
            'true' = byte_size(Details) =< 15,
            'true' = Details =:= << <<C>> || <<C>> <= Details, is_cnam_char(C)>>,
            'true' = kz_json:is_true([<<"cnam_listing">>, <<"cnam_listing_enabled">>], Body)
    end,
    %% echo the settings back the way Telnyx does, so the round trip is tested
    rep({'ok', 200, [], kz_json:encode(kz_json:from_list([{<<"data">>, Body}]))});
req('post', ["addresses"], [], Body) ->
    %% v2 requires a name and a country on any emergency-capable address
    'true' = is_binary(kz_json:get_ne_binary_value(<<"business_name">>, Body)),
    <<"US">> = kz_json:get_value(<<"country_code">>, Body),
    case kz_json:get_ne_binary_value(<<"street_address">>, Body) of
        <<"301 MARINA BLVD">> ->
            <<"SAN FRANCISCO">> = kz_json:get_value(<<"locality">>, Body),
            <<"CA">> = kz_json:get_value(<<"administrative_area">>, Body),
            rep_fixture("telnyx2_create_address.json");
        <<"1 MARKET ST">> ->
            rep_fixture("telnyx2_create_address2.json")
    end;
req('post', ["phone_numbers", "1293384261075731499", "actions", "enable_emergency"], [], Body) ->
    %% emergency_address_id is required even when disabling
    'true' = is_binary(kz_json:get_ne_binary_value(<<"emergency_address_id">>, Body)),
    case kz_json:is_true(<<"emergency_enabled">>, Body) of
        'true' -> rep_fixture("telnyx2_enable_emergency.json");
        'false' -> rep_fixture("telnyx2_disable_emergency.json")
    end;
req('delete', ["addresses", AddressId], [], _)
  when AddressId =:= "1293384261075731501";
       AddressId =:= "1293384261075731502" ->
    rep_fixture("telnyx2_delete_address.json").

rep_fixture(Fixture) ->
    rep({'ok', 200, [], list_to_binary(knm_util:fixture(Fixture))}).

is_cnam_char(C) when $0 =< C, C =< $9 -> 'true';
is_cnam_char(C) when $A =< C, C =< $Z -> 'true';
is_cnam_char(C) when $a =< C, C =< $z -> 'true';
is_cnam_char(C) -> $\s =:= C.

-else.

-spec req(atom(), [nonempty_string()], kz_term:proplist(), kz_json:object()) -> kz_json:object().
req('get'=_Method, Path, Query, EmptyJObj) ->
    Url = url(Path, Query),
    Headers = http_headers(EmptyJObj),
    ?DEBUG_APPEND("Request:~n~s ~s~n~p~n", [_Method, Url, Headers]),
    rep(kz_http:get(Url, Headers, http_options()));
req('delete'=_Method, Path, Query, EmptyJObj) ->
    Url = url(Path, Query),
    Headers = http_headers(EmptyJObj),
    ?DEBUG_APPEND("Request:~n~s ~s~n~p~n", [_Method, Url, Headers]),
    rep(kz_http:delete(Url, Headers, <<>>, http_options()));
req(Method, Path, Query, JObj)
  when Method =:= 'post';
       Method =:= 'put';
       Method =:= 'patch' ->
    Url = url(Path, Query),
    Headers = http_headers(JObj),
    Body = kz_json:encode(JObj),
    ?DEBUG_APPEND("Request:~n~s ~s~n~p~n~s~n", [Method, Url, Headers, Body]),
    rep(kz_http:req(Method, Url, Headers, Body, http_options())).

-spec url([nonempty_string()], kz_term:proplist()) -> nonempty_string().
url(Path, []) -> ?URL(Path);
url(Path, Query) ->
    ?URL(Path) ++ "?" ++ binary_to_list(query_string(Query)).

http_headers(BodyJObj) ->
    [{"Accept", "application/json"}
    ,{"Authorization", "Bearer " ++ binary_to_list(?TOKEN)}
    ,{"User-Agent", ?KNM_USER_AGENT}
     | [{"Content-Type", "application/json"} || not kz_json:is_empty(BodyJObj)]
    ].

http_options() ->
    [{'ssl', [{'verify', 'verify_none'}]}
    ,{'timeout', 180 * ?MILLISECONDS_IN_SECOND}
    ,{'connect_timeout', 180 * ?MILLISECONDS_IN_SECOND}
    ].
-endif.

%%% Internals

%%------------------------------------------------------------------------------
%% @doc Render Telnyx's bracketed filter syntax.
%%
%% Nested proplists become `filter%5Bphone_number%5D%5Bstarts_with%5D=…', and
%% `undefined' values drop out, so callers can pass optional filters through
%% unconditionally.
%% @end
%%------------------------------------------------------------------------------
-spec query_string(kz_term:proplist()) -> binary().
query_string(Query) ->
    kz_http_util:props_to_querystring(Query, #{'return' => 'binary'}).

-spec rep(kz_http:ret()) -> kz_json:object().
rep({'ok', Code, _Headers, <<"{",_/binary>>=Response})
  when Code =:= 200;
       Code =:= 201;
       Code =:= 202 ->
    ?DEBUG_APPEND("Response:~n~p~n~p~n~s~n", [Code, _Headers, Response]),
    maybe_filter_rates(kz_json:decode(Response));
rep({'ok', Code, _Headers, _Response}) ->
    ?DEBUG_APPEND("Response:~n~p~n~p~n~s~n", [Code, _Headers, _Response]),
    Reason = http_code(Code),
    lager:warning("request error: ~p (~s)", [Code, Reason]),
    lager:debug("response: ~s", [_Response]),
    knm_errors:by_carrier(?CARRIER, Reason, 'undefined');
rep({'error', R}=_E) ->
    lager:warning("request error: ~p", [_E]),
    knm_errors:by_carrier(?CARRIER, kz_term:to_binary(R), 'undefined').

-spec http_code(pos_integer()) -> atom().
http_code(400) -> 'bad_request';
http_code(401) -> 'unauthenticated';
http_code(403) -> 'unauthorized';
http_code(404) -> 'not_found';
http_code(422) -> 'unprocessable_entity';
http_code(Code) when Code >= 500 -> 'server_error';
http_code(_Code) -> 'empty_response'.

%%------------------------------------------------------------------------------
%% @doc Drop search results that are not priced the way the system expects.
%%
%% v2 reports pricing per result under `cost_information', and as strings
%% rather than the floats v1 put at the top level.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_filter_rates(kz_json:object()) -> kz_json:object().
maybe_filter_rates(JObj) -> maybe_filter_rates(JObj, ?SHOULD_FILTER_RATES).

-spec maybe_filter_rates(kz_json:object(), boolean()) -> kz_json:object().
maybe_filter_rates(JObj, 'false') -> JObj;
maybe_filter_rates(JObj, 'true') ->
    UpfrontCost = kapps_config:get_float(?MOD_CONFIG_CAT, <<"upfront_cost">>, 1.0),
    MonthlyCost = kapps_config:get_float(?MOD_CONFIG_CAT, <<"monthly_cost">>, 1.0),
    case kz_json:get_list_value(<<"data">>, JObj) of
        'undefined' -> JObj;
        Data ->
            Results = [Result
                       || Result <- Data,
                          cost(Result, <<"upfront_cost">>) == UpfrontCost,
                          cost(Result, <<"monthly_cost">>) == MonthlyCost
                      ],
            lager:debug("kept ~p of ~p results after rate filtering", [length(Results), length(Data)]),
            kz_json:set_value(<<"data">>, Results, JObj)
    end.

-spec cost(kz_json:object(), kz_term:ne_binary()) -> float() | 'undefined'.
cost(Result, Key) ->
    case kz_json:get_ne_binary_value([<<"cost_information">>, Key], Result) of
        'undefined' -> 'undefined';
        Cost -> kz_term:to_float(Cost)
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec maybe_add_connection(kz_json:object()) -> kz_json:object().
maybe_add_connection(JObj) ->
    case ?CONNECTION_ID of
        'undefined' -> JObj;
        ConnectionId -> kz_json:set_value(<<"connection_id">>, ConnectionId, JObj)
    end.

-spec maybe_add_messaging_profile(kz_json:object()) -> kz_json:object().
maybe_add_messaging_profile(JObj) ->
    case ?MESSAGING_PROFILE_ID of
        'undefined' -> JObj;
        ProfileId -> kz_json:set_value(<<"messaging_profile_id">>, ProfileId, JObj)
    end.

%%% End of Module
