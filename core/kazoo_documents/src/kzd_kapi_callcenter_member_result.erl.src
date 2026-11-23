%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_member_result' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_member_result).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([agent_call_id/1, agent_call_id/2, set_agent_call_id/2]).
-export([agent_id/1, agent_id/2, set_agent_id/2]).
-export([call_id/1, call_id/2, set_call_id/2]).
-export([ended_timestamp/1, ended_timestamp/2, set_ended_timestamp/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([joined_timestamp/1, joined_timestamp/2, set_joined_timestamp/2]).
-export([queue_id/1, queue_id/2, set_queue_id/2]).
-export([result/1, result/2, set_result/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.member_result">>).

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

-spec agent_call_id(doc()) -> kz_term:api_binary().
agent_call_id(Doc) ->
    agent_call_id(Doc, 'undefined').

-spec agent_call_id(doc(), Default) -> binary() | Default.
agent_call_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Agent_Call_ID">>], Doc, Default).

-spec set_agent_call_id(doc(), binary()) -> doc().
set_agent_call_id(Doc, AgentCallId) ->
    kz_json:set_value([<<"Agent_Call_ID">>], AgentCallId, Doc).

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

-spec ended_timestamp(doc()) -> kz_term:api_integer().
ended_timestamp(Doc) ->
    ended_timestamp(Doc, 'undefined').

-spec ended_timestamp(doc(), Default) -> integer() | Default.
ended_timestamp(Doc, Default) ->
    kz_json:get_integer_value([<<"Ended_Timestamp">>], Doc, Default).

-spec set_ended_timestamp(doc(), integer()) -> doc().
set_ended_timestamp(Doc, EndedTimestamp) ->
    kz_json:set_value([<<"Ended_Timestamp">>], EndedTimestamp, Doc).

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

-spec joined_timestamp(doc()) -> kz_term:api_integer().
joined_timestamp(Doc) ->
    joined_timestamp(Doc, 'undefined').

-spec joined_timestamp(doc(), Default) -> integer() | Default.
joined_timestamp(Doc, Default) ->
    kz_json:get_integer_value([<<"Joined_Timestamp">>], Doc, Default).

-spec set_joined_timestamp(doc(), integer()) -> doc().
set_joined_timestamp(Doc, JoinedTimestamp) ->
    kz_json:set_value([<<"Joined_Timestamp">>], JoinedTimestamp, Doc).

-spec queue_id(doc()) -> kz_term:api_binary().
queue_id(Doc) ->
    queue_id(Doc, 'undefined').

-spec queue_id(doc(), Default) -> binary() | Default.
queue_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Queue_ID">>], Doc, Default).

-spec set_queue_id(doc(), binary()) -> doc().
set_queue_id(Doc, QueueId) ->
    kz_json:set_value([<<"Queue_ID">>], QueueId, Doc).

-spec result(doc()) -> kz_term:api_binary().
result(Doc) ->
    result(Doc, 'undefined').

-spec result(doc(), Default) -> binary() | Default.
result(Doc, Default) ->
    kz_json:get_binary_value([<<"Result">>], Doc, Default).

-spec set_result(doc(), binary()) -> doc().
set_result(Doc, Result) ->
    kz_json:set_value([<<"Result">>], Result, Doc).
