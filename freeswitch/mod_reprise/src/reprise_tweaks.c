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
 * Luis Azedo <luis@2600hz.com>
 * Vonix LLC (port to the stock FreeSWITCH core for Reprise, 2026)
 *
 * mod_hacks.c -- hacks with state handlers
 *
 */
#include "reprise_kz.h"

static char *TWEAK_NAMES[] = {
	"interaction-id",
	"export-vars",
	"switch-uri",
	"replaces-call-id",
	"loopback-vars",
	"caller-id",
	"transfers",
	"bridge",
	"bridge-replaces-aleg",
	"bridge-replaces-call-id",
	"bridge-variables",
	"restore-caller-id-on-blind-xfer"
};

/* copied from the older leg to the newer one on CHANNEL_BRIDGE
 * (freeswitch-kazoo 20.23.6 list: the OpenKazoo one also carried
 * sip_h_k-cid and the Switch-URI/URL pair, which are now filled in only
 * where missing, in either direction) */
static const char *bridge_variables[] = {
		"Call-Control-Queue",
		"Call-Control-PID",
		"Call-Control-Node",
		INTERACTION_VARIABLE,
		KZ_ENDPOINT_IDS_VARIABLE,
		KZ_ORIGINATE_UUID_VARIABLE,
		"ecallmgr_Ecallmgr-Node",
		NULL
};

static const char *bridge_check_variables[] = {
		"Switch-URI",
		"Switch-URL",
		NULL
};

/* copied from the originating leg to every leg it originates */
static const char *outgoing_variables[] = {
		INTERACTION_VARIABLE,
		KZ_ENDPOINT_IDS_VARIABLE,
		KZ_ORIGINATE_UUID_VARIABLE,
		"ecallmgr_Ecallmgr-Node",
		NULL
};

/* "<gregorian seconds>-<8 alnum>": an interaction id another cluster may hand us */
switch_bool_t kz_is_valid_interaction_id(const char *interaction_id)
{
	long int long_part = 0;
	char uuid_part[10] = {0};
	int parts, i;

	if (zstr(interaction_id)) return SWITCH_FALSE;
	parts = sscanf(interaction_id, "%ld-%8s", &long_part, uuid_part);
	if (parts != 2 || long_part <= 0 || strlen(uuid_part) != 8) return SWITCH_FALSE;
	for (i = 0; i < 8; i++) {
		if (!isalnum((unsigned char) uuid_part[i])) return SWITCH_FALSE;
	}
	/* the whole string must be consumed: "123-abcdefgh-extra" is not one */
	return strlen(interaction_id) == strlen(uuid_part) + 1 + (size_t) snprintf(NULL, 0, "%ld", long_part) ? SWITCH_TRUE : SWITCH_FALSE;
}


/* Call-Interaction-ID is "<gregorian seconds>-<8 hex>"; the closed module
 * also exposes its halves (the cdr app keys the MODB on
 * Call-Interaction-Timestamp via the cdr profile's interaction-timestamp
 * field, and reports Call-Interaction-Key / -Is-Root) */
static void kz_set_interaction(switch_channel_t *channel, const char *interaction_id, int is_root)
{
	const char *dash;

	switch_channel_set_variable(channel, INTERACTION_VARIABLE, interaction_id);
	if (zstr(interaction_id)) return;
	if ((dash = strchr(interaction_id, '-'))) {
		char ts[32];
		switch_size_t n = (switch_size_t) (dash - interaction_id);
		if (n >= sizeof(ts)) n = sizeof(ts) - 1;
		memcpy(ts, interaction_id, n);
		ts[n] = '\0';
		switch_channel_set_variable(channel, "Call-Interaction-Timestamp", ts);
		switch_channel_set_variable(channel, "Call-Interaction-Key", dash + 1);
	}
	switch_channel_set_variable(channel, "Call-Interaction-Is-Root", is_root ? "true" : "false");
}

static switch_status_t kz_tweaks_signal_bridge_on_hangup(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_event_t *my_event;

	const char *peer_uuid = switch_channel_get_variable(channel, "Bridge-B-Unique-ID");

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "tweak signal bridge on hangup: %s , %s\n", switch_core_session_get_uuid(session), peer_uuid);

	if (switch_event_create(&my_event, SWITCH_EVENT_CHANNEL_UNBRIDGE) == SWITCH_STATUS_SUCCESS) {
		switch_event_add_header_string(my_event, SWITCH_STACK_BOTTOM, "Bridge-A-Unique-ID", switch_core_session_get_uuid(session));
		switch_event_add_header_string(my_event, SWITCH_STACK_BOTTOM, "Bridge-B-Unique-ID", peer_uuid);
		switch_channel_event_set_data(channel, my_event);
		switch_event_fire(&my_event);
	}

	return SWITCH_STATUS_SUCCESS;
}

static const switch_state_handler_table_t kz_tweaks_signal_bridge_state_handlers = {
	/*.on_init */ NULL,
	/*.on_routing */ NULL,
	/*.on_execute */ NULL,
	/*.on_hangup */ kz_tweaks_signal_bridge_on_hangup,
	/*.on_exchange_media */ NULL,
	/*.on_soft_execute */ NULL,
	/*.on_consume_media */ NULL,
	/*.on_hibernate */ NULL,
	/*.on_reset */ NULL,
	/*.on_park */ NULL,
	/*.on_reporting */ NULL,
	/*.on_destroy */ NULL
};

static void kz_tweaks_handle_bridge_variables(switch_event_t *event)
{
	switch_core_session_t *a_session = NULL, *b_session = NULL;
	const char *a_leg = switch_event_get_header(event, "Bridge-A-Unique-ID");
	const char *b_leg = switch_event_get_header(event, "Bridge-B-Unique-ID");
	const char *reentry = switch_event_get_header(event, "Bridge-Event-Processed");
	int i;

	if (!kz_test_tweak(KZ_TWEAK_BRIDGE_VARIABLES)) return;

	if(reentry) return;

	switch_log_printf(SWITCH_CHANNEL_UUID_LOG(a_leg), SWITCH_LOG_DEBUG, "tweak bridge event handler: variables : %s , %s\n", a_leg, b_leg);

	if (a_leg && (a_session = switch_core_session_locate(a_leg)) != NULL) {
		switch_channel_t *a_channel = switch_core_session_get_channel(a_session);
		switch_channel_timetable_t *a_times = switch_channel_get_timetable(a_channel);
		if(b_leg && (b_session = switch_core_session_locate(b_leg)) != NULL) {
			switch_channel_t *b_channel = switch_core_session_get_channel(b_session);
			switch_channel_timetable_t *b_times = switch_channel_get_timetable(b_channel);
			if (a_times->created <= b_times->created) {
				for(i = 0; bridge_variables[i] != NULL; i++) {
					const char *val = switch_channel_get_variable_dup(a_channel, bridge_variables[i], SWITCH_FALSE, -1);
					switch_channel_set_variable(b_channel, bridge_variables[i], val);
				}
			} else {
				for(i = 0; bridge_variables[i] != NULL; i++) {
					const char *val = switch_channel_get_variable_dup(b_channel, bridge_variables[i], SWITCH_FALSE, -1);
					switch_channel_set_variable(a_channel, bridge_variables[i], val);
				}
			}
			for(i = 0; bridge_check_variables[i] != NULL; i++) {
				const char *a_val = switch_channel_get_variable_dup(a_channel, bridge_check_variables[i], SWITCH_FALSE, -1);
				const char *b_val = switch_channel_get_variable_dup(b_channel, bridge_check_variables[i], SWITCH_FALSE, -1);
				if (a_val != NULL && b_val == NULL) {
					switch_channel_set_variable(b_channel, bridge_check_variables[i], a_val);
				} else if (b_val != NULL && a_val == NULL) {
					switch_channel_set_variable(a_channel, bridge_check_variables[i], b_val);
				}
			}
			switch_core_session_rwunlock(b_session);
		}
		switch_core_session_rwunlock(a_session);
	} else {
		switch_log_printf(SWITCH_CHANNEL_UUID_LOG(a_leg), SWITCH_LOG_DEBUG1, "NOT FOUND : %s\n", a_leg);
	}
}

static void kz_tweaks_handle_bridge_replaces_call_id(switch_event_t *event)
{
	switch_event_t *my_event;

	const char *replaced_call_id =	switch_event_get_header(event, "variable_sip_replaces_call_id");
	const char *peer_uuid = switch_event_get_header(event, "Unique-ID");
	const char *reentry = switch_event_get_header(event, "Bridge-Event-Processed");

	if (!kz_test_tweak(KZ_TWEAK_BRIDGE_REPLACES_CALL_ID)) return;

	if(reentry) return;

	if(replaced_call_id) {
		switch_core_session_t *call_session = NULL;
		const char *call_id = switch_event_get_header(event, "Bridge-B-Unique-ID");
		if (call_id && (call_session = switch_core_session_locate(call_id)) != NULL) {
			switch_channel_t *call_channel = switch_core_session_get_channel(call_session);
			if (switch_event_create(&my_event, SWITCH_EVENT_CHANNEL_BRIDGE) == SWITCH_STATUS_SUCCESS) {
				switch_event_add_header_string(my_event, SWITCH_STACK_BOTTOM, "Bridge-A-Unique-ID", switch_core_session_get_uuid(call_session));
				switch_event_add_header_string(my_event, SWITCH_STACK_BOTTOM, "Bridge-B-Unique-ID", peer_uuid);
				switch_event_add_header_string(my_event, SWITCH_STACK_BOTTOM, "Bridge-Event-Processed", "true");
				switch_channel_event_set_data(call_channel, my_event);
				switch_event_fire(&my_event);
			}
			switch_channel_set_variable(call_channel, "Bridge-B-Unique-ID", peer_uuid);
			switch_channel_add_state_handler(call_channel, &kz_tweaks_signal_bridge_state_handlers);
			switch_core_session_rwunlock(call_session);
		} else {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "NOT FOUND : %s\n", call_id);
		}
	}
}

static void kz_tweaks_channel_bridge_event_handler(switch_event_t *event)
{
	if (!kz_test_tweak(KZ_TWEAK_BRIDGE)) return;

	kz_tweaks_handle_bridge_replaces_call_id(event);
	kz_tweaks_handle_bridge_variables(event);
}

// TRANSFERS

static void kz_tweaks_channel_replaced_event_handler(switch_event_t *event)
{
	const char *uuid = switch_event_get_header(event, "Unique-ID");
	const char *replaced_by = switch_event_get_header(event, "att_xfer_replaced_by");

	if (!kz_test_tweak(KZ_TWEAK_TRANSFERS)) return;

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "REPLACED : %s , %s\n", uuid, replaced_by);
}

static void kz_tweaks_channel_intercepted_event_handler(switch_event_t *event)
{
	const char *uuid = switch_event_get_header(event, "Unique-ID");
	const char *peer_uuid = switch_event_get_header(event, "intercepted_by");

	if (!kz_test_tweak(KZ_TWEAK_TRANSFERS)) return;

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "INTERCEPTED : %s => %s\n", uuid, peer_uuid);
}

static void kz_tweaks_channel_transferor_event_handler(switch_event_t *event)
{
	switch_core_session_t *uuid_session = NULL;
	switch_event_t *evt = NULL;
	const char *uuid = switch_event_get_header(event, "Unique-ID");

	const char *orig_call_id = switch_event_get_header(event, "att_xfer_original_call_id");
	const char *dest_peer_uuid = switch_event_get_header(event, "att_xfer_destination_peer_uuid");
	const char *dest_call_id = switch_event_get_header(event, "att_xfer_destination_call_id");

	const char *file = switch_event_get_header(event, "Event-Calling-File");
	const char *func = switch_event_get_header(event, "Event-Calling-Function");
	const char *line = switch_event_get_header(event, "Event-Calling-Line-Number");

	if (!kz_test_tweak(KZ_TWEAK_TRANSFERS)) return;

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "TRANSFEROR : %s , %s , %s, %s, %s , %s , %s \n", uuid, orig_call_id, dest_peer_uuid, dest_call_id, file, func, line);
	if ((uuid_session = switch_core_session_locate(uuid)) != NULL) {
		switch_channel_t *uuid_channel = switch_core_session_get_channel(uuid_session);
		const char* interaction_id = switch_channel_get_variable_dup(uuid_channel, INTERACTION_VARIABLE, SWITCH_TRUE, -1);
		// set to uuid & peer_uuid
		if(interaction_id != NULL) {
			switch_core_session_t *session = NULL;
			if(dest_call_id && (session = switch_core_session_locate(dest_call_id)) != NULL) {
				switch_channel_t *channel = switch_core_session_get_channel(session);
				const char* prv_interaction_id = switch_channel_get_variable_dup(channel, INTERACTION_VARIABLE, SWITCH_TRUE, -1);
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "LOCATING UUID PRV : %s : %s\n", prv_interaction_id, interaction_id);
				kz_set_interaction(channel, interaction_id, 0);
				if (switch_event_create(&evt, SWITCH_EVENT_CHANNEL_DATA) == SWITCH_STATUS_SUCCESS) {
					switch_channel_event_set_data(channel, evt);
					switch_event_fire(&evt);
				}
				switch_core_session_rwunlock(session);
			} else {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "TRANSFEROR NO UUID SESSION: %s , %s , %s \n", uuid, dest_call_id, dest_peer_uuid);
			}
			if(dest_peer_uuid && (session = switch_core_session_locate(dest_peer_uuid)) != NULL) {
				switch_channel_t *channel = switch_core_session_get_channel(session);
				const char* prv_interaction_id = switch_channel_get_variable_dup(channel, INTERACTION_VARIABLE, SWITCH_TRUE, -1);
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "LOCATING PEER UUID PRV : %s : %s\n", prv_interaction_id, interaction_id);
				kz_set_interaction(channel, interaction_id, 0);
				if (switch_event_create(&evt, SWITCH_EVENT_CHANNEL_DATA) == SWITCH_STATUS_SUCCESS) {
					switch_channel_event_set_data(channel, evt);
					switch_event_fire(&evt);
				}
				switch_core_session_rwunlock(session);
			} else {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "TRANSFEROR NO PEER SESSION: %s , %s , %s \n", uuid, dest_call_id, dest_peer_uuid);
			}
			if(orig_call_id && (session = switch_core_session_locate(orig_call_id)) != NULL) {
				switch_channel_t *channel = switch_core_session_get_channel(session);
				const char* prv_interaction_id = switch_channel_get_variable_dup(channel, INTERACTION_VARIABLE, SWITCH_TRUE, -1);
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "LOCATING PEER UUID PRV : %s : %s\n", prv_interaction_id, interaction_id);
				kz_set_interaction(channel, interaction_id, 0);
				if (switch_event_create(&evt, SWITCH_EVENT_CHANNEL_DATA) == SWITCH_STATUS_SUCCESS) {
					switch_channel_event_set_data(channel, evt);
					switch_event_fire(&evt);
				}
				switch_core_session_rwunlock(session);
			} else {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "TRANSFEROR NO PEER SESSION: %s , %s , %s \n", uuid, dest_call_id, dest_peer_uuid);
			}
		} else {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "TRANSFEROR ID = NULL : %s , %s , %s \n", uuid, dest_call_id, dest_peer_uuid);
		}
		switch_core_session_rwunlock(uuid_session);
	} else {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "SESSION NOT FOUND : %s\n", uuid);
	}
}

static void kz_tweaks_channel_transferee_event_handler(switch_event_t *event)
{
	const char *uuid = switch_event_get_header(event, "Unique-ID");
	const char *replaced_by_uuid = switch_event_get_header(event, "att_xfer_replaced_call_id");

	if (!kz_test_tweak(KZ_TWEAK_TRANSFERS)) return;

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "TRANSFEREE : %s replaced by %s\n", uuid, replaced_by_uuid);
}

// END TRANSFERS


static switch_status_t kz_tweaks_handle_loopback(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_channel_t *a_channel = NULL;
	const char * loopback_leg = NULL;
	const char * loopback_aleg = NULL;
	switch_core_session_t *a_session = NULL;
	switch_event_t *event = NULL;
	switch_event_header_t *header = NULL;
	switch_event_t *to_add = NULL;
	switch_event_t *to_remove = NULL;
	switch_caller_profile_t *caller;
	int n = 0;

	if (!kz_test_tweak(KZ_TWEAK_LOOPBACK_VARS)) {
		return SWITCH_STATUS_SUCCESS;
	}

	caller = switch_channel_get_caller_profile(channel);
	if(strncmp(caller->source, "mod_loopback", 12))
		return SWITCH_STATUS_SUCCESS;

	if((loopback_leg = switch_channel_get_variable(channel, "loopback_leg")) == NULL)
		return SWITCH_STATUS_SUCCESS;

	if(strncmp(loopback_leg, "B", 1))
		return SWITCH_STATUS_SUCCESS;

	switch_channel_get_variables(channel, &event);
	switch_event_create_plain(&to_add, SWITCH_EVENT_CHANNEL_DATA);
	switch_event_create_plain(&to_remove, SWITCH_EVENT_CHANNEL_DATA);

	for(header = event->headers; header; header = header->next) {
		if(!strncmp(header->name, "Export-Loopback-", 16)) {
			kz_switch_event_add_variable_name_printf(to_add, SWITCH_STACK_BOTTOM, header->value, "%s", header->name+16);
			switch_channel_set_variable(channel, header->name, NULL);
			n++;
		} else if(!strncmp(header->name, "sip_loopback_", 13)) {
			kz_switch_event_add_variable_name_printf(to_add, SWITCH_STACK_BOTTOM, header->value, "sip_%s", header->name+13);
		} else if(!strncmp(header->name, "ecallmgr_", 9)) {
			switch_event_add_header_string(to_remove, SWITCH_STACK_BOTTOM, header->name, header->value);
		}
	}
	if(n) {
		for(header = to_remove->headers; header; header = header->next) {
			switch_channel_set_variable(channel, header->name, NULL);
		}
	}

	for(header = to_add->headers; header; header = header->next) {
		switch_channel_set_variable(channel, header->name, header->value);
	}

	// cleanup leg A
	loopback_aleg = switch_channel_get_variable(channel, "other_loopback_leg_uuid");
	if(loopback_aleg != NULL) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "found loopback a-leg uuid - %s\n", loopback_aleg);
		if ((a_session = switch_core_session_locate(loopback_aleg))) {
			a_channel = switch_core_session_get_channel(a_session);
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "found loopback session a - %s\n", loopback_aleg);
			switch_channel_del_variable_prefix(a_channel, "Export-Loopback-");
		} else {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "Couldn't locate loopback session a - %s\n", loopback_aleg);
		}
	} else {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "Couldn't find loopback a-leg uuid!\n");
	}

	/*
	 *  set Interaction-ID
	 *  if we're not crossing account boundaries
	 */
	if (kz_test_tweak(KZ_TWEAK_INTERACTION_ID)) {
		if (a_channel) {
			const char *interaction_id = switch_channel_get_variable_dup(a_channel, INTERACTION_VARIABLE, SWITCH_FALSE, -1);
			const char *a_account_id  = switch_channel_get_variable_dup(a_channel, "ecallmgr_Account-ID", SWITCH_FALSE, -1);
			const char *b_account_id  = switch_channel_get_variable_dup(channel, "ecallmgr_Account-ID", SWITCH_FALSE, -1);
			if ((!a_account_id) || (!b_account_id) || (!strcmp(a_account_id, b_account_id))) {
				kz_set_interaction(channel, interaction_id, 0);
			}
		}
	}

	if (a_session){
		switch_core_session_rwunlock(a_session);
	}
	switch_event_destroy(&event);
	switch_event_destroy(&to_add);
	switch_event_destroy(&to_remove);

	return SWITCH_STATUS_SUCCESS;

}

static void kz_tweaks_handle_caller_id(switch_core_session_t *session)
{
	if (kz_test_tweak(KZ_TWEAK_CALLER_ID)) {
		switch_channel_t *channel = switch_core_session_get_channel(session);
		switch_caller_profile_t* caller = switch_channel_get_caller_profile(channel);
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "CHECKING CALLER-ID\n");
		if (caller && switch_channel_direction(channel) == SWITCH_CALL_DIRECTION_INBOUND) {
			const char* val = NULL;
			if((val=switch_caller_get_field_by_name(caller, "Endpoint-Caller-ID-Name"))) {
				caller->caller_id_name = val;
				caller->orig_caller_id_name = val;
			}
			if((val=switch_caller_get_field_by_name(caller, "Endpoint-Caller-ID-Number"))) {
				caller->caller_id_number = val;
				caller->orig_caller_id_number = val;
			}
		}
	}
}

static switch_status_t kz_tweaks_handle_nightmare_xfer_interaction_id(switch_core_session_t *session)
{
	if (kz_test_tweak(KZ_TWEAK_INTERACTION_ID)) {
		switch_core_session_t *replace_session = NULL;
		switch_channel_t *channel = switch_core_session_get_channel(session);
		const char *replaced_call_id = switch_channel_get_variable(channel, "sip_replaces_call_id");
		const char *core_uuid = switch_channel_get_variable(channel, "sip_h_X-FS-From-Core-UUID");
		const char *partner_uuid = switch_channel_get_variable(channel, "sip_h_X-FS-Refer-Partner-UUID");
		const char *interaction_id = switch_channel_get_variable(channel, "sip_h_X-FS-Call-Interaction-ID");
		if(core_uuid && partner_uuid && replaced_call_id && interaction_id) {
			kz_set_interaction(channel, interaction_id, 0);
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "checking nightmare xfer tweak for %s\n", switch_channel_get_uuid(channel));
			if ((replace_session = switch_core_session_locate(replaced_call_id))) {
				switch_channel_t *replaced_call_channel = switch_core_session_get_channel(replace_session);
				kz_set_interaction(replaced_call_channel, interaction_id, 0);
				switch_core_session_rwunlock(replace_session);
			}
			if ((replace_session = switch_core_session_locate(partner_uuid))) {
				switch_channel_t *replaced_call_channel = switch_core_session_get_channel(replace_session);
				kz_set_interaction(replaced_call_channel, interaction_id, 0);
				switch_core_session_rwunlock(replace_session);
			}
		}
	}

	return SWITCH_STATUS_SUCCESS;

}

static switch_status_t kz_tweaks_handle_replaces_call_id(switch_core_session_t *session)
{
	if (kz_test_tweak(KZ_TWEAK_REPLACES_CALL_ID)) {
		switch_core_session_t *replace_call_session = NULL;
		switch_event_t *event;
		switch_channel_t *channel = switch_core_session_get_channel(session);
		const char *replaced_call_id = switch_channel_get_variable(channel, "sip_replaces_call_id");
		const char *core_uuid = switch_channel_get_variable(channel, "sip_h_X-FS-From-Core-UUID");
		if((!core_uuid) && replaced_call_id) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "checking replaces header tweak for %s\n", replaced_call_id);
			if ((replace_call_session = switch_core_session_locate(replaced_call_id))) {
				switch_channel_t *replaced_call_channel = switch_core_session_get_channel(replace_call_session);
				int i;
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "setting bridge variables from %s to %s\n", replaced_call_id, switch_channel_get_uuid(channel));
				for(i = 0; bridge_variables[i] != NULL; i++) {
					const char *val = switch_channel_get_variable_dup(replaced_call_channel, bridge_variables[i], SWITCH_TRUE, -1);
					switch_channel_set_variable(channel, bridge_variables[i], val);
				}
				if (switch_event_create(&event, SWITCH_EVENT_CHANNEL_DATA) == SWITCH_STATUS_SUCCESS) {
					switch_channel_event_set_data(channel, event);
					switch_event_fire(&event);
				}
				switch_core_session_rwunlock(replace_call_session);
			}
		}
	}

	return SWITCH_STATUS_SUCCESS;

}


/* Switch-URI / Switch-URL from another leg (the kz originate session, a
 * loopback's other side, the partner, the bridge id), filled in where
 * this channel has none; SUCCESS when that leg had them */
static switch_status_t kz_tweaks_check_bridge_variables_uuid(switch_channel_t *channel, const char *uuid)
{
	switch_core_session_t *a_session;
	switch_status_t ret = SWITCH_STATUS_FALSE;

	/* the uuids come from Kazoo-set variables: never locate ourselves */
	if (zstr(uuid) || !strcmp(uuid, switch_channel_get_uuid(channel))) return ret;
	if ((a_session = switch_core_session_locate(uuid))) {
		int i;
		switch_channel_t *a_channel = switch_core_session_get_channel(a_session);
		for (i = 0; bridge_check_variables[i] != NULL; i++) {
			const char *a_val = switch_channel_get_variable_dup(a_channel, bridge_check_variables[i], SWITCH_FALSE, -1);
			if (a_val != NULL) {
				ret = SWITCH_STATUS_SUCCESS;
				if (switch_channel_get_variable_dup(channel, bridge_check_variables[i], SWITCH_FALSE, -1) == NULL) {
					switch_channel_set_variable(channel, bridge_check_variables[i], a_val);
				}
			}
		}
		switch_core_session_rwunlock(a_session);
	}
	return ret;
}

/* Switch-URI (sip:host:port of the sofia profile the leg is on) and
 * Switch-URL: from sofia_profile_uri (the OpenKazoo port read
 * sofia_profile_url, which mod_sofia never sets, so only the bridge copy
 * ever populated them), else from a related leg (freeswitch-kazoo 20.23.6) */
const char *kz_switch_uri_host(const char *profile_url)
{
	const char *at;
	if (!profile_url) return NULL;
	/* strcspn's "position of '@'" is the string length when there is
	 * none: +1 would point past the NUL. Only a real '@' is skipped. */
	at = strchr(profile_url, '@');
	return (at && at > profile_url) ? at + 1 : profile_url;
}

static switch_status_t kz_tweaks_handle_switch_uri(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	if (kz_test_tweak(KZ_TWEAK_SWITCH_URI)) {
		const char *profile_url = switch_channel_get_variable(channel, "sofia_profile_uri");
		if(profile_url) {
			switch_channel_set_variable(channel, "Switch-URL", profile_url);
			switch_channel_set_variable_printf(channel, "Switch-URI", "sip:%s", kz_switch_uri_host(profile_url));
		} else if (switch_channel_get_variable_dup(channel, "Switch-URI", SWITCH_FALSE, -1) == NULL) {
			const char *uuid = switch_channel_get_variable_dup(channel, KZ_ORIGINATE_UUID_VARIABLE, SWITCH_FALSE, -1);
			switch_status_t found = SWITCH_STATUS_FALSE;
			if (uuid) {
				found = kz_tweaks_check_bridge_variables_uuid(channel, uuid);
			}
			if (found != SWITCH_STATUS_SUCCESS) {
				uuid = switch_channel_get_variable_dup(channel, "other_loopback_from_uuid", SWITCH_FALSE, -1);
				if (!uuid) {
					uuid = switch_channel_get_variable_dup(channel, "loopback_from_uuid", SWITCH_FALSE, -1);
				}
				if (uuid) {
					found = kz_tweaks_check_bridge_variables_uuid(channel, uuid);
				}
			}
			if (found != SWITCH_STATUS_SUCCESS) {
				uuid = switch_channel_get_partner_uuid(channel);
				if (uuid) {
					found = kz_tweaks_check_bridge_variables_uuid(channel, uuid);
				}
			}
			if (found != SWITCH_STATUS_SUCCESS) {
				uuid = switch_channel_get_variable_dup(channel, KZ_BRIDGE_ID, SWITCH_FALSE, -1);
				if (uuid) {
					found = kz_tweaks_check_bridge_variables_uuid(channel, uuid);
				}
			}
			if (found != SWITCH_STATUS_SUCCESS) {
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "Switch-URI not set: no sofia profile and no related leg\n");
			}
		}
	}

	return SWITCH_STATUS_SUCCESS;

}

static char * kz_tweaks_new_interaction_id()
{
	long int first = (switch_micro_time_now() / 1000000) + UNIX_EPOCH_IN_GREGORIAN;
	char uuid_str[SWITCH_UUID_FORMATTED_LENGTH + 1];
	switch_uuid_t uuid;
	switch_uuid_get(&uuid);
	switch_uuid_format(uuid_str, &uuid);
	uuid_str[8] = '\0';
	return switch_mprintf("%ld-%s", first, uuid_str);
}

static void kz_tweaks_handle_interaction_id(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	char * val = NULL;
	switch_core_session_t *peer_session = NULL;
	const char* peer_interaction_id = NULL;

	if (kz_test_tweak(KZ_TWEAK_INTERACTION_ID)) {
		const char *external_id;
		val = kz_tweaks_new_interaction_id();
		if (val) {
			switch_channel_set_variable(channel, "Original-"INTERACTION_VARIABLE, val);
			if(switch_core_session_get_partner(session, &peer_session) == SWITCH_STATUS_SUCCESS) {
				switch_channel_t *peer_channel = switch_core_session_get_channel(peer_session);
				peer_interaction_id = switch_channel_get_variable_dup(peer_channel, INTERACTION_VARIABLE, SWITCH_FALSE, -1);
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "PEER_SESSION => %s\n", peer_interaction_id);
				if(peer_interaction_id) {
					kz_set_interaction(channel, peer_interaction_id, 0);
				}
				switch_core_session_rwunlock(peer_session);
			} else if ((external_id = switch_channel_get_variable_dup(channel, "sip_h_X-External-"INTERACTION_VARIABLE, SWITCH_FALSE, -1)) != NULL) {
				/* an INVITE from another Kazoo cluster carries its interaction id
				 * (freeswitch-kazoo 20.23.6); take it if well-formed */
				if (kz_is_valid_interaction_id(external_id)) {
					switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "interaction id %s taken from the incoming X-External-Call-Interaction-ID\n", external_id);
					kz_set_interaction(channel, external_id, 0);
				} else {
					switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_WARNING, "incoming X-External-Call-Interaction-ID %s is invalid, using %s\n", external_id, val);
					kz_set_interaction(channel, val, 1);
				}
			} else if (!switch_channel_get_variable_dup(channel, INTERACTION_VARIABLE, SWITCH_FALSE, -1)) {
				kz_set_interaction(channel, val, 1);
			}
		}

		switch_safe_free(val);
	}

}

/* the outgoing-channel hook on every leg (freeswitch-kazoo 20.23.6 form):
 * the interaction id and the outgoing_variables go to the new leg; the
 * new leg is pushed onto originated_legs of the kz originate session
 * (the _json_originated_legs of its CDR); presence_id comes from the
 * caller profile's Endpoint-Presence-ID when the dial string set none */
static switch_status_t kz_outgoing_channel(switch_core_session_t * session, switch_event_t * event, switch_caller_profile_t * cp, switch_core_session_t * peer_session, switch_originate_flag_t flag)
{
	int i;

	if (!peer_session) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "outgoing channel hook without a peer session\n");
		return SWITCH_STATUS_SUCCESS;
	}

	if (kz_test_tweak(KZ_TWEAK_INTERACTION_ID)) {
		switch_channel_t *channel = switch_core_session_get_channel(session);
		switch_channel_t *peer_channel = switch_core_session_get_channel(peer_session);
		const char* interaction_id = switch_channel_get_variable_dup(channel, INTERACTION_VARIABLE, SWITCH_FALSE, -1);
		if (interaction_id) {
			kz_set_interaction(peer_channel, interaction_id, 0);
		}
		for (i = 0; outgoing_variables[i] != NULL; i++) {
			const char *a_val = switch_channel_get_variable_dup(channel, outgoing_variables[i], SWITCH_FALSE, -1);
			if (a_val != NULL) {
				switch_channel_set_variable(peer_channel, outgoing_variables[i], a_val);
			}
		}
	}

	{
		switch_core_session_t *kz_session = NULL;
		switch_channel_t *peer_channel = switch_core_session_get_channel(peer_session);
		switch_channel_t *channel = switch_core_session_get_channel(session);
		const char *uuid = switch_core_session_get_uuid(session);
		const char *kz_uuid = switch_channel_get_variable_dup(channel, KZ_ORIGINATE_UUID_VARIABLE, SWITCH_FALSE, -1);
		if (kz_uuid && strcmp(uuid, kz_uuid) && (kz_session = switch_core_session_locate(kz_uuid)) != NULL) {
			switch_channel_t *kz_channel = switch_core_session_get_channel(kz_session);
			char *val = switch_core_session_sprintf(kz_session, "%s;%s;%s",
							switch_core_session_get_uuid(peer_session),
							switch_str_nil(switch_channel_get_variable_dup(peer_channel, "callee_id_name", SWITCH_FALSE, -1)),
							switch_str_nil(switch_channel_get_variable_dup(peer_channel, "callee_id_number", SWITCH_FALSE, -1)));
			switch_channel_add_variable_var_check(kz_channel, "originated_legs", val, SWITCH_FALSE, SWITCH_STACK_PUSH);
			switch_core_session_rwunlock(kz_session);
		}
	}

	{
		const char *val = NULL;
		switch_channel_t *peer_channel = switch_core_session_get_channel(peer_session);
		switch_caller_profile_t *peer_caller = switch_channel_get_caller_profile(peer_channel);
		if (switch_channel_get_variable_dup(peer_channel, "presence_id", SWITCH_FALSE, -1) == NULL && peer_caller
			&& (val = switch_caller_get_field_by_name(peer_caller, "Endpoint-Presence-ID")) != NULL) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(peer_session), SWITCH_LOG_DEBUG, "presence_id %s from the caller profile\n", val);
			switch_channel_set_variable(peer_channel, "presence_id", val);
		}
	}

	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t kz_tweaks_register_handle_blind_xfer(switch_core_session_t *session)
{
	if (kz_test_tweak(KZ_TWEAK_RESTORE_CALLER_ID_ON_BLIND_XFER)) {
		switch_channel_t *channel = switch_core_session_get_channel(session);
		switch_channel_set_variable(channel, "execute_on_blind_transfer", "kz_restore_caller_id");
	}
	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t kz_tweaks_on_init(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "checking tweaks for %s\n", switch_channel_get_uuid(channel));
	switch_channel_set_flag(channel, CF_VERBOSE_EVENTS);
	switch_core_event_hook_add_outgoing_channel(session, kz_outgoing_channel);
	kz_tweaks_handle_interaction_id(session);
	kz_tweaks_handle_switch_uri(session);
	kz_tweaks_handle_caller_id(session);
	kz_tweaks_handle_nightmare_xfer_interaction_id(session);
	kz_tweaks_handle_replaces_call_id(session);
	kz_tweaks_handle_loopback(session);
	kz_tweaks_register_handle_blind_xfer(session);

	return SWITCH_STATUS_SUCCESS;
}

static switch_state_handler_table_t kz_tweaks_state_handlers = {
	/*.on_init */ kz_tweaks_on_init,
	/*.on_routing */ NULL,
	/*.on_execute */ NULL,
	/*.on_hangup */ NULL,
	/*.on_exchange_media */ NULL,
	/*.on_soft_execute */ NULL,
	/*.on_consume_media */ NULL,
	/*.on_hibernate */ NULL,
	/*.on_reset */ NULL,
	/*.on_park */ NULL,
	/*.on_reporting */ NULL,
	/*.on_destroy */ NULL
};


static void kz_tweaks_register_state_handlers()
{
/*
 * we may need two handlers
 * one with SSH_FLAG_PRE_EXEC
 * and another without it
 * mod_loopback tweaks needs post-init (SSH_FLAG_PRE_EXEC off)
 *
 * kz_tweaks_state_handlers.flags = SSH_FLAG_PRE_EXEC;
 *
 */
	switch_core_add_state_handler(&kz_tweaks_state_handlers);
}

static void kz_tweaks_unregister_state_handlers()
{
	switch_core_remove_state_handler(&kz_tweaks_state_handlers);
}

static void kz_tweaks_bind_events()
{
	if (switch_event_bind("kz_tweaks", SWITCH_EVENT_CHANNEL_BRIDGE, SWITCH_EVENT_SUBCLASS_ANY, kz_tweaks_channel_bridge_event_handler, NULL) != SWITCH_STATUS_SUCCESS) {
	        switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "Couldn't bind to channel_bridge event!\n");
	}
	if (switch_event_bind("kz_tweaks", SWITCH_EVENT_CUSTOM, "sofia::replaced", kz_tweaks_channel_replaced_event_handler, NULL) != SWITCH_STATUS_SUCCESS) {
	        switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "Couldn't bind to channel_bridge event!\n");
	}
	if (switch_event_bind("kz_tweaks", SWITCH_EVENT_CUSTOM, "sofia::intercepted", kz_tweaks_channel_intercepted_event_handler, NULL) != SWITCH_STATUS_SUCCESS) {
	        switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "Couldn't bind to channel_bridge event!\n");
	}
	if (switch_event_bind("kz_tweaks", SWITCH_EVENT_CUSTOM, "sofia::transferor", kz_tweaks_channel_transferor_event_handler, NULL) != SWITCH_STATUS_SUCCESS) {
	        switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "Couldn't bind to channel_bridge event!\n");
	}
	if (switch_event_bind("kz_tweaks", SWITCH_EVENT_CUSTOM, "sofia::transferee", kz_tweaks_channel_transferee_event_handler, NULL) != SWITCH_STATUS_SUCCESS) {
	        switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "Couldn't bind to channel_bridge event!\n");
	}
}

static void kz_tweaks_unbind_events()
{
	switch_event_unbind_callback(kz_tweaks_channel_bridge_event_handler);
	switch_event_unbind_callback(kz_tweaks_channel_replaced_event_handler);
	switch_event_unbind_callback(kz_tweaks_channel_intercepted_event_handler);
	switch_event_unbind_callback(kz_tweaks_channel_transferor_event_handler);
	switch_event_unbind_callback(kz_tweaks_channel_transferee_event_handler);
}

void kz_tweaks_add_core_variables()
{
	switch_core_set_variable("UNIX_EPOCH_IN_GREGORIAN", UNIX_EPOCH_IN_GREGORIAN_STR);
}

void kz_tweaks_start()
{
	kz_tweaks_add_core_variables();
	kz_tweaks_register_state_handlers();
	kz_tweaks_bind_events();
}

void kz_tweaks_stop()
{
	kz_tweaks_unbind_events();
	kz_tweaks_unregister_state_handlers();
}

const char *kz_tweak_name(kz_tweak_t tweak)
{
	return TWEAK_NAMES[tweak];
}

switch_status_t kz_name_tweak(const char *name, kz_tweak_t *type)
{
	kz_tweak_t x;
	for (x = 0; x < KZ_TWEAK_MAX; x++) {
		if (!strcasecmp(name, TWEAK_NAMES[x])) {
			*type = x;
			return SWITCH_STATUS_SUCCESS;
		}
	}

	return SWITCH_STATUS_FALSE;
}

/* For Emacs:
 * Local Variables:
 * mode:c
 * indent-tabs-mode:t
 * tab-width:4
 * c-basic-offset:4
 * End:
 * For VIM:
 * vim:set softtabstop=4 shiftwidth=4 tabstop=4:
 */


