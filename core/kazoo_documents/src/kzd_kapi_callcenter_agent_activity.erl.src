%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_agent_activity' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_agent_activity).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([activity/1, activity/2, set_activity/2]).
-export([agent_id/1, agent_id/2, set_agent_id/2]).
-export([call_id/1, call_id/2, set_call_id/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([queue_call/1, queue_call/2, set_queue_call/2]).
-export([timestamp/1, timestamp/2, set_timestamp/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.agent_activity">>).

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

-spec activity(doc()) -> kz_term:api_binary().
activity(Doc) ->
    activity(Doc, 'undefined').

-spec activity(doc(), Default) -> binary() | Default.
activity(Doc, Default) ->
    kz_json:get_binary_value([<<"Activity">>], Doc, Default).

-spec set_activity(doc(), binary()) -> doc().
set_activity(Doc, Activity) ->
    kz_json:set_value([<<"Activity">>], Activity, Doc).

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

-spec queue_call(doc()) -> kz_term:api_boolean().
queue_call(Doc) ->
    queue_call(Doc, 'undefined').

-spec queue_call(doc(), Default) -> boolean() | Default.
queue_call(Doc, Default) ->
    kz_json:get_boolean_value([<<"Queue_Call">>], Doc, Default).

-spec set_queue_call(doc(), boolean()) -> doc().
set_queue_call(Doc, QueueCall) ->
    kz_json:set_value([<<"Queue_Call">>], QueueCall, Doc).

-spec timestamp(doc()) -> kz_term:api_integer().
timestamp(Doc) ->
    timestamp(Doc, 'undefined').

-spec timestamp(doc(), Default) -> integer() | Default.
timestamp(Doc, Default) ->
    kz_json:get_integer_value([<<"Timestamp">>], Doc, Default).

-spec set_timestamp(doc(), integer()) -> doc().
set_timestamp(Doc, Timestamp) ->
    kz_json:set_value([<<"Timestamp">>], Timestamp, Doc).
