%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_agent_availability' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_agent_availability).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([agent_id/1, agent_id/2, set_agent_id/2]).
-export([availability/1, availability/2, set_availability/2]).
-export([break_ends/1, break_ends/2, set_break_ends/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([previous/1, previous/2, set_previous/2]).
-export([source/1, source/2, set_source/2]).
-export([timestamp/1, timestamp/2, set_timestamp/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.agent_availability">>).

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

-spec availability(doc()) -> kz_term:api_binary().
availability(Doc) ->
    availability(Doc, 'undefined').

-spec availability(doc(), Default) -> binary() | Default.
availability(Doc, Default) ->
    kz_json:get_binary_value([<<"Availability">>], Doc, Default).

-spec set_availability(doc(), binary()) -> doc().
set_availability(Doc, Availability) ->
    kz_json:set_value([<<"Availability">>], Availability, Doc).

-spec break_ends(doc()) -> kz_term:api_integer().
break_ends(Doc) ->
    break_ends(Doc, 'undefined').

-spec break_ends(doc(), Default) -> integer() | Default.
break_ends(Doc, Default) ->
    kz_json:get_integer_value([<<"Break_Ends">>], Doc, Default).

-spec set_break_ends(doc(), integer()) -> doc().
set_break_ends(Doc, BreakEnds) ->
    kz_json:set_value([<<"Break_Ends">>], BreakEnds, Doc).

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

-spec previous(doc()) -> kz_term:api_binary().
previous(Doc) ->
    previous(Doc, 'undefined').

-spec previous(doc(), Default) -> binary() | Default.
previous(Doc, Default) ->
    kz_json:get_binary_value([<<"Previous">>], Doc, Default).

-spec set_previous(doc(), binary()) -> doc().
set_previous(Doc, Previous) ->
    kz_json:set_value([<<"Previous">>], Previous, Doc).

-spec source(doc()) -> kz_term:api_binary().
source(Doc) ->
    source(Doc, 'undefined').

-spec source(doc(), Default) -> binary() | Default.
source(Doc, Default) ->
    kz_json:get_binary_value([<<"Source">>], Doc, Default).

-spec set_source(doc(), binary()) -> doc().
set_source(Doc, Source) ->
    kz_json:set_value([<<"Source">>], Source, Doc).

-spec timestamp(doc()) -> kz_term:api_integer().
timestamp(Doc) ->
    timestamp(Doc, 'undefined').

-spec timestamp(doc(), Default) -> integer() | Default.
timestamp(Doc, Default) ->
    kz_json:get_integer_value([<<"Timestamp">>], Doc, Default).

-spec set_timestamp(doc(), integer()) -> doc().
set_timestamp(Doc, Timestamp) ->
    kz_json:set_value([<<"Timestamp">>], Timestamp, Doc).
