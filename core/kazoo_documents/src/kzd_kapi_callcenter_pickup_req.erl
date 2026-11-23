%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_pickup_req' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_pickup_req).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([call_id/1, call_id/2, set_call_id/2]).
-export([deadline_ms/1, deadline_ms/2, set_deadline_ms/2]).
-export([device_ids/1, device_ids/2, set_device_ids/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([queue_id/1, queue_id/2, set_queue_id/2]).
-export([supervisor_id/1, supervisor_id/2, set_supervisor_id/2]).
-export([target_id/1, target_id/2, set_target_id/2]).
-export([target_type/1, target_type/2, set_target_type/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.pickup_req">>).

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

-spec deadline_ms(doc()) -> kz_term:api_integer().
deadline_ms(Doc) ->
    deadline_ms(Doc, 'undefined').

-spec deadline_ms(doc(), Default) -> integer() | Default.
deadline_ms(Doc, Default) ->
    kz_json:get_integer_value([<<"Deadline_Ms">>], Doc, Default).

-spec set_deadline_ms(doc(), integer()) -> doc().
set_deadline_ms(Doc, DeadlineMs) ->
    kz_json:set_value([<<"Deadline_Ms">>], DeadlineMs, Doc).

-spec device_ids(doc()) -> kz_term:api_ne_binaries().
device_ids(Doc) ->
    device_ids(Doc, 'undefined').

-spec device_ids(doc(), Default) -> kz_term:ne_binaries() | Default.
device_ids(Doc, Default) ->
    kz_json:get_list_value([<<"Device_IDs">>], Doc, Default).

-spec set_device_ids(doc(), kz_term:ne_binaries()) -> doc().
set_device_ids(Doc, DeviceIds) ->
    kz_json:set_value([<<"Device_IDs">>], DeviceIds, Doc).

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

-spec queue_id(doc()) -> kz_term:api_binary().
queue_id(Doc) ->
    queue_id(Doc, 'undefined').

-spec queue_id(doc(), Default) -> binary() | Default.
queue_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Queue_ID">>], Doc, Default).

-spec set_queue_id(doc(), binary()) -> doc().
set_queue_id(Doc, QueueId) ->
    kz_json:set_value([<<"Queue_ID">>], QueueId, Doc).

-spec supervisor_id(doc()) -> kz_term:api_binary().
supervisor_id(Doc) ->
    supervisor_id(Doc, 'undefined').

-spec supervisor_id(doc(), Default) -> binary() | Default.
supervisor_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Supervisor_ID">>], Doc, Default).

-spec set_supervisor_id(doc(), binary()) -> doc().
set_supervisor_id(Doc, SupervisorId) ->
    kz_json:set_value([<<"Supervisor_ID">>], SupervisorId, Doc).

-spec target_id(doc()) -> kz_term:api_binary().
target_id(Doc) ->
    target_id(Doc, 'undefined').

-spec target_id(doc(), Default) -> binary() | Default.
target_id(Doc, Default) ->
    kz_json:get_binary_value([<<"Target_ID">>], Doc, Default).

-spec set_target_id(doc(), binary()) -> doc().
set_target_id(Doc, TargetId) ->
    kz_json:set_value([<<"Target_ID">>], TargetId, Doc).

-spec target_type(doc()) -> kz_term:api_binary().
target_type(Doc) ->
    target_type(Doc, 'undefined').

-spec target_type(doc(), Default) -> binary() | Default.
target_type(Doc, Default) ->
    kz_json:get_binary_value([<<"Target_Type">>], Doc, Default).

-spec set_target_type(doc(), binary()) -> doc().
set_target_type(Doc, TargetType) ->
    kz_json:set_value([<<"Target_Type">>], TargetType, Doc).
