%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_agent_offer' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_agent_offer).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([agent_id/1, agent_id/2, set_agent_id/2]).
-export([call_id/1, call_id/2, set_call_id/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([offer_timeout/1, offer_timeout/2, set_offer_timeout/2]).
-export([queue_id/1, queue_id/2, set_queue_id/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.agent_offer">>).

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

-spec agent_id(doc()) -> kz_term:api_binary().
agent_id(Doc) ->
    agent_id(Doc, 'undefined').

-spec agent_id(doc(), Default) -> binary() | Default.
agent_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Agent_ID">>], Doc, Default).

-spec set_agent_id(doc(), binary()) -> doc().
set_agent_id(Doc, AgentId) ->
    kz_json:set_value([<<"Agent_ID">>], AgentId, Doc).

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

-spec offer_timeout(doc()) -> kz_term:api_integer().
offer_timeout(Doc) ->
    offer_timeout(Doc, 'undefined').

-spec offer_timeout(doc(), Default) -> integer() | Default.
offer_timeout(Doc, Default) ->
    kz_json:get_integer_value([<<"Offer_Timeout">>], Doc, Default).

-spec set_offer_timeout(doc(), integer()) -> doc().
set_offer_timeout(Doc, OfferTimeout) ->
    kz_json:set_value([<<"Offer_Timeout">>], OfferTimeout, Doc).

-spec queue_id(doc()) -> kz_term:api_binary().
queue_id(Doc) ->
    queue_id(Doc, 'undefined').

-spec queue_id(doc(), Default) -> binary() | Default.
queue_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Queue_ID">>], Doc, Default).

-spec set_queue_id(doc(), binary()) -> doc().
set_queue_id(Doc, QueueId) ->
    kz_json:set_value([<<"Queue_ID">>], QueueId, Doc).
