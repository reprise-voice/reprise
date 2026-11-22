/*
 * reprise_presence.c -- KZ_PRESENCE_DIALOG, the closed module's BLF producer.
 *
 * Kazoo's BLF path: the switch publishes a presence `dialog_update`
 * (exchange `presence`, key `dialog.<realm>.<call-id>`) for every state
 * change of a channel that carries a presence_id; Kamailio's kazoo module
 * consumes it (event_route[kazoo:consumer-event-presence-dialog-update])
 * and NOTIFYs the dialog-info subscribers. ecallmgr still ships the
 * publisher that built that document from the stock core's PRESENCE_IN
 * event (ecallmgr_presence_event_publisher), but the extension's AMQP
 * event stream never runs its publish stage, so on this transport the
 * switch fires the closed module's KZ_PRESENCE_DIALOG itself: this file is
 * that publisher ported header by header, and the served `presence` event
 * profile renders the Presence-Dialog-* headers into the document.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * Portions translated from Kazoo's ecallmgr_presence_event_publisher.erl
 * (applications/ecallmgr in this tree), Copyright (C) 2010-2023, 2600Hz,
 * under the same license.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise.h"
#include "reprise_kz.h"

#define REPRISE_PRESENCE_TASK_GROUP "reprise_presence"

static struct {
	switch_event_node_t *node;
	int started;
	uint64_t seen, fired, skipped;
} presence;

static const char *first_of(switch_event_t *event, const char *const *names)
{
	for (; *names; names++) {
		const char *v = switch_event_get_header(event, *names);
		if (!zstr(v)) return v;
	}
	return NULL;
}

static void lower_copy(char *dst, switch_size_t dstlen, const char *src)
{
	switch_size_t i;
	for (i = 0; src && src[i] && i + 1 < dstlen; i++) {
		dst[i] = (char) tolower((unsigned char) src[i]);
	}
	dst[i] = '\0';
}

/* ecallmgr_presence_event_publisher:presence_status/3: the dialog state
 * from the leg's direction, the PRESENCE_IN status (a channel state name
 * such as cs_routing, or answered / hangup / hold / unhold ...) and the
 * channel's Answer-State */
const char *reprise_presence_state(const char *direction, const char *status, const char *answer_state)
{
	if (!strcmp(answer_state, "answered")) return "confirmed";
	if (!strcmp(answer_state, "hangup")) return "terminated";
	if (!strcmp(status, "hangup")) return "terminated";
	if (!strncmp(status, "cs_", 3)) return reprise_presence_state(direction, status + 3, answer_state);
	if (!strcmp(answer_state, "ringing")) {
		return !strcmp(direction, "initiator") ? "confirmed" : "early";
	}
	return answer_state;
}

/* the KZ_PRESENCE_DIALOG event for a PRESENCE_IN, or NULL when the
 * publisher would have dropped it (not a call, no presence id, no
 * direction). The result carries every header of the PRESENCE_IN (the
 * profile references CCVs and the interaction id) plus the
 * Presence-Dialog-* derivations; the caller fires or destroys it. */
switch_event_t *reprise_presence_dialog_build(switch_event_t *in)
{
	static const char *const realm_names[] = {"variable_ecallmgr_Realm", "variable_sip_invite_domain",
											  "variable_sip_auth_realm", "variable_sip_to_host", NULL};
	static const char *const from_names[] = {"variable_ecallmgr_Presence-ID", "from", "variable_presence_id",
											 "Channel-Presence-ID", NULL};
	static const char *const pid_names[] = {"Channel-Presence-ID", "variable_presence_id", NULL};
	static const char *const to_initiator[] = {"Caller-Destination-Number", "variable_sip_to_user", NULL};
	static const char *const to_recipient[] = {"Caller-Caller-ID-Number", "variable_sip_from_user", NULL};
	/* what switch_event_prep_for_delivery stamps: dropped so the fired
	 * event gets its own, not the PRESENCE_IN's */
	static const char *const delivery_headers[] = {"Event-Name", "Event-Subclass", "Event-Date-Local", "Event-Date-GMT",
												   "Event-Date-Timestamp", "Event-Calling-File", "Event-Calling-Function",
												   "Event-Calling-Line-Number", "Event-Sequence", NULL};
	const char *proto = switch_event_get_header(in, "proto");
	const char *uuid = switch_event_get_header(in, "Unique-ID");
	const char *call_direction = switch_event_get_header(in, "presence-call-direction");
	const char *from, *pid_src, *at, *to_user, *state, *direction, *tag, *switch_uri;
	char from_user[256], realm[256], presence_id[512], uri[600];
	char status[64], answer_state[64];
	switch_event_t *out = NULL;
	int i;

	if (!proto || strcmp(proto, "any") || zstr(uuid)) return NULL;
	if (call_direction && !strcasecmp(call_direction, "inbound")) {
		direction = "initiator";
	} else if (call_direction && !strcasecmp(call_direction, "outbound")) {
		direction = "recipient";
	} else {
		return NULL;
	}
	if (!(from = first_of(in, from_names)) || !(pid_src = first_of(in, pid_names))) return NULL;

	/* {From-User, Realm}: the from split at '@', else the channel's realm */
	if ((at = strchr(from, '@'))) {
		switch_size_t n = (switch_size_t) (at - from) + 1;
		switch_copy_string(from_user, from, n < sizeof(from_user) ? n : sizeof(from_user));
		switch_copy_string(realm, at + 1, sizeof(realm));
		if ((at = strchr(realm, '@'))) *((char *) at) = '\0';
	} else {
		const char *r = first_of(in, realm_names);
		switch_copy_string(from_user, from, sizeof(from_user));
		switch_copy_string(realm, r ? r : REPRISE_PRESENCE_DEFAULT_REALM, sizeof(realm));
	}
	/* Presence-ID: the presence id's user part, in that realm */
	at = strchr(pid_src, '@');
	switch_snprintf(presence_id, sizeof(presence_id), "%.*s@%s",
					at ? (int) (at - pid_src) : (int) strlen(pid_src), pid_src, realm);

	to_user = first_of(in, !strcmp(direction, "initiator") ? to_initiator : to_recipient);
	lower_copy(status, sizeof(status), switch_event_get_header(in, "status"));
	lower_copy(answer_state, sizeof(answer_state), switch_event_get_header(in, "Answer-State"));
	state = reprise_presence_state(direction, status, answer_state);
	if (zstr(state)) return NULL;

	if (switch_event_create_subclass(&out, SWITCH_EVENT_CUSTOM, REPRISE_EVENT_PRESENCE_DIALOG) != SWITCH_STATUS_SUCCESS) {
		return NULL;
	}
	switch_event_merge(out, in);
	for (i = 0; delivery_headers[i]; i++) {
		switch_event_del_header(out, delivery_headers[i]);
	}

	switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-Presence-ID", presence_id);
	switch_snprintf(uri, sizeof(uri), "sip:%s", presence_id);
	switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-From", uri);
	switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-Presence-URI", uri);
	switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-From-User", from_user);
	switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-Realm", realm);
	if (to_user) {
		switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-To-User", to_user);
		switch_snprintf(uri, sizeof(uri), "sip:%s@%s", to_user, realm);
		switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-To", uri);
	}
	if (!zstr((tag = switch_event_get_header(in, "variable_sip_from_tag")))) {
		switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-From-Tag", tag);
	}
	if (!zstr((tag = switch_event_get_header(in, "variable_sip_to_tag")))) {
		switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-To-Tag", tag);
	}
	if (!zstr((switch_uri = switch_event_get_header(in, "variable_Switch-URI")))) {
		switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-Switch-URI", switch_uri);
	}
	switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-Direction", direction);
	switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-State", state);
	switch_event_add_header_string(out, SWITCH_STACK_BOTTOM, "Presence-Dialog-Expires",
								   !strcmp(state, "terminated") ? "20" : "0");
	return out;
}

/* the publisher holds a terminated back one second (a short call's
 * confirmed must not arrive after it); the switch's scheduler thread
 * fires it for us */
static void presence_terminated_task(switch_scheduler_task_t *task)
{
	switch_event_t *event = (switch_event_t *) task->cmd_arg;

	if (reprise_globals.running && presence.started) {
		switch_event_fire(&event);
		presence.fired++;
	}
	if (event) switch_event_destroy(&event);
}

static void presence_in_handler(switch_event_t *event)
{
	switch_event_t *out;
	const char *state;

	if (!reprise_globals.running || !presence.started) return;
	presence.seen++;
	if (!(out = reprise_presence_dialog_build(event))) {
		presence.skipped++;
		return;
	}
	state = switch_event_get_header(out, "Presence-Dialog-State");
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "presence dialog %s %s -> %s (%s)\n",
					  switch_event_get_header_nil(out, "Presence-Dialog-From"), state,
					  switch_event_get_header_nil(out, "Presence-Dialog-To"),
					  switch_event_get_header_nil(out, "Unique-ID"));
	if (state && !strcmp(state, "terminated")) {
		switch_scheduler_add_task(switch_epoch_time_now(NULL) + 1, presence_terminated_task, "presence terminated",
								  REPRISE_PRESENCE_TASK_GROUP, 0, out, SSHF_NONE);
		return;
	}
	switch_event_fire(&out);
	presence.fired++;
}

void reprise_presence_start(void)
{
	if (presence.started) return;
	if (switch_event_reserve_subclass(REPRISE_EVENT_PRESENCE_DIALOG) != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "subclass %s already reserved\n", REPRISE_EVENT_PRESENCE_DIALOG);
	}
	if (switch_event_bind_removable(REPRISE_PRESENCE_TASK_GROUP, SWITCH_EVENT_PRESENCE_IN, SWITCH_EVENT_SUBCLASS_ANY,
									presence_in_handler, NULL, &presence.node) != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "cannot bind PRESENCE_IN\n");
		return;
	}
	presence.started = 1;
}

void reprise_presence_stop(void)
{
	if (!presence.started) return;
	presence.started = 0;
	if (presence.node) switch_event_unbind(&presence.node);
	/* a terminated still waiting its second is dropped with its event
	 * (the scheduler frees only malloc'd args) */
	switch_scheduler_del_task_group(REPRISE_PRESENCE_TASK_GROUP);
	switch_event_free_subclass(REPRISE_EVENT_PRESENCE_DIALOG);
}

void reprise_presence_status(switch_stream_handle_t *stream)
{
	stream->write_function(stream, "presence dialog: %s, PRESENCE_IN seen=%" SWITCH_UINT64_T_FMT
						   " fired=%" SWITCH_UINT64_T_FMT " skipped=%" SWITCH_UINT64_T_FMT "\n",
						   presence.started ? "on" : "off", presence.seen, presence.fired, presence.skipped);
}

/* For Emacs:
 * Local Variables:
 * mode:c
 * indent-tabs-mode:t
 * tab-width:4
 * c-basic-offset:4
 * End:
 * For VIM:
 * vim:set softtabstop=4 shiftwidth=4 tabstop=4
 */
