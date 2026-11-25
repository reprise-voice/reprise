%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_status_resp' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_status_resp).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([node/1, node/2, set_node/2]).
-export([on_queue_call/1, on_queue_call/2, set_on_queue_call/2]).
-export([queues/1, queues/2, set_queues/2]).
-export([shard/1, shard/2, set_shard/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.status_resp">>).

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

-spec on_queue_call(doc()) -> kz_term:api_ne_binaries().
on_queue_call(Doc) ->
    on_queue_call(Doc, 'undefined').

-spec on_queue_call(doc(), Default) -> kz_term:ne_binaries() | Default.
on_queue_call(Doc, Default) ->
    kz_json:get_list_value([<<"On_Queue_Call">>], Doc, Default).

-spec set_on_queue_call(doc(), kz_term:ne_binaries()) -> doc().
set_on_queue_call(Doc, OnQueueCall) ->
    kz_json:set_value([<<"On_Queue_Call">>], OnQueueCall, Doc).

-spec queues(doc()) -> kz_term:api_objects().
queues(Doc) ->
    queues(Doc, 'undefined').

-spec queues(doc(), Default) -> kz_json:objects() | Default.
queues(Doc, Default) ->
    kz_json:get_list_value([<<"Queues">>], Doc, Default).

-spec set_queues(doc(), kz_json:objects()) -> doc().
set_queues(Doc, Queues) ->
    kz_json:set_value([<<"Queues">>], Queues, Doc).

-spec shard(doc()) -> kz_term:api_integer().
shard(Doc) ->
    shard(Doc, 'undefined').

-spec shard(doc(), Default) -> integer() | Default.
shard(Doc, Default) ->
    kz_json:get_integer_value([<<"Shard">>], Doc, Default).

-spec set_shard(doc(), integer()) -> doc().
set_shard(Doc, Shard) ->
    kz_json:set_value([<<"Shard">>], Shard, Doc).
