%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2025, 2600Hz
%%% (C) 2026, Vonix LLC
%%% @doc A Number Manager module for carrier: telnyx.com, API v2.
%%%
%%% Telnyx stopped serving the v1 (`/origination') endpoints that
%%% {@link knm_telnyx} talks to on accounts created after the v2 cutover, so
%%% newer accounts need this module instead. The two can coexist: they read
%%% separate config sections (`number_manager.telnyx' vs
%%% `number_manager.telnyx2') and are selected per number by `pvt_module_name'.
%%% @end
%%%-----------------------------------------------------------------------------
-module(knm_telnyx2).
-behaviour(knm_gen_carrier).

-export([info/0]).
-export([is_local/0]).
-export([find_numbers/3]).
-export([acquire_number/1]).
-export([disconnect_number/1]).
-export([is_number_billable/1]).
-export([should_lookup_cnam/0]).
-export([check_numbers/1]).

-include("knm.hrl").

-define(MOD_CONFIG_CAT, <<(?KNM_CONFIG_CAT)/binary, ".telnyx2">>).

-define(IS_SANDBOX_PROVISIONING_TRUE
       ,kapps_config:get_is_true(?MOD_CONFIG_CAT, <<"sandbox_provisioning">>, 'false')
       ).
-define(IS_PROVISIONING_ENABLED
       ,kapps_config:get_is_true(?MOD_CONFIG_CAT, <<"enable_provisioning">>, 'true')
       ).
-define(SHOULD_KEEP_BEST_EFFORT
       ,kapps_config:get_is_true(?MOD_CONFIG_CAT, <<"should_keep_best_effort">>, 'false')
       ).

%% A number order is asynchronous: it comes back `pending' and settles into
%% `success' or `failure'. Poll rather than leave the number in limbo, but
%% give up instead of blocking the caller forever on a stuck order.
-ifdef(TEST).
-define(ORDER_POLL_INTERVAL, 1).
-else.
-define(ORDER_POLL_INTERVAL
       ,kapps_config:get_integer(?MOD_CONFIG_CAT, <<"order_poll_interval_ms">>, 2 * ?MILLISECONDS_IN_SECOND)
       ).
-endif.
-define(ORDER_POLL_ATTEMPTS
       ,kapps_config:get_integer(?MOD_CONFIG_CAT, <<"order_poll_attempts">>, 10)
       ).

%%% API

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec info() -> map().
info() ->
    #{?CARRIER_INFO_MAX_PREFIX => 3
     }.

%%------------------------------------------------------------------------------
%% @doc Is this carrier handling numbers local to the system?
%%
%% <div class="notice">A non-local (foreign) carrier module makes HTTP requests.</div>
%% @end
%%------------------------------------------------------------------------------
-spec is_local() -> boolean().
is_local() -> 'false'.

-spec is_number_billable(knm_phone_number:pn_record()) -> 'true'.
is_number_billable(_PN) -> 'true'.

%%------------------------------------------------------------------------------
%% @doc Check with carrier if these numbers are registered with it.
%% @end
%%------------------------------------------------------------------------------
-spec check_numbers(kz_term:ne_binaries()) -> {'ok', kz_json:object()} |
          {'error', any()}.
check_numbers(_Numbers) -> {'error', 'not_implemented'}.

%%------------------------------------------------------------------------------
%% @doc Query the system for a quantity of available numbers in a rate center
%% @end
%%------------------------------------------------------------------------------
-spec find_numbers(kz_term:ne_binary(), pos_integer(), knm_search:options()) ->
          {'ok', knm_search:results()}.
find_numbers(<<"+1", NPA:3/binary, _/binary>>=Num, Quantity, Options)
  when ?IS_US_TOLLFREE(NPA) ->
    Results = search_numbers('tollfree', Quantity, NPA, get_nxx(Num)),
    {'ok', format_search_resp(Results, Options)};

find_numbers(<<"+1", NPA:3/binary, _/binary>>=Num, Quantity, Options) ->
    Results = search_numbers('npa', Quantity, NPA, get_nxx(Num)),
    {'ok', format_search_resp(Results, Options)};

find_numbers(<<"+",_/binary>>=_InternationalNum, Quantity, Options) ->
    Country = knm_search:country(Options),
    Results = search_numbers('region', Quantity, Country, 'undefined'),
    {'ok', format_search_resp(Results, Options)}.

%%------------------------------------------------------------------------------
%% @doc For a given Number, parse out the NXX value.
%% Return `undefined' if the NXX value can not be parsed.
%% @end
%%------------------------------------------------------------------------------
-spec get_nxx(kz_term:ne_binary()) -> kz_term:api_ne_binary().
get_nxx(<<_PlusOneAreaCode:5/binary, NXX:3/binary, _/binary>>) -> NXX;
get_nxx(_) -> 'undefined'.

%%------------------------------------------------------------------------------
%% @doc Acquire a given number from the carrier
%% @end
%%------------------------------------------------------------------------------
-spec acquire_number(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
acquire_number(PN) ->
    Debug = ?IS_SANDBOX_PROVISIONING_TRUE,
    case ?IS_PROVISIONING_ENABLED of
        'false' when Debug ->
            lager:debug("allowing sandbox provisioning"),
            PN;
        'false' ->
            knm_errors:unspecified('provisioning_disabled', PN);
        'true' ->
            Num = knm_phone_number:number(PN),
            Req = knm_telnyx2_util:maybe_add_connection(
                    knm_telnyx2_util:maybe_add_messaging_profile(
                      kz_json:from_list(
                        [{<<"phone_numbers">>
                         ,[kz_json:from_list([{<<"phone_number">>, Num}])]
                         }
                        ]))),
            Rep = knm_telnyx2_util:req('post', ["number_orders"], Req),
            case order_id(Rep) of
                'undefined' ->
                    lager:debug("order failure: ~s", [kz_json:encode(Rep)]),
                    knm_errors:by_carrier(?MODULE, order_error(Rep), Num);
                OrderId ->
                    check_order(PN, OrderId, order_status(Rep), ?ORDER_POLL_ATTEMPTS)
            end
    end.

-spec order_id(kz_json:object()) -> kz_term:api_ne_binary().
order_id(Rep) ->
    kz_json:get_ne_binary_value([<<"data">>, <<"id">>], Rep).

-spec order_status(kz_json:object()) -> kz_term:api_ne_binary().
order_status(Rep) ->
    kz_json:get_ne_binary_value([<<"data">>, <<"status">>], Rep).

%%------------------------------------------------------------------------------
%% @doc Poll a `pending' order until Telnyx settles it.
%% @end
%%------------------------------------------------------------------------------
-spec check_order(knm_phone_number:pn_record(), kz_term:ne_binary(), kz_term:api_ne_binary(), non_neg_integer()) ->
          knm_phone_number:pn_record().
check_order(PN, OrderId, <<"success">>, _Attempts) ->
    lager:debug("number order ~s succeeded", [OrderId]),
    Data = kz_json:from_list([{<<"order_id">>, OrderId}]),
    knm_phone_number:update_carrier_data(PN, Data);

check_order(PN, OrderId, <<"failure">>, _Attempts) ->
    lager:debug("number order ~s failed", [OrderId]),
    knm_errors:by_carrier(?MODULE, <<"order_failed">>, PN);

check_order(PN, OrderId, <<"pending">>, Attempts) when Attempts > 0 ->
    timer:sleep(?ORDER_POLL_INTERVAL),
    Rep = knm_telnyx2_util:req('get', ["number_orders", kz_term:to_list(OrderId)]),
    case order_id(Rep) of
        'undefined' ->
            lager:debug("could not read back order ~s: ~s", [OrderId, kz_json:encode(Rep)]),
            knm_errors:by_carrier(?MODULE, order_error(Rep), PN);
        _OrderId ->
            check_order(PN, OrderId, order_status(Rep), Attempts - 1)
    end;

check_order(PN, OrderId, <<"pending">>, _NoAttemptsLeft) ->
    lager:warning("number order ~s still pending after ~p polls", [OrderId, ?ORDER_POLL_ATTEMPTS]),
    knm_errors:by_carrier(?MODULE, <<"order_pending">>, PN);

check_order(PN, OrderId, Status, _Attempts) ->
    lager:debug("number order ~s in unhandled state ~p", [OrderId, Status]),
    knm_errors:by_carrier(?MODULE, <<"order_failed">>, PN).

-spec order_error(kz_json:object()) -> kz_term:ne_binary().
order_error(Rep) ->
    case kz_json:get_list_value(<<"errors">>, Rep) of
        [Error|_] ->
            kz_json:get_ne_binary_value(<<"detail">>, Error, <<"unknown_error">>);
        _ ->
            kz_json:get_ne_binary_value(<<"message">>, Rep, <<"unknown_error">>)
    end.

%%------------------------------------------------------------------------------
%% @doc Release a number from the routing table
%% @end
%%------------------------------------------------------------------------------
-spec disconnect_number(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
disconnect_number(PN) ->
    Debug = ?IS_SANDBOX_PROVISIONING_TRUE,
    case ?IS_PROVISIONING_ENABLED of
        'true' -> PN;
        'false' when Debug ->
            lager:debug("allowing sandbox provisioning"),
            PN;
        'false' ->
            knm_errors:unspecified('provisioning_disabled', PN)
    end.

-spec should_lookup_cnam() -> boolean().
should_lookup_cnam() -> 'true'.

%%% Internals

-type kind() :: 'npa' | 'tollfree' | 'region'.

-spec search_numbers(kind(), pos_integer(), kz_term:ne_binary(), kz_term:api_ne_binary()) ->
          kz_json:objects().
search_numbers(SearchKind, Quantity, Prefix, NXX) ->
    Query = [{<<"filter">>, search_filter(SearchKind, Quantity, Prefix, NXX)}],
    Rep = knm_telnyx2_util:req('get', ["available_phone_numbers"], Query, kz_json:new()),
    kz_json:get_list_value(<<"data">>, Rep, []).

%%------------------------------------------------------------------------------
%% @doc Build the `filter[…]' proplist for a search.
%%
%% `undefined' entries are dropped by the query-string encoder, so the optional
%% NXX can be threaded through unconditionally.
%% @end
%%------------------------------------------------------------------------------
-spec search_filter(kind(), pos_integer(), kz_term:ne_binary(), kz_term:api_ne_binary()) ->
          kz_term:proplist().
search_filter(SearchKind, Quantity, Prefix, NXX) ->
    [{<<"limit">>, Quantity}
    ,{<<"best_effort">>, ?SHOULD_KEEP_BEST_EFFORT}
     | starts_with(NXX) ++ search_prefix(SearchKind, Prefix)
    ].

%% @doc `starts_with' is matched against the number after the NDC, so it only
%% makes sense once an NXX has been parsed out of the request.
-spec starts_with(kz_term:api_ne_binary()) -> kz_term:proplist().
starts_with('undefined') -> [];
starts_with(NXX) -> [{<<"phone_number">>, [{<<"starts_with">>, NXX}]}].

-spec search_prefix(kind(), kz_term:ne_binary()) -> kz_term:proplist().
search_prefix('tollfree', NPA) ->
    [{<<"phone_number_type">>, <<"toll_free">>}
    ,{<<"national_destination_code">>, NPA}
    ];
search_prefix('npa', NPA) ->
    [{<<"phone_number_type">>, <<"local">>}
    ,{<<"national_destination_code">>, NPA}
    ];
search_prefix('region', Country) ->
    [{<<"country_code">>, Country}].

%%------------------------------------------------------------------------------
%% @doc Unlike v1, v2 returns real E.164 numbers for every search kind — the
%% international search no longer hands back bare prefixes to pad out.
%% @end
%%------------------------------------------------------------------------------
-spec format_search_resp(kz_json:objects(), knm_search:options()) -> knm_search:results().
format_search_resp(JObjs, Options) ->
    QID = knm_search:query_id(Options),
    [{QID, {Num, ?MODULE, ?NUMBER_STATE_DISCOVERY, Data}}
     || Data <- JObjs,
        Num <- [kz_json:get_ne_binary_value(<<"phone_number">>, Data)],
        'undefined' =/= Num
    ].

%%% End of Module
