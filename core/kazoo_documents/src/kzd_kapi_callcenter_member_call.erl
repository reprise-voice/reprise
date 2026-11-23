%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_member_call' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_member_call).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([call/1, call/2, set_call/2]).
-export([caller_id_name/1, caller_id_name/2, set_caller_id_name/2]).
-export([caller_id_number/1, caller_id_number/2, set_caller_id_number/2]).
-export([callflow_node/1, callflow_node/2, set_callflow_node/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([joined_timestamp/1, joined_timestamp/2, set_joined_timestamp/2]).
-export([priority/1, priority/2, set_priority/2]).
-export([queue_id/1, queue_id/2, set_queue_id/2]).
-export([shard_count/1, shard_count/2, set_shard_count/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.member_call">>).

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

-spec call(doc()) -> kz_term:api_object().
call(Doc) ->
    call(Doc, 'undefined').

-spec call(doc(), Default) -> kz_json:object() | Default.
call(Doc, Default) ->
    kz_json:get_json_value([<<"Call">>], Doc, Default).

-spec set_call(doc(), kz_json:object()) -> doc().
set_call(Doc, Call) ->
    kz_json:set_value([<<"Call">>], Call, Doc).

-spec caller_id_name(doc()) -> kz_term:api_binary().
caller_id_name(Doc) ->
    caller_id_name(Doc, 'undefined').

-spec caller_id_name(doc(), Default) -> binary() | Default.
caller_id_name(Doc, Default) ->
    kz_json:get_binary_value([<<"Caller_ID_Name">>], Doc, Default).

-spec set_caller_id_name(doc(), binary()) -> doc().
set_caller_id_name(Doc, CallerIdName) ->
    kz_json:set_value([<<"Caller_ID_Name">>], CallerIdName, Doc).

-spec caller_id_number(doc()) -> kz_term:api_binary().
caller_id_number(Doc) ->
    caller_id_number(Doc, 'undefined').

-spec caller_id_number(doc(), Default) -> binary() | Default.
caller_id_number(Doc, Default) ->
    kz_json:get_binary_value([<<"Caller_ID_Number">>], Doc, Default).

-spec set_caller_id_number(doc(), binary()) -> doc().
set_caller_id_number(Doc, CallerIdNumber) ->
    kz_json:set_value([<<"Caller_ID_Number">>], CallerIdNumber, Doc).

-spec callflow_node(doc()) -> kz_term:api_binary().
callflow_node(Doc) ->
    callflow_node(Doc, 'undefined').

-spec callflow_node(doc(), Default) -> binary() | Default.
callflow_node(Doc, Default) ->
    kz_json:get_binary_value([<<"Callflow_Node">>], Doc, Default).

-spec set_callflow_node(doc(), binary()) -> doc().
set_callflow_node(Doc, CallflowNode) ->
    kz_json:set_value([<<"Callflow_Node">>], CallflowNode, Doc).

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

-spec priority(doc()) -> integer().
priority(Doc) ->
    priority(Doc, 0).

-spec priority(doc(), Default) -> integer() | Default.
priority(Doc, Default) ->
    kz_json:get_integer_value([<<"Priority">>], Doc, Default).

-spec set_priority(doc(), integer()) -> doc().
set_priority(Doc, Priority) ->
    kz_json:set_value([<<"Priority">>], Priority, Doc).

-spec queue_id(doc()) -> kz_term:api_binary().
queue_id(Doc) ->
    queue_id(Doc, 'undefined').

-spec queue_id(doc(), Default) -> binary() | Default.
queue_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Queue_ID">>], Doc, Default).

-spec set_queue_id(doc(), binary()) -> doc().
set_queue_id(Doc, QueueId) ->
    kz_json:set_value([<<"Queue_ID">>], QueueId, Doc).

-spec shard_count(doc()) -> kz_term:api_integer().
shard_count(Doc) ->
    shard_count(Doc, 'undefined').

-spec shard_count(doc(), Default) -> integer() | Default.
shard_count(Doc, Default) ->
    kz_json:get_integer_value([<<"Shard_Count">>], Doc, Default).

-spec set_shard_count(doc(), integer()) -> doc().
set_shard_count(Doc, ShardCount) ->
    kz_json:set_value([<<"Shard_Count">>], ShardCount, Doc).
