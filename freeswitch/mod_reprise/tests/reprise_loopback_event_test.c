/* Real loopback execution bowout must carry channel identity for AMQP routing.
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

/* Recreate the observed scheduling boundary: the old loopback bridge has
 * not observed its peer's BRIDGED flag before bowout resets and parks that peer. */
static int force_race;
static switch_atomic_t race_exercised;

static switch_status_t wait_boundary(switch_channel_t *channel, switch_channel_flag_t flag, switch_bool_t present,
									 uint32_t timeout, switch_channel_t *super)
{
	if (force_race && flag == CF_BRIDGED && present && super && strstr(switch_channel_get_name(super), "/nested-b")) {
		switch_time_t end = switch_micro_time_now() + 5000000;

		while (switch_micro_time_now() < end && switch_channel_get_state(channel) < CS_HANGUP) {
			if (switch_channel_test_flag(channel, CF_PARK)) {
				switch_atomic_set(&race_exercised, 1);
				break;
			}
			switch_yield(1000);
		}
	}
	return switch_channel_wait_for_flag(channel, flag, present, timeout, super);
}

/* Compile the pinned bridge implementation with only its wait boundary
 * controlled; libfreeswitch binds its internal symbols and cannot be interposed. */
#define switch_channel_wait_for_flag wait_boundary
#include <switch_ivr_bridge.c>
#undef switch_channel_wait_for_flag

/* The directory: "user" owns a kz device, anything else is a null endpoint. */
static switch_status_t locate_user(const char *key, const char *id, const char *domain, const char *ip,
								   switch_xml_t *user, switch_event_t *params)
{
	const char *dial = !strcmp(id, "user") ? "kz/device@example.invalid"
										   : "[null_auto_answer_delay=100,null_enable_auto_answer=true]null/target";
	char *xml = switch_mprintf("<user id='%s'><params><param name='endpoint-dial-string' value='%s'/></params></user>",
							   id, dial);

	*user = switch_xml_parse_str_dynamic(xml, SWITCH_FALSE);
	return *user ? SWITCH_STATUS_SUCCESS : SWITCH_STATUS_FALSE;
}

#define switch_xml_locate_user_merged locate_user
#include "../src/reprise_endpoints.c"
#undef switch_xml_locate_user_merged

static reprise_config_t *config;
static switch_event_t *replacement;
static switch_atomic_t replacement_seen;
static switch_mutex_t *event_mutex;

static void on_bowout(switch_event_t *event)
{
	switch_mutex_lock(event_mutex);
	if (!replacement) {
		switch_event_dup(&replacement, event);
		switch_atomic_set(&replacement_seen, 1);
	}
	switch_mutex_unlock(event_mutex);
}

SWITCH_STANDARD_APP(test_park)
{
	switch_ivr_park(session, NULL);
}

SWITCH_STANDARD_APP(test_bridge)
{
	switch_core_session_t *peer = NULL;
	switch_call_cause_t cause;

	if (switch_ivr_originate(session, &peer, &cause, "null/target", 3, NULL, NULL, NULL, NULL, NULL, SOF_NONE, NULL,
							 NULL) == SWITCH_STATUS_SUCCESS) {
		switch_ivr_multi_threaded_bridge(session, peer, NULL, NULL, NULL);
		switch_core_session_rwunlock(peer);
	}
}

/* "nested" bridges through the kz endpoint; anything else bridges directly. */
SWITCH_STANDARD_DIALPLAN(test_dialplan)
{
	switch_caller_extension_t *extension = switch_caller_extension_new(session, "bowout-target", "target");
	const char *destination =
		switch_channel_get_caller_profile(switch_core_session_get_channel(session))->destination_number;

	if (!strcmp(destination, "nested")) {
		switch_caller_extension_add_application(session, extension, "kz_bridge", "kz/user@example.invalid");
	} else {
		switch_caller_extension_add_application(session, extension, "test_bridge", "");
	}
	return extension;
}

SWITCH_MODULE_LOAD_FUNCTION(test_load)
{
	switch_application_interface_t *app_interface;
	switch_dialplan_interface_t *dp_interface;

	*module_interface = switch_loadable_module_create_module_interface(pool, "reprise_loopback_event_test");
	SWITCH_ADD_APP(app_interface, "test_bridge", "test", "test", test_bridge, "", SAF_SUPPORT_NOMEDIA);
	SWITCH_ADD_APP(app_interface, "test_park", "test", "test", test_park, "", SAF_SUPPORT_NOMEDIA | SAF_NO_LOOPBACK);
	SWITCH_ADD_DIALPLAN(dp_interface, "bowout-test", test_dialplan);
	reprise_kz_endpoints_add(module_interface);
	reprise_kz_dptools_add(module_interface);
	return SWITCH_STATUS_SUCCESS;
}

static const char *header(switch_event_t *event, const char *name)
{
	return switch_str_nil(switch_event_get_header(event, name));
}

/* Render the event through the served profile and build its routing key,
 * alongside the key ecallmgr binds for that event name. */
static void routing_keys(switch_event_t *event, const char *profile_name, const char *event_name, char *actual,
						 char *expected, size_t len)
{
	reprise_event_profile_t *profile = reprise_test_event_profile(config, profile_name);
	reprise_event_t *definition;
	cJSON *json;

	switch_assert(profile);
	definition = reprise_test_profile_event(profile, switch_event_get_header(event, "Event-Subclass"));
	switch_assert(definition);
	json = reprise_fields_render(definition->fields, event, profile->name);
	reprise_routing_key_build(&profile->routing_key, json, event, actual, len);
	snprintf(expected, len, "call.%s.%s", event_name, header(event, "Unique-ID"));
	fprintf(stderr, "ROUTING actual=%s expected=%s\n", actual, expected);
	cJSON_Delete(json);
}

/* Originate returns on the loopback leg's early media, before the other leg
 * has bridged to the real target; bowout on execute needs that bridge, so
 * wait for the other leg's BRIDGED flag (set before the bridge threads run,
 * ahead of the wait the race scenario stalls). */
static void wait_for_other_leg_bridged(switch_core_session_t *session)
{
	const char *other =
		switch_channel_get_variable(switch_core_session_get_channel(session), "other_loopback_leg_uuid");
	switch_time_t end = switch_micro_time_now() + 5000000;
	int bridged = 0;

	while (other && !bridged && switch_micro_time_now() < end) {
		switch_core_session_t *peer = switch_core_session_locate(other);

		if (peer) {
			bridged = switch_channel_test_flag(switch_core_session_get_channel(peer), CF_BRIDGED);
			switch_core_session_rwunlock(peer);
		}
		if (!bridged) switch_yield(1000);
	}
}

/* Originate the loopback pair into the bowout dialplan, hand the caller a
 * park extension and wait for the replacement event. */
static switch_status_t originate_bowout(const char *destination)
{
	switch_core_session_t *session = NULL;
	switch_call_cause_t cause;
	switch_caller_extension_t *extension;
	switch_time_t end;
	char *dial = switch_mprintf("{loopback_bowout_on_execute=true,ecallmgr_Account-ID=account-fixture}%s", destination);
	switch_status_t status =
		switch_ivr_originate(NULL, &session, &cause, dial, 4, NULL, NULL, NULL, NULL, NULL, SOF_NONE, NULL, NULL);

	free(dial);
	if (status != SWITCH_STATUS_SUCCESS) return status;

	wait_for_other_leg_bridged(session);
	extension = switch_caller_extension_new(session, "park", "park");
	switch_caller_extension_add_application(session, extension, "test_park", "");
	switch_channel_set_caller_extension(switch_core_session_get_channel(session), extension);
	switch_channel_set_state(switch_core_session_get_channel(session), CS_EXECUTE);
	switch_core_session_rwunlock(session);

	end = switch_micro_time_now() + 5000000;
	while (!switch_atomic_read(&replacement_seen) && switch_micro_time_now() < end) {
		switch_yield(1000);
	}
	return status;
}

/* The resigning loopback pair must leave and the real target must own the
 * copied park application; the event alone is not enough. */
static int replacement_survives(void)
{
	switch_time_t end = switch_micro_time_now() + 5000000;
	int survived = 0;

	while (!survived && switch_micro_time_now() < end) {
		switch_core_session_t *target = switch_core_session_locate(header(replacement, "Acquired-UUID"));
		switch_core_session_t *old_a = switch_core_session_locate(header(replacement, "Resigning-UUID"));
		switch_core_session_t *old_b = switch_core_session_locate(header(replacement, "Resigning-Peer-UUID"));

		if (target) {
			switch_channel_t *channel = switch_core_session_get_channel(target);

			survived = switch_channel_ready(channel) && switch_channel_test_flag(channel, CF_PARK) && !old_a &&
					   !old_b && switch_core_session_count() == 1;
			switch_core_session_rwunlock(target);
		}
		if (old_a) switch_core_session_rwunlock(old_a);
		if (old_b) switch_core_session_rwunlock(old_b);
		if (!survived) switch_yield(1000);
	}
	return survived;
}

/* The fst checks shared by every bowout scenario; a macro so they report
 * from the test body. */
#define check_replacement_identity()                                                                                   \
	do {                                                                                                               \
		char actual[256], expected[256];                                                                               \
		fst_check_string_equals(header(replacement, "Unique-ID"), header(replacement, "Resigning-UUID"));              \
		fst_check_string_equals(header(replacement, "variable_ecallmgr_Account-ID"), "account-fixture");               \
		fst_check(!zstr(switch_event_get_header(replacement, "Acquired-UUID")));                                       \
		routing_keys(replacement, "loopback", "CHANNEL_REPLACED", actual, expected, sizeof(actual));                   \
		fst_check_string_equals(actual, expected);                                                                     \
	} while (0)

static switch_status_t loopback_log(const switch_log_node_t *node, switch_log_level_t level)
{
	fprintf(stderr, "%s", node->data);
	return SWITCH_STATUS_SUCCESS;
}

FST_CORE_BEGIN("../loopback-conf")
{
	const char *err = NULL;
	switch_memory_pool_t *pool;

	if (getenv("REPRISE_TEST_TRACE")) switch_log_bind_logger(loopback_log, SWITCH_LOG_DEBUG, SWITCH_FALSE);
	switch_core_new_memory_pool(&pool);
	switch_mutex_init(&event_mutex, SWITCH_MUTEX_NESTED, pool);
	if (switch_loadable_module_exists("mod_loopback") != SWITCH_STATUS_SUCCESS) {
		switch_status_t status = switch_loadable_module_load_module("/usr/local/freeswitch/lib/freeswitch/mod",
																	"mod_loopback", SWITCH_FALSE, &err);

		fprintf(stderr, "MODULE status=%d error=%s\n", status, switch_str_nil(err));
		switch_assert(status == SWITCH_STATUS_SUCCESS);
	}
	switch_assert(switch_loadable_module_build_dynamic("reprise_loopback_event_test", test_load, NULL, NULL,
													   SWITCH_FALSE) == SWITCH_STATUS_SUCCESS);
	switch_event_bind("bowout-test", SWITCH_EVENT_CUSTOM, "loopback::bowout", on_bowout, NULL);
	config = reprise_test_load_fixture();

	FST_SUITE_BEGIN(loopback_replacement)

	FST_SETUP_BEGIN()
	{
		force_race = 0;
		switch_atomic_set(&race_exercised, 0);
		switch_mutex_lock(event_mutex);
		if (replacement) switch_event_destroy(&replacement);
		switch_atomic_set(&replacement_seen, 0);
		switch_mutex_unlock(event_mutex);
	}
	FST_SETUP_END()

	FST_TEARDOWN_BEGIN()
	{
	}
	FST_TEARDOWN_END()

	FST_TEST_BEGIN(execution_bowout_carries_routing_identity)
	{
		fst_requires(originate_bowout("loopback/target/default/bowout-test") == SWITCH_STATUS_SUCCESS);
		fst_requires(replacement);
		check_replacement_identity();
		fst_xcheck(replacement_survives(), "replacement target survives old loopback destruction and parks");
		switch_core_session_hupall(SWITCH_CAUSE_NORMAL_CLEARING);
		fst_check(reprise_test_drained());
	}
	FST_TEST_END()

	FST_TEST_BEGIN(nested_endpoint_bowout_keeps_real_target)
	{
		fst_requires(originate_bowout("loopback/nested/default/bowout-test") == SWITCH_STATUS_SUCCESS);
		fst_requires(replacement);
		check_replacement_identity();
		fst_xcheck(replacement_survives(), "replacement target survives old loopback destruction and parks");
		switch_core_session_hupall(SWITCH_CAUSE_NORMAL_CLEARING);
		fst_check(reprise_test_drained());
	}
	FST_TEST_END()

	FST_TEST_BEGIN(bowout_during_bridge_startup_preserves_new_owner)
	{
		force_race = 1;
		fst_requires(originate_bowout("loopback/nested/default/bowout-test") == SWITCH_STATUS_SUCCESS);
		fst_requires(replacement);
		check_replacement_identity();
		fst_xcheck(replacement_survives(), "replacement target survives old loopback destruction and parks");
		fst_check(switch_atomic_read(&race_exercised));
		switch_core_session_hupall(SWITCH_CAUSE_NORMAL_CLEARING);
		fst_check(reprise_test_drained());
	}
	FST_TEST_END()

	FST_TEST_BEGIN(sofia_and_direct_handoffs_keep_event_routing)
	{
		static const struct {
			const char *subclass;
			const char *profile;
			const char *event_name;
		} handoffs[] = {
			{"sofia::transferee", "sofia_transfer", "CHANNEL_TRANSFEREE"},
			{"sofia::transferor", "sofia_transfer", "CHANNEL_TRANSFEROR"},
			{"sofia::replaced", "sofia_transfer", "CHANNEL_REPLACED"},
			{"sofia::intercepted", "sofia_transfer", "CHANNEL_INTERCEPTED"},
			{"loopback::direct", "loopback", "CHANNEL_DIRECT"},
		};
		size_t i;

		for (i = 0; i < sizeof(handoffs) / sizeof(handoffs[0]); i++) {
			switch_event_t *event = NULL;
			char actual[256], expected[256];

			switch_event_create_subclass(&event, SWITCH_EVENT_CUSTOM, handoffs[i].subclass);
			switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Unique-ID", "handoff-fixture");
			routing_keys(event, handoffs[i].profile, handoffs[i].event_name, actual, expected, sizeof(actual));
			fst_check_string_equals(actual, expected);
			switch_event_destroy(&event);
		}
	}
	FST_TEST_END()

	FST_SUITE_END()

	switch_event_unbind_callback(on_bowout);
	if (replacement) switch_event_destroy(&replacement);
	reprise_config_destroy(&config);
	switch_core_destroy_memory_pool(&pool);
}
FST_CORE_END()
