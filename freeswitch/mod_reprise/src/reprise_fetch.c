/*
 * reprise_fetch.c -- serving FreeSWITCH XML fetches over AMQP. One search
 * function is bound for every section a fetch profile covers
 * (configuration / dialplan / directory / channels / languages); the
 * handler renders the fetch params through the profile's fields into the
 * kz_api request (the dialplan one IS the kapi_route request), publishes
 * it to the profile's exchange with the routing key from its spec (plus
 * the call-id hash header that steers dialplan fetches through ecallmgr's
 * x-consistent-hash exchange), and blocks the switch's thread until the
 * fetch worker delivers the reply (message_id = Fetch-UUID, text/xml on
 * our targeted queue) or the profile's timeout (microseconds) passes.
 * Not-found replies pass through: the core recognises
 * <section name="result"><result status="not found"/>.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise.h"
#include "reprise_fields.h"
#include "reprise_kz.h"

typedef struct reprise_pending_s {
	char uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
	char *xml; /* malloc'd reply body */
	struct reprise_pending_s *next;
} reprise_pending_t;

static struct {
	switch_mutex_t *mutex;
	switch_thread_cond_t *cond;
	reprise_pending_t *pending;
	switch_xml_binding_t *binding;
	uint32_t generation; /* bumped by reprise_fetch_stop: waiters of an older one give up */
	uint64_t requests, replies, timeouts, unmatched, failures, republished;
} fetch;

/* kz_amqp_util:encode/1 for routing-key parts */
static void encode_part(const char *in, char *out, switch_size_t outlen)
{
	static const char hex[] = "0123456789ABCDEF";
	switch_size_t used = 0;

	if (!strcmp(in, "*") || !strcmp(in, "#")) {
		switch_copy_string(out, in, outlen);
		return;
	}
	for (; *in && used + 4 < outlen; in++) {
		unsigned char c = (unsigned char) *in;
		if (isalnum(c) || c == '-' || c == '_' || c == '~') {
			out[used++] = (char) c;
		} else if (c == ' ') {
			out[used++] = '+';
		} else {
			out[used++] = '%';
			out[used++] = hex[c >> 4];
			out[used++] = hex[c & 15];
		}
	}
	out[used] = '\0';
}

static const char *json_str(cJSON *json, const char *key)
{
	cJSON *item = cJSON_GetObjectItem(json, key);
	return (item && item->type == cJSON_String) ? item->valuestring : NULL;
}

/* build a routing key from a spec against the rendered document: static
 * parts verbatim, field parts from the JSON (or the event), encoded
 * unless encode-part="false" */
void reprise_routing_key_build(reprise_routing_key_t *spec, cJSON *json, switch_event_t *event,
						   char *out, switch_size_t outlen)
{
	reprise_rk_field_t *f;
	switch_size_t used = 0;

	out[0] = '\0';
	for (f = spec->fields; f; f = f->next) {
		const char *value = NULL;
		char *expanded = NULL;
		char encoded[512];

		if (f->type && !strcmp(f->type, "static")) {
			value = f->value;
		} else if (f->type && !strcmp(f->type, "expand")) {
			expanded = reprise_expand_headers(event, f->value);
			value = expanded;
		} else if (f->type && !strcmp(f->type, "first-of")) {
			char list[512];
			char *argv[REPRISE_LIST_MAX] = {0};
			int argc, n;
			switch_copy_string(list, switch_str_nil(f->value), sizeof(list));
			argc = switch_separate_string(list, '|', argv, REPRISE_LIST_MAX);
			for (n = 0; n < argc && !value; n++) {
				value = json_str(json, argv[n]);
				if (!value) value = switch_event_get_header(event, argv[n]);
			}
		} else {
			value = json_str(json, f->name);
			if (!value) value = switch_event_get_header(event, f->name);
		}
		if (zstr(value)) {
			if (expanded != f->value) switch_safe_free(expanded);
			continue;
		}

		if (f->encode_part) {
			encode_part(value, encoded, sizeof(encoded));
			value = encoded;
		}
		if (used) {
			if (used + 1 >= outlen) {
				if (expanded != f->value) switch_safe_free(expanded);
				break;
			}
			out[used++] = '.';
			out[used] = '\0';
		}
		switch_copy_string(out + used, value, outlen - used);
		used += strlen(out + used);
		if (expanded != f->value) switch_safe_free(expanded);
	}
}

static reprise_fetch_profile_t *profile_for_section(reprise_config_t *config, const char *section)
{
	reprise_fetch_profile_t *p;
	for (p = config->fetch_profiles; p; p = p->next) {
		if (!strcasecmp(p->fetch_section, section)) return p;
	}
	return NULL;
}

/* when the fetch is on behalf of a call but carries no channel data, pull
 * the channel's variables in (mod_kazoo does the same) */
static void add_channel_data(switch_event_t *event)
{
	static const char *sources[] = {"Fetch-Call-UUID", "Call-ID", "Caller-Unique-ID", "Unique-ID", "uuid", NULL};
	int i;

	if (switch_event_get_header(event, "Unique-ID")) return;

	for (i = 0; sources[i]; i++) {
		const char *call_id = switch_event_get_header(event, sources[i]);
		switch_core_session_t *session;
		if (call_id && (session = switch_core_session_locate(call_id))) {
			switch_channel_t *channel = switch_core_session_get_channel(session);
			switch_channel_event_set_data(channel, event);
			switch_core_session_rwunlock(session);
			return;
		}
	}
}

static switch_xml_t fetch_handler(const char *section, const char *tag_name, const char *key_name,
								  const char *key_value, switch_event_t *params, void *user_data)
{
	reprise_config_t *config;
	reprise_fetch_profile_t *profile;
	switch_event_t *event = NULL;
	cJSON *json;
	reprise_pending_t pending, **pp;
	char routing_key[1024];
	char timeout_str[32];
	char server_id[512];
	const char *hash_value = NULL;
	switch_time_t started = switch_micro_time_now(), deadline;
	switch_xml_t xml = NULL;
	switch_status_t published;
	uint32_t worker_reconnects, generation;
	reprise_publisher_t *publisher;

	if (!reprise_globals.running || !fetch.binding || !(config = reprise_config_hold())) {
		return NULL;
	}
	if (!(profile = profile_for_section(config, section))) {
		reprise_config_release(config);
		return NULL;
	}
	worker_reconnects = reprise_worker_reconnects(profile->amqp_profile);
	if (!reprise_worker_queue_name(profile->amqp_profile, server_id, sizeof(server_id))) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING,
						  "fetch %s: no %s worker queue to receive the reply\n", section, profile->amqp_profile);
		reprise_config_release(config);
		return NULL;
	}

	/* our own copy: the caller keeps params, and we decode + annotate */
	if (params) {
		switch_event_dup(&event, params);
	} else {
		switch_event_create(&event, SWITCH_EVENT_GENERAL);
	}
	if (!event) {
		reprise_config_release(config);
		return NULL;
	}

	memset(&pending, 0, sizeof(pending));
	switch_uuid_str(pending.uuid, sizeof(pending.uuid));
	switch_snprintf(timeout_str, sizeof(timeout_str), "%" SWITCH_UINT64_T_FMT, profile->fetch_timeout_us);

	add_channel_data(event);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Switch-Nodename", reprise_globals.node_name);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Core-UUID", reprise_globals.core_uuid);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Fetch-UUID", pending.uuid);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Fetch-Section", section);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Fetch-Tag", switch_str_nil(tag_name));
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Fetch-Key-Name", switch_str_nil(key_name));
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Fetch-Key-Value", switch_str_nil(key_value));
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Fetch-Timeout", timeout_str);
	switch_event_add_header(event, SWITCH_STACK_BOTTOM, "Fetch-Timestamp-Micro", "%" SWITCH_UINT64_T_FMT, (uint64_t) started);
	/* the extension binds its prompt handler (ecallmgr_fs_fetch_configuration_prompt)
	 * for Fetch-Version community only; the prompt file interface's fetch
	 * (reprise_prompts.c) goes out as that bundle so it is answered */
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Kazoo-Bundle",
								   (tag_name && !strcasecmp(tag_name, "prompt")) ? "community" : REPRISE_BUNDLE);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Kazoo-Release", REPRISE_RELEASE);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Kazoo-Version", REPRISE_APP_VERSION);
	kz_event_add_interaction(event);
	reprise_event_decode(event);

	json = reprise_fields_render(profile->fields, event, profile->name);
	if (!json_str(json, "Server-ID")) {
		cJSON_AddStringToObject(json, "Server-ID", server_id);
	}
	if (!json_str(json, "Msg-ID")) {
		cJSON_AddStringToObject(json, "Msg-ID", pending.uuid);
	}
	reprise_routing_key_build(&profile->routing_key, json, event, routing_key, sizeof(routing_key));
	if (profile->routing_key.hash_event_field) {
		hash_value = json_str(json, profile->routing_key.hash_event_field);
		if (!hash_value) hash_value = switch_event_get_header(event, profile->routing_key.hash_event_field);
	}

	/* register before publishing: the reply can beat us to the table */
	switch_mutex_lock(fetch.mutex);
	pending.next = fetch.pending;
	fetch.pending = &pending;
	fetch.requests++;
	generation = fetch.generation;
	switch_mutex_unlock(fetch.mutex);

	/* the publisher is swapped under the global mutex on restart; a
	 * restart cannot destroy it while this handler runs (reprise_fetch_stop's
	 * unbind waits for us), so a snapshot of the pointer is enough. The
	 * wait is bounded by our own deadline: a publish stuck on a stalled
	 * broker must not hold every fetch thread behind it. */
	switch_mutex_lock(reprise_globals.mutex);
	publisher = reprise_globals.publisher;
	switch_mutex_unlock(reprise_globals.mutex);
	deadline = started + (switch_time_t) profile->fetch_timeout_us;
	published = publisher
		? reprise_publisher_publish_wait(publisher, profile->amqp_exchange, routing_key, json,
									 hash_value ? profile->routing_key.hash_amqp_header : NULL, hash_value,
									 deadline - switch_micro_time_now())
		: SWITCH_STATUS_FALSE;
	if (reprise_globals.trace_fetch) { /* the whole document, for contract work */
		char *body = cJSON_PrintUnformatted(json);
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "fetch %s (%s) document: %s\n", section, pending.uuid, switch_str_nil(body));
		switch_safe_free(body);
	}
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "fetch %s/%s %s=%s (%s) -> %s [%s]%s%s\n",
					  section, switch_str_nil(tag_name), switch_str_nil(key_name), switch_str_nil(key_value),
					  pending.uuid, profile->amqp_exchange, routing_key,
					  hash_value ? " call-id=" : "", switch_str_nil(hash_value));

	switch_mutex_lock(fetch.mutex);
	if (published == SWITCH_STATUS_SUCCESS) {
		int republished = 0;
		while (!pending.xml && reprise_globals.running && fetch.generation == generation) {
			switch_time_t now = switch_micro_time_now();
			int reconnected;
			if (now >= deadline) break;
			switch_thread_cond_timedwait(fetch.cond, fetch.mutex, deadline - now);
			if (pending.xml || republished) continue;
			/* the reply queue is auto-delete: if its worker reconnected while
			 * we waited, the reply may have been published into the void.
			 * Ask once more (same Fetch-UUID) as long as time remains.
			 * Lock order: the worker list is read under reprise_globals.mutex,
			 * never while holding fetch.mutex (the CLI status path takes
			 * them the other way round). */
			switch_mutex_unlock(fetch.mutex);
			reconnected = reprise_worker_reconnects(profile->amqp_profile) != worker_reconnects;
			if (reconnected && switch_micro_time_now() + 500000 < deadline) {
				republished = 1;
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE, "fetch %s (%s): reply queue reconnected, republishing\n",
								  section, pending.uuid);
				reprise_publisher_publish_wait(publisher, profile->amqp_exchange, routing_key, json,
										   hash_value ? profile->routing_key.hash_amqp_header : NULL, hash_value,
										   deadline - switch_micro_time_now());
				switch_mutex_lock(fetch.mutex);
				fetch.republished++;
			} else {
				switch_mutex_lock(fetch.mutex);
			}
		}
	} else {
		fetch.failures++;
	}
	for (pp = &fetch.pending; *pp; pp = &(*pp)->next) {
		if (*pp == &pending) {
			*pp = pending.next;
			break;
		}
	}
	if (!pending.xml && published == SWITCH_STATUS_SUCCESS) fetch.timeouts++;
	switch_mutex_unlock(fetch.mutex);

	if (pending.xml) {
		switch_log_printf(SWITCH_CHANNEL_LOG, reprise_globals.trace_fetch ? SWITCH_LOG_INFO : SWITCH_LOG_DEBUG,
						  "fetch %s (%s) replied after %dms: %s\n",
						  section, pending.uuid, (int) ((switch_micro_time_now() - started) / 1000), pending.xml);
		if (!(xml = switch_xml_parse_str_dynamic(pending.xml, SWITCH_FALSE))) {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "fetch %s (%s): unparseable XML reply\n",
							  section, pending.uuid);
			free(pending.xml);
		}
	} else if (published == SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE, "fetch %s/%s %s=%s (%s) timed out after %dms\n",
						  section, switch_str_nil(tag_name), switch_str_nil(key_name), switch_str_nil(key_value),
						  pending.uuid, (int) ((switch_micro_time_now() - started) / 1000));
	}

	cJSON_Delete(json);
	switch_event_destroy(&event);
	reprise_config_release(config);
	return xml;
}

/* fetch worker: a reply for a waiting fetch (message_id = Fetch-UUID) */
void reprise_fetch_dispatch(reprise_worker_t *worker, amqp_envelope_t *envelope)
{
	amqp_basic_properties_t *props = &envelope->message.properties;
	reprise_pending_t *p;
	char *body;

	if (!(props->_flags & AMQP_BASIC_MESSAGE_ID_FLAG) || !props->message_id.len) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "worker[%s] delivery without message_id ignored\n", worker->name);
		return;
	}
	if (envelope->message.body.len > REPRISE_MAX_FETCH_REPLY_BYTES) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
						  "worker[%s] fetch reply %.*s of %" SWITCH_SIZE_T_FMT " bytes exceeds the %d byte cap; dropped\n",
						  worker->name, (int) props->message_id.len, (char *) props->message_id.bytes,
						  (switch_size_t) envelope->message.body.len, REPRISE_MAX_FETCH_REPLY_BYTES);
		switch_mutex_lock(fetch.mutex);
		fetch.unmatched++;
		switch_mutex_unlock(fetch.mutex);
		return;
	}
	if (!(body = malloc(envelope->message.body.len + 1))) return;
	memcpy(body, envelope->message.body.bytes, envelope->message.body.len);
	body[envelope->message.body.len] = '\0';

	switch_mutex_lock(fetch.mutex);
	for (p = fetch.pending; p; p = p->next) {
		if (strlen(p->uuid) == props->message_id.len
			&& !memcmp(p->uuid, props->message_id.bytes, props->message_id.len)) {
			break;
		}
	}
	if (p && !p->xml) {
		p->xml = body;
		body = NULL;
		fetch.replies++;
		switch_thread_cond_broadcast(fetch.cond);
	} else {
		fetch.unmatched++;
	}
	switch_mutex_unlock(fetch.mutex);

	if (body) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "worker[%s] reply %.*s has no waiter (late?)\n",
						  worker->name, (int) props->message_id.len, (char *) props->message_id.bytes);
		free(body);
	}
}

void reprise_fetch_start(reprise_config_t *config)
{
	reprise_fetch_profile_t *p;
	uint32_t sections = 0;

	if (!fetch.mutex) {
		switch_mutex_init(&fetch.mutex, SWITCH_MUTEX_NESTED, reprise_globals.pool);
		switch_thread_cond_create(&fetch.cond, reprise_globals.pool);
	}
	if (fetch.binding) return; /* bound once; the handler reads the live config */

	for (p = config->fetch_profiles; p; p = p->next) {
		switch_xml_section_t s = switch_xml_parse_section_string(p->fetch_section);
		if (!s) {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "fetch profile %s: unknown section %s\n",
							  p->name, p->fetch_section);
			continue;
		}
		sections |= (uint32_t) s;
	}
	if (!sections) return;

	if (switch_xml_bind_search_function_ret(fetch_handler, (switch_xml_section_t) sections, NULL, &fetch.binding) != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "failed to bind the XML fetch handler\n");
		return;
	}
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE, "serving XML fetches over AMQP (sections 0x%x)\n", (unsigned) sections);
}

/* The core calls search functions under a read lock and unbind takes
 * the write lock, so the unbind below returns only when no fetch_handler
 * is left inside -- everything torn down after it (publisher, config)
 * is safe. Release the waiters first, or that unbind sits out the
 * remainder of a fetch timeout. */
void reprise_fetch_stop(void)
{
	if (fetch.mutex) { /* release every waiter: their generation is over */
		switch_mutex_lock(fetch.mutex);
		fetch.generation++;
		switch_thread_cond_broadcast(fetch.cond);
		switch_mutex_unlock(fetch.mutex);
	}
	if (fetch.binding) {
		switch_xml_unbind_search_function(&fetch.binding);
		fetch.binding = NULL;
	}
}

int reprise_fetch_waiting(void)
{
	reprise_pending_t *p;
	int waiting = 0;

	if (!fetch.mutex) return 0;
	switch_mutex_lock(fetch.mutex);
	for (p = fetch.pending; p; p = p->next) waiting++;
	switch_mutex_unlock(fetch.mutex);
	return waiting;
}

/* called without reprise_globals.mutex (lock order: fetch.mutex is a leaf) */
void reprise_fetch_status(switch_stream_handle_t *stream)
{
	int waiting = 0;
	reprise_pending_t *p;

	if (!fetch.mutex) return;
	switch_mutex_lock(fetch.mutex);
	for (p = fetch.pending; p; p = p->next) waiting++;
	stream->write_function(stream, "fetch: %s, requests=%" SWITCH_UINT64_T_FMT " replies=%" SWITCH_UINT64_T_FMT
						   " timeouts=%" SWITCH_UINT64_T_FMT " unmatched=%" SWITCH_UINT64_T_FMT
						   " publish-failures=%" SWITCH_UINT64_T_FMT " republished=%" SWITCH_UINT64_T_FMT " waiting=%d\n",
						   fetch.binding ? "bound" : "unbound", fetch.requests, fetch.replies,
						   fetch.timeouts, fetch.unmatched, fetch.failures, fetch.republished, waiting);
	switch_mutex_unlock(fetch.mutex);
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
