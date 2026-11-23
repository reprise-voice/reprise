%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `callcenter_agent' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_callcenter_agent).

-export([new/0]).
-export([agent_id/1, agent_id/2, set_agent_id/2]).
-export([availability/1, availability/2, set_availability/2]).
-export([break_ends/1, break_ends/2, set_break_ends/2]).
-export([counters/1, counters/2, set_counters/2]).
-export([counters_calls_answered/1, counters_calls_answered/2, set_counters_calls_answered/2]).
-export([counters_last_call_end/1, counters_last_call_end/2, set_counters_last_call_end/2]).
-export([counters_missed/1, counters_missed/2, set_counters_missed/2]).
-export([counters_talk_time_s/1, counters_talk_time_s/2, set_counters_talk_time_s/2]).
-export([presence_id/1, presence_id/2, set_presence_id/2]).
-export([previous/1, previous/2, set_previous/2]).
-export([source/1, source/2, set_source/2]).
-export([timestamp/1, timestamp/2, set_timestamp/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"callcenter_agent">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec agent_id(doc()) -> kz_term:api_binary().
agent_id(Doc) ->
    agent_id(Doc, 'undefined').

-spec agent_id(doc(), Default) -> binary() | Default.
agent_id(Doc, Default) ->
    kz_json:get_binary_value([<<"agent_id">>], Doc, Default).

-spec set_agent_id(doc(), binary()) -> doc().
set_agent_id(Doc, AgentId) ->
    kz_json:set_value([<<"agent_id">>], AgentId, Doc).

-spec availability(doc()) -> binary().
availability(Doc) ->
    availability(Doc, <<"logged_out">>).

-spec availability(doc(), Default) -> binary() | Default.
availability(Doc, Default) ->
    kz_json:get_binary_value([<<"availability">>], Doc, Default).

-spec set_availability(doc(), binary()) -> doc().
set_availability(Doc, Availability) ->
    kz_json:set_value([<<"availability">>], Availability, Doc).

-spec break_ends(doc()) -> kz_term:api_integer().
break_ends(Doc) ->
    break_ends(Doc, 'undefined').

-spec break_ends(doc(), Default) -> integer() | Default.
break_ends(Doc, Default) ->
    kz_json:get_integer_value([<<"break_ends">>], Doc, Default).

-spec set_break_ends(doc(), integer()) -> doc().
set_break_ends(Doc, BreakEnds) ->
    kz_json:set_value([<<"break_ends">>], BreakEnds, Doc).

-spec counters(doc()) -> kz_json:object().
counters(Doc) ->
    counters(Doc, kz_json:new()).

-spec counters(doc(), Default) -> kz_json:object() | Default.
counters(Doc, Default) ->
    kz_json:get_json_value([<<"counters">>], Doc, Default).

-spec set_counters(doc(), kz_json:object()) -> doc().
set_counters(Doc, Counters) ->
    kz_json:set_value([<<"counters">>], Counters, Doc).

-spec counters_calls_answered(doc()) -> integer().
counters_calls_answered(Doc) ->
    counters_calls_answered(Doc, 0).

-spec counters_calls_answered(doc(), Default) -> integer() | Default.
counters_calls_answered(Doc, Default) ->
    kz_json:get_integer_value([<<"counters">>, <<"calls_answered">>], Doc, Default).

-spec set_counters_calls_answered(doc(), integer()) -> doc().
set_counters_calls_answered(Doc, CountersCallsAnswered) ->
    kz_json:set_value([<<"counters">>, <<"calls_answered">>], CountersCallsAnswered, Doc).

-spec counters_last_call_end(doc()) -> kz_term:api_integer().
counters_last_call_end(Doc) ->
    counters_last_call_end(Doc, 'undefined').

-spec counters_last_call_end(doc(), Default) -> integer() | Default.
counters_last_call_end(Doc, Default) ->
    kz_json:get_integer_value([<<"counters">>, <<"last_call_end">>], Doc, Default).

-spec set_counters_last_call_end(doc(), integer()) -> doc().
set_counters_last_call_end(Doc, CountersLastCallEnd) ->
    kz_json:set_value([<<"counters">>, <<"last_call_end">>], CountersLastCallEnd, Doc).

-spec counters_missed(doc()) -> integer().
counters_missed(Doc) ->
    counters_missed(Doc, 0).

-spec counters_missed(doc(), Default) -> integer() | Default.
counters_missed(Doc, Default) ->
    kz_json:get_integer_value([<<"counters">>, <<"missed">>], Doc, Default).

-spec set_counters_missed(doc(), integer()) -> doc().
set_counters_missed(Doc, CountersMissed) ->
    kz_json:set_value([<<"counters">>, <<"missed">>], CountersMissed, Doc).

-spec counters_talk_time_s(doc()) -> integer().
counters_talk_time_s(Doc) ->
    counters_talk_time_s(Doc, 0).

-spec counters_talk_time_s(doc(), Default) -> integer() | Default.
counters_talk_time_s(Doc, Default) ->
    kz_json:get_integer_value([<<"counters">>, <<"talk_time_s">>], Doc, Default).

-spec set_counters_talk_time_s(doc(), integer()) -> doc().
set_counters_talk_time_s(Doc, CountersTalkTimeS) ->
    kz_json:set_value([<<"counters">>, <<"talk_time_s">>], CountersTalkTimeS, Doc).

-spec presence_id(doc()) -> kz_term:api_binary().
presence_id(Doc) ->
    presence_id(Doc, 'undefined').

-spec presence_id(doc(), Default) -> binary() | Default.
presence_id(Doc, Default) ->
    kz_json:get_binary_value([<<"presence_id">>], Doc, Default).

-spec set_presence_id(doc(), binary()) -> doc().
set_presence_id(Doc, PresenceId) ->
    kz_json:set_value([<<"presence_id">>], PresenceId, Doc).

-spec previous(doc()) -> kz_term:api_binary().
previous(Doc) ->
    previous(Doc, 'undefined').

-spec previous(doc(), Default) -> binary() | Default.
previous(Doc, Default) ->
    kz_json:get_binary_value([<<"previous">>], Doc, Default).

-spec set_previous(doc(), binary()) -> doc().
set_previous(Doc, Previous) ->
    kz_json:set_value([<<"previous">>], Previous, Doc).

-spec source(doc()) -> kz_term:api_binary().
source(Doc) ->
    source(Doc, 'undefined').

-spec source(doc(), Default) -> binary() | Default.
source(Doc, Default) ->
    kz_json:get_binary_value([<<"source">>], Doc, Default).

-spec set_source(doc(), binary()) -> doc().
set_source(Doc, Source) ->
    kz_json:set_value([<<"source">>], Source, Doc).

-spec timestamp(doc()) -> kz_term:api_integer().
timestamp(Doc) ->
    timestamp(Doc, 'undefined').

-spec timestamp(doc(), Default) -> integer() | Default.
timestamp(Doc, Default) ->
    kz_json:get_integer_value([<<"timestamp">>], Doc, Default).

-spec set_timestamp(doc(), integer()) -> doc().
set_timestamp(Doc, Timestamp) ->
    kz_json:set_value([<<"timestamp">>], Timestamp, Doc).
