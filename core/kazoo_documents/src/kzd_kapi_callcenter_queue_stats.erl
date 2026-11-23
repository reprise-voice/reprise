%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_callcenter_queue_stats' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_callcenter_queue_stats).

-export([new/0]).
-export([account_id/1, account_id/2, set_account_id/2]).
-export([agents_available/1, agents_available/2, set_agents_available/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([longest_wait/1, longest_wait/2, set_longest_wait/2]).
-export([queue_id/1, queue_id/2, set_queue_id/2]).
-export([timestamp/1, timestamp/2, set_timestamp/2]).
-export([waiting/1, waiting/2, set_waiting/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.callcenter.queue_stats">>).

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

-spec longest_wait(doc()) -> kz_term:api_integer().
longest_wait(Doc) ->
    longest_wait(Doc, 'undefined').

-spec longest_wait(doc(), Default) -> integer() | Default.
longest_wait(Doc, Default) ->
    kz_json:get_integer_value([<<"Longest_Wait">>], Doc, Default).

-spec set_longest_wait(doc(), integer()) -> doc().
set_longest_wait(Doc, LongestWait) ->
    kz_json:set_value([<<"Longest_Wait">>], LongestWait, Doc).

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
