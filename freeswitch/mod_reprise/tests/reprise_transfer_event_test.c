/* Real channel snapshots through the served transfer completion profile.
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

static reprise_config_t *config;
static reprise_event_t *definition;
static switch_core_session_t *origin, *saved;

SWITCH_MODULE_LOAD_FUNCTION(event_test_load)
{
	*module_interface = switch_loadable_module_create_module_interface(pool, "reprise_transfer_event_test");
	reprise_kz_commands_add(module_interface);
	return SWITCH_STATUS_SUCCESS;
}

static switch_core_session_t *fixture(void)
{
	switch_core_session_t *session = switch_core_session_request_by_name("null", SWITCH_CALL_DIRECTION_INBOUND, NULL);
	switch_caller_profile_t *profile =
		switch_caller_profile_new(switch_core_session_get_pool(session), "phone", "XML", "Caller", "3104", "127.0.0.1",
								  NULL, NULL, NULL, "test", "default", "3101");

	switch_channel_set_caller_profile(switch_core_session_get_channel(session), profile);
	return session;
}

/* A CHANNEL_EXECUTE_COMPLETE for kz_bridge, snapshotted from the origin channel. */
static switch_event_t *completion(void)
{
	switch_event_t *event = NULL;

	switch_event_create_plain(&event, SWITCH_EVENT_CHANNEL_EXECUTE_COMPLETE);
	switch_channel_event_set_data(switch_core_session_get_channel(origin), event);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Application", "kz_bridge");
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Application-UUID", "bridge-command");
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Application-UUID-Name", "bridge");
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Application-Response", "_none_");
	return event;
}

FST_CORE_BEGIN("../conf")
{
	reprise_event_profile_t *profile;

	config = reprise_test_load_fixture();
	profile = reprise_test_event_profile(config, "execute_complete");
	switch_assert(profile);
	definition = profile->events;
	switch_assert(definition);
	switch_loadable_module_build_dynamic("reprise_transfer_event_test", event_test_load, NULL, NULL, SWITCH_FALSE);
	origin = fixture();
	saved = fixture();
	switch_assert(origin && saved);
	switch_channel_set_flag(switch_core_session_get_channel(saved), CF_ANSWERED);

	FST_SUITE_BEGIN(transfer_event_contract)

	FST_SETUP_BEGIN()
	{
		switch_channel_t *channel = switch_core_session_get_channel(origin);

		switch_channel_clear_flag(channel, CF_TRANSFER);
		switch_channel_clear_flag(channel, CF_ORIGINATING_XFER);
		switch_channel_clear_flag(channel, CF_XFER_ZOMBIE);
		switch_channel_clear_flag(channel, CF_REDIRECT);
		switch_channel_clear_flag(channel, CF_INTERCEPTED);
	}
	FST_SETUP_END()

	FST_TEARDOWN_BEGIN()
	{
	}
	FST_TEARDOWN_END()

	FST_TEST_BEGIN(intentional_unbridge_does_not_complete_callflow)
	{
		switch_event_t *event;

		switch_channel_set_flag(switch_core_session_get_channel(origin), CF_TRANSFER);
		event = completion();
		fst_check(reprise_filters_apply(event, definition->filters) != NULL);
		switch_event_destroy(&event);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(real_failed_bridge_still_reaches_callflow)
	{
		switch_event_t *event = completion();

		switch_event_del_header(event, "Application-Response");
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Application-Response", "USER_BUSY");
		fst_check(reprise_filters_apply(event, definition->filters) == NULL);
		switch_event_destroy(&event);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(early_transfer_failure_is_reported_on_saved_call)
	{
		switch_channel_t *channel = switch_core_session_get_channel(origin);
		switch_event_t *event;
		cJSON *json, *id, *cause, *state;

		switch_channel_set_flag(channel, CF_TRANSFER);
		switch_channel_set_flag(channel, CF_ORIGINATING_XFER);
		switch_channel_set_variable(channel, "satt_uuid", switch_core_session_get_uuid(saved));
		switch_channel_set_variable(channel, "last_bridge_hangup_cause", "USER_BUSY");
		switch_channel_set_variable(channel, "last_bridge_proto_specific_hangup_cause", "sip:486");
		event = completion();
		fst_check(reprise_filters_apply(event, definition->filters) == NULL);

		json = reprise_fields_render(definition->fields, event, "execute_complete");
		id = cJSON_GetObjectItem(json, "Call-ID");
		cause = cJSON_GetObjectItem(json, "Hangup-Cause");
		state = cJSON_GetObjectItem(json, "Channel-Answer-State");
		fst_check(cJSON_IsString(id) && !strcmp(id->valuestring, switch_core_session_get_uuid(saved)));
		fst_check(cJSON_IsString(cause) && !strcmp(cause->valuestring, "USER_BUSY"));
		fst_check(cJSON_IsString(state) && !strcmp(state->valuestring, "answered"));
		fst_check(cJSON_GetObjectItem(json, "Unique-ID") == NULL);
		cJSON_Delete(json);
		switch_event_destroy(&event);
	}
	FST_TEST_END()

	FST_SUITE_END()

	switch_core_session_destroy(&origin);
	switch_core_session_destroy(&saved);
	reprise_config_destroy(&config);
}
FST_CORE_END()
