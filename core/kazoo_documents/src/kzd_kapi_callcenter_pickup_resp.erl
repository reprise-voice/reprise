%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_pickup_resp' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_pickup_resp).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([call_id/1, call_id/2, set_call_id/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([node/1, node/2, set_node/2]).
-export([offer_timeout/1, offer_timeout/2, set_offer_timeout/2]).
-export([reason/1, reason/2, set_reason/2]).
-export([result/1, result/2, set_result/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.pickup_resp">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec account_id(doc()) -> kz_term:api_binary().
account_id(Doc) ->
    account_id(Doc, 'undefined').

-spec account_id(doc(), Default) -> binary() | Default.
account_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Account_ID">>], Doc, Default).

-spec set_account_id(doc(), binary()) -> doc().
set_account_id(Doc, AccountId) ->
    kz_json:set_value([<<"Account_ID">>], AccountId, Doc).

-spec call_id(doc()) -> kz_term:api_binary().
call_id(Doc) ->
    call_id(Doc, 'undefined').

-spec call_id(doc(), Default) -> binary() | Default.
call_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Call_ID">>], Doc, Default).

-spec set_call_id(doc(), binary()) -> doc().
set_call_id(Doc, CallId) ->
    kz_json:set_value([<<"Call_ID">>], CallId, Doc).

-spec event_category(doc()) -> kz_term:api_binary().
event_category(Doc) ->
    event_category(Doc, 'undefined').

-spec event_category(doc(), Default) -> binary() | Default.
event_category(Doc, Default) ->
    kz_json:get_binary_value([<<"Event_Category">>], Doc, Default).

-spec set_event_category(doc(), binary()) -> doc().
set_event_category(Doc, EventCategory) ->
    kz_json:set_value([<<"Event_Category">>], EventCategory, Doc).

-spec event_name(doc()) -> kz_term:api_binary().
event_name(Doc) ->
    event_name(Doc, 'undefined').

-spec event_name(doc(), Default) -> binary() | Default.
event_name(Doc, Default) ->
    kz_json:get_binary_value([<<"Event_Name">>], Doc, Default).

-spec set_event_name(doc(), binary()) -> doc().
set_event_name(Doc, EventName) ->
    kz_json:set_value([<<"Event_Name">>], EventName, Doc).

-spec node(doc()) -> kz_term:api_binary().
node(Doc) ->
    node(Doc, 'undefined').

-spec node(doc(), Default) -> binary() | Default.
node(Doc, Default) ->
    kz_json:get_binary_value([<<"Node">>], Doc, Default).

-spec set_node(doc(), binary()) -> doc().
set_node(Doc, Node) ->
    kz_json:set_value([<<"Node">>], Node, Doc).

-spec offer_timeout(doc()) -> kz_term:api_integer().
offer_timeout(Doc) ->
    offer_timeout(Doc, 'undefined').

-spec offer_timeout(doc(), Default) -> integer() | Default.
offer_timeout(Doc, Default) ->
    kz_json:get_integer_value([<<"Offer_Timeout">>], Doc, Default).

-spec set_offer_timeout(doc(), integer()) -> doc().
set_offer_timeout(Doc, OfferTimeout) ->
    kz_json:set_value([<<"Offer_Timeout">>], OfferTimeout, Doc).

-spec reason(doc()) -> kz_term:api_binary().
reason(Doc) ->
    reason(Doc, 'undefined').

-spec reason(doc(), Default) -> binary() | Default.
reason(Doc, Default) ->
    kz_json:get_binary_value([<<"Reason">>], Doc, Default).

-spec set_reason(doc(), binary()) -> doc().
set_reason(Doc, Reason) ->
    kz_json:set_value([<<"Reason">>], Reason, Doc).

-spec result(doc()) -> kz_term:api_binary().
result(Doc) ->
    result(Doc, 'undefined').

-spec result(doc(), Default) -> binary() | Default.
result(Doc, Default) ->
    kz_json:get_binary_value([<<"Result">>], Doc, Default).

-spec set_result(doc(), binary()) -> doc().
set_result(Doc, Result) ->
    kz_json:set_value([<<"Result">>], Result, Doc).
