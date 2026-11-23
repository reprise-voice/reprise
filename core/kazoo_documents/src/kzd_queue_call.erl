%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `queue_call' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_queue_call).

-export([new/0]).
-export([agent_call_id/1, agent_call_id/2, set_agent_call_id/2]).
-export([agent_id/1, agent_id/2, set_agent_id/2]).
-export([answered/1, answered/2, set_answered/2]).
-export([call_id/1, call_id/2, set_call_id/2]).
-export([caller_id_name/1, caller_id_name/2, set_caller_id_name/2]).
-export([caller_id_number/1, caller_id_number/2, set_caller_id_number/2]).
-export([cancel_reason/1, cancel_reason/2, set_cancel_reason/2]).
-export([cancelled/1, cancelled/2, set_cancelled/2]).
-export([ended/1, ended/2, set_ended/2]).
-export([joined/1, joined/2, set_joined/2]).
-export([offered_to/1, offered_to/2, set_offered_to/2]).
-export([picked_up/1, picked_up/2, set_picked_up/2]).
-export([queue_id/1, queue_id/2, set_queue_id/2]).
-export([recording/1, recording/2, set_recording/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"queue_call">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec agent_call_id(doc()) -> kz_term:api_binary().
agent_call_id(Doc) ->
    agent_call_id(Doc, 'undefined').

-spec agent_call_id(doc(), Default) -> binary() | Default.
agent_call_id(Doc, Default) ->
    kz_json:get_binary_value([<<"agent_call_id">>], Doc, Default).

-spec set_agent_call_id(doc(), binary()) -> doc().
set_agent_call_id(Doc, AgentCallId) ->
    kz_json:set_value([<<"agent_call_id">>], AgentCallId, Doc).

-spec agent_id(doc()) -> kz_term:api_binary().
agent_id(Doc) ->
    agent_id(Doc, 'undefined').

-spec agent_id(doc(), Default) -> binary() | Default.
agent_id(Doc, Default) ->
    kz_json:get_binary_value([<<"agent_id">>], Doc, Default).

-spec set_agent_id(doc(), binary()) -> doc().
set_agent_id(Doc, AgentId) ->
    kz_json:set_value([<<"agent_id">>], AgentId, Doc).

-spec answered(doc()) -> kz_term:api_integer().
answered(Doc) ->
    answered(Doc, 'undefined').

-spec answered(doc(), Default) -> integer() | Default.
answered(Doc, Default) ->
    kz_json:get_integer_value([<<"answered">>], Doc, Default).

-spec set_answered(doc(), integer()) -> doc().
set_answered(Doc, Answered) ->
    kz_json:set_value([<<"answered">>], Answered, Doc).

-spec call_id(doc()) -> kz_term:api_binary().
call_id(Doc) ->
    call_id(Doc, 'undefined').

-spec call_id(doc(), Default) -> binary() | Default.
call_id(Doc, Default) ->
    kz_json:get_binary_value([<<"call_id">>], Doc, Default).

-spec set_call_id(doc(), binary()) -> doc().
set_call_id(Doc, CallId) ->
    kz_json:set_value([<<"call_id">>], CallId, Doc).

-spec caller_id_name(doc()) -> kz_term:api_binary().
caller_id_name(Doc) ->
    caller_id_name(Doc, 'undefined').

-spec caller_id_name(doc(), Default) -> binary() | Default.
caller_id_name(Doc, Default) ->
    kz_json:get_binary_value([<<"caller_id_name">>], Doc, Default).

-spec set_caller_id_name(doc(), binary()) -> doc().
set_caller_id_name(Doc, CallerIdName) ->
    kz_json:set_value([<<"caller_id_name">>], CallerIdName, Doc).

-spec caller_id_number(doc()) -> kz_term:api_binary().
caller_id_number(Doc) ->
    caller_id_number(Doc, 'undefined').

-spec caller_id_number(doc(), Default) -> binary() | Default.
caller_id_number(Doc, Default) ->
    kz_json:get_binary_value([<<"caller_id_number">>], Doc, Default).

-spec set_caller_id_number(doc(), binary()) -> doc().
set_caller_id_number(Doc, CallerIdNumber) ->
    kz_json:set_value([<<"caller_id_number">>], CallerIdNumber, Doc).

-spec cancel_reason(doc()) -> kz_term:api_binary().
cancel_reason(Doc) ->
    cancel_reason(Doc, 'undefined').

-spec cancel_reason(doc(), Default) -> binary() | Default.
cancel_reason(Doc, Default) ->
    kz_json:get_binary_value([<<"cancel_reason">>], Doc, Default).

-spec set_cancel_reason(doc(), binary()) -> doc().
set_cancel_reason(Doc, CancelReason) ->
    kz_json:set_value([<<"cancel_reason">>], CancelReason, Doc).

-spec cancelled(doc()) -> kz_term:api_integer().
cancelled(Doc) ->
    cancelled(Doc, 'undefined').

-spec cancelled(doc(), Default) -> integer() | Default.
cancelled(Doc, Default) ->
    kz_json:get_integer_value([<<"cancelled">>], Doc, Default).

-spec set_cancelled(doc(), integer()) -> doc().
set_cancelled(Doc, Cancelled) ->
    kz_json:set_value([<<"cancelled">>], Cancelled, Doc).

-spec ended(doc()) -> kz_term:api_integer().
ended(Doc) ->
    ended(Doc, 'undefined').

-spec ended(doc(), Default) -> integer() | Default.
ended(Doc, Default) ->
    kz_json:get_integer_value([<<"ended">>], Doc, Default).

-spec set_ended(doc(), integer()) -> doc().
set_ended(Doc, Ended) ->
    kz_json:set_value([<<"ended">>], Ended, Doc).

-spec joined(doc()) -> kz_term:api_integer().
joined(Doc) ->
    joined(Doc, 'undefined').

-spec joined(doc(), Default) -> integer() | Default.
joined(Doc, Default) ->
    kz_json:get_integer_value([<<"joined">>], Doc, Default).

-spec set_joined(doc(), integer()) -> doc().
set_joined(Doc, Joined) ->
    kz_json:set_value([<<"joined">>], Joined, Doc).

-spec offered_to(doc()) -> kz_json:objects().
offered_to(Doc) ->
    offered_to(Doc, []).

-spec offered_to(doc(), Default) -> kz_json:objects() | Default.
offered_to(Doc, Default) ->
    kz_json:get_list_value([<<"offered_to">>], Doc, Default).

-spec set_offered_to(doc(), kz_json:objects()) -> doc().
set_offered_to(Doc, OfferedTo) ->
    kz_json:set_value([<<"offered_to">>], OfferedTo, Doc).

-spec picked_up(doc()) -> kz_term:api_boolean().
picked_up(Doc) ->
    picked_up(Doc, 'undefined').

-spec picked_up(doc(), Default) -> boolean() | Default.
picked_up(Doc, Default) ->
    kz_json:get_boolean_value([<<"picked_up">>], Doc, Default).

-spec set_picked_up(doc(), boolean()) -> doc().
set_picked_up(Doc, PickedUp) ->
    kz_json:set_value([<<"picked_up">>], PickedUp, Doc).

-spec queue_id(doc()) -> kz_term:api_binary().
queue_id(Doc) ->
    queue_id(Doc, 'undefined').

-spec queue_id(doc(), Default) -> binary() | Default.
queue_id(Doc, Default) ->
    kz_json:get_binary_value([<<"queue_id">>], Doc, Default).

-spec set_queue_id(doc(), binary()) -> doc().
set_queue_id(Doc, QueueId) ->
    kz_json:set_value([<<"queue_id">>], QueueId, Doc).

-spec recording(doc()) -> kz_term:api_binary().
recording(Doc) ->
    recording(Doc, 'undefined').

-spec recording(doc(), Default) -> binary() | Default.
recording(Doc, Default) ->
    kz_json:get_binary_value([<<"recording">>], Doc, Default).

-spec set_recording(doc(), binary()) -> doc().
set_recording(Doc, Recording) ->
    kz_json:set_value([<<"recording">>], Recording, Doc).
