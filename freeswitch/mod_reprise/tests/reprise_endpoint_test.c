/* Execute the actual endpoint with deterministic directory/originate edges.
 * No broker, SIP listener, or real call is used.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include <test/switch_test.h>
#include "reprise_kz.h"
#include "reprise_test_alloc.h"
#include "reprise_test_util.h"

static const char *directory_reply;
static int originate_calls;
static char first_dial[512], observed_dial[512], observed_name[128], observed_number[128];

static switch_status_t test_locate_user(const char *key, const char *user_name, const char *domain_name, const char *ip,
										switch_xml_t *user, switch_event_t *params)
{
	*user = switch_xml_parse_str_dynamic(strdup(directory_reply), SWITCH_FALSE);
	return *user ? SWITCH_STATUS_SUCCESS : SWITCH_STATUS_FALSE;
}

/* Every nested originate fails with SUBSCRIBER_ABSENT after recording what
 * the endpoint asked for. */
static switch_status_t test_originate(switch_core_session_t *session, switch_core_session_t **bleg,
									  switch_call_cause_t *cause, const char *bridgeto, uint32_t timelimit_sec,
									  const switch_state_handler_table_t *table, const char *cid_name_override,
									  const char *cid_num_override, switch_caller_profile_t *caller_profile_override,
									  switch_event_t *ovars, switch_originate_flag_t flags,
									  switch_call_cause_t *cancel_cause, switch_dial_handle_t *dh)
{
	originate_calls++;
	if (originate_calls == 1) snprintf(first_dial, sizeof(first_dial), "%s", bridgeto);
	snprintf(observed_dial, sizeof(observed_dial), "%s", bridgeto);
	snprintf(observed_name, sizeof(observed_name), "%s", switch_str_nil(cid_name_override));
	snprintf(observed_number, sizeof(observed_number), "%s", switch_str_nil(cid_num_override));
	*cause = SWITCH_CAUSE_SUBSCRIBER_ABSENT;
	return SWITCH_STATUS_FALSE;
}

/* Redirect only these two edges; compile the endpoint implementation itself. */
#define switch_xml_locate_user_merged test_locate_user
#define switch_ivr_originate test_originate
#include "../src/reprise_endpoints.c"
#undef switch_xml_locate_user_merged
#undef switch_ivr_originate

static switch_status_t endpoint_log(const switch_log_node_t *node, switch_log_level_t level)
{
	fprintf(stderr, "%s", node->data);
	return SWITCH_STATUS_SUCCESS;
}

SWITCH_MODULE_LOAD_FUNCTION(endpoint_test_load)
{
	*module_interface = switch_loadable_module_create_module_interface(pool, "reprise_endpoint_test");
	reprise_kz_endpoints_add(module_interface);
	return SWITCH_STATUS_SUCCESS;
}

/* The outer call uses the real core lifecycle. Only the nested originate
 * inside reprise_endpoints.c is replaced with the controlled failure above. */
static switch_call_cause_t run_endpoint(switch_event_t *vars)
{
	switch_core_session_t *session = NULL;
	switch_call_cause_t cause = SWITCH_CAUSE_NONE;

	switch_ivr_originate(NULL, &session, &cause, "kz/test@example.invalid", 3, NULL, NULL, NULL, NULL, vars, SOF_NONE,
						 NULL, NULL);
	if (session) {
		switch_channel_hangup(switch_core_session_get_channel(session), SWITCH_CAUSE_NORMAL_CLEARING);
		switch_core_session_rwunlock(session);
	}
	reprise_test_drained();
	return cause;
}

/* Ignore injected loopback policy variables while checking endpoint order. */
static const char *without_forward_vars(const char *dial)
{
	static char result[512];
	const char *start = strstr(dial, "[^^!");

	if (start) {
		const char *end = strchr(start, ']');

		if (end) {
			snprintf(result, sizeof(result), "%.*s%s", (int) (start - dial), dial, end + 1);
			return result;
		}
	}
	return dial;
}

/* XML mirrors ecallmgr_fs_xml:callfwd_el/1. Empty runtime means indirect. */
static switch_call_cause_t run_forwarding(const char *params, const char *forward_vars, const char *runtime)
{
	switch_event_t *vars = NULL;
	switch_call_cause_t cause;
	char *xml =
		switch_mprintf("<user id='test'><params><param name='endpoint-dial-string' value='sofia/internal/original'/>"
					   "%s</params><call-forward>%s</call-forward></user>",
					   params, forward_vars);

	directory_reply = xml;
	if (runtime) {
		switch_event_create_plain(&vars, SWITCH_EVENT_GENERAL);
		switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "kz-endpoint-runtime-context", runtime);
	}
	cause = run_endpoint(vars);
	if (vars) switch_event_destroy(&vars);
	free(xml);
	directory_reply = NULL;
	return cause;
}

#define FORWARD_DIAL "<variable name='Dial-String' value='loopback/3101@example.invalid'/>"
#define SUBSTITUTE "<variable name='Is-Substitute' value='true'/>"
#define DIRECT_ONLY "<variable name='Direct-Calls-Only' value='true'/>"
#define LEGACY_DIAL "<param name='callforward-dial-string' value='loopback/legacy@example.invalid'/>"

FST_CORE_BEGIN("../conf")
{
	if (getenv("REPRISE_TEST_TRACE")) switch_log_bind_logger(endpoint_log, SWITCH_LOG_DEBUG, SWITCH_FALSE);
	switch_loadable_module_build_dynamic("reprise_endpoint_test", endpoint_test_load, NULL, NULL, SWITCH_FALSE);

	FST_SUITE_BEGIN(reprise_endpoint)

	FST_SETUP_BEGIN()
	{
		originate_calls = 0;
		first_dial[0] = observed_dial[0] = observed_name[0] = observed_number[0] = '\0';
	}
	FST_SETUP_END()

	FST_TEARDOWN_BEGIN()
	{
	}
	FST_TEARDOWN_END()

	FST_TEST_BEGIN(endpoint_alias_cleanup)
	{
		directory_reply = "<user id='test'><params><param name='endpoint-dial-string' "
						  "value='[sip_proxy_uri=sip:proxy]sofia/internal/test'/></params></user>";
		fst_check(run_endpoint(NULL) == SWITCH_CAUSE_SUBSCRIBER_ABSENT);
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial), "[sip_route_uri=sip:proxy]sofia/internal/test");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(endpoint_caller_id_lifetime)
	{
		switch_event_t *vars = NULL;

		directory_reply =
			"<user id='test'><params><param name='endpoint-dial-string' value='sofia/internal/test'/></params></user>";
		switch_event_create_plain(&vars, SWITCH_EVENT_GENERAL);
		switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "CIDName", "Resolved Caller");
		switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "CIDNumber", "12345");
		switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "origination_caller_id_name", "${CIDName}");
		switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "origination_caller_id_number", "${CIDNumber}");
		fst_check(run_endpoint(vars) == SWITCH_CAUSE_SUBSCRIBER_ABSENT);
		fst_check(originate_calls == 1);
		fst_check_string_equals(observed_name, "Resolved Caller");
		fst_check_string_equals(observed_number, "12345");
		switch_event_destroy(&vars);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(endpoint_malformed_flags)
	{
		switch_event_t *vars = NULL;

		directory_reply = "<user id='test'><params><param name='endpoint-dial-string' value='sofia/internal/test'/>"
						  "<param name='callforward-dial-string' value='sofia/internal/forward'/></params>"
						  "<call-forward><variable name='Direct-Calls-Only' value='true'/>"
						  "<variable name='Is-Substitute' value='true'/></call-forward></user>";
		switch_event_create_plain(&vars, SWITCH_EVENT_GENERAL);
		switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, "kz-endpoint-runtime-context",
									   "{\"Flags\":[null,42,true]}");
		fst_check(run_endpoint(vars) == SWITCH_CAUSE_SUBSCRIBER_ABSENT);
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial), "sofia/internal/test");
		switch_event_destroy(&vars);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_canonical_substitute)
	{
		fst_check(run_forwarding("", FORWARD_DIAL SUBSTITUTE, NULL) == SWITCH_CAUSE_SUBSCRIBER_ABSENT);
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial), "loopback/3101@example.invalid");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_legacy_compatibility)
	{
		run_forwarding(LEGACY_DIAL, SUBSTITUTE, NULL);
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial), "loopback/legacy@example.invalid");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_canonical_precedence)
	{
		run_forwarding(LEGACY_DIAL, FORWARD_DIAL SUBSTITUTE, NULL);
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial), "loopback/3101@example.invalid");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_append_separator)
	{
		run_forwarding("<param name='endpoint-separator' value='|'/>", FORWARD_DIAL, NULL);
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial),
								"sofia/internal/original|loopback/3101@example.invalid");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_failover_order)
	{
		run_forwarding("", FORWARD_DIAL "<variable name='Is-Failover' value='true'/>", NULL);
		fst_check(originate_calls == 2);
		fst_check_string_equals(first_dial, "sofia/internal/original");
		fst_check_string_equals(without_forward_vars(observed_dial), "loopback/3101@example.invalid");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_direct_only_direct)
	{
		run_forwarding("", FORWARD_DIAL SUBSTITUTE DIRECT_ONLY, "{\"Flags\":[\"direct_call\"]}");
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial), "loopback/3101@example.invalid");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_direct_only_indirect)
	{
		run_forwarding("", FORWARD_DIAL SUBSTITUTE DIRECT_ONLY, "{\"Flags\":[]}");
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial), "sofia/internal/original");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_missing_selected_target)
	{
		fst_check(run_forwarding("", SUBSTITUTE, NULL) == SWITCH_CAUSE_MANDATORY_IE_MISSING);
		fst_check(originate_calls == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_empty_canonical_does_not_use_legacy)
	{
		fst_check(run_forwarding(LEGACY_DIAL, "<variable name='Dial-String' value=''/>" SUBSTITUTE, NULL) ==
				  SWITCH_CAUSE_MANDATORY_IE_MISSING);
		fst_check(originate_calls == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_missing_unselected_target)
	{
		run_forwarding("", SUBSTITUTE DIRECT_ONLY, "{\"Flags\":[]}");
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial), "sofia/internal/original");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_disabled_directory)
	{
		directory_reply = "<user id='test'><params><param name='endpoint-dial-string' "
						  "value='sofia/internal/original'/></params></user>";
		run_endpoint(NULL);
		fst_check(originate_calls == 1);
		fst_check_string_equals(without_forward_vars(observed_dial), "sofia/internal/original");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(endpoint_empty_destination)
	{
		directory_reply = "<user id='test'><params><param name='endpoint-dial-string' value=''/></params></user>";
		fst_check(run_endpoint(NULL) == SWITCH_CAUSE_MANDATORY_IE_MISSING);
		fst_check(originate_calls == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_inception_only)
	{
		run_forwarding("", FORWARD_DIAL SUBSTITUTE "<variable name='Inception-Only' value='offnet'/>",
					   "{\"Inception\":\"onnet\"}");
		fst_check(originate_calls == 1);
		fst_check_string_equals(observed_dial, "sofia/internal/original");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(forwarding_indirect_only)
	{
		run_forwarding("", FORWARD_DIAL SUBSTITUTE "<variable name='Indirect-Calls-Only' value='true'/>",
					   "{\"Flags\":[\"direct_call\"]}");
		fst_check(originate_calls == 1);
		fst_check_string_equals(observed_dial, "sofia/internal/original");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(failover_reason_filter)
	{
		run_forwarding(
			"",
			FORWARD_DIAL
			"<variable name='Is-Failover' value='true'/><variable name='Failover-Reasons' value='USER_BUSY'/>",
			NULL);
		fst_check(originate_calls == 1);
		fst_check_string_equals(observed_dial, "sofia/internal/original");
	}
	FST_TEST_END()

	FST_TEST_BEGIN(endpoint_dnd)
	{
		directory_reply =
			"<user id='test'><profile-variables><variable name='Endpoint-DND' value='true'/></profile-variables>"
			"<params><param name='endpoint-dial-string' value='sofia/internal/test'/></params></user>";
		fst_check(run_endpoint(NULL) == SWITCH_CAUSE_SUBSCRIBER_DND);
		fst_check(originate_calls == 0);
	}
	FST_TEST_END()

	FST_TEST_BEGIN(endpoint_exact_loop_is_rejected)
	{
		switch_event_t *vars = NULL;

		directory_reply =
			"<user id='test'><params><param name='endpoint-dial-string' value='sofia/internal/test'/></params></user>";
		switch_event_create_plain(&vars, SWITCH_EVENT_GENERAL);
		switch_event_add_header_string(vars, SWITCH_STACK_BOTTOM, KZ_ENDPOINT_IDS_VARIABLE, "test");
		fst_check(run_endpoint(vars) == SWITCH_CAUSE_REQUESTED_CHAN_UNAVAIL);
		fst_check(originate_calls == 0);
		switch_event_destroy(&vars);
	}
	FST_TEST_END()

	FST_SUITE_END()
}
FST_CORE_END()
