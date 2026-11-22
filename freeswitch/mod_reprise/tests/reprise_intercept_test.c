/* Real channel lookup/ownership; intercept media and originate handoff are
 * controlled boundaries. Live SIP tests verify the complete call path.
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

/* What kz_intercept handed to the core, and what the core should answer. */
static char intercepted_uuid[128];
static switch_bool_t intercepted_bleg;
static switch_status_t intercept_result;

static switch_status_t test_intercept(switch_core_session_t *session, const char *uuid, switch_bool_t bleg)
{
	snprintf(intercepted_uuid, sizeof(intercepted_uuid), "%s", uuid);
	intercepted_bleg = bleg;
	return intercept_result;
}

static switch_channel_state_t test_hangup(switch_channel_t *channel, const char *file, const char *function, int line,
										  switch_call_cause_t cause)
{
	return CS_HANGUP;
}

static void test_wait(switch_channel_t *channel, switch_channel_state_t state, uint32_t timeout)
{
}

static switch_status_t test_answer(switch_channel_t *channel)
{
	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t test_kill(switch_core_session_t *session, switch_signal_t signal)
{
	return SWITCH_STATUS_SUCCESS;
}

#define switch_core_session_perform_kill_channel(s, f, fn, l, sig) test_kill(s, sig)
#define switch_channel_perform_hangup test_hangup
#define switch_ivr_intercept_session test_intercept
#define switch_channel_wait_for_state_timeout test_wait
#define switch_channel_perform_answer(c, f, fn, l) test_answer(c)
#include "../src/reprise_dptools.c"
#undef switch_core_session_perform_kill_channel
#undef switch_channel_perform_hangup
#undef switch_ivr_intercept_session
#undef switch_channel_wait_for_state_timeout
#undef switch_channel_perform_answer

/* 0: the picker; 1: the ringing target; 2 and 3: the callers it may reach. */
static switch_core_session_t *sessions[4];

static switch_core_session_t *fixture(switch_call_direction_t direction)
{
	switch_core_session_t *session = switch_core_session_request_by_name("null", direction, NULL);

	if (session) {
		switch_channel_t *channel = switch_core_session_get_channel(session);
		switch_caller_profile_t *profile =
			switch_caller_profile_new(switch_core_session_get_pool(session), "phone", "XML", "Caller", "3104",
									  "127.0.0.1", NULL, NULL, NULL, "test", "default", "3101");

		switch_channel_set_name(channel, "null/intercept-fixture");
		switch_channel_set_caller_profile(channel, profile);
	}
	return session;
}

static switch_channel_t *channel_of(int index)
{
	return switch_core_session_get_channel(sessions[index]);
}

static const char *uuid_of(int index)
{
	return switch_core_session_get_uuid(sessions[index]);
}

static const char *picker_response(void)
{
	return switch_str_nil(switch_channel_get_variable(channel_of(0), SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE));
}

SWITCH_STANDARD_APP(reject_confirmation)
{
	switch_channel_hangup(switch_core_session_get_channel(session), SWITCH_CAUSE_USER_BUSY);
}

SWITCH_MODULE_LOAD_FUNCTION(intercept_test_load)
{
	switch_application_interface_t *app_interface;

	*module_interface = switch_loadable_module_create_module_interface(pool, "reprise_intercept_test");
	SWITCH_ADD_APP(app_interface, "reject_confirmation", "test confirmation", "test confirmation", reject_confirmation,
				   "", SAF_NONE);
	return SWITCH_STATUS_SUCCESS;
}

struct confirmation_control {
	const char *uuid;
	int accepted;
	int answered;
};

/* Answer the confirmation leg once it exists, optionally as a group pickup. */
static void *SWITCH_THREAD_FUNC answer_confirmation(switch_thread_t *thread, void *obj)
{
	struct confirmation_control *control = obj;
	switch_time_t end = switch_micro_time_now() + 2000000;

	while (switch_micro_time_now() < end) {
		switch_core_session_t *session = switch_core_session_locate(control->uuid);

		if (session) {
			switch_channel_t *channel = switch_core_session_get_channel(session);
			switch_channel_state_t state = switch_channel_get_state(channel);

			if (switch_core_session_get_private(session) && state >= CS_ROUTING && state < CS_HANGUP) {
				if (control->accepted) switch_channel_set_flag(channel, CF_GROUP_ACCEPTED);
				switch_channel_mark_answered(channel);
				control->answered = 1;
				switch_core_session_rwunlock(session);
				return NULL;
			}
			switch_core_session_rwunlock(session);
		}
		switch_yield(1000);
	}
	return NULL;
}

static switch_call_cause_t confirmation_cause;
static int confirmation_answered;

/* Originate a null leg that must pass group confirmation (which rejects). */
static switch_status_t confirmation_call(int accepted)
{
	switch_core_session_t *session = NULL;
	switch_call_cause_t cause;
	switch_event_t *vars = NULL;
	switch_memory_pool_t *pool = NULL;
	switch_thread_t *thread;
	switch_threadattr_t *attr = NULL;
	switch_status_t status, joined;
	switch_uuid_t id;
	char uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
	struct confirmation_control control = {uuid, accepted, 0};

	switch_uuid_get(&id);
	switch_uuid_format(uuid, &id);
	switch_core_new_memory_pool(&pool);
	switch_threadattr_create(&attr, pool);
	switch_thread_create(&thread, attr, answer_confirmation, &control, pool);

	switch_event_create_plain(&vars, SWITCH_EVENT_GENERAL);
	switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "group_confirm_key", "exec");
	switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "group_confirm_file", "reject_confirmation");
	switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "origination_uuid", uuid);
	switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "null_enable_auto_answer", "false");
	status = switch_ivr_originate(NULL, &session, &cause, "null/confirmation", 2, NULL, NULL, NULL, NULL, vars,
								  SOF_NONE, NULL, NULL);
	if (session) {
		switch_channel_hangup(switch_core_session_get_channel(session), SWITCH_CAUSE_NORMAL_CLEARING);
		switch_core_session_rwunlock(session);
	}
	switch_thread_join(&joined, thread);
	switch_core_destroy_memory_pool(&pool);
	switch_event_destroy(&vars);

	confirmation_cause = cause;
	confirmation_answered = control.answered;
	fprintf(stderr, "CONFIRM accepted=%d answered=%d status=%d cause=%s\n", accepted, control.answered, status,
			switch_channel_cause2str(cause));
	reprise_test_drained();
	return status;
}

static switch_status_t intercept_log(const switch_log_node_t *node, switch_log_level_t level)
{
	fprintf(stderr, "%s", node->data);
	return SWITCH_STATUS_SUCCESS;
}

FST_CORE_BEGIN("../conf")
{
	const char *err = NULL;

	if (getenv("REPRISE_TEST_TRACE")) switch_log_bind_logger(intercept_log, SWITCH_LOG_DEBUG, SWITCH_FALSE);
	if (switch_loadable_module_exists("mod_loopback") != SWITCH_STATUS_SUCCESS) {
		switch_loadable_module_load_module("/usr/local/freeswitch/lib/freeswitch/mod", "mod_loopback", SWITCH_FALSE,
										   &err);
	}
	switch_loadable_module_build_dynamic("reprise_intercept_test", intercept_test_load, NULL, NULL, SWITCH_FALSE);

	/* Each suite lives in its own block: the FST macros declare locals. */
	{
		sessions[0] = fixture(SWITCH_CALL_DIRECTION_INBOUND);
		sessions[1] = fixture(SWITCH_CALL_DIRECTION_OUTBOUND);
		sessions[2] = fixture(SWITCH_CALL_DIRECTION_INBOUND);
		sessions[3] = fixture(SWITCH_CALL_DIRECTION_INBOUND);

		FST_SUITE_BEGIN(intercept_contract)

		FST_SETUP_BEGIN()
		{
			static const char *variables[] = {SWITCH_SIGNAL_BOND_VARIABLE,
											  KZ_ORIGINATE_UUID_VARIABLE,
											  "satt_uuid",
											  SWITCH_HOLDING_UUID_VARIABLE,
											  "intercept_unbridged_only",
											  "intercept_unanswered_only",
											  "intercept_forbidden",
											  NULL};
			int i, j;

			intercepted_uuid[0] = '\0';
			intercepted_bleg = SWITCH_FALSE;
			intercept_result = SWITCH_STATUS_SUCCESS;
			fst_requires(sessions[0] && sessions[1] && sessions[2] && sessions[3]);
			for (i = 0; i < 4; i++) {
				switch_channel_t *channel = channel_of(i);

				for (j = 0; variables[j]; j++) {
					switch_channel_set_variable(channel, variables[j], NULL);
				}
				switch_channel_clear_flag(channel, CF_BRIDGED);
				switch_channel_clear_flag(channel, CF_ANSWERED);
				switch_channel_clear_flag(channel, CF_ORIGINATING_XFER);
				switch_channel_clear_flag(channel, CF_XFER_ZOMBIE);
				switch_channel_clear_flag(channel, CF_GROUP_ACCEPTED);
			}
		}
		FST_SETUP_END()

		FST_TEARDOWN_BEGIN()
		{
		}
		FST_TEARDOWN_END()

		FST_TEST_BEGIN(ringing_target_selects_original_caller)
		{
			switch_channel_set_variable(channel_of(1), SWITCH_SIGNAL_BOND_VARIABLE, uuid_of(2));
			kz_intercept_function(sessions[0], uuid_of(1));
			fst_check_string_equals(intercepted_uuid, uuid_of(2));
		}
		FST_TEST_END()

		FST_TEST_BEGIN(nested_kz_originate_selects_original_caller)
		{
			switch_channel_set_variable(channel_of(1), KZ_ORIGINATE_UUID_VARIABLE, uuid_of(2));
			kz_intercept_function(sessions[0], uuid_of(1));
			fst_check_string_equals(intercepted_uuid, uuid_of(2));
		}
		FST_TEST_END()

		FST_TEST_BEGIN(early_transfer_pickup_selects_saved_original)
		{
			switch_channel_t *target = channel_of(1);
			switch_channel_t *consult = channel_of(2);

			switch_channel_set_variable(target, KZ_ORIGINATE_UUID_VARIABLE, uuid_of(2));
			switch_channel_set_variable(consult, "satt_uuid", uuid_of(3));
			switch_channel_set_variable(consult, SWITCH_HOLDING_UUID_VARIABLE, uuid_of(3));
			switch_channel_set_flag(consult, CF_ORIGINATING_XFER);
			switch_channel_set_flag(consult, CF_XFER_ZOMBIE);
			kz_intercept_function(sessions[0], uuid_of(1));
			fst_check_string_equals(intercepted_uuid, uuid_of(3));
			fst_check(!switch_channel_test_flag(consult, CF_ORIGINATING_XFER));
			fst_check(!switch_channel_test_flag(consult, CF_XFER_ZOMBIE));
			fst_check(zstr(switch_channel_get_variable(consult, SWITCH_HOLDING_UUID_VARIABLE)));
		}
		FST_TEST_END()

		FST_TEST_BEGIN(unbridged_target_keeps_uuid)
		{
			kz_intercept_function(sessions[0], uuid_of(1));
			fst_check_string_equals(intercepted_uuid, uuid_of(1));
		}
		FST_TEST_END()

		FST_TEST_BEGIN(missing_target_reports_failure)
		{
			kz_intercept_function(sessions[0], "nonexistent-target");
			fst_check_string_equals(intercepted_uuid, "");
			fst_check_string_equals(picker_response(), "ERROR");
		}
		FST_TEST_END()

		FST_TEST_BEGIN(intercept_error_not_reported_as_success)
		{
			intercept_result = SWITCH_STATUS_FALSE;
			kz_intercept_function(sessions[0], uuid_of(1));
			fst_check_string_equals(picker_response(), "ERROR");
		}
		FST_TEST_END()

		FST_TEST_BEGIN(bridged_target_cannot_bypass_unbridged_policy)
		{
			switch_channel_set_variable(channel_of(0), "intercept_unbridged_only", "true");
			switch_channel_set_flag(channel_of(1), CF_BRIDGED);
			kz_intercept_function(sessions[0], uuid_of(1));
			fst_check_string_equals(intercepted_uuid, "");
		}
		FST_TEST_END()

		FST_TEST_BEGIN(answered_target_cannot_bypass_unanswered_policy)
		{
			switch_channel_set_variable(channel_of(0), "intercept_unanswered_only", "true");
			switch_channel_set_flag(channel_of(1), CF_ANSWERED);
			kz_intercept_function(sessions[0], uuid_of(1));
			fst_check_string_equals(intercepted_uuid, "");
		}
		FST_TEST_END()

		FST_TEST_BEGIN(forbidden_target_not_intercepted)
		{
			switch_channel_set_variable(channel_of(1), "intercept_forbidden", "true");
			kz_intercept_function(sessions[0], uuid_of(1));
			fst_check_string_equals(intercepted_uuid, "");
		}
		FST_TEST_END()

		FST_TEST_BEGIN(bleg_hands_the_partner_to_the_core)
		{
			char args[160];

			switch_channel_set_variable(channel_of(1), SWITCH_SIGNAL_BOND_VARIABLE, uuid_of(2));
			snprintf(args, sizeof(args), "-bleg %s", uuid_of(1));
			kz_intercept_function(sessions[0], args);
			fst_check_string_equals(intercepted_uuid, uuid_of(2));
			fst_check(intercepted_bleg == SWITCH_FALSE);
			fst_check_string_equals(picker_response(), "SUCCESS");
		}
		FST_TEST_END()

		FST_TEST_BEGIN(bleg_resolves_the_kz_originate_partner)
		{
			char args[160];

			switch_channel_set_variable(channel_of(1), KZ_ORIGINATE_UUID_VARIABLE, uuid_of(2));
			snprintf(args, sizeof(args), "-bleg %s", uuid_of(1));
			kz_intercept_function(sessions[0], args);
			fst_check_string_equals(intercepted_uuid, uuid_of(2));
			fst_check(intercepted_bleg == SWITCH_FALSE);
		}
		FST_TEST_END()

		FST_TEST_BEGIN(bleg_policy_applies_to_the_partner)
		{
			char args[160];

			switch_channel_set_variable(channel_of(1), SWITCH_SIGNAL_BOND_VARIABLE, uuid_of(2));
			switch_channel_set_variable(channel_of(0), "intercept_unbridged_only", "true");
			switch_channel_set_flag(channel_of(2), CF_BRIDGED);
			snprintf(args, sizeof(args), "-bleg %s", uuid_of(1));
			kz_intercept_function(sessions[0], args);
			fst_check_string_equals(intercepted_uuid, "");
		}
		FST_TEST_END()

		FST_TEST_BEGIN(self_target_rejected)
		{
			kz_intercept_function(sessions[0], uuid_of(0));
			fst_check_string_equals(intercepted_uuid, "");
		}
		FST_TEST_END()

		FST_SUITE_END()

		{
			int i;

			for (i = 0; i < 4; i++) {
				if (sessions[i]) switch_core_session_destroy(&sessions[i]);
			}
		}
	}

	{
		FST_SUITE_BEGIN(intercept_confirmation)

		FST_SETUP_BEGIN()
		{
		}
		FST_SETUP_END()

		FST_TEARDOWN_BEGIN()
		{
			fst_check(switch_core_session_count() == 0);
		}
		FST_TEARDOWN_END()

		FST_TEST_BEGIN(normal_originate_still_requires_confirmation)
		{
			fst_check(confirmation_call(0) != SWITCH_STATUS_SUCCESS);
			fst_check(confirmation_answered == 1);
			fst_check(confirmation_cause == SWITCH_CAUSE_USER_BUSY);
		}
		FST_TEST_END()

		FST_TEST_BEGIN(pickup_acceptance_bypasses_confirmation)
		{
			fst_check(confirmation_call(1) == SWITCH_STATUS_SUCCESS);
		}
		FST_TEST_END()

		FST_SUITE_END()
	}
}
FST_CORE_END()
