/* Exercise the real patched originate controller and kz endpoint. Only the
 * directory service is replaced. Comma dialing is the producer contract.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include <test/switch_test.h>
#include "reprise_kz.h"
#include "reprise_test_util.h"

/* Devices a, b and c are null endpoints; only the winner auto-answers. */
static switch_time_t seen[3];
static switch_atomic_t started[3];
static const char *winner;
static const char *separator;
static switch_atomic_t pickup_hooks;

#define AUTO_ANSWER_C "[null_enable_auto_answer=true,null_auto_answer_delay=800]null/c"

SWITCH_STANDARD_API(ring_pickup_probe)
{
	switch_atomic_inc(&pickup_hooks);
	stream->write_function(stream, "+OK");
	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t directory_reply(switch_xml_t *user, char *xml)
{
	*user = switch_xml_parse_str_dynamic(xml, SWITCH_FALSE);
	return *user ? SWITCH_STATUS_SUCCESS : SWITCH_STATUS_FALSE;
}

/* A user whose call-forward appends to (or fails over from) its own devices. */
static char *forwarding_user(const char *id, const char *dial, const char *sep, int failover, const char *forward)
{
	return switch_mprintf("<user id='%s'><params>"
						  "<param name='endpoint-dial-string' value='%s'/>"
						  "<param name='endpoint-separator' value='%s'/></params>"
						  "<call-forward><variable name='Is-Failover' value='%s'/>"
						  "<variable name='Dial-String' value='%s'/></call-forward></user>",
						  id, dial, sep, failover ? "true" : "false", forward);
}

static switch_status_t locate_user(const char *key, const char *id, const char *domain, const char *ip,
								   switch_xml_t *user, switch_event_t *params)
{
	char *dest, *xml;

	if (!strcmp(id, "gone")) return SWITCH_STATUS_FALSE;
	if (!strcmp(id, "early")) {
		return directory_reply(user, strdup("<user id='early'><params><param name='endpoint-dial-string' "
											"value='[null_pre_answer=true,null_enable_auto_answer=false]null/early'/>"
											"</params></user>"));
	}
	if (!strcmp(id, "flatappend")) {
		return directory_reply(user,
							   forwarding_user(id, "[null_enable_auto_answer=false]null/a", ",", 0, AUTO_ANSWER_C));
	}
	if (!strcmp(id, "flatfailover")) {
		return directory_reply(user, forwarding_user(id, "missing_endpoint/a", ",", 1,
													 "[null_enable_auto_answer=false]null/a," AUTO_ANSWER_C));
	}
	if (!strcmp(id, "append")) {
		return directory_reply(user, forwarding_user(id, "kz/a@example.invalid", separator, 0, "kz/c@example.invalid"));
	}
	if (!strcmp(id, "failover")) {
		return directory_reply(user, forwarding_user(id, "kz/gone@example.invalid", separator, 1,
													 "kz/a@example.invalid,kz/c@example.invalid"));
	}

	if (!strcmp(id, "multi")) {
		dest = switch_mprintf("kz/a@example.invalid%skz/c@example.invalid", separator);
	} else if (!strcmp(id, "usera")) {
		dest = strdup("kz/a@example.invalid");
	} else if (!strcmp(id, "userb")) {
		dest = strdup("kz/b@example.invalid");
	} else {
		/* A device: record when it was asked for. */
		int idx = id[0] - 'a';

		if (idx >= 0 && idx < 3) {
			seen[idx] = switch_micro_time_now();
			switch_atomic_set(&started[idx], 1);
		}
		dest = switch_mprintf("[null_enable_auto_answer=%s,null_auto_answer_delay=800]null/%s",
							  winner && !strcmp(id, winner) ? "true" : "false", id);
	}
	xml = switch_mprintf("<user id='%s'><params><param name='endpoint-dial-string' value='%s'/></params></user>", id,
						 dest);
	free(dest);
	return directory_reply(user, xml);
}

#define switch_xml_locate_user_merged locate_user
#include "../src/reprise_endpoints.c"
#undef switch_xml_locate_user_merged

static switch_status_t ring_log(const switch_log_node_t *node, switch_log_level_t level)
{
	fprintf(stderr, "%s", node->data);
	return SWITCH_STATUS_SUCCESS;
}

/* A minimal fault-injection endpoint exercises core handoff errors and the
 * independent stock pickup path without changing the kz implementation. */
static switch_endpoint_interface_t *swap_test_interface;
static const char *pickup_target;

static switch_call_cause_t swap_test_outgoing(switch_core_session_t *caller, switch_event_t *vars,
											  switch_caller_profile_t *profile, switch_core_session_t **out,
											  switch_memory_pool_t **pool, switch_originate_flag_t flags,
											  switch_call_cause_t *cancel)
{
	switch_channel_t *channel;

	*out = switch_core_session_request(swap_test_interface, SWITCH_CALL_DIRECTION_OUTBOUND, flags, pool);
	if (!*out) return SWITCH_CAUSE_DESTINATION_OUT_OF_ORDER;
	channel = switch_core_session_get_channel(*out);
	switch_channel_set_caller_profile(channel, switch_caller_profile_clone(*out, profile));
	switch_channel_set_name(channel, "swap-test/pending");
	switch_channel_set_state(channel, CS_INIT);
	return SWITCH_CAUSE_SUCCESS;
}

static switch_status_t swap_test_init(switch_core_session_t *session)
{
	switch_channel_set_state(switch_core_session_get_channel(session), CS_ROUTING);
	return SWITCH_STATUS_SUCCESS;
}

/* The destination selects the handoff target: self, empty, the pickup
 * target, or a session that does not exist. */
static switch_status_t swap_test_route(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	const char *mode = switch_channel_get_caller_profile(channel)->destination_number;
	const char *target;

	if (!strcmp(mode, "self")) {
		target = switch_core_session_get_uuid(session);
	} else if (!strcmp(mode, "empty")) {
		target = NULL;
	} else if (!strcmp(mode, "pickup")) {
		target = pickup_target;
	} else {
		target = "missing-test-session";
	}
	switch_channel_set_variable(channel, "channel_swap_uuid", target);
	switch_channel_set_flag(channel, !strcmp(mode, "pickup") ? CF_CHANNEL_SWAP : CF_SESSION_SWAP);
	return SWITCH_STATUS_FALSE;
}

static switch_io_routines_t swap_test_io = {.outgoing_channel = swap_test_outgoing};
static switch_state_handler_table_t swap_test_states = {.on_init = swap_test_init, .on_routing = swap_test_route};

SWITCH_MODULE_LOAD_FUNCTION(ring_load)
{
	switch_api_interface_t *api_interface;

	*module_interface = switch_loadable_module_create_module_interface(pool, "reprise_ring_test");
	SWITCH_ADD_API(api_interface, "ring_pickup_probe", "test pickup hook", ring_pickup_probe, "");
	reprise_kz_endpoints_add(module_interface);
	swap_test_interface = switch_loadable_module_create_interface(*module_interface, SWITCH_ENDPOINT_INTERFACE);
	swap_test_interface->interface_name = "swap-test";
	swap_test_interface->io_routines = &swap_test_io;
	swap_test_interface->state_handler = &swap_test_states;
	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t call(const char *members, switch_core_session_t **session, switch_call_cause_t *cause,
							switch_call_cause_t *cancel)
{
	char *dial = switch_mprintf("<leg_timeout=3,ignore_early_media=true,origination_caller_id_number=3104>%s", members);
	switch_status_t status =
		switch_ivr_originate(NULL, session, cause, dial, 5, NULL, NULL, NULL, NULL, NULL, SOF_NONE, cancel, NULL);

	fprintf(stderr, "RING dial=%s status=%d cause=%s seen=%d/%d/%d span_ms=%ld\n", dial, status,
			switch_channel_cause2str(*cause), seen[0] > 0, seen[1] > 0, seen[2] > 0,
			seen[0] && seen[1] ? (long) ((seen[1] - seen[0]) / 1000) : -1L);
	free(dial);
	return status;
}

static void finish(switch_core_session_t *session)
{
	if (session) {
		switch_channel_hangup(switch_core_session_get_channel(session), SWITCH_CAUSE_NORMAL_CLEARING);
		switch_core_session_rwunlock(session);
	}
}

/* Ring a member list and hang up whatever answered. expected_leg is the
 * channel-name fragment of the leg that should win; matched and answered
 * report on the winner and may be NULL. */
static switch_status_t ring(const char *members, const char *expected_leg, int *matched, int *answered)
{
	switch_core_session_t *session = NULL;
	switch_call_cause_t cause;
	switch_status_t status = call(members, &session, &cause, NULL);
	switch_channel_t *channel = session ? switch_core_session_get_channel(session) : NULL;

	if (matched) *matched = channel && expected_leg && strstr(switch_channel_get_name(channel), expected_leg) != NULL;
	if (answered) *answered = channel && switch_channel_test_flag(channel, CF_ANSWERED);
	finish(session);
	return status;
}

/* Ring two members joined by the producer's separator. */
static switch_status_t ring_pair(const char *first, const char *second, const char *expected_leg, int *matched)
{
	char *members = switch_mprintf("%s%s%s", first, separator, second);
	switch_status_t status = ring(members, expected_leg, matched, NULL);

	free(members);
	return status;
}

static void *SWITCH_THREAD_FUNC cancel_when_ringing(switch_thread_t *thread, void *obj)
{
	switch_time_t end = switch_micro_time_now() + 4000000;

	while (!(switch_atomic_read(&started[0]) && switch_atomic_read(&started[1]) && switch_atomic_read(&started[2])) &&
		   switch_micro_time_now() < end) {
		switch_yield(10000);
	}
	*(switch_call_cause_t *) obj = SWITCH_CAUSE_ORIGINATOR_CANCEL;
	return NULL;
}

static void *SWITCH_THREAD_FUNC cancel_when_first_rings(switch_thread_t *thread, void *obj)
{
	switch_time_t end = switch_micro_time_now() + 4000000;

	while (!switch_atomic_read(&started[0]) && switch_micro_time_now() < end) {
		switch_yield(10000);
	}
	*(switch_call_cause_t *) obj = SWITCH_CAUSE_ORIGINATOR_CANCEL;
	return NULL;
}

/* Ring while a thread cancels the originate once the chosen devices ring. */
static switch_status_t ring_with_cancel(const char *members, switch_thread_start_t canceller,
										switch_call_cause_t *cause)
{
	switch_core_session_t *session = NULL;
	switch_call_cause_t cancel = 0;
	switch_memory_pool_t *pool;
	switch_threadattr_t *attr;
	switch_thread_t *thread;
	switch_status_t status, joined;

	switch_core_new_memory_pool(&pool);
	switch_threadattr_create(&attr, pool);
	switch_thread_create(&thread, attr, canceller, &cancel, pool);
	status = call(members, &session, cause, &cancel);
	finish(session);
	switch_thread_join(&joined, thread);
	switch_core_destroy_memory_pool(&pool);
	return status;
}

FST_CORE_BEGIN("../conf")
{
	const char *err = NULL;

	if (getenv("REPRISE_TEST_TRACE")) switch_log_bind_logger(ring_log, SWITCH_LOG_DEBUG, SWITCH_FALSE);
	switch_loadable_module_load_module("/usr/local/freeswitch/lib/freeswitch/mod", "mod_loopback", SWITCH_FALSE, &err);
	switch_loadable_module_load_module("/usr/local/freeswitch/lib/freeswitch/mod", "mod_tone_stream", SWITCH_FALSE,
									   &err);
	switch_loadable_module_build_dynamic("reprise_ring_test", ring_load, NULL, NULL, SWITCH_FALSE);
	separator = ",";

	FST_SUITE_BEGIN(ring_fanout)

	FST_SETUP_BEGIN()
	{
		memset(seen, 0, sizeof(seen));
		memset(started, 0, sizeof(started));
		winner = NULL;
	}
	FST_SETUP_END()

	FST_TEARDOWN_BEGIN()
	{
		fst_check(reprise_test_drained());
	}
	FST_TEARDOWN_END()

	FST_TEST_BEGIN(direct_devices)
	{
		switch_status_t status = ring_pair("kz/a@example.invalid", "kz/b@example.invalid", NULL, NULL);

		fst_check(seen[0] > 0 && seen[1] > 0);
		fst_check(llabs(seen[1] - seen[0]) < 500000);
		fst_check(status != SWITCH_STATUS_SUCCESS);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(one_device_users)
	{
		switch_status_t status = ring_pair("kz/usera@example.invalid", "kz/userb@example.invalid", NULL, NULL);

		fst_check(seen[0] > 0 && seen[1] > 0);
		fst_check(llabs(seen[1] - seen[0]) < 500000);
		fst_check(status != SWITCH_STATUS_SUCCESS);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(all_owned_devices)
	{
		switch_status_t status = ring_pair("kz/multi@example.invalid", "kz/userb@example.invalid", NULL, NULL);

		fst_check(seen[0] > 0 && seen[1] > 0);
		fst_check(llabs(seen[1] - seen[0]) < 500000);
		fst_check(seen[2] > 0);
		fst_check(status != SWITCH_STATUS_SUCCESS);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(first_device_wins)
	{
		int matched;
		switch_status_t status;

		winner = "a";
		status = ring_pair("kz/multi@example.invalid", "kz/userb@example.invalid", "null/a", &matched);
		fst_check(seen[0] > 0 && seen[1] > 0);
		fst_check(llabs(seen[1] - seen[0]) < 500000);
		fst_check(seen[2] > 0);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(matched);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(second_user_wins)
	{
		int matched;
		switch_status_t status;

		winner = "b";
		status = ring_pair("kz/multi@example.invalid", "kz/userb@example.invalid", "null/b", &matched);
		fst_check(seen[0] > 0 && seen[1] > 0);
		fst_check(llabs(seen[1] - seen[0]) < 500000);
		fst_check(seen[2] > 0);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(matched);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(second_owned_device_wins)
	{
		int matched;
		switch_status_t status;

		winner = "c";
		status = ring_pair("kz/multi@example.invalid", "kz/userb@example.invalid", "null/c", &matched);
		fst_check(seen[0] > 0 && seen[1] > 0);
		fst_check(llabs(seen[1] - seen[0]) < 500000);
		fst_check(seen[2] > 0);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(matched);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(delayed_second_user_wins)
	{
		int matched;
		switch_status_t status;

		winner = "b";
		status =
			ring_pair("kz/multi@example.invalid", "[leg_delay_start=1]kz/userb@example.invalid", "null/b", &matched);
		fst_check(seen[0] > 0 && seen[1] > 0);
		/* Stock delay scheduling uses whole seconds and an elapsed > delay check. */
		fst_check(seen[1] - seen[0] >= 800000 && seen[1] - seen[0] < 2250000);
		fst_check(seen[2] > 0);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(matched);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(sequential_parent_waits_for_multidevice_winner)
	{
		int matched, answered;
		switch_status_t status;

		winner = "c";
		status = ring("kz/multi@example.invalid|kz/userb@example.invalid", "null/c", &matched, &answered);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(answered);
		fst_check(matched);
		fst_check(seen[0] > 0 && seen[2] > 0);
		fst_check(seen[1] == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(caller_cancellation_reaches_all_children)
	{
		switch_call_cause_t cause;
		char *members = switch_mprintf("kz/multi@example.invalid%skz/userb@example.invalid", separator);
		switch_status_t status = ring_with_cancel(members, cancel_when_ringing, &cause);

		free(members);
		fst_check(status != SWITCH_STATUS_SUCCESS);
		fst_check(cause == SWITCH_CAUSE_ORIGINATOR_CANCEL);
		fst_check(seen[0] && seen[1] && seen[2]);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(missing_child_does_not_block_other_user)
	{
		int matched;
		switch_status_t status;

		winner = "b";
		status = ring_pair("kz/gone@example.invalid", "kz/userb@example.invalid", "null/b", &matched);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(matched);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(append_group_waits_for_winner)
	{
		int matched;
		switch_status_t status;

		winner = "c";
		status = ring("kz/append@example.invalid|kz/userb@example.invalid", "null/c", &matched, NULL);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(matched);
		fst_check(seen[0] && seen[2]);
		fst_check(seen[1] == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(failover_group_waits_for_winner)
	{
		int matched;
		switch_status_t status;

		winner = "c";
		status = ring("kz/failover@example.invalid|kz/userb@example.invalid", "null/c", &matched, NULL);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(matched);
		fst_check(seen[0] && seen[2]);
		fst_check(seen[1] == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(flatappend_does_not_select_unanswered_child)
	{
		int matched, answered;
		switch_status_t status =
			ring("kz/flatappend@example.invalid|kz/userb@example.invalid", "null/c", &matched, &answered);

		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(matched);
		fst_check(answered);
		fst_check(seen[1] == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(flatfailover_does_not_select_unanswered_child)
	{
		int matched, answered;
		switch_status_t status =
			ring("kz/flatfailover@example.invalid|kz/userb@example.invalid", "null/c", &matched, &answered);

		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(matched);
		fst_check(answered);
		fst_check(seen[1] == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(cancellation_prevents_delayed_member_start)
	{
		switch_call_cause_t cause;
		char *members =
			switch_mprintf("kz/usera@example.invalid%s[leg_delay_start=3]kz/userb@example.invalid", separator);
		switch_time_t start = switch_micro_time_now();
		switch_status_t status = ring_with_cancel(members, cancel_when_first_rings, &cause);

		free(members);
		fst_check(status != SWITCH_STATUS_SUCCESS);
		fst_check(cause == SWITCH_CAUSE_ORIGINATOR_CANCEL);
		fst_check(seen[0] > 0 && seen[1] == 0);
		fst_check(switch_micro_time_now() - start < 1000000);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(normal_answer_does_not_execute_pickup_hooks)
	{
		switch_status_t status;
		int hook_count;

		winner = "a";
		switch_atomic_set(&pickup_hooks, 0);
		status = ring("[api_on_pickup=ring_pickup_probe]kz/usera@example.invalid", NULL, NULL, NULL);
		hook_count = switch_atomic_read(&pickup_hooks);
		fprintf(stderr, "PICKUP hooks=%d status=%d\n", hook_count, status);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(hook_count == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(early_media_handoff_does_not_answer)
	{
		switch_core_session_t *session = NULL;
		switch_call_cause_t cause;
		switch_status_t status =
			switch_ivr_originate(NULL, &session, &cause, "{ignore_early_media=false}kz/early@example.invalid", 3, NULL,
								 NULL, NULL, NULL, NULL, SOF_NONE, NULL, NULL);
		switch_channel_t *channel = session ? switch_core_session_get_channel(session) : NULL;
		int early = channel && switch_channel_test_flag(channel, CF_EARLY_MEDIA);
		int answered = channel && switch_channel_test_flag(channel, CF_ANSWERED);
		int physical = channel && strstr(switch_channel_get_name(channel), "null/early") != NULL;

		finish(session);
		fst_check(status == SWITCH_STATUS_SUCCESS);
		fst_check(early);
		fst_check(!answered);
		fst_check(physical);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(ignored_early_media_is_not_a_winner)
	{
		switch_core_session_t *session = NULL;
		switch_call_cause_t cause;
		switch_status_t status = switch_ivr_originate(NULL, &session, &cause,
													  "{ignore_early_media=true,leg_timeout=1}kz/early@example.invalid",
													  2, NULL, NULL, NULL, NULL, NULL, SOF_NONE, NULL, NULL);

		finish(session);
		fst_check(status != SWITCH_STATUS_SUCCESS);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(invalid_handoff_targets_fail_and_drain)
	{
		const char *modes[] = {"empty", "missing", "self"};
		int i;

		for (i = 0; i < 3; i++) {
			switch_core_session_t *session = NULL;
			switch_call_cause_t cause;
			char *dial = switch_mprintf("swap-test/%s", modes[i]);
			switch_status_t status = switch_ivr_originate(NULL, &session, &cause, dial, 2, NULL, NULL, NULL, NULL, NULL,
														  SOF_NONE, NULL, NULL);

			fprintf(stderr, "HANDOFF invalid=%s status=%d cause=%s\n", modes[i], status,
					switch_channel_cause2str(cause));
			free(dial);
			finish(session);
			fst_check(status != SWITCH_STATUS_SUCCESS);
			fst_check(cause == SWITCH_CAUSE_DESTINATION_OUT_OF_ORDER);
			fst_check(reprise_test_drained());
		}
	}
	FST_TEST_END()

	FST_TEST_BEGIN(core_pickup_swap_retains_pickup_hooks)
	{
		switch_core_session_t *target = NULL, *session = NULL;
		switch_call_cause_t cause;
		switch_status_t status = switch_ivr_originate(NULL, &target, &cause, "null/pickup", 2, NULL, NULL, NULL, NULL,
													  NULL, SOF_NONE, NULL, NULL);

		fst_check(status == SWITCH_STATUS_SUCCESS);
		if (target) {
			switch_channel_t *channel = switch_core_session_get_channel(target);

			pickup_target = switch_core_session_get_uuid(target);
			switch_channel_set_variable(channel, "api_on_pickup", "ring_pickup_probe");
			switch_atomic_set(&pickup_hooks, 0);
			status = switch_ivr_originate(NULL, &session, &cause, "swap-test/pickup", 2, NULL, NULL, NULL, NULL, NULL,
										  SOF_NONE, NULL, NULL);
			fst_check(status == SWITCH_STATUS_SUCCESS);
			fst_check(session == target);
			fst_check(switch_atomic_read(&pickup_hooks) == 1);
			fst_check(!zstr(switch_channel_get_variable(channel, "picked_up_uuid")));
			finish(session);
			switch_core_session_rwunlock(target);
			pickup_target = NULL;
		}
	}
	FST_TEST_END()

	FST_SUITE_END()
}
FST_CORE_END()
