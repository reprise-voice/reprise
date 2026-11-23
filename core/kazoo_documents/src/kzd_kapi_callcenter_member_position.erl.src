%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_member_position' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_member_position).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([agents_available/1, agents_available/2, set_agents_available/2]).
-export([call_id/1, call_id/2, set_call_id/2]).
-export([caller_id_name/1, caller_id_name/2, set_caller_id_name/2]).
-export([caller_id_number/1, caller_id_number/2, set_caller_id_number/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([joined_timestamp/1, joined_timestamp/2, set_joined_timestamp/2]).
-export([media_node/1, media_node/2, set_media_node/2]).
-export([offered/1, offered/2, set_offered/2]).
-export([position/1, position/2, set_position/2]).
-export([queue_id/1, queue_id/2, set_queue_id/2]).
-export([timestamp/1, timestamp/2, set_timestamp/2]).
-export([waiting/1, waiting/2, set_waiting/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.member_position">>).

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

-spec agents_available(doc()) -> kz_term:api_integer().
agents_available(Doc) ->
    agents_available(Doc, 'undefined').

-spec agents_available(doc(), Default) -> integer() | Default.
agents_available(Doc, Default) ->
    kz_json:get_integer_value([<<"Agents_Available">>], Doc, Default).

-spec set_agents_available(doc(), integer()) -> doc().
set_agents_available(Doc, AgentsAvailable) ->
    kz_json:set_value([<<"Agents_Available">>], AgentsAvailable, Doc).

-spec call_id(doc()) -> kz_term:api_binary().
call_id(Doc) ->
    call_id(Doc, 'undefined').

-spec call_id(doc(), Default) -> binary() | Default.
call_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Call_ID">>], Doc, Default).

-spec set_call_id(doc(), binary()) -> doc().
set_call_id(Doc, CallId) ->
    kz_json:set_value([<<"Call_ID">>], CallId, Doc).

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

-spec media_node(doc()) -> kz_term:api_binary().
media_node(Doc) ->
    media_node(Doc, 'undefined').

-spec media_node(doc(), Default) -> binary() | Default.
media_node(Doc, Default) ->
    kz_json:get_binary_value([<<"Media_Node">>], Doc, Default).

-spec set_media_node(doc(), binary()) -> doc().
set_media_node(Doc, MediaNode) ->
    kz_json:set_value([<<"Media_Node">>], MediaNode, Doc).

-spec offered(doc()) -> kz_term:api_boolean().
offered(Doc) ->
    offered(Doc, 'undefined').

-spec offered(doc(), Default) -> boolean() | Default.
offered(Doc, Default) ->
    kz_json:get_boolean_value([<<"Offered">>], Doc, Default).

-spec set_offered(doc(), boolean()) -> doc().
set_offered(Doc, Offered) ->
    kz_json:set_value([<<"Offered">>], Offered, Doc).

-spec position(doc()) -> kz_term:api_integer().
position(Doc) ->
    position(Doc, 'undefined').

-spec position(doc(), Default) -> integer() | Default.
position(Doc, Default) ->
    kz_json:get_integer_value([<<"Position">>], Doc, Default).

-spec set_position(doc(), integer()) -> doc().
set_position(Doc, Position) ->
    kz_json:set_value([<<"Position">>], Position, Doc).

-spec queue_id(doc()) -> kz_term:api_binary().
queue_id(Doc) ->
    queue_id(Doc, 'undefined').

-spec queue_id(doc(), Default) -> binary() | Default.
queue_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Queue_ID">>], Doc, Default).

-spec set_queue_id(doc(), binary()) -> doc().
set_queue_id(Doc, QueueId) ->
    kz_json:set_value([<<"Queue_ID">>], QueueId, Doc).

-spec timestamp(doc()) -> kz_term:api_integer().
timestamp(Doc) ->
    timestamp(Doc, 'undefined').

-spec timestamp(doc(), Default) -> integer() | Default.
timestamp(Doc, Default) ->
    kz_json:get_integer_value([<<"Timestamp">>], Doc, Default).

-spec set_timestamp(doc(), integer()) -> doc().
set_timestamp(Doc, Timestamp) ->
    kz_json:set_value([<<"Timestamp">>], Timestamp, Doc).

-spec waiting(doc()) -> kz_term:api_integer().
waiting(Doc) ->
    waiting(Doc, 'undefined').

-spec waiting(doc(), Default) -> integer() | Default.
waiting(Doc, Default) ->
    kz_json:get_integer_value([<<"Waiting">>], Doc, Default).

-spec set_waiting(doc(), integer()) -> doc().
set_waiting(Doc, Waiting) ->
    kz_json:set_value([<<"Waiting">>], Waiting, Doc).
