/* Native CDR regression: real channel initialization, NULL-parent originate,
 * asynchronous kz endpoint and the served CDR renderer. Only directory lookup
 * is replaced. Requires the matching patched FreeSWITCH core; make test-cdr.
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

static switch_status_t locate_user(const char *key, const char *id, const char *domain, const char *ip,
								   switch_xml_t *user, switch_event_t *params)
{
	const char *dest = !strcmp(id, "usera") ? "kz/a@example.invalid" : "null/a";
	char *xml = switch_mprintf("<user id='%s'><params><param name='endpoint-dial-string' value='%s'/></params></user>",
							   id, dest);
	*user = switch_xml_parse_str_dynamic(xml, SWITCH_FALSE);
	return *user ? SWITCH_STATUS_SUCCESS : SWITCH_STATUS_FALSE;
}
#define switch_xml_locate_user_merged locate_user
#include "../src/reprise_endpoints.c"
#undef switch_xml_locate_user_merged

static switch_status_t cdr_log(const switch_log_node_t *node, switch_log_level_t level)
{
	fprintf(stderr, "%s", node->data);
	return SWITCH_STATUS_SUCCESS;
}
SWITCH_MODULE_LOAD_FUNCTION(cdr_load)
{
	*module_interface = switch_loadable_module_create_module_interface(pool, "reprise_cdr_test");
	reprise_kz_endpoints_add(module_interface);
	return SWITCH_STATUS_SUCCESS;
}
static void finish(switch_core_session_t *s)
{
	if (s) {
		switch_channel_hangup(switch_core_session_get_channel(s), SWITCH_CAUSE_NORMAL_CLEARING);
		switch_core_session_rwunlock(s);
	}
}
static int matches(cJSON *json, const char *id, double timestamp, const char *key, int root)
{
	cJSON *interaction = cJSON_GetObjectItem(json, "Call-Interaction");
	cJSON *i = cJSON_GetObjectItem(interaction, "Id"), *t = cJSON_GetObjectItem(interaction, "Timestamp"),
		  *k = cJSON_GetObjectItem(interaction, "Key"), *r = cJSON_GetObjectItem(interaction, "Is-Root");
	return cJSON_IsString(i) && !strcmp(i->valuestring, id) && cJSON_IsNumber(t) && t->valuedouble == timestamp &&
		   cJSON_IsString(k) && !strcmp(k->valuestring, key) && (root ? cJSON_IsTrue(r) : cJSON_IsFalse(r));
}
static reprise_config_t *cdr_config;

/* The KZ_CDR events the reporting hook fires, by channel name. */
static switch_memory_pool_t *cdr_pool;
static switch_mutex_t *cdr_mutex;
static switch_event_t *cdr_reported;

static void on_cdr(switch_event_t *event)
{
	switch_mutex_lock(cdr_mutex);
	switch_event_add_header_string(cdr_reported, SWITCH_STACK_BOTTOM, switch_event_get_header_nil(event, "Channel-Name"), "reported");
	switch_mutex_unlock(cdr_mutex);
}

/* Whether a KZ_CDR for the channel arrived within a second: the event
 * dispatch is asynchronous, so a report that is coming takes a moment and
 * a report that is not coming needs the whole wait to be sure. */
static int cdr_reported_for(const char *channel_name)
{
	switch_time_t end = switch_micro_time_now() + 1000000;
	int reported = 0;

	do {
		switch_mutex_lock(cdr_mutex);
		reported = switch_event_get_header(cdr_reported, channel_name) != NULL;
		switch_mutex_unlock(cdr_mutex);
		if (!reported) switch_yield(10000);
	} while (!reported && switch_micro_time_now() < end);
	return reported;
}

static cJSON *metadata(switch_core_session_t *session, const char *label)
{
	switch_event_t *event = NULL;
	reprise_event_profile_t *profile;
	reprise_event_t *definition;
	cJSON *json = NULL;
	char *text;
	switch_event_create_subclass(&event, SWITCH_EVENT_CUSTOM, "KZ_CDR");
	switch_channel_event_set_data(switch_core_session_get_channel(session), event);
	kz_event_add_interaction(event);
	for (profile = cdr_config->event_profiles; profile; profile = profile->next) {
		if (strcmp(profile->name, "cdr")) continue;
		for (definition = profile->events; definition; definition = definition->next) {
			if (!strcmp(definition->name, "KZ_CDR")) json = reprise_fields_render(definition->fields, event, profile->name);
		}
	}
	text = cJSON_PrintUnformatted(json);
	fprintf(stderr, "CDR_REGRESSION %s %s\n", label, switch_str_nil(text));
	free(text);
	switch_event_destroy(&event);
	return json;
}

static switch_core_session_t *originate(switch_core_session_t *parent, const char *dial)
{
	switch_core_session_t *session = NULL;
	switch_call_cause_t cause;
	switch_status_t status =
		switch_ivr_originate(parent, &session, &cause, dial, 4, NULL, NULL, NULL, NULL, NULL, SOF_NONE, NULL, NULL);
	fprintf(stderr, "ORIGINATE %s status=%d cause=%s\n", dial, status, switch_channel_cause2str(cause));
	return session;
}

/* A leg that is never answered: the originate gives up after a second and
 * cancels it, which hangs it up unanswered and runs its reporting. */
static switch_core_session_t *originate_unanswered(const char *dial)
{
	switch_core_session_t *session = NULL;
	switch_call_cause_t cause;
	switch_status_t status =
		switch_ivr_originate(NULL, &session, &cause, dial, 1, NULL, NULL, NULL, NULL, NULL, SOF_NONE, NULL, NULL);
	fprintf(stderr, "ORIGINATE %s status=%d cause=%s\n", dial, status, switch_channel_cause2str(cause));
	if (session) finish(session);
	return session;
}

static int complete(cJSON *json)
{
	cJSON *timestamp = cJSON_GetObjectItem(json, "Timestamp");
	cJSON *interaction = cJSON_GetObjectItem(json, "Call-Interaction");
	cJSON *nested = cJSON_GetObjectItem(interaction, "Timestamp");
	return cJSON_IsNumber(timestamp) && cJSON_IsNumber(nested) && nested->valuedouble == timestamp->valuedouble &&
		   cJSON_IsString(cJSON_GetObjectItem(interaction, "Id")) &&
		   cJSON_IsString(cJSON_GetObjectItem(interaction, "Key")) &&
		   cJSON_IsBool(cJSON_GetObjectItem(interaction, "Is-Root"));
}

FST_CORE_BEGIN("../conf")
{
	const char *err = NULL;
	const char *module_dir = getenv("REPRISE_TEST_MODDIR");

	switch_log_bind_logger(cdr_log, SWITCH_LOG_DEBUG10, SWITCH_FALSE);
	cdr_config = reprise_test_load_fixture();
	if (switch_loadable_module_exists("mod_loopback") != SWITCH_STATUS_SUCCESS) {
		switch_status_t status = switch_loadable_module_load_module(
			module_dir ? module_dir : SWITCH_GLOBAL_dirs.mod_dir, "mod_loopback", SWITCH_FALSE, &err);
		if (status != SWITCH_STATUS_SUCCESS) fprintf(stderr, "Cannot load mod_loopback: %s\n", switch_str_nil(err));
		switch_assert(status == SWITCH_STATUS_SUCCESS);
	}
	switch_assert(switch_loadable_module_build_dynamic("reprise_cdr_test", cdr_load, NULL, NULL, SWITCH_FALSE) ==
				  SWITCH_STATUS_SUCCESS);
	reprise_globals.tweaks[KZ_TWEAK_INTERACTION_ID] = 1;
	kz_tweaks_start();
	kz_cdr_start();
	switch_core_new_memory_pool(&cdr_pool);
	switch_mutex_init(&cdr_mutex, SWITCH_MUTEX_NESTED, cdr_pool);
	switch_event_create_plain(&cdr_reported, SWITCH_EVENT_CHANNEL_DATA);
	switch_event_bind("cdr-test", SWITCH_EVENT_CUSTOM, "KZ_CDR", on_cdr, NULL);

	FST_SUITE_BEGIN(cdr_interaction_contract)

	FST_SETUP_BEGIN()
	{
	}
	FST_SETUP_END()

	FST_TEARDOWN_BEGIN()
	{
		fst_check(reprise_test_drained());
	}
	FST_TEARDOWN_END()

	FST_TEST_BEGIN(fresh_leg_metadata_present)
	{
		switch_core_session_t *session = originate(NULL, "null/fresh");
		fst_check(session != NULL);
		if (session) {
			cJSON *json = metadata(session, "fresh");
			fst_check(complete(json));
			fst_check(cJSON_IsTrue(cJSON_GetObjectItem(cJSON_GetObjectItem(json, "Call-Interaction"), "Is-Root")));
			cJSON_Delete(json);
			finish(session);
		}
	}
	FST_TEST_END()

	FST_TEST_BEGIN(inherited_id_without_parent_metadata_required)
	{
		switch_core_session_t *session = originate(NULL, "{Call-Interaction-ID=63956145231-30acab7f}null/inherited");
		fst_check(session != NULL);
		if (session) {
			cJSON *json = metadata(session, "inherited");
			fst_check(complete(json));
			fst_check(matches(json, "63956145231-30acab7f", 63956145231.0, "30acab7f", 0));
			cJSON_Delete(json);
			finish(session);
		}
	}
	FST_TEST_END()

	FST_TEST_BEGIN(inherited_id_via_kz_metadata_required)
	{
		switch_core_session_t *session =
			originate(NULL, "{Call-Interaction-ID=63956145231-30acab7f}kz/usera@example.invalid");
		fst_check(session != NULL);
		if (session) {
			cJSON *json = metadata(session, "kz-child");
			fst_check(complete(json));
			fst_check(matches(json, "63956145231-30acab7f", 63956145231.0, "30acab7f", 0));
			cJSON_Delete(json);
			finish(session);
		}
	}
	FST_TEST_END()

	FST_TEST_BEGIN(explicit_parent_hook_metadata_present)
	{
		switch_core_session_t *parent = originate(NULL, "null/parent");
		fst_check(parent != NULL);
		if (parent) {
			switch_core_session_t *child = originate(parent, "null/child");
			fst_check(child != NULL);
			if (child) {
				cJSON *json = metadata(child, "parent-hook-child");
				cJSON *interaction = cJSON_GetObjectItem(json, "Call-Interaction");
				cJSON *id = cJSON_GetObjectItem(interaction, "Id");
				const char *parent_id =
					switch_channel_get_variable(switch_core_session_get_channel(parent), "Call-Interaction-ID");
				fst_check(complete(json));
				fst_check(cJSON_IsString(id) && parent_id && !strcmp(id->valuestring, parent_id));
				fst_check(cJSON_IsFalse(cJSON_GetObjectItem(interaction, "Is-Root")));
				cJSON_Delete(json);
				finish(child);
			}
			finish(parent);
		}
	}
	FST_TEST_END()

	FST_TEST_BEGIN(reassigned_id_does_not_keep_old_timestamp)
	{
		switch_core_session_t *session = originate(NULL, "null/reassigned");
		fst_check(session != NULL);
		if (session) {
			cJSON *json;
			switch_channel_set_variable(switch_core_session_get_channel(session), "Call-Interaction-ID",
										"63956145231-30acab7f");
			json = metadata(session, "reassigned");
			fst_check(complete(json));
			fst_check(matches(json, "63956145231-30acab7f", 63956145231.0, "30acab7f", 0));
			cJSON_Delete(json);
			finish(session);
		}
	}
	FST_TEST_END()

	FST_TEST_BEGIN(hangup_reports_a_cdr)
	{
		switch_core_session_t *session = originate(NULL, "null/reported");
		fst_check(session != NULL);
		if (session) {
			char name[256];
			switch_copy_string(name, switch_channel_get_name(switch_core_session_get_channel(session)), sizeof(name));
			finish(session);
			fst_check(cdr_reported_for(name));
		}
	}
	FST_TEST_END()

	FST_TEST_BEGIN(unanswered_hangup_reports_a_cdr)
	{
		/* A channel that never answers is cancelled by the originate and
		 * still reported. */
		fst_check(originate_unanswered("{null_enable_auto_answer=false}null/unanswered") == NULL);
		fst_check(cdr_reported_for("null/unanswered"));
	}
	FST_TEST_END()

	FST_TEST_BEGIN(redirected_before_answer_reports_no_cdr)
	{
		/* What ecallmgr sets on an unanswered channel it sends to another
		 * media server with a 302: the arriving channel reports the call. */
		fst_check(originate_unanswered("{null_enable_auto_answer=false,ecallmgr_Redirected-To=sip:10.0.0.2:11000}null/redirected") == NULL);
		fst_check(!cdr_reported_for("null/redirected"));
	}
	FST_TEST_END()

	FST_TEST_BEGIN(redirected_after_answer_keeps_its_cdr)
	{
		/* The answer won the race and sofia refused the redirect: the call
		 * went on here and its record stands. */
		switch_core_session_t *session = originate(NULL, "{ecallmgr_Redirected-To=sip:10.0.0.2:11000}null/answered-first");
		fst_check(session != NULL);
		if (session) {
			char name[256];
			switch_copy_string(name, switch_channel_get_name(switch_core_session_get_channel(session)), sizeof(name));
			fst_check(switch_channel_test_flag(switch_core_session_get_channel(session), CF_ANSWERED));
			finish(session);
			fst_check(cdr_reported_for(name));
		}
	}
	FST_TEST_END()

	FST_SUITE_END()
	switch_event_unbind_callback(on_cdr);
	switch_event_destroy(&cdr_reported);
	switch_core_destroy_memory_pool(&cdr_pool);
	kz_cdr_stop();
	kz_tweaks_stop();
	reprise_config_destroy(&cdr_config);
}
FST_CORE_END()
