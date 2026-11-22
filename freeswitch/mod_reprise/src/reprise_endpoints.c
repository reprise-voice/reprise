/*
 * FreeSWITCH Modular Media Switching Software Library / Soft-Switch Application
 * Copyright (C) 2005-2012, Anthony Minessale II <anthm@freeswitch.org>
 *
 * Version: MPL 1.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is FreeSWITCH Modular Media Switching Software Library / Soft-Switch Application
 *
 * The Initial Developer of the Original Code is
 * Anthony Minessale II <anthm@freeswitch.org>
 * Portions created by the Initial Developer are Copyright (C)
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * The contributors named in mod_kazoo's kazoo_endpoints.c as distributed
 * in freeswitch-20.23.6-2600hz.23 (2600Hz).
 * Vonix LLC (port to the stock FreeSWITCH core, 2026).
 *
 *
 * reprise_endpoints.c -- the `kz` endpoint. Ported from the distributed
 * mod_kazoo 20.23.6-2600hz.23; source: the
 * freeswitch-20.23.6-2600hz.23.el9.x86_64 debugsource RPM.
 *
 */
#include "reprise_kz.h"
#include "reprise_endpoint_compat.h"
/* ecallmgr's dial strings and dial-vars name two mod_sofia variables the
 * 2600hz FreeSWITCH fork added and stock sofia does not know:
 * sip_proxy_uri (the location reply's Proxy-URI: send the INVITE through
 * this proxy) and sip_invite_uri (SIP-Invite-URI: the request URI). Stock
 * sofia's names are sip_route_uri (NUTAG_PROXY) and sip_invite_req_uri.
 * Alias them in the expanded dial string and in the leg's variables. */
static const struct { const char *fork; const char *stock; } sofia_aliases[] = {
	{"sip_proxy_uri", "sip_route_uri"},
	{"sip_invite_uri", "sip_invite_req_uri"},
	{NULL, NULL}
};

/* Always return an owned string: reprise_expand_headers may return its input. */
char *kz_endpoint_expand_dial(switch_event_t *event, const char *input)
{
	int i;
	char *dial = reprise_expand_headers(event, input);
	if (dial && dial == input) dial = strdup(input);
	for (i = 0; sofia_aliases[i].fork && dial; i++) {
		char from[64], to[64], *replaced;
		switch_snprintf(from, sizeof(from), "%s=", sofia_aliases[i].fork);
		switch_snprintf(to, sizeof(to), "%s=", sofia_aliases[i].stock);
		if (!strstr(dial, from)) continue;
		replaced = switch_string_replace(dial, from, to);
		free(dial);
		dial = replaced;
	}
	return dial;
}

int kz_endpoint_context_has_flag(cJSON *ctx, const char *flag)
{
	cJSON *flags, *item;
	if (!ctx || ctx->type != cJSON_Object || !flag) return 0;
	flags = cJSON_GetObjectItem(ctx, "Flags");
	if (!flags || flags->type != cJSON_Array) return 0;
	cJSON_ArrayForEach(item, flags) {
		if (item->type == cJSON_String && item->valuestring && !strcmp(item->valuestring, flag)) return 1;
	}
	return 0;
}

static void kz_alias_sofia_headers(switch_event_t *event)
{
	int i;
	if (!event) return;
	for (i = 0; sofia_aliases[i].fork; i++) {
		const char *val = switch_event_get_header(event, sofia_aliases[i].fork);
		if (!zstr(val) && !switch_event_get_header(event, sofia_aliases[i].stock)) {
			switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, sofia_aliases[i].stock, val);
		}
	}
}



#define KZ_ENDPOINT_LOOPBACK_EXPORT KZ_ORIGINATE_UUID_VARIABLE "," INTERACTION_VARIABLE "," KZ_ENDPOINT_IDS_VARIABLE

static switch_endpoint_interface_t *kz_endpoint_interface = NULL;


static const char *kz_known_ccvs[] = {
		"Account-ID",
		"Authorizing-Type",
		"Authorizing-ID",
		"Owner-ID",
		"Retain-CID",
		"Ecallmgr-Node",
		"Channel-Authorized",
		INTERACTION_VARIABLE,
		NULL
};

switch_bool_t kz_is_known_ccv(const char *ccv)
{
	int i;
	for(i = 0; kz_known_ccvs[i] != NULL; i++) {
		if  (!strcasecmp(ccv, kz_known_ccvs[i])) return SWITCH_TRUE;
	}
	return SWITCH_FALSE;
}


static const char *kz_endpoint_variables[] = {
		"Call-Control-Queue",
		"Call-Control-PID",
		"Call-Control-Node",
		INTERACTION_VARIABLE,
		"ecallmgr_Ecallmgr-Node",
		KZ_ORIGINATE_UUID_VARIABLE,
		KZ_ENDPOINT_IDS_VARIABLE,
		"Switch-URI",
		"Switch-URL",
		NULL
};

typedef enum {
	KZ_INCEPTION_UNKNOWN,
	KZ_INCEPTION_ONNET,
	KZ_INCEPTION_OFFNET
} kz_inception_enum_t;
typedef uint32_t kz_inception_t;

typedef enum {
	KZ_CFWD_SUBSTITUTE,
	KZ_CFWD_FAILOVER,
	KZ_CFWD_NORMAL
} kz_cfwd_enum_t;
typedef uint32_t kz_cfwd_type_t;

struct kz_cfwd {
	kz_cfwd_type_t type;
	char* dial;
	switch_event_t *variables;
};
typedef struct kz_cfwd kz_cfwd_t;

typedef enum {
	KZ_FAILOVER_MIGRATE,
	KZ_FAILOVER_NORMAL
} kz_failover_enum_t;
typedef uint32_t kz_failover_type_t;

struct kz_failover {
	kz_failover_type_t type;
	char* dial;
	switch_event_t *variables;
};
typedef struct kz_failover kz_failover_t;

struct kz_private_object {
	switch_core_session_t *session;
	switch_core_session_t *outbound_session;
	switch_xml_t xml_endpoint;
	switch_event_t *var_event;
	switch_call_cause_t cancel_cause;
	switch_call_cause_t *cancel_cause_ptr;
	switch_caller_profile_t* caller_profile;
	char* failover_dial_string;
	char* failover_reasons;
	char* dial_string;
	char* account_id;
	char* endpoint_id;
	char* reference_uuid;
	char* origination_uuid;
	switch_bool_t done;
	switch_call_cause_t setup_cause;
	cJSON* runtime_context;
	kz_inception_t inception;
	kz_cfwd_t* cfwd;
	kz_failover_t* failover;
	switch_bool_t routing;
	switch_call_cause_t cause;
	switch_status_t dial_status;
};

typedef struct kz_private_object kz_private_object_t;

switch_bool_t kz_is_context_flag_set(cJSON* context, char* flag)
{
	cJSON *item = NULL, *flags = NULL;

	if (!context) {
		return SWITCH_FALSE;
	}

	flags = cJSON_GetObjectItem(context, "Flags");
	if (!flags) {
		return SWITCH_FALSE;
	}

	if (flags->type != cJSON_Array) {
		return SWITCH_FALSE;
	}

	cJSON_ArrayForEach(item, flags) {
		if (item->type == cJSON_String && item->valuestring && !strcmp(item->valuestring, flag)) {
			return SWITCH_TRUE;
		}
	}

	return SWITCH_FALSE;
}

static switch_status_t kz_endpoint_pool_destroy_callback(void *data)
{
	kz_private_object_t* tech_pvt = (kz_private_object_t*) data;

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "POOL DESTROY CALLBACK\n");

	if (tech_pvt->xml_endpoint) {
		switch_xml_free(tech_pvt->xml_endpoint);
	}

	if (tech_pvt->var_event) {
		switch_event_destroy(&tech_pvt->var_event);
	}

	if (tech_pvt->cfwd && tech_pvt->cfwd->variables) {
		switch_event_destroy(&tech_pvt->cfwd->variables);
	}

	if (tech_pvt->failover && tech_pvt->failover->variables) {
		switch_event_destroy(&tech_pvt->failover->variables);
	}

	if (tech_pvt->session) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "RELEASE CALLER\n");
		switch_core_session_rwunlock(tech_pvt->session);
	}

	if (tech_pvt->outbound_session) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "RELEASE INNER\n");
		switch_core_session_rwunlock(tech_pvt->outbound_session);
	}

	if (tech_pvt->runtime_context) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "RELEASE RUNTIME CONTEXT\n");
		cJSON_Delete(tech_pvt->runtime_context);
	}

	return SWITCH_STATUS_SUCCESS;
}

kz_private_object_t *kz_new_pvt(switch_core_session_t *session)
{
	switch_memory_pool_t *pool = switch_core_session_get_pool(session);
	kz_private_object_t *tech_pvt = (kz_private_object_t *) switch_core_session_alloc(session, sizeof(kz_private_object_t));
	/* Released by on_destroy, while the session pool is still alive. */
	(void)pool;
	return tech_pvt;
}

void kz_endpoint_update_caller_profile_and_variables(switch_core_session_t *session, switch_core_session_t *new_session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	const char *context;
	switch_caller_profile_t *cp;
	switch_channel_t* new_channel = switch_core_session_get_channel(new_session);

	if (tech_pvt->var_event) {
		switch_event_del_header(tech_pvt->var_event, "origination_uuid");
	}

	if ((context = switch_channel_get_variable(new_channel, "user_context"))) {
		if ((cp = switch_channel_get_caller_profile(new_channel))) {
			cp->context = switch_core_strdup(cp->pool, context);
		}
	}
}

SWITCH_DECLARE(cJSON*) kz_endpoint_get_runtime_context(switch_core_session_t *session)
{
	switch_channel_t* channel = switch_core_session_get_channel(session);
	cJSON* ctx = NULL;
	const char * str_ctx = switch_channel_get_variable(channel, "kz-endpoint-runtime-context");
	if ( str_ctx  ) {
		ctx = cJSON_Parse(str_ctx);
	}
	return ctx;
}

void kz_endpoint_setup_runtime_context(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	tech_pvt->runtime_context = kz_endpoint_get_runtime_context(session);
}

SWITCH_DECLARE(kz_inception_t) kz_parse_inception(const char* inception)
{
	if(!inception) {
		return KZ_INCEPTION_UNKNOWN;
	}

	if (!strcasecmp(inception, "onnet")) {
		return KZ_INCEPTION_ONNET;
	} else if (!strcasecmp(inception, "internal")) {
		return KZ_INCEPTION_ONNET;
	} else if (!strcasecmp(inception, "offnet")) {
		return KZ_INCEPTION_OFFNET;
	} else if (!strcasecmp(inception, "external")) {
		return KZ_INCEPTION_OFFNET;
	} else {
		return KZ_INCEPTION_UNKNOWN;
	}
}

SWITCH_DECLARE(const char*) kz_inception2str(kz_inception_t inception)
{
	if (inception == KZ_INCEPTION_ONNET) {
		return "onnet";
	} if (inception == KZ_INCEPTION_OFFNET) {
			return "offnet";
	}
	return "unknown";
}

void kz_endpoint_setup_inception(switch_core_session_t *session)
{
	const char * inception = NULL;
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	if (!tech_pvt->runtime_context) {
		return;
	}
	inception = cJSON_GetObjectCstr(tech_pvt->runtime_context, "Inception");
	tech_pvt->inception = kz_parse_inception(inception);
}

/* Directory profile variables are available independently of the stock
 * core's optional global soft-profile lookup setting. */
static const char *kz_endpoint_profile_field(switch_caller_profile_t *profile, const char *name)
{
 profile_node_t *node;
 if (!profile) return NULL;
 for (node=profile->soft; node; node=node->next) {
  if (!strcasecmp(node->var,name)) return node->val;
 }
 return switch_caller_get_field_by_name(profile,name);
}

void kz_endpoint_setup_caller_profile_defaults(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t* channel = switch_core_session_get_channel(session);
	switch_caller_profile_t* profile = switch_channel_get_caller_profile(channel);
	const char* cid_num = NULL;
	const char* cid_name = NULL;

	if (tech_pvt->inception == KZ_INCEPTION_OFFNET) {
		cid_num = kz_endpoint_profile_field(profile, "External-Caller-ID-Number");
		if (!cid_num) {
			cid_num = kz_endpoint_profile_field(profile, "Endpoint-Caller-ID-Number");
		}
		cid_name = kz_endpoint_profile_field(profile, "External-Caller-ID-Name");
		if (!cid_name) {
			cid_name = kz_endpoint_profile_field(profile, "Endpoint-Caller-ID-Name");
		}
	} else {
		cid_num = kz_endpoint_profile_field(profile, "Internal-Caller-ID-Number");
		if (!cid_num) {
			cid_num = kz_endpoint_profile_field(profile, "Endpoint-Caller-ID-Number");
		}
		cid_name = kz_endpoint_profile_field(profile, "Internal-Caller-ID-Name");
		if (!cid_name) {
			cid_name = kz_endpoint_profile_field(profile, "Endpoint-Caller-ID-Name");
		}
	}

	switch_channel_set_profile_var(channel, "callee_id_number", cid_num);
	switch_channel_set_profile_var(channel, "callee_id_name", cid_name);
	switch_channel_set_profile_var(channel, "orig_caller_id_number", cid_num);
	switch_channel_set_profile_var(channel, "orig_caller_id_name", cid_name);

}

void kz_endpoint_setup_caller_profile(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t* channel = switch_core_session_get_channel(session);
	switch_xml_t x_param, x_params;
	const char* cid_override;

	/* Stock soft profile nodes are pool-owned. Detach inherited fields. */
	switch_channel_get_caller_profile(channel)->soft = NULL;

	if ((x_params = switch_xml_child(tech_pvt->xml_endpoint, "profile-variables"))) {
		for (x_param = switch_xml_child(x_params, "variable"); x_param; x_param = x_param->next) {
			const char *pvar = switch_xml_attr_soft(x_param, "name");
			const char *val = switch_xml_attr(x_param, "value");
			switch_channel_set_profile_var(channel, pvar, val);
		}
	}

	kz_endpoint_setup_caller_profile_defaults(session);

	cid_override = switch_channel_get_variable_dup(channel, "origination_caller_id_name", SWITCH_FALSE, -1);
	if (cid_override) {
		switch_channel_set_profile_var(channel, "caller_id_name", cid_override);
	}

	cid_override = switch_channel_get_variable_dup(channel, "origination_caller_id_number", SWITCH_FALSE, -1);
	if (cid_override) {
		switch_channel_set_profile_var(channel, "caller_id_number", cid_override);
	}

	cid_override = switch_channel_get_variable_dup(channel, "origination_callee_id_name", SWITCH_FALSE, -1);
	if (cid_override) {
		switch_channel_set_profile_var(channel, "callee_id_name", cid_override);
		switch_channel_set_profile_var(channel, "orig_caller_id_name", cid_override);
	}

	cid_override = switch_channel_get_variable_dup(channel, "origination_callee_id_number", SWITCH_FALSE, -1);
	if (cid_override) {
		switch_channel_set_profile_var(channel, "callee_id_number", cid_override);
		switch_channel_set_profile_var(channel, "orig_caller_id_number", cid_override);
	}

}

switch_call_cause_t kz_endpoint_dial(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t* channel = switch_core_session_get_channel(session);
	switch_caller_profile_t* caller_profile = switch_channel_get_caller_profile(channel);
	switch_status_t status;
	switch_call_cause_t cause = SWITCH_CAUSE_SUCCESS;
	switch_call_cause_t my_cancel_cause = 0;
	unsigned int timelimit = SWITCH_DEFAULT_TIMEOUT;
	const char* vvar = NULL;
	const char* cid_name_override = NULL;
	const char* cid_num_override = NULL;
	switch_core_session_t* new_session = NULL;

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "channel dialing\n");

	if ((vvar = switch_channel_get_variable_dup(channel, KZ_ENDPOINT_IDS_VARIABLE, SWITCH_FALSE, -1)) != NULL) {
		switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, KZ_ENDPOINT_IDS_VARIABLE, vvar);
	}

	switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM | SWITCH_STACK_PUSH, KZ_ENDPOINT_IDS_VARIABLE, tech_pvt->endpoint_id);


	cid_name_override = kz_get_variable_from_event_or_channel(tech_pvt->var_event, channel, "origination_caller_id_name");
	cid_num_override = kz_get_variable_from_event_or_channel(tech_pvt->var_event, channel, "origination_caller_id_number");
	/* Stock originate copies soft profile fields without this fork-only flag. */
	switch_event_del_header(tech_pvt->var_event, "leg_delay_start");

	if ((vvar = switch_channel_get_variable_dup(channel, "leg_timeout", SWITCH_FALSE, -1))) {
		timelimit = atoi(vvar);
	}

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "dialing to %s / %s (%d sec) => %s\n",
					tech_pvt->endpoint_id, tech_pvt->account_id, timelimit, tech_pvt->dial_string);

	status = kz_switch_ivr_originate(NULL, &new_session, &cause, tech_pvt->dial_string, timelimit, NULL,
									cid_name_override, cid_num_override, caller_profile, tech_pvt->var_event, SOF_NONE,
									tech_pvt->cancel_cause_ptr, NULL);

	my_cancel_cause = *tech_pvt->cancel_cause_ptr;

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "dial result to %s / %s => %d %s , %d %s\n",
					tech_pvt->endpoint_id, tech_pvt->account_id, cause, switch_channel_cause2str(cause),
					my_cancel_cause, switch_channel_cause2str(my_cancel_cause));

	if (status != SWITCH_STATUS_SUCCESS && my_cancel_cause == 0 && tech_pvt->failover_dial_string) {
		const char* failed_reason = switch_channel_cause2str(cause);
		const char* cancel_reason = switch_channel_cause2str(my_cancel_cause);
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "failover => %s %s %s\n", failed_reason, cancel_reason, tech_pvt->failover_reasons);
		if(my_cancel_cause == 0 && (tech_pvt->failover_reasons == NULL || strstr(tech_pvt->failover_reasons, failed_reason) != NULL)) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "trying failover => %d %s\n", cause, tech_pvt->failover_dial_string);
			cause = SWITCH_CAUSE_SUCCESS;
			status = kz_switch_ivr_originate(NULL, &new_session, &cause, tech_pvt->failover_dial_string, timelimit, NULL,
										cid_name_override, cid_num_override, caller_profile, tech_pvt->var_event, SOF_NONE,
										tech_pvt->cancel_cause_ptr, NULL);

			if (status != SWITCH_STATUS_SUCCESS) {
				my_cancel_cause = *tech_pvt->cancel_cause_ptr;
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "failover dial for %s / %s failed => %s => %d %s , %d %s\n",
								tech_pvt->endpoint_id, tech_pvt->account_id, tech_pvt->failover_dial_string, cause, switch_channel_cause2str(cause),
								my_cancel_cause, switch_channel_cause2str(my_cancel_cause));
			}
		} else {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "call was canceled => %d %s\n", my_cancel_cause, cancel_reason);
		}
	}

	if (status == SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "DIAL STATUS SUCCESS\n");
		if (new_session) {
			switch_channel_t* o_channel = switch_core_session_get_channel(new_session);
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "DIAL STATUS SUCCESS WITH SESSION\n");
			kz_endpoint_update_caller_profile_and_variables(session, new_session);
			if (switch_core_session_read_lock(new_session) != SWITCH_STATUS_SUCCESS) {
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_WARNING, "error obtaining read lock on originated session\n");
				cause = SWITCH_CAUSE_CRASH;
				switch_channel_hangup(o_channel, cause);
			} else {
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "DIAL STATUS SUCCESS WITH SESSION & TECH\n");
				tech_pvt->outbound_session = new_session;
			}
			switch_core_session_rwunlock(new_session);
		} else {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_WARNING, "DIAL STATUS SUCCESS WITH NO SESSION\n");
			cause = SWITCH_CAUSE_CRASH;
		}
	}

	tech_pvt->done = SWITCH_TRUE;
	tech_pvt->dial_status = status;
	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "DIAL IS DONE\n");

	return cause;
}

static void kz_tweaks_variables_to_event(switch_core_session_t *session, switch_event_t *event)
{
	int i;
	switch_channel_t *channel = switch_core_session_get_channel(session);
	for(i = 0; kz_endpoint_variables[i] != NULL; i++) {
		const char *val = switch_channel_get_variable_dup(channel, kz_endpoint_variables[i], SWITCH_FALSE, -1);
		if (val) {
			switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, kz_endpoint_variables[i], val);
		}
	}
}

switch_call_cause_t kz_endpoint_fetch(switch_core_session_t *session)
{
	switch_xml_t xml_endpoint = NULL;
	switch_call_cause_t cause = SWITCH_CAUSE_DESTINATION_OUT_OF_ORDER;
	switch_event_t *params = NULL;
	switch_channel_t *channel = switch_core_session_get_channel(session);
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t *caller_channel = NULL;
	const char* var = NULL;

	switch_event_create(&params, SWITCH_EVENT_REQUEST_PARAMS);
	switch_assert(params);
	switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "as_channel", "true");
	switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "action", "user_call");

	if (tech_pvt->session) {
		char* uuid = switch_core_session_get_uuid(tech_pvt->session);
		caller_channel = switch_core_session_get_channel(tech_pvt->session);
		switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "Fetch-Call-UUID", uuid);
	} else if ((var = switch_event_get_header(tech_pvt->var_event, "ent_originate_aleg_uuid")) != NULL) {
		switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "Fetch-Call-UUID", var);
	} else if ((var = switch_event_get_header(tech_pvt->var_event, KZ_ORIGINATE_UUID_VARIABLE)) != NULL) {
		switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "Fetch-Call-UUID", var);
	}

	if (tech_pvt->session && (var = switch_channel_variable(caller_channel, "ent_originate_aleg_uuid")) != NULL) {
		switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "Enterprise-Call-UUID", var);
	} else if ((var = switch_event_get_header(tech_pvt->var_event, "ent_originate_aleg_uuid")) != NULL) {
		switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "Enterprise-Call-UUID", var);
	}

	if ((var = switch_event_get_header(tech_pvt->var_event, "kz_originate_aleg_uuid")) != NULL) {
		switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "Kazoo-Call-UUID", var);
	}

	if (switch_channel_var_true(channel, "Fetch-Exclude-Cache")) {
		switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "Fetch-Exclude-Cache", "true");
	}

	switch_event_add_header(params, SWITCH_STACK_BOTTOM, "Fetch-Cache-Key", "%s@%s",tech_pvt->endpoint_id, tech_pvt->account_id);

	if ((var = switch_channel_variable(channel, "kz_endpoint_query_timeout_micro")) != NULL) {
		switch_event_add_header_string(params, SWITCH_STACK_BOTTOM, "Fetch-Timeout-Override", var);
	}

	switch_event_merge(params, tech_pvt->var_event);

	if (switch_xml_locate_user_merged("id", tech_pvt->endpoint_id, tech_pvt->account_id, NULL, &xml_endpoint, params) != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "can't find endpoint %s in account %s\n", tech_pvt->endpoint_id, tech_pvt->account_id);
		/* The default Failover-Reasons (kz_directory_failover) match on this cause. */
		cause = SWITCH_CAUSE_SUBSCRIBER_ABSENT;
		goto error;
	}

	tech_pvt->xml_endpoint = xml_endpoint;

	cause = SWITCH_CAUSE_SUCCESS;

	goto done;

  error:
	if (xml_endpoint) {
		switch_xml_free(xml_endpoint);
		if (tech_pvt) {
			tech_pvt->xml_endpoint = NULL;
		}
	}

  done:

	if (params) {
		switch_event_destroy(&params);
	}

	return cause;
}

static switch_call_cause_t kz_endpoint_io_outgoing_channel(switch_core_session_t *session,
							switch_event_t *var_event,
							switch_caller_profile_t *outbound_profile,
							switch_core_session_t **new_session, switch_memory_pool_t **pool, switch_originate_flag_t flags,
							switch_call_cause_t *cancel_cause)
{
	char *endpoint_id = NULL, *account_id = NULL;
	switch_call_cause_t cause = SWITCH_CAUSE_DESTINATION_OUT_OF_ORDER;

	switch_core_session_t* nsession = NULL;
	switch_channel_t *channel = NULL;
	kz_private_object_t* tech_pvt = NULL;
	switch_caller_profile_t* caller_profile = NULL;
	const char* var = NULL;
	char channel_name[128];


	if (!outbound_profile || zstr(outbound_profile->destination_number)) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_CRIT, "invalid endpoint destination\n");
		goto error;
	}

	if (!(nsession = switch_core_session_request_uuid(kz_endpoint_interface, SWITCH_CALL_DIRECTION_OUTBOUND, flags, pool, NULL))) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_CRIT, "error creating session\n");
		goto error;
	}

	tech_pvt = kz_new_pvt(nsession);
	switch_core_session_set_private(nsession, tech_pvt);
	channel = switch_core_session_get_channel(nsession);

	endpoint_id = switch_core_session_strdup(nsession, outbound_profile->destination_number);
	if (!endpoint_id) {
		goto error;
	}

	if ((account_id = strchr(endpoint_id, '@'))) {
		*account_id++ = '\0';
	} else {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(nsession), SWITCH_LOG_WARNING, "invalid format for endpoint %s\n", endpoint_id);
		goto error;
	}

	if (session) {
		char* uuid = switch_core_session_get_uuid(session);
		tech_pvt->reference_uuid = switch_core_strdup(switch_core_session_get_pool(nsession), uuid);
	} else if (var_event && (var = switch_event_get_header(var_event, "ent_originate_aleg_uuid")) != NULL) {
		tech_pvt->reference_uuid = switch_core_strdup(switch_core_session_get_pool(nsession), var);
	} else if (var_event && (var = switch_event_get_header(var_event, KZ_ORIGINATE_UUID_VARIABLE)) != NULL) {
		tech_pvt->reference_uuid = switch_core_strdup(switch_core_session_get_pool(nsession), var);
	}

	tech_pvt->account_id = account_id;
	tech_pvt->endpoint_id = endpoint_id;
	/* The callback cancel pointer belongs to the outer originate stack.
	 * Child cancellation uses session-owned state, signalled by kill_channel. */
	tech_pvt->cancel_cause_ptr = &tech_pvt->cancel_cause;

	if (session) {
		if (switch_core_session_read_lock(session) != SWITCH_STATUS_SUCCESS) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(nsession), SWITCH_LOG_WARNING, "error obtaining read lock on session\n");
			goto error;
		}
	}

	tech_pvt->session = session;

	if (var_event) {
		switch_event_dup(&tech_pvt->var_event, var_event);
		switch_event_del_header(tech_pvt->var_event, "Event-Name");
		switch_event_del_header(var_event, "origination_uuid");
	} else {
		switch_event_create_plain(&tech_pvt->var_event, SWITCH_EVENT_CHANNEL_DATA);
	}

	switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, "dialed_user", endpoint_id);
	switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, "dialed_domain", account_id);
	if (tech_pvt->reference_uuid) {
		switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, KZ_ORIGINATE_UUID_VARIABLE, tech_pvt->reference_uuid);
	}

	switch_event_del_header(tech_pvt->var_event, "fail_on_single_reject");

	switch_channel_set_flag(channel, CF_NO_PRESENCE);
	switch_channel_set_flag(channel, CF_NO_CDR);
	switch_channel_set_flag(channel, CF_DISABLE_ON_API);
	switch_channel_set_flag(channel, CF_DISABLE_ON_EXEC);
	switch_channel_set_variable(channel, "NO_EVENTS_PLEASE", "true");
	switch_channel_set_variable(channel, "process_cdr", "false");
	/* This port has no commercial meta engine on temporary channels. */


	switch_snprintf(channel_name, sizeof(channel_name), "kz/%s@%s", endpoint_id, account_id);
	switch_channel_set_name(channel, channel_name);

	caller_profile = switch_caller_profile_clone(nsession, outbound_profile);
	caller_profile->source = switch_core_strdup(caller_profile->pool, MODNAME);
	switch_channel_set_caller_profile(channel, caller_profile);
	tech_pvt->caller_profile = caller_profile;
	switch_channel_set_state(channel, CS_INIT);
	switch_core_session_set_private(nsession, tech_pvt);


	*new_session = nsession;
	cause = SWITCH_CAUSE_SUCCESS;

	goto done;

  error:
	if (nsession) {
		switch_core_session_destroy(&nsession);
	}

	if (pool) {
		*pool = NULL;
	}

  done:

	return cause;
}

void kz_endpoint_setup_forward_exports(switch_core_session_t *session, switch_event_t * evt)
{
	switch_channel_t* channel = switch_core_session_get_channel(session);
	switch_stream_handle_t stream = { 0 };

	/* cfwd & failover loopback settings */
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "loopback_no_cdr", "both");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "loopback_no_presence", "true");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "loopback_no_pre_answer", "true");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "loopback_bowout_on_execute", "false");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "loopback_bowout", "true");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "loopback_bridge_bowout", "true");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "loopback_cfwd_failover", "true");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "loopback_no_meta", "true");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "loopback_export", KZ_ENDPOINT_LOOPBACK_EXPORT);


	/* auto export removing known ccvs */
	if (switch_channel_variable(channel, "ecallmgr_Call-Forward-Exports") == NULL) {
		switch_event_header_t *hi = NULL;
		int count = 0;
		SWITCH_STANDARD_STREAM(stream);
		for (hi = switch_channel_variable_first(channel); hi; hi = hi->next) {
			if (!strncasecmp((char *) hi->name, "ecallmgr_", 9)) {
				if (!kz_is_known_ccv(hi->name + 9)) {
					if (count) stream.write_function(&stream, "|");
					stream.write_function(&stream, "%s", hi->name + 9);
					count++;
				}
			}
		}
		switch_channel_variable_last(channel);
		if (count) {
			switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "ecallmgr_Call-Forward-Exports", stream.data);
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "adding ecallmgr_Call-Forward-Exports => %s\n", (char*)stream.data);
		}
		switch_safe_free(stream.data);
	}
}

#define QUOTED_ESC_COMMA 1

char* kz_endpoint_setup_create_forward_endpoint(switch_core_session_t *session, const char * original_dial)
{
	switch_event_t * event = NULL;
	switch_event_header_t *hp = NULL;
	switch_stream_handle_t stream = { 0 };
	char *p = NULL;
	char *forward_dial = NULL;
	char* dial = switch_core_session_strdup(session, original_dial);
	int count = 0;

	switch_event_create_plain(&event, SWITCH_EVENT_CLONE);
	event->flags |= EF_UNIQ_HEADERS;

	/* strip leading spaces */
	while (dial && *dial && *dial == ' ') {
		dial++;
	}

	/* extract channel variables, allowing multiple sets of braces */
	while (*dial == '[') {
		char *parsed = NULL;
		char *bend = switch_find_end_paren(dial, '[', ']');

		for (p = dial + 1; p && p < bend && *p; p++) {
			if (*p == QUOTED_ESC_COMMA) {
				*p = ',';
			}
		}

		if (switch_event_create_brackets(dial, '[', ']', ',', &event, &parsed, SWITCH_FALSE) != SWITCH_STATUS_SUCCESS || !parsed) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_ERROR, "Parse Error!\n");
			goto done;
		}

		if (dial == parsed) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_ERROR, "Parse Error!\n");
			goto done;
		} else {
			dial = parsed;
		}
	}

	// add forward properties for loopback
	kz_endpoint_setup_forward_exports(session, event);

	// create the endpoint
	SWITCH_STANDARD_STREAM(stream);
	stream.write_function(&stream, "[^^!");
	for (hp = event->headers; hp; hp = hp->next) {
		if (count) {
			stream.write_function(&stream, "!");
		}
		count++;
		stream.write_function(&stream, "%s='%s'", hp->name, hp->value);
	}
	stream.write_function(&stream, "]%s", dial);
	forward_dial = switch_core_session_strdup(session, (char*)stream.data);
	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "created forward dial %s\n", forward_dial);


done:
	switch_safe_free(stream.data);
	switch_event_destroy(&event);
	return forward_dial;
}

void kz_endpoint_setup_callforward(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t* channel = switch_core_session_get_channel(session);
	switch_bool_t direct_calls_only = SWITCH_FALSE;
	switch_bool_t indirect_calls_only = SWITCH_FALSE;
	switch_bool_t is_valid = SWITCH_TRUE;
	const char* dial = NULL;
	const char* inception = NULL;
	const char* dial_uri = NULL;
	kz_cfwd_t* cfwd = NULL;
	kz_cfwd_type_t cfwd_type = KZ_CFWD_NORMAL;
	switch_xml_t x_param, x_callfwd;
	const char* tmp = NULL;

	if ((x_callfwd = switch_xml_child(tech_pvt->xml_endpoint, "call-forward")) == NULL) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "no callforward properties for endpoint %s\n", tech_pvt->endpoint_id);
		return;
	}

	for (x_param = switch_xml_child(x_callfwd, "variable"); x_param; x_param = x_param->next) {
		const char *var = switch_xml_attr_soft(x_param, "name");
		const char *val = switch_xml_attr(x_param, "value");
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "cfw %s => %s\n", var, val);
		if (!strcasecmp(var, "Is-Substitute")) {
			if (switch_true(val)) {
				cfwd_type = KZ_CFWD_SUBSTITUTE;
			};
		} else if (!strcasecmp(var, "Is-Failover")) {
			if (switch_true(val)) {
				cfwd_type = KZ_CFWD_FAILOVER;
			};
		} else if (!strcasecmp(var, "Direct-Calls-Only")) {
			direct_calls_only = switch_true(val);
		} else if (!strcasecmp(var, "Indirect-Calls-Only")) {
			indirect_calls_only = switch_true(val);
		} else if (!strcasecmp(var, "Inception-Only")) {
			inception = val;
		} else if (!strcasecmp(var, "Dial-String")) {
			dial = val;
		} else if (!strcasecmp(var, "Request-URI")) {
			dial_uri = val;
		} else if (!strcasecmp(var, "Failover-Reasons")) {
			tech_pvt->failover_reasons = switch_core_session_strdup(session, val);
		}
	}

	if (direct_calls_only) {
		if(!kz_is_context_flag_set(tech_pvt->runtime_context, "direct_call")) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "callforward is set to direct calls only\n");
			return;
		}
	}

	if (indirect_calls_only) {
		if(kz_is_context_flag_set(tech_pvt->runtime_context, "direct_call")) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "callforward is set to indirect calls only\n");
			return;
		}
	}

	if (inception) {
		if(kz_parse_inception(inception) != tech_pvt->inception) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "callforward is set for inception %s only and this call has %s inception\n", inception, kz_inception2str(tech_pvt->inception));
			return;
		}
	}

	if (!is_valid) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "callforward properties not valid\n");
		return;
	}

	/* Canonical Dial-String takes precedence, including an explicit empty
	 * value. Older directory producers used callforward-dial-string. */
	if (dial == NULL) {
		switch_xml_t params = switch_xml_child(tech_pvt->xml_endpoint, "params");
		for (x_param = switch_xml_child(params, "param"); x_param; x_param = x_param->next) {
			if (!strcasecmp(switch_xml_attr_soft(x_param, "name"), "callforward-dial-string")) {
				dial = switch_xml_attr(x_param, "value");
				break;
			}
		}
	}
	if (zstr(dial)) {
		tech_pvt->setup_cause = SWITCH_CAUSE_MANDATORY_IE_MISSING;
		return;
	}

	if ((tmp = switch_channel_get_variable_dup(channel, "kz_cfwd_active", SWITCH_FALSE, -1)) && switch_true(tmp)) {
		tmp = switch_channel_get_variable_dup(channel, "kz_cfwd_dial_uri", SWITCH_FALSE, -1);
		if (dial_uri && tmp && !strcmp(tmp, dial_uri)) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "callforward already active\n");
			return;
		} else {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "callforward ok with kz_cfwd_active because of different uris (%s : %s)\n", tmp, dial_uri);
		}
	}

	if (cfwd_type == KZ_CFWD_FAILOVER) {
		kz_failover_t* failover = NULL;
		char * cfwd_dial = kz_endpoint_setup_create_forward_endpoint(session, dial);
		if (cfwd_dial == NULL) {
			return;
		}
		failover = (kz_failover_t *) switch_core_session_alloc(session, sizeof(kz_failover_t));
		failover->dial = cfwd_dial;
		failover->type = KZ_FAILOVER_MIGRATE;
		tech_pvt->failover = failover;
		switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, "kz_failover_active", "true");
		switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, "kz_failover_dial_uri", dial_uri);
	} else {
		char * cfwd_dial = kz_endpoint_setup_create_forward_endpoint(session, dial);
		if (cfwd_dial == NULL) {
			return;
		}
		cfwd = (kz_cfwd_t *) switch_core_session_alloc(session, sizeof(kz_cfwd_t));
		cfwd->dial = cfwd_dial;
		cfwd->type = cfwd_type;
		tech_pvt->cfwd = cfwd;
	}
	switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, "kz_cfwd_active", "true");
	switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, "kz_cfwd_dial_uri", dial_uri);
}

void kz_endpoint_setup_failover(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t* channel = switch_core_session_get_channel(session);
	switch_bool_t direct_calls_only = SWITCH_FALSE;
	switch_bool_t indirect_calls_only = SWITCH_FALSE;
	switch_bool_t is_valid = SWITCH_TRUE;
	const char* dial = NULL;
	const char* inception = NULL;
	const char* dial_uri = NULL;
	kz_failover_t* failover = NULL;
	kz_failover_type_t failover_type = KZ_FAILOVER_NORMAL;
	switch_xml_t x_param, x_failover;
	const char* tmp = NULL;
	char * cfwd_dial = NULL;

	if ((x_failover = switch_xml_child(tech_pvt->xml_endpoint, "failover")) == NULL) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "no failover properties for endpoint %s\n", tech_pvt->endpoint_id);
		return;
	}

	for (x_param = switch_xml_child(x_failover, "variable"); x_param; x_param = x_param->next) {
		const char *var = switch_xml_attr_soft(x_param, "name");
		const char *val = switch_xml_attr(x_param, "value");
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "cfw %s => %s\n", var, val);
		if (!strcasecmp(var, "Direct-Calls-Only")) {
			direct_calls_only = switch_true(val);
		} else if (!strcasecmp(var, "Indirect-Calls-Only")) {
			indirect_calls_only = switch_true(val);
		} else if (!strcasecmp(var, "Inception-Only")) {
			inception = val;
		} else if (!strcasecmp(var, "Dial-String")) {
			dial = val;
		} else if (!strcasecmp(var, "Request-URI")) {
			dial_uri = val;
		} else if (!strcasecmp(var, "Failover-Reasons")) {
			tech_pvt->failover_reasons = switch_core_session_strdup(session, val);
		}
	}

	if (!dial) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "failover dial string not set\n");
		return;
	}

	if (direct_calls_only) {
		if(!kz_is_context_flag_set(tech_pvt->runtime_context, "direct_call")) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "failover is set to direct calls only\n");
			return;
		}
	}

	if (indirect_calls_only) {
		if(kz_is_context_flag_set(tech_pvt->runtime_context, "direct_call")) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "failover is set to indirect calls only\n");
			return;
		}
	}

	if (inception) {
		if(kz_parse_inception(inception) != tech_pvt->inception) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "failover is set for inception %s only and this call has %s inception\n", inception, kz_inception2str(tech_pvt->inception));
			return;
		}
	}

	if (!is_valid) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "failover properties not valid\n");
		return;
	}

	if ((tmp = switch_channel_get_variable_dup(channel, "kz_failover_active", SWITCH_FALSE, -1)) && switch_true(tmp)) {
		tmp = switch_channel_get_variable_dup(channel, "kz_failover_dial_uri", SWITCH_FALSE, -1);
		if (dial_uri && tmp && !strcmp(tmp, dial_uri)) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "failover already active\n");
			return;
		} else {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "failover ok with kz_cfwd_active because of different uris (%s : %s)\n", tmp, dial_uri);
		}
	}

	cfwd_dial = kz_endpoint_setup_create_forward_endpoint(session, dial);
	if (cfwd_dial == NULL) {
		return;
	}
	failover = (kz_failover_t *) switch_core_session_alloc(session, sizeof(kz_failover_t));
	failover->dial = cfwd_dial;
	failover->type = failover_type;
	tech_pvt->failover = failover;
	switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, "kz_failover_active", "true");
	switch_event_add_header_string(tech_pvt->var_event, SWITCH_STACK_BOTTOM, "kz_failover_dial_uri", dial_uri);
}

void kz_endpoint_add_user_profile_to_event(switch_core_session_t *session, switch_event_t *event)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_xml_t x_param, x_params;
	if ((x_params = switch_xml_child(tech_pvt->xml_endpoint, "profile-variables"))) {
		for (x_param = switch_xml_child(x_params, "variable"); x_param; x_param = x_param->next) {
			const char *pvar = switch_xml_attr_soft(x_param, "name");
			const char *val = switch_xml_attr(x_param, "value");
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "adding profile variable to event => %s = %s\n", pvar, val);
			switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, pvar, val);
		}
	}
}

void kz_endpoint_add_user_variables_to_event(switch_core_session_t *session, switch_event_t *event)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_xml_t x_param, x_params;
	if ((x_params = switch_xml_child(tech_pvt->xml_endpoint, "variables"))) {
		for (x_param = switch_xml_child(x_params, "variable"); x_param; x_param = x_param->next) {
			const char *pvar = switch_xml_attr_soft(x_param, "name");
			const char *val = switch_xml_attr(x_param, "value");
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "adding variable to event => %s = %s\n", pvar, val);
			switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, pvar, val);
		}
	}
}

void kz_endpoint_add_user_params_to_event(switch_core_session_t *session, switch_event_t *event)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_xml_t x_param, x_params;
	if ((x_params = switch_xml_child(tech_pvt->xml_endpoint, "params"))) {
		for (x_param = switch_xml_child(x_params, "param"); x_param; x_param = x_param->next) {
			const char *pvar = switch_xml_attr_soft(x_param, "name");
			const char *val = switch_xml_attr(x_param, "value");
			if (!strncasecmp(pvar, "dial-var-", 9)) {
				switch_event_del_header(event, pvar + 9);
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "adding dialog var to event => %s = %s\n", pvar + 9, val);
				switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, pvar + 9, val);
			}
		}
	}
}

void kz_endpoint_add_user_context_variables_to_event(switch_core_session_t *session, const char* element, switch_event_t *event)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_xml_t x_param, x_params;
	if ((x_params = switch_xml_child(tech_pvt->xml_endpoint, "variables"))) {
		if ((x_params = switch_xml_child(x_params, element))) {
			for (x_param = switch_xml_child(x_params, "variable"); x_param; x_param = x_param->next) {
				const char *pvar = switch_xml_attr_soft(x_param, "name");
				const char *val = switch_xml_attr(x_param, "value");
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "adding variable from %s to event => %s = %s\n", element, pvar, val);
				switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, pvar, val);
			}
		}
	}
}

void kz_endpoint_add_inception_variables_to_event(switch_core_session_t *session, switch_event_t *event)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	if (tech_pvt->inception == KZ_INCEPTION_OFFNET) {
		kz_endpoint_add_user_context_variables_to_event(session, "external", event);
		kz_endpoint_add_user_context_variables_to_event(session, "offnet", event);
	} else {
		kz_endpoint_add_user_context_variables_to_event(session, "internal", event);
		kz_endpoint_add_user_context_variables_to_event(session, "onnet", event);
	}
}

void kz_endpoint_add_user_to_event(switch_core_session_t *session, switch_event_t *event)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "dialed_user", tech_pvt->endpoint_id);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "dialed_domain", tech_pvt->account_id);
	kz_endpoint_add_user_profile_to_event(session, event);
	kz_endpoint_add_user_variables_to_event(session, event);
	kz_endpoint_add_user_params_to_event(session, event);
}

SWITCH_DECLARE(switch_event_t *) kz_endpoint_create_resolve_event(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_event_t *event = NULL;
	switch_core_session_t *a_session = NULL, *e_session = NULL;
	switch_channel_t *a_channel = NULL;

	if(tech_pvt->session) {
		a_session = tech_pvt->session;
	} else {
		const char* uuid_e_session = switch_event_get_header(tech_pvt->var_event, "ent_originate_aleg_uuid");
		if (uuid_e_session && (e_session = switch_core_session_locate(uuid_e_session)) != NULL) {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "ACQUIRED LOCK\n");
			a_session = e_session;
		} else if (tech_pvt->reference_uuid) {
			if ((e_session = switch_core_session_locate(tech_pvt->reference_uuid)) != NULL) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "ACQUIRED LOCK\n");
				a_session = e_session;
			}
		}
	}

	if (a_session) {
		switch_event_create_plain(&event, SWITCH_EVENT_CHANNEL_DATA);
		a_channel = switch_core_session_get_channel(a_session);
		switch_channel_event_set_data(a_channel, event);
		kz_tweaks_variables_to_event(a_session, tech_pvt->var_event);
	} else {
		switch_event_dup(&event, tech_pvt->var_event);
		switch_event_del_header(event, "Event-Name");
	}

	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "dialed_user", tech_pvt->endpoint_id);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "dialed_domain", tech_pvt->account_id);

	if (tech_pvt->reference_uuid) {
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "kz_originate_aleg_uuid", tech_pvt->reference_uuid);
	}

	if(e_session) {
		switch_core_session_rwunlock(e_session);
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "RELEASED LOCK\n");
	}

	return event;
}

switch_call_cause_t kz_endpoint_build_dial_string(switch_core_session_t* session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);

	char *dest = NULL;
	switch_call_cause_t cause = SWITCH_CAUSE_SUCCESS;

	char stupid[128] = "";
	const char *endpoint_dial = NULL;
	const char *failover_dial = NULL;
	const char *cfwd_dial = NULL;
	char *b_failover_dial = NULL;
	const char *endpoint_separator = NULL;
	const char *base = NULL;
	char *d_dest = NULL;
	switch_event_t *event = NULL;
	switch_event_t *var_event = tech_pvt->var_event;
	switch_xml_t x_param, x_params;

	kz_endpoint_add_user_variables_to_event(session, var_event);
	kz_endpoint_add_user_params_to_event(session, var_event);
	kz_endpoint_add_inception_variables_to_event(session, var_event);

	if ((x_params = switch_xml_child(tech_pvt->xml_endpoint, "params"))) {
		for (x_param = switch_xml_child(x_params, "param"); x_param; x_param = x_param->next) {
			const char *pvar = switch_xml_attr_soft(x_param, "name");
			const char *val = switch_xml_attr(x_param, "value");
			if (!strcasecmp(pvar, "endpoint-dial-string")) {
				endpoint_dial = val;
			} else if (!strcasecmp(pvar, "endpoint-separator")) {
				endpoint_separator = val;
			}
		}
	}

	if (tech_pvt->failover) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "setting failover => %s\n", tech_pvt->failover->dial);
			failover_dial = tech_pvt->failover->dial;
	}

	if (tech_pvt->cfwd) {
		if (tech_pvt->cfwd->type == KZ_CFWD_SUBSTITUTE) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "setting call fwd substitute => %s\n", tech_pvt->cfwd->dial);
			endpoint_dial = tech_pvt->cfwd->dial;
		} else {
			cfwd_dial = tech_pvt->cfwd->dial;
		}
	}

	if (zstr(endpoint_dial) && zstr(cfwd_dial) && zstr(failover_dial)) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_ERROR, "No dial-string available, please check your user directory.\n");
		cause = SWITCH_CAUSE_MANDATORY_IE_MISSING;
		goto done;
	}


	event = kz_endpoint_create_resolve_event(session);
	kz_endpoint_add_user_to_event(session, event);
	if (tech_pvt->runtime_context) {
		kz_expand_json_to_event(tech_pvt->runtime_context, event, "kz_ctx");
	}

	/* The dial is the endpoint's own string, the forward, or both joined. */
	if (endpoint_dial && cfwd_dial) {
		dest = switch_mprintf("%s%s%s", endpoint_dial, (endpoint_separator ? endpoint_separator : ","), cfwd_dial);
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "added call fwd '%s' to '%s'\n", cfwd_dial, endpoint_dial);
	}
	if ((base = dest ? dest : (endpoint_dial ? endpoint_dial : cfwd_dial))) {
		/* kz_endpoint_expand_dial always returns an owned string */
		d_dest = kz_endpoint_expand_dial(event, base);
		switch_safe_free(dest);
		dest = d_dest;
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "built dialing %s\n", d_dest);
	}

	if(failover_dial) {
		b_failover_dial = kz_endpoint_expand_dial(event, failover_dial);
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "built failover dial %s\n", b_failover_dial);
	}

	if (kz_expand_headers(event, tech_pvt->var_event) != SWITCH_STATUS_SUCCESS) {
		cause = SWITCH_CAUSE_INVALID_IE_CONTENTS;
		goto done;
	}
	kz_alias_sofia_headers(tech_pvt->var_event);

	switch_event_destroy(&event);

	switch_snprintf(stupid, sizeof(stupid), "kz/%s@%s", tech_pvt->endpoint_id, tech_pvt->account_id);
	if (d_dest && switch_stristr(stupid, d_dest)) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "Waddya Daft? You almost called '%s' in an infinate loop!\n", stupid);
		cause = SWITCH_CAUSE_INVALID_IE_CONTENTS;
		goto done;
	}

	if (d_dest) {
		tech_pvt->dial_string = switch_core_session_strdup(session, d_dest);
	}

	if (b_failover_dial) {
		if (tech_pvt->dial_string) {
			tech_pvt->failover_dial_string = switch_core_session_strdup(session, b_failover_dial);
		} else {
			/*
			 * short-circuit here, if there's no dial string and a failover exists
			 * just dial the failover
			 */
			tech_pvt->dial_string = switch_core_session_strdup(session, b_failover_dial);
		}
	}

  done:

	if (event) switch_event_destroy(&event);
	switch_safe_free(dest);

	if(b_failover_dial && b_failover_dial != failover_dial) {
		switch_safe_free(b_failover_dial);
	}

	return cause;
}

switch_call_cause_t kz_endpoint_validate_endpoint(switch_core_session_t* session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t* channel = switch_core_session_get_channel(session);
	switch_caller_profile_t* profile = switch_channel_get_caller_profile(channel);
	switch_caller_profile_t* originator_profile = switch_channel_get_originator_caller_profile(channel);
	const char* val = NULL;

	if ((val=kz_endpoint_profile_field(profile, "Endpoint-DND")) && switch_true(val)) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "endpoint_id %s has dnd activated\n", tech_pvt->endpoint_id);
		return SWITCH_CAUSE_SUBSCRIBER_DND;
	}

	if (!switch_true(switch_core_get_variable("kz_disable_endpoint_self_calling_validation"))) {
		if(!kz_is_context_flag_set(tech_pvt->runtime_context, "can_call_self")) {
			if (originator_profile) {
				const char* originator_id = kz_endpoint_profile_field(originator_profile, "Endpoint-ID");
				const char* originator_owner_id = kz_endpoint_profile_field(originator_profile, "Endpoint-Owner-ID");
				const char* id = kz_endpoint_profile_field(profile, "Endpoint-ID");
				const char* owner_id = kz_endpoint_profile_field(profile, "Endpoint-Owner-ID");
#if 0
				{
					switch_event_t* t;
					switch_event_create(&t, SWITCH_EVENT_GENERAL);
					switch_caller_profile_event_set_data(originator_profile, "Originator", t);
					switch_caller_profile_event_set_data(profile, "Callee", t);
					DUMP_EVENT(t);
					switch_event_destroy(&t);
				}
#endif
				if (owner_id != NULL && originator_owner_id != NULL && !strcmp(owner_id, originator_owner_id)) {
					switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "originator and target have same owner and can_call_self is not set : %s : %s\n", owner_id, originator_owner_id);
					return SWITCH_CAUSE_REQUESTED_CHAN_UNAVAIL;
				}
				if (owner_id != NULL && originator_id != NULL && !strcmp(owner_id, originator_id)) {
					switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "the owner of the target is the originator and can_call_self is not set : %s : %s\n", owner_id, originator_id);
					return SWITCH_CAUSE_REQUESTED_CHAN_UNAVAIL;
				}
				if (id != NULL && originator_owner_id != NULL && !strcmp(id, originator_owner_id)) {
					switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "target is the owner of the originator and can_call_self is not set : %s : %s\n", id, originator_owner_id);
					return SWITCH_CAUSE_REQUESTED_CHAN_UNAVAIL;
				}
				if (id != NULL && originator_id != NULL && !strcmp(id, originator_id)) {
					switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "target and originator are the same and can_call_self is not set : %s : %s\n", id, originator_id);
					return SWITCH_CAUSE_REQUESTED_CHAN_UNAVAIL;
				}
			}
		}

	}

	/* Stock indexes only array headers; scalar headers use index -1. */
	val = switch_channel_get_variable_dup(channel, KZ_ENDPOINT_IDS_VARIABLE, SWITCH_FALSE, -1);
	if (val) {
		int idx = 0;
		if (!strcmp(val, tech_pvt->endpoint_id)) return SWITCH_CAUSE_REQUESTED_CHAN_UNAVAIL;
		while ((val = switch_channel_get_variable_dup(channel, KZ_ENDPOINT_IDS_VARIABLE, SWITCH_FALSE, idx++)) != NULL) {
			if (!strcmp(val, tech_pvt->endpoint_id)) return SWITCH_CAUSE_REQUESTED_CHAN_UNAVAIL;
		}
	}
	return SWITCH_CAUSE_SUCCESS;
}


static switch_status_t kz_on_channel_init(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_status_t status = SWITCH_STATUS_SUCCESS;
	switch_call_cause_t cause;

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "CHANNEL INIT\n");

	switch_channel_set_variable(channel, "fail_on_single_reject", NULL);

	cause = kz_endpoint_fetch(session);
	if (cause != SWITCH_CAUSE_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_NOTICE, "failed to building dial string %d %s\n", cause, switch_channel_cause2str(cause));
		tech_pvt->done = SWITCH_TRUE;
		status = SWITCH_STATUS_FALSE;
		switch_channel_hangup(channel, cause);
		return status;
	}


	kz_endpoint_setup_runtime_context(session);
	kz_endpoint_setup_inception(session);
	kz_endpoint_setup_caller_profile(session);
	kz_endpoint_setup_callforward(session);
	kz_endpoint_setup_failover(session);

	cause = tech_pvt->setup_cause ? tech_pvt->setup_cause : kz_endpoint_validate_endpoint(session);
	if (cause == SWITCH_CAUSE_SUCCESS) {
		cause = kz_endpoint_build_dial_string(session);
	}

	if (cause != SWITCH_CAUSE_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_NOTICE, "failed to building dial string %d %s\n", cause, switch_channel_cause2str(cause));
		tech_pvt->done = SWITCH_TRUE;
		status = SWITCH_STATUS_FALSE;
		switch_channel_hangup(channel, cause);
	} else {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "built dial string\n");
		switch_channel_set_state(channel, CS_ROUTING);
	}

	return status;
}

static switch_status_t kz_on_channel_routing(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_status_t status = SWITCH_STATUS_FALSE;
	switch_call_cause_t cause;

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "CHANNEL ROUTING\n");

	if (tech_pvt->routing) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_WARNING, "CHANNEL ROUTING REENTRANCE, THIS IS NOT EXPECTED\n");
		return status;
	}

	tech_pvt->routing = SWITCH_TRUE;

	switch_channel_mark_ring_ready(channel);

	cause = kz_endpoint_dial(session);

	if (cause == SWITCH_CAUSE_SUCCESS) {
		if (*tech_pvt->cancel_cause_ptr == 0) {
			char* uuid = switch_core_session_get_uuid(tech_pvt->outbound_session);
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "dial succeeded uuid:%s\n", uuid);
			switch_channel_set_variable(channel, "channel_swap_uuid", uuid);
			switch_channel_set_flag(channel, CF_SESSION_SWAP);
		} else {
			switch_channel_hangup(channel, *tech_pvt->cancel_cause_ptr);
		}
	} else if (cause != SWITCH_CAUSE_SWAPPED) {
		if (*tech_pvt->cancel_cause_ptr == 0) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "dial didn't succeed %d %s\n", cause, switch_channel_cause2str(cause));
			switch_channel_hangup(channel, cause);
		}
	}

	tech_pvt->cause = cause;

	return status;
}


static switch_status_t kz_on_channel_hangup(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_status_t status = SWITCH_STATUS_SUCCESS;
	switch_call_cause_t cause = switch_channel_get_cause(channel);

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "CHANNEL HANGUP %d %s\n", cause, switch_channel_cause2str(cause));

	if (tech_pvt->outbound_session && cause != SWITCH_CAUSE_SWAPPED) {
		switch_channel_t *o_channel = switch_core_session_get_channel(tech_pvt->outbound_session);
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "hanging outbound %s with %d %s\n",
						switch_core_session_get_uuid(tech_pvt->outbound_session), cause, switch_channel_cause2str(cause));
		switch_channel_hangup(o_channel, cause);
	}

	return status;
}

static switch_status_t kz_on_execute(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_status_t status = SWITCH_STATUS_SUCCESS;
	switch_call_cause_t cause = switch_channel_get_cause(channel);

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "CHANNEL EXECUTE %d %s\n", cause, switch_channel_cause2str(cause));

	return status;
}

static switch_status_t kz_on_consume_media(switch_core_session_t *session)
{
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_status_t status = SWITCH_STATUS_SUCCESS;
	switch_call_cause_t cause = tech_pvt->cause;

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "CHANNEL CONSUME MEDIA %d %s\n", cause, switch_channel_cause2str(cause));

	if (cause == SWITCH_CAUSE_SUCCESS) {
		if (*tech_pvt->cancel_cause_ptr == 0) {
			char* uuid = switch_core_session_get_uuid(tech_pvt->outbound_session);
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "dial succeeded uuid:%s\n", uuid);
			switch_channel_set_variable(channel, "channel_swap_uuid", uuid);
			switch_channel_set_flag(channel, CF_SESSION_SWAP);
		}
	} else if (cause != SWITCH_CAUSE_SWAPPED) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "channel was canceled\n");
	} else {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "channel was swapped\n");
	}

	return status;
}

static switch_status_t kz_on_exchange_media(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_status_t status = SWITCH_STATUS_SUCCESS;
	switch_call_cause_t cause = switch_channel_get_cause(channel);

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "CHANNEL EXCHANGE MEDIA %d %s\n", cause, switch_channel_cause2str(cause));

	return status;
}

static switch_status_t kz_on_soft_execute(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_status_t status = SWITCH_STATUS_SUCCESS;
	switch_call_cause_t cause = switch_channel_get_cause(channel);

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "CHANNEL SOFT EXECUTE %d %s\n", cause, switch_channel_cause2str(cause));

	return status;
}

static switch_status_t kz_endpoint_io_kill_channel(switch_core_session_t *session, int sig)
{
	switch_channel_t* channel = switch_core_session_get_channel(session);
	kz_private_object_t* tech_pvt = switch_core_session_get_private(session);

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "CHANNEL SIGNAL %d\n", sig);

	switch (sig) {
	case SWITCH_SIG_BREAK:
		break;
	case SWITCH_SIG_KILL:
		if(tech_pvt && !tech_pvt->done) {
			switch_call_cause_t cause = switch_channel_get_cause(channel);
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "SIGNALING CANCEL\n");
			*tech_pvt->cancel_cause_ptr = cause;
			tech_pvt->done = SWITCH_TRUE;
		} else {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "NOT SIGNALING CANCEL\n");
		}
		break;
	default:
		break;
	}

	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t kz_on_channel_destroy(switch_core_session_t *session)
{
	switch_status_t status = SWITCH_STATUS_SUCCESS;
	if (switch_core_session_get_private(session))
		kz_endpoint_pool_destroy_callback(switch_core_session_get_private(session));
	return status;
}


/* kazoo endpoint */

switch_io_routines_t kz_endpoint_io_routines = {
	/*.outgoing_channel */ kz_endpoint_io_outgoing_channel,
	/*.read_frame */ NULL,
	/*.write_frame */ NULL,
	/*.kill_channel */ kz_endpoint_io_kill_channel,
	/*.send_dtmf */ NULL,
	/*.receive_message */ NULL

};

switch_state_handler_table_t kz_endpoint_event_handlers = {
	/*.on_init */ kz_on_channel_init,
	/*.on_routing */ kz_on_channel_routing,
	/*.on_execute */ kz_on_execute,
	/*.on_hangup */ kz_on_channel_hangup,
	/*.on_exchange_media */ kz_on_exchange_media,
	/*.on_soft_execute */ kz_on_soft_execute,
	/*.on_consume_media */ kz_on_consume_media,
	/*.on_hibernate */ NULL,
	/*.on_reset */ NULL,
	/*.on_park */ NULL,
	/*.on_reporting */ NULL,
	/*.on_destroy */ kz_on_channel_destroy
};


void reprise_kz_endpoints_add(switch_loadable_module_interface_t **module_interface) {
	switch_kazoo_session_swap_v1();
	kz_endpoint_interface = (switch_endpoint_interface_t *) switch_loadable_module_create_interface(*module_interface, SWITCH_ENDPOINT_INTERFACE);
	kz_endpoint_interface->interface_name = "kz";
	kz_endpoint_interface->io_routines = &kz_endpoint_io_routines;
	kz_endpoint_interface->state_handler = &kz_endpoint_event_handlers;
}
