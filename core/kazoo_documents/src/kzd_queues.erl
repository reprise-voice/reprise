%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2025, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_queues).

-export([new/0]).
-export([agent_no_answer_status/1, agent_no_answer_status/2, set_agent_no_answer_status/2]).
-export([agent_ring_timeout/1, agent_ring_timeout/2, set_agent_ring_timeout/2]).
-export([agent_wrapup_time/1, agent_wrapup_time/2, set_agent_wrapup_time/2]).
-export([agents/1, agents/2, set_agents/2]).
-export([announce/1, announce/2, set_announce/2]).
-export([announce_interval/1, announce_interval/2, set_announce_interval/2]).
-export([announce_media/1, announce_media/2, set_announce_media/2]).
-export([announce_position/1, announce_position/2, set_announce_position/2]).
-export([announcements/1, announcements/2, set_announcements/2]).
-export([announcements_media/1, announcements_media/2, set_announcements_media/2]).
-export([announcements_media_in_the_queue/1, announcements_media_in_the_queue/2, set_announcements_media_in_the_queue/2]).
-export([announcements_media_you_are_at_position/1, announcements_media_you_are_at_position/2, set_announcements_media_you_are_at_position/2]).
-export([cid_prefix/1, cid_prefix/2, set_cid_prefix/2]).
-export([enter_when_empty/1, enter_when_empty/2, set_enter_when_empty/2]).
-export([exit_keys/1, exit_keys/2, set_exit_keys/2]).
-export([greeting/1, greeting/2, set_greeting/2]).
-export([max_queue_size/1, max_queue_size/2, set_max_queue_size/2]).
-export([max_wait_time/1, max_wait_time/2, set_max_wait_time/2]).
-export([max_wait_time_with_no_agent/1, max_wait_time_with_no_agent/2, set_max_wait_time_with_no_agent/2]).
-export([max_wait_time_with_no_agent_time_reached/1, max_wait_time_with_no_agent_time_reached/2, set_max_wait_time_with_no_agent_time_reached/2]).
-export([moh/1, moh/2, set_moh/2]).
-export([name/1, name/2, set_name/2]).
-export([outbound_caller_id/1, outbound_caller_id/2, set_outbound_caller_id/2]).
-export([outbound_caller_id_name/1, outbound_caller_id_name/2, set_outbound_caller_id_name/2]).
-export([outbound_caller_id_number/1, outbound_caller_id_number/2, set_outbound_caller_id_number/2]).
-export([record/1, record/2, set_record/2]).
-export([ring_simultaneously/1, ring_simultaneously/2, set_ring_simultaneously/2]).
-export([skip_agents_with_external_calls/1, skip_agents_with_external_calls/2, set_skip_agents_with_external_calls/2]).
-export([strategy/1, strategy/2, set_strategy/2]).
-export([tier_rules/1, tier_rules/2, set_tier_rules/2]).
-export([tier_rules_apply/1, tier_rules_apply/2, set_tier_rules_apply/2]).
-export([tier_rules_no_agent_no_wait/1, tier_rules_no_agent_no_wait/2, set_tier_rules_no_agent_no_wait/2]).
-export([tier_rules_wait_multiply_level/1, tier_rules_wait_multiply_level/2, set_tier_rules_wait_multiply_level/2]).
-export([tier_rules_wait_seconds/1, tier_rules_wait_seconds/2, set_tier_rules_wait_seconds/2]).
-export([time_base_score/1, time_base_score/2, set_time_base_score/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"queues">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec agent_no_answer_status(doc()) -> binary().
agent_no_answer_status(Doc) ->
    agent_no_answer_status(Doc, <<"on_break">>).

-spec agent_no_answer_status(doc(), Default) -> binary() | Default.
agent_no_answer_status(Doc, Default) ->
    kz_json:get_binary_value([<<"agent_no_answer_status">>], Doc, Default).

-spec set_agent_no_answer_status(doc(), binary()) -> doc().
set_agent_no_answer_status(Doc, AgentNoAnswerStatus) ->
    kz_json:set_value([<<"agent_no_answer_status">>], AgentNoAnswerStatus, Doc).

-spec agent_ring_timeout(doc()) -> integer().
agent_ring_timeout(Doc) ->
    agent_ring_timeout(Doc, 15).

-spec agent_ring_timeout(doc(), Default) -> integer() | Default.
agent_ring_timeout(Doc, Default) ->
    kz_json:get_integer_value([<<"agent_ring_timeout">>], Doc, Default).

-spec set_agent_ring_timeout(doc(), integer()) -> doc().
set_agent_ring_timeout(Doc, AgentRingTimeout) ->
    kz_json:set_value([<<"agent_ring_timeout">>], AgentRingTimeout, Doc).

-spec agent_wrapup_time(doc()) -> integer().
agent_wrapup_time(Doc) ->
    agent_wrapup_time(Doc, 0).

-spec agent_wrapup_time(doc(), Default) -> integer() | Default.
agent_wrapup_time(Doc, Default) ->
    kz_json:get_integer_value([<<"agent_wrapup_time">>], Doc, Default).

-spec set_agent_wrapup_time(doc(), integer()) -> doc().
set_agent_wrapup_time(Doc, AgentWrapupTime) ->
    kz_json:set_value([<<"agent_wrapup_time">>], AgentWrapupTime, Doc).

-spec agents(doc()) -> kz_json:objects().
agents(Doc) ->
    agents(Doc, []).

-spec agents(doc(), Default) -> kz_json:objects() | Default.
agents(Doc, Default) ->
    kz_json:get_list_value([<<"agents">>], Doc, Default).

-spec set_agents(doc(), kz_json:objects()) -> doc().
set_agents(Doc, Agents) ->
    kz_json:set_value([<<"agents">>], Agents, Doc).

-spec announce(doc()) -> kz_json:object().
announce(Doc) ->
    announce(Doc, kz_json:new()).

-spec announce(doc(), Default) -> kz_json:object() | Default.
announce(Doc, Default) ->
    kz_json:get_json_value([<<"announce">>], Doc, Default).

-spec set_announce(doc(), kz_json:object()) -> doc().
set_announce(Doc, Announce) ->
    kz_json:set_value([<<"announce">>], Announce, Doc).

-spec announce_interval(doc()) -> integer().
announce_interval(Doc) ->
    announce_interval(Doc, 30).

-spec announce_interval(doc(), Default) -> integer() | Default.
announce_interval(Doc, Default) ->
    kz_json:get_integer_value([<<"announce">>, <<"interval">>], Doc, Default).

-spec set_announce_interval(doc(), integer()) -> doc().
set_announce_interval(Doc, AnnounceInterval) ->
    kz_json:set_value([<<"announce">>, <<"interval">>], AnnounceInterval, Doc).

-spec announce_media(doc()) -> kz_term:api_binary().
announce_media(Doc) ->
    announce_media(Doc, 'undefined').

-spec announce_media(doc(), Default) -> binary() | Default.
announce_media(Doc, Default) ->
    kz_json:get_binary_value([<<"announce">>, <<"media">>], Doc, Default).

-spec set_announce_media(doc(), binary()) -> doc().
set_announce_media(Doc, AnnounceMedia) ->
    kz_json:set_value([<<"announce">>, <<"media">>], AnnounceMedia, Doc).

-spec announce_position(doc()) -> boolean().
announce_position(Doc) ->
    announce_position(Doc, 'false').

-spec announce_position(doc(), Default) -> boolean() | Default.
announce_position(Doc, Default) ->
    kz_json:get_boolean_value([<<"announce">>, <<"position">>], Doc, Default).

-spec set_announce_position(doc(), boolean()) -> doc().
set_announce_position(Doc, AnnouncePosition) ->
    kz_json:set_value([<<"announce">>, <<"position">>], AnnouncePosition, Doc).

-spec announcements(doc()) -> kz_term:api_object().
announcements(Doc) ->
    announcements(Doc, 'undefined').

-spec announcements(doc(), Default) -> kz_json:object() | Default.
announcements(Doc, Default) ->
    kz_json:get_json_value([<<"announcements">>], Doc, Default).

-spec set_announcements(doc(), kz_json:object()) -> doc().
set_announcements(Doc, Announcements) ->
    kz_json:set_value([<<"announcements">>], Announcements, Doc).

-spec announcements_media(doc()) -> kz_term:api_object().
announcements_media(Doc) ->
    announcements_media(Doc, 'undefined').

-spec announcements_media(doc(), Default) -> kz_json:object() | Default.
announcements_media(Doc, Default) ->
    kz_json:get_json_value([<<"announcements">>, <<"media">>], Doc, Default).

-spec set_announcements_media(doc(), kz_json:object()) -> doc().
set_announcements_media(Doc, AnnouncementsMedia) ->
    kz_json:set_value([<<"announcements">>, <<"media">>], AnnouncementsMedia, Doc).

-spec announcements_media_in_the_queue(doc()) -> kz_term:api_binary().
announcements_media_in_the_queue(Doc) ->
    announcements_media_in_the_queue(Doc, 'undefined').

-spec announcements_media_in_the_queue(doc(), Default) -> binary() | Default.
announcements_media_in_the_queue(Doc, Default) ->
    kz_json:get_binary_value([<<"announcements">>, <<"media">>, <<"in_the_queue">>], Doc, Default).

-spec set_announcements_media_in_the_queue(doc(), binary()) -> doc().
set_announcements_media_in_the_queue(Doc, AnnouncementsMediaInTheQueue) ->
    kz_json:set_value([<<"announcements">>, <<"media">>, <<"in_the_queue">>], AnnouncementsMediaInTheQueue, Doc).

-spec announcements_media_you_are_at_position(doc()) -> kz_term:api_binary().
announcements_media_you_are_at_position(Doc) ->
    announcements_media_you_are_at_position(Doc, 'undefined').

-spec announcements_media_you_are_at_position(doc(), Default) -> binary() | Default.
announcements_media_you_are_at_position(Doc, Default) ->
    kz_json:get_binary_value([<<"announcements">>, <<"media">>, <<"you_are_at_position">>], Doc, Default).

-spec set_announcements_media_you_are_at_position(doc(), binary()) -> doc().
set_announcements_media_you_are_at_position(Doc, AnnouncementsMediaYouAreAtPosition) ->
    kz_json:set_value([<<"announcements">>, <<"media">>, <<"you_are_at_position">>], AnnouncementsMediaYouAreAtPosition, Doc).

-spec cid_prefix(doc()) -> kz_term:api_binary().
cid_prefix(Doc) ->
    cid_prefix(Doc, 'undefined').

-spec cid_prefix(doc(), Default) -> binary() | Default.
cid_prefix(Doc, Default) ->
    kz_json:get_binary_value([<<"cid_prefix">>], Doc, Default).

-spec set_cid_prefix(doc(), binary()) -> doc().
set_cid_prefix(Doc, CidPrefix) ->
    kz_json:set_value([<<"cid_prefix">>], CidPrefix, Doc).

-spec enter_when_empty(doc()) -> boolean().
enter_when_empty(Doc) ->
    enter_when_empty(Doc, 'true').

-spec enter_when_empty(doc(), Default) -> boolean() | Default.
enter_when_empty(Doc, Default) ->
    kz_json:get_boolean_value([<<"enter_when_empty">>], Doc, Default).

-spec set_enter_when_empty(doc(), boolean()) -> doc().
set_enter_when_empty(Doc, EnterWhenEmpty) ->
    kz_json:set_value([<<"enter_when_empty">>], EnterWhenEmpty, Doc).

-spec exit_keys(doc()) -> binary().
exit_keys(Doc) ->
    exit_keys(Doc, <<"#">>).

-spec exit_keys(doc(), Default) -> binary() | Default.
exit_keys(Doc, Default) ->
    kz_json:get_binary_value([<<"exit_keys">>], Doc, Default).

-spec set_exit_keys(doc(), binary()) -> doc().
set_exit_keys(Doc, ExitKeys) ->
    kz_json:set_value([<<"exit_keys">>], ExitKeys, Doc).

-spec greeting(doc()) -> kz_term:api_binary().
greeting(Doc) ->
    greeting(Doc, 'undefined').

-spec greeting(doc(), Default) -> binary() | Default.
greeting(Doc, Default) ->
    kz_json:get_binary_value([<<"greeting">>], Doc, Default).

-spec set_greeting(doc(), binary()) -> doc().
set_greeting(Doc, Greeting) ->
    kz_json:set_value([<<"greeting">>], Greeting, Doc).

-spec max_queue_size(doc()) -> integer().
max_queue_size(Doc) ->
    max_queue_size(Doc, 0).

-spec max_queue_size(doc(), Default) -> integer() | Default.
max_queue_size(Doc, Default) ->
    kz_json:get_integer_value([<<"max_queue_size">>], Doc, Default).

-spec set_max_queue_size(doc(), integer()) -> doc().
set_max_queue_size(Doc, MaxQueueSize) ->
    kz_json:set_value([<<"max_queue_size">>], MaxQueueSize, Doc).

-spec max_wait_time(doc()) -> integer().
max_wait_time(Doc) ->
    max_wait_time(Doc, 0).

-spec max_wait_time(doc(), Default) -> integer() | Default.
max_wait_time(Doc, Default) ->
    kz_json:get_integer_value([<<"max_wait_time">>], Doc, Default).

-spec set_max_wait_time(doc(), integer()) -> doc().
set_max_wait_time(Doc, MaxWaitTime) ->
    kz_json:set_value([<<"max_wait_time">>], MaxWaitTime, Doc).

-spec max_wait_time_with_no_agent(doc()) -> integer().
max_wait_time_with_no_agent(Doc) ->
    max_wait_time_with_no_agent(Doc, 0).

-spec max_wait_time_with_no_agent(doc(), Default) -> integer() | Default.
max_wait_time_with_no_agent(Doc, Default) ->
    kz_json:get_integer_value([<<"max_wait_time_with_no_agent">>], Doc, Default).

-spec set_max_wait_time_with_no_agent(doc(), integer()) -> doc().
set_max_wait_time_with_no_agent(Doc, MaxWaitTimeWithNoAgent) ->
    kz_json:set_value([<<"max_wait_time_with_no_agent">>], MaxWaitTimeWithNoAgent, Doc).

-spec max_wait_time_with_no_agent_time_reached(doc()) -> integer().
max_wait_time_with_no_agent_time_reached(Doc) ->
    max_wait_time_with_no_agent_time_reached(Doc, 5).

-spec max_wait_time_with_no_agent_time_reached(doc(), Default) -> integer() | Default.
max_wait_time_with_no_agent_time_reached(Doc, Default) ->
    kz_json:get_integer_value([<<"max_wait_time_with_no_agent_time_reached">>], Doc, Default).

-spec set_max_wait_time_with_no_agent_time_reached(doc(), integer()) -> doc().
set_max_wait_time_with_no_agent_time_reached(Doc, MaxWaitTimeWithNoAgentTimeReached) ->
    kz_json:set_value([<<"max_wait_time_with_no_agent_time_reached">>], MaxWaitTimeWithNoAgentTimeReached, Doc).

-spec moh(doc()) -> kz_term:api_binary().
moh(Doc) ->
    moh(Doc, 'undefined').

-spec moh(doc(), Default) -> binary() | Default.
moh(Doc, Default) ->
    kz_json:get_binary_value([<<"moh">>], Doc, Default).

-spec set_moh(doc(), binary()) -> doc().
set_moh(Doc, Moh) ->
    kz_json:set_value([<<"moh">>], Moh, Doc).

-spec name(doc()) -> kz_term:api_ne_binary().
name(Doc) ->
    name(Doc, 'undefined').

-spec name(doc(), Default) -> kz_term:ne_binary() | Default.
name(Doc, Default) ->
    kz_json:get_ne_binary_value([<<"name">>], Doc, Default).

-spec set_name(doc(), kz_term:ne_binary()) -> doc().
set_name(Doc, Name) ->
    kz_json:set_value([<<"name">>], Name, Doc).

-spec outbound_caller_id(doc()) -> kz_json:object().
outbound_caller_id(Doc) ->
    outbound_caller_id(Doc, kz_json:new()).

-spec outbound_caller_id(doc(), Default) -> kz_json:object() | Default.
outbound_caller_id(Doc, Default) ->
    kz_json:get_json_value([<<"outbound_caller_id">>], Doc, Default).

-spec set_outbound_caller_id(doc(), kz_json:object()) -> doc().
set_outbound_caller_id(Doc, OutboundCallerId) ->
    kz_json:set_value([<<"outbound_caller_id">>], OutboundCallerId, Doc).

-spec outbound_caller_id_name(doc()) -> kz_term:api_binary().
outbound_caller_id_name(Doc) ->
    outbound_caller_id_name(Doc, 'undefined').

-spec outbound_caller_id_name(doc(), Default) -> binary() | Default.
outbound_caller_id_name(Doc, Default) ->
    kz_json:get_binary_value([<<"outbound_caller_id">>, <<"name">>], Doc, Default).

-spec set_outbound_caller_id_name(doc(), binary()) -> doc().
set_outbound_caller_id_name(Doc, OutboundCallerIdName) ->
    kz_json:set_value([<<"outbound_caller_id">>, <<"name">>], OutboundCallerIdName, Doc).

-spec outbound_caller_id_number(doc()) -> kz_term:api_binary().
outbound_caller_id_number(Doc) ->
    outbound_caller_id_number(Doc, 'undefined').

-spec outbound_caller_id_number(doc(), Default) -> binary() | Default.
outbound_caller_id_number(Doc, Default) ->
    kz_json:get_binary_value([<<"outbound_caller_id">>, <<"number">>], Doc, Default).

-spec set_outbound_caller_id_number(doc(), binary()) -> doc().
set_outbound_caller_id_number(Doc, OutboundCallerIdNumber) ->
    kz_json:set_value([<<"outbound_caller_id">>, <<"number">>], OutboundCallerIdNumber, Doc).

-spec record(doc()) -> boolean().
record(Doc) ->
    record(Doc, 'false').

-spec record(doc(), Default) -> boolean() | Default.
record(Doc, Default) ->
    kz_json:get_boolean_value([<<"record">>], Doc, Default).

-spec set_record(doc(), boolean()) -> doc().
set_record(Doc, Record) ->
    kz_json:set_value([<<"record">>], Record, Doc).

-spec ring_simultaneously(doc()) -> integer().
ring_simultaneously(Doc) ->
    ring_simultaneously(Doc, 1).

-spec ring_simultaneously(doc(), Default) -> integer() | Default.
ring_simultaneously(Doc, Default) ->
    kz_json:get_integer_value([<<"ring_simultaneously">>], Doc, Default).

-spec set_ring_simultaneously(doc(), integer()) -> doc().
set_ring_simultaneously(Doc, RingSimultaneously) ->
    kz_json:set_value([<<"ring_simultaneously">>], RingSimultaneously, Doc).

-spec skip_agents_with_external_calls(doc()) -> boolean().
skip_agents_with_external_calls(Doc) ->
    skip_agents_with_external_calls(Doc, 'true').

-spec skip_agents_with_external_calls(doc(), Default) -> boolean() | Default.
skip_agents_with_external_calls(Doc, Default) ->
    kz_json:get_boolean_value([<<"skip_agents_with_external_calls">>], Doc, Default).

-spec set_skip_agents_with_external_calls(doc(), boolean()) -> doc().
set_skip_agents_with_external_calls(Doc, SkipAgentsWithExternalCalls) ->
    kz_json:set_value([<<"skip_agents_with_external_calls">>], SkipAgentsWithExternalCalls, Doc).

-spec strategy(doc()) -> binary().
strategy(Doc) ->
    strategy(Doc, <<"longest_idle">>).

-spec strategy(doc(), Default) -> binary() | Default.
strategy(Doc, Default) ->
    kz_json:get_binary_value([<<"strategy">>], Doc, Default).

-spec set_strategy(doc(), binary()) -> doc().
set_strategy(Doc, Strategy) ->
    kz_json:set_value([<<"strategy">>], Strategy, Doc).

-spec tier_rules(doc()) -> kz_json:object().
tier_rules(Doc) ->
    tier_rules(Doc, kz_json:new()).

-spec tier_rules(doc(), Default) -> kz_json:object() | Default.
tier_rules(Doc, Default) ->
    kz_json:get_json_value([<<"tier_rules">>], Doc, Default).

-spec set_tier_rules(doc(), kz_json:object()) -> doc().
set_tier_rules(Doc, TierRules) ->
    kz_json:set_value([<<"tier_rules">>], TierRules, Doc).

-spec tier_rules_apply(doc()) -> boolean().
tier_rules_apply(Doc) ->
    tier_rules_apply(Doc, 'false').

-spec tier_rules_apply(doc(), Default) -> boolean() | Default.
tier_rules_apply(Doc, Default) ->
    kz_json:get_boolean_value([<<"tier_rules">>, <<"apply">>], Doc, Default).

-spec set_tier_rules_apply(doc(), boolean()) -> doc().
set_tier_rules_apply(Doc, TierRulesApply) ->
    kz_json:set_value([<<"tier_rules">>, <<"apply">>], TierRulesApply, Doc).

-spec tier_rules_no_agent_no_wait(doc()) -> boolean().
tier_rules_no_agent_no_wait(Doc) ->
    tier_rules_no_agent_no_wait(Doc, 'true').

-spec tier_rules_no_agent_no_wait(doc(), Default) -> boolean() | Default.
tier_rules_no_agent_no_wait(Doc, Default) ->
    kz_json:get_boolean_value([<<"tier_rules">>, <<"no_agent_no_wait">>], Doc, Default).

-spec set_tier_rules_no_agent_no_wait(doc(), boolean()) -> doc().
set_tier_rules_no_agent_no_wait(Doc, TierRulesNoAgentNoWait) ->
    kz_json:set_value([<<"tier_rules">>, <<"no_agent_no_wait">>], TierRulesNoAgentNoWait, Doc).

-spec tier_rules_wait_multiply_level(doc()) -> boolean().
tier_rules_wait_multiply_level(Doc) ->
    tier_rules_wait_multiply_level(Doc, 'false').

-spec tier_rules_wait_multiply_level(doc(), Default) -> boolean() | Default.
tier_rules_wait_multiply_level(Doc, Default) ->
    kz_json:get_boolean_value([<<"tier_rules">>, <<"wait_multiply_level">>], Doc, Default).

-spec set_tier_rules_wait_multiply_level(doc(), boolean()) -> doc().
set_tier_rules_wait_multiply_level(Doc, TierRulesWaitMultiplyLevel) ->
    kz_json:set_value([<<"tier_rules">>, <<"wait_multiply_level">>], TierRulesWaitMultiplyLevel, Doc).

-spec tier_rules_wait_seconds(doc()) -> integer().
tier_rules_wait_seconds(Doc) ->
    tier_rules_wait_seconds(Doc, 0).

-spec tier_rules_wait_seconds(doc(), Default) -> integer() | Default.
tier_rules_wait_seconds(Doc, Default) ->
    kz_json:get_integer_value([<<"tier_rules">>, <<"wait_seconds">>], Doc, Default).

-spec set_tier_rules_wait_seconds(doc(), integer()) -> doc().
set_tier_rules_wait_seconds(Doc, TierRulesWaitSeconds) ->
    kz_json:set_value([<<"tier_rules">>, <<"wait_seconds">>], TierRulesWaitSeconds, Doc).

-spec time_base_score(doc()) -> binary().
time_base_score(Doc) ->
    time_base_score(Doc, <<"system">>).

-spec time_base_score(doc(), Default) -> binary() | Default.
time_base_score(Doc, Default) ->
    kz_json:get_binary_value([<<"time_base_score">>], Doc, Default).

-spec set_time_base_score(doc(), binary()) -> doc().
set_time_base_score(Doc, TimeBaseScore) ->
    kz_json:set_value([<<"time_base_score">>], TimeBaseScore, Doc).
