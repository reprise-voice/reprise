/*
 * reprise_events.c -- event streams: every <event> of every event profile in
 * the fetched kazoo.conf is bound in the switch; when it fires, the event
 * is gated by the profile's and the event's filters, rendered through the
 * event's fields (plus the profile's override-fields), given the routing
 * key from the event's or profile's spec and the hash header, and queued
 * to the stream of the profile's amqp-profile. One thread per stream
 * drains its queue onto its own publisher connection, so the switch's
 * event dispatch threads never touch the broker.
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

typedef struct reprise_target_s {
	reprise_event_profile_t *profile;
	reprise_event_t *event;
	int (*gate)(switch_event_t *event); /* alias precondition, or NULL */
	struct reprise_target_s *next;
} reprise_target_t;

/* one switch binding per distinct (event type, subclass); several
 * profiles can listen to the same event */
typedef struct reprise_binding_s {
	switch_event_types_t type;
	char *subclass;
	char id[SWITCH_UUID_FORMATTED_LENGTH + 1];
	switch_event_node_t *node;
	reprise_target_t *targets;
	uint64_t seen, published, filtered;
	struct reprise_binding_s *next;
} reprise_binding_t;

typedef struct {
	char *exchange;
	char *routing_key;
	char *body;
	switch_size_t body_len;
	char *header_name;
	char *header_value;
} reprise_msg_t;

typedef struct reprise_stream_s {
	char *name; /* amqp profile */
	switch_queue_t *queue;
	switch_mutex_t *mutex;      /* the byte budget: the queue bounds messages, this bounds their bytes */
	switch_size_t queued_bytes;
	switch_thread_t *thread;
	reprise_publisher_t *pub;
	uint64_t queued, published, dropped, failed;
	struct reprise_stream_s *next;
} reprise_stream_t;

/* events.mutex (module lifetime) pins bindings, streams and their
 * publishers: reprise_events_stop destroys them under it, reprise_events_status
 * walks them under it. The switch's event threads reach a binding only
 * through the core's node rwlock, which unbind takes for writing. */
static struct {
	switch_mutex_t *mutex;
	switch_memory_pool_t *pool;
	reprise_config_t *config; /* pinned while bound */
	reprise_binding_t *bindings;
	reprise_stream_t *streams;
	int started;
	volatile int stopping; /* restart: stream threads leave their loop */
} events;

void reprise_events_init(switch_memory_pool_t *pool)
{
	if (!events.mutex) switch_mutex_init(&events.mutex, SWITCH_MUTEX_NESTED, pool);
}

static void stream_account(reprise_stream_t *stream, switch_size_t bytes, int add)
{
	switch_mutex_lock(stream->mutex);
	if (add) {
		stream->queued_bytes += bytes;
	} else if (stream->queued_bytes >= bytes) {
		stream->queued_bytes -= bytes;
	} else {
		stream->queued_bytes = 0;
	}
	switch_mutex_unlock(stream->mutex);
}

static void msg_free(reprise_msg_t *msg)
{
	if (!msg) return;
	switch_safe_free(msg->exchange);
	switch_safe_free(msg->routing_key);
	switch_safe_free(msg->body);
	switch_safe_free(msg->header_name);
	switch_safe_free(msg->header_value);
	free(msg);
}

static void *SWITCH_THREAD_FUNC stream_thread(switch_thread_t *thread, void *data)
{
	reprise_stream_t *stream = (reprise_stream_t *) data;
	void *pop;

	switch_atomic_inc(&reprise_globals.threads);
	while (reprise_globals.running && !events.stopping) {
		if (switch_queue_pop_timeout(stream->queue, &pop, 500000) != SWITCH_STATUS_SUCCESS) {
			reprise_publisher_service(stream->pub);
			continue;
		}
		if (pop) {
			reprise_msg_t *msg = (reprise_msg_t *) pop;
			stream_account(stream, msg->body_len, 0);
			if (reprise_publisher_publish_body(stream->pub, msg->exchange, msg->routing_key, msg->body,
										   msg->header_name, msg->header_value) == SWITCH_STATUS_SUCCESS) {
				stream->published++;
			} else {
				stream->failed++;
			}
			msg_free(msg);
		}
	}
	/* drain what is left */
	while (switch_queue_trypop(stream->queue, &pop) == SWITCH_STATUS_SUCCESS) {
		msg_free((reprise_msg_t *) pop);
	}
	switch_atomic_dec(&reprise_globals.threads);
	return NULL;
}

static reprise_stream_t *stream_find(const char *name)
{
	reprise_stream_t *s;
	for (s = events.streams; s; s = s->next) {
		if (!strcmp(s->name, name)) return s;
	}
	return NULL;
}

static reprise_stream_t *stream_create(const char *name, reprise_config_t *config)
{
	reprise_stream_t *stream = switch_core_alloc(events.pool, sizeof(*stream));
	switch_threadattr_t *thd_attr = NULL;
	switch_memory_pool_t *tmp = NULL;

	stream->name = switch_core_strdup(events.pool, name);
	switch_queue_create(&stream->queue, REPRISE_STREAM_QUEUE_LEN, events.pool);
	switch_mutex_init(&stream->mutex, SWITCH_MUTEX_NESTED, events.pool);
	switch_core_new_memory_pool(&tmp);
	stream->pub = reprise_publisher_create(reprise_brokers_snapshot(tmp, config));
	switch_core_destroy_memory_pool(&tmp);

	switch_threadattr_create(&thd_attr, events.pool);
	switch_threadattr_stacksize_set(thd_attr, SWITCH_THREAD_STACKSIZE);
	switch_thread_create(&stream->thread, thd_attr, stream_thread, stream, events.pool);

	stream->next = events.streams;
	events.streams = stream;
	return stream;
}

/* the hash header value: hash-event-field may be a |-list (conference:
 * "Unique-ID|Conference-Unique-ID") */
static const char *hash_value(reprise_routing_key_t *spec, cJSON *json, switch_event_t *event)
{
	char list[256];
	char *argv[8] = {0};
	int argc, n;

	if (zstr(spec->hash_event_field)) return NULL;
	switch_copy_string(list, spec->hash_event_field, sizeof(list));
	argc = switch_separate_string(list, '|', argv, 8);
	for (n = 0; n < argc; n++) {
		cJSON *item = cJSON_GetObjectItem(json, argv[n]);
		const char *v = (item && item->type == cJSON_String) ? item->valuestring : switch_event_get_header(event, argv[n]);
		if (!zstr(v)) return switch_event_get_header(event, argv[n]) ? switch_event_get_header(event, argv[n]) : v;
	}
	return NULL;
}

static void publish_target(reprise_binding_t *binding, reprise_target_t *target, switch_event_t *event)
{
	reprise_event_profile_t *profile = target->profile;
	reprise_event_t *ev = target->event;
	reprise_routing_key_t *spec = ev->has_routing_key ? &ev->routing_key : &profile->routing_key;
	reprise_filter_t *rejected;
	switch_event_t *copy = NULL;
	cJSON *json;
	char routing_key[1024];
	const char *hash;
	reprise_stream_t *stream;
	reprise_msg_t *msg;

	if (target->gate && !target->gate(event)) {
		binding->filtered++;
		return;
	}
	if ((rejected = reprise_filters_apply(event, profile->filters))
		|| (rejected = reprise_filters_apply(event, ev->filters))) {
		binding->filtered++;
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "event %s: profile %s filtered by %s\n",
						  ev->name, profile->name, switch_str_nil(rejected->name));
		return;
	}
	if (zstr(profile->amqp_profile) || zstr(profile->amqp_exchange)
		|| !(stream = stream_find(profile->amqp_profile))) {
		return;
	}

	switch_event_dup(&copy, event);
	if (!copy) return;
	switch_event_add_header_string(copy, SWITCH_STACK_BOTTOM, "Switch-Nodename", reprise_globals.node_name);
	if (!switch_event_get_header(copy, "Core-UUID")) {
		switch_event_add_header_string(copy, SWITCH_STACK_BOTTOM, "Core-UUID", reprise_globals.core_uuid);
	}
	kz_event_add_interaction(copy);
	reprise_event_decode(copy);

	json = reprise_fields_render(ev->fields, copy, profile->name);
	if (profile->override_fields) {
		reprise_fields_add(json, copy, profile->override_fields->head, profile->name);
	}
	reprise_routing_key_build(spec, json, copy, routing_key, sizeof(routing_key));
	hash = hash_value(spec, json, copy);

	if (zstr(routing_key)) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "event %s: profile %s renders an empty routing key\n",
						  ev->name, profile->name);
		cJSON_Delete(json);
		switch_event_destroy(&copy);
		return;
	}

	if (!(msg = calloc(1, sizeof(*msg)))) {
		cJSON_Delete(json);
		switch_event_destroy(&copy);
		stream->dropped++;
		return;
	}
	msg->exchange = strdup(profile->amqp_exchange);
	msg->routing_key = strdup(routing_key);
	msg->body = cJSON_PrintUnformatted(json);
	msg->body_len = msg->body ? strlen(msg->body) : 0;
	if (hash && spec->hash_amqp_header) {
		msg->header_name = strdup(spec->hash_amqp_header);
		msg->header_value = strdup(hash);
	}
	cJSON_Delete(json);
	switch_event_destroy(&copy);

	if (!msg->exchange || !msg->routing_key || !msg->body) {
		stream->dropped++;
		msg_free(msg);
		return;
	}
	/* the queue bounds the message count; the byte budget bounds what a
	 * burst of large events (verbose CDRs) can hold while the broker is
	 * away. Both are checked under the stream mutex so the accounting
	 * cannot drift past the budget. */
	switch_mutex_lock(stream->mutex);
	if (stream->queued_bytes + msg->body_len <= REPRISE_STREAM_QUEUE_BYTES
		&& switch_queue_trypush(stream->queue, msg) == SWITCH_STATUS_SUCCESS) {
		stream->queued_bytes += msg->body_len;
		switch_mutex_unlock(stream->mutex);
		stream->queued++;
		binding->published++;
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "event %s -> %s [%s] via %s\n",
						  ev->name, profile->amqp_exchange, routing_key, profile->amqp_profile);
	} else {
		switch_mutex_unlock(stream->mutex);
		stream->dropped++;
		msg_free(msg);
	}
}

/* Distributed mod_kazoo suppresses internal endpoint/loopback channels at
 * the transport boundary; real endpoint events remain available. */
int reprise_event_is_suppressed(switch_event_t *event)
{
 return switch_true(switch_event_get_header(event, "variable_NO_EVENTS_PLEASE")) ||
        switch_true(switch_event_get_header(event, "NO_EVENTS_PLEASE"));
}

static void event_handler(switch_event_t *event)
{
	reprise_binding_t *binding = (reprise_binding_t *) event->bind_user_data;
	reprise_target_t *t;

	if (!reprise_globals.running || !events.started) return;
	binding->seen++;
	if (reprise_event_is_suppressed(event)) { binding->filtered++; return; }
	for (t = binding->targets; t; t = t->next) {
		publish_target(binding, t, event);
	}
}

/* profile event names that are the closed module's own view of a switch
 * event: CHANNEL_APP_EXECUTE_COMPLETE is CHANNEL_EXECUTE_COMPLETE for an
 * application a call-control command started (Application-UUID set and
 * not "null", Application-UUID-Name carrying the Kazoo app name) --
 * OpenKazoo's config spells the same gate out as filters */
typedef struct {
	const char *profile_name;
	const char *switch_name;
	int (*gate)(switch_event_t *event);
	int rtcp; /* bound only with rtcp-events=true */
} reprise_event_alias_t;

static int gate_app_execute_complete(switch_event_t *event)
{
	const char *app_uuid = switch_event_get_header(event, "Application-UUID");
	return !zstr(app_uuid) && strcmp(app_uuid, "null")
		&& !zstr(switch_event_get_header(event, "Application-UUID-Name"));
}

/* the rtcp profile names the 2600hz fork's RTCP events; stock FreeSWITCH
 * fires SEND_RTCP_MESSAGE / RECV_RTCP_MESSAGE (switch_rtp.c) */
static const reprise_event_alias_t aliases[] = {
	{"CHANNEL_APP_EXECUTE_COMPLETE", "CHANNEL_EXECUTE_COMPLETE", gate_app_execute_complete, 0},
	{"RTCP_SEND_PACKET", "SEND_RTCP_MESSAGE", NULL, 1},
	{"RTCP_RECV_PACKET", "RECV_RTCP_MESSAGE", NULL, 1},
	{NULL, NULL, NULL, 0}
};

static const reprise_event_alias_t *alias_for(const char *name)
{
	const reprise_event_alias_t *a;
	for (a = aliases; a->profile_name; a++) {
		if (!strcasecmp(a->profile_name, name)) return a;
	}
	return NULL;
}

static reprise_binding_t *binding_for(const char *name)
{
	switch_event_types_t type;
	const char *subclass = NULL;
	reprise_binding_t *b;
	const reprise_event_alias_t *alias = alias_for(name);

	if (alias) name = alias->switch_name;
	if (switch_name_event(name, &type) != SWITCH_STATUS_SUCCESS) {
		type = SWITCH_EVENT_CUSTOM;
		subclass = name;
	} else if (type == SWITCH_EVENT_CUSTOM) {
		return NULL; /* "CUSTOM" alone binds everything; not what a profile means */
	}
	for (b = events.bindings; b; b = b->next) {
		if (b->type == type && ((!subclass && !b->subclass) || (subclass && b->subclass && !strcasecmp(subclass, b->subclass)))) {
			return b;
		}
	}
	b = switch_core_alloc(events.pool, sizeof(*b));
	b->type = type;
	b->subclass = subclass ? switch_core_strdup(events.pool, subclass) : NULL;
	switch_uuid_str(b->id, sizeof(b->id));
	if (switch_event_bind_removable(b->id, type, b->subclass ? b->subclass : SWITCH_EVENT_SUBCLASS_ANY,
									event_handler, b, &b->node) != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "cannot bind event %s\n", name);
		return NULL;
	}
	b->next = events.bindings;
	events.bindings = b;
	return b;
}

void reprise_events_start(reprise_config_t *config)
{
	reprise_event_profile_t *profile;
	int n_bindings = 0, n_targets = 0, n_rtcp_skipped = 0;
	reprise_config_t *held;

	/* pin the config before taking the events mutex: reprise_config_hold
	 * takes reprise_globals.mutex, which is never taken under events.mutex */
	held = reprise_config_hold();
	switch_mutex_lock(events.mutex);
	if (events.started) {
		switch_mutex_unlock(events.mutex);
		reprise_config_release(held);
		return;
	}
	events.stopping = 0;
	switch_core_new_memory_pool(&events.pool);
	events.config = held;

	for (profile = config->event_profiles; profile; profile = profile->next) {
		reprise_event_t *ev;
		if (!zstr(profile->amqp_profile) && !stream_find(profile->amqp_profile)) {
			stream_create(profile->amqp_profile, config);
		}
		for (ev = profile->events; ev; ev = ev->next) {
			const reprise_event_alias_t *alias = alias_for(ev->name);
			reprise_binding_t *b;
			reprise_target_t *t;
			/* the served rtcp profile is unconditional, but nothing in
			 * Kazoo consumes the rtcp exchange: every leg would publish an
			 * unread event per report interval. Off unless asked for. */
			if (alias && alias->rtcp && !reprise_globals.rtcp_events) {
				n_rtcp_skipped++;
				continue;
			}
			if (!(b = binding_for(ev->name))) continue;
			t = switch_core_alloc(events.pool, sizeof(*t));
			t->profile = profile;
			t->event = ev;
			t->gate = alias ? alias->gate : NULL;
			t->next = b->targets;
			b->targets = t;
			n_targets++;
		}
	}
	for (n_bindings = 0; ; ) {
		reprise_binding_t *b;
		for (b = events.bindings; b; b = b->next) {
			n_bindings++;
			/* stock switch_rtp fires SEND/RECV_RTCP_MESSAGE only when the
			 * channel variable fire_rtcp_events is true (the 2600hz fork
			 * always does); a global variable covers every channel */
			if (b->type == SWITCH_EVENT_SEND_RTCP_MESSAGE || b->type == SWITCH_EVENT_RECV_RTCP_MESSAGE) {
				switch_core_set_variable("fire_rtcp_events", "true");
			}
		}
		break;
	}
	events.started = 1;
	switch_mutex_unlock(events.mutex);
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE, "event streams: %d switch bindings, %d profile targets\n",
					  n_bindings, n_targets);
	if (n_rtcp_skipped) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE,
						  "rtcp profile: %d events not bound (rtcp-events=false; nothing in Kazoo consumes them)\n", n_rtcp_skipped);
	}
}

/* under events.mutex for its whole duration: a status walk cannot
 * overlap the destruction (the stream threads are joined here, and the
 * core's unbind returns only once no event handler is inside) */
void reprise_events_stop(void)
{
	reprise_binding_t *b;
	reprise_stream_t *s;
	reprise_config_t *config;

	switch_mutex_lock(events.mutex);
	if (!events.started) {
		switch_mutex_unlock(events.mutex);
		return;
	}
	events.started = 0;
	events.stopping = 1;
	for (b = events.bindings; b; b = b->next) {
		if (b->node) switch_event_unbind(&b->node);
	}
	for (s = events.streams; s; s = s->next) {
		if (s->thread) {
			switch_status_t rv;
			switch_thread_join(&rv, s->thread);
		}
		reprise_publisher_destroy(&s->pub);
	}
	config = events.config;
	events.config = NULL;
	events.bindings = NULL;
	events.streams = NULL;
	if (events.pool) switch_core_destroy_memory_pool(&events.pool);
	switch_mutex_unlock(events.mutex);
	reprise_config_release(config); /* reprise_globals.mutex: outside events.mutex */
}

/* called without reprise_globals.mutex held */
void reprise_events_status(switch_stream_handle_t *stream)
{
	reprise_stream_t *s;
	reprise_binding_t *b;

	if (!events.mutex) return;
	switch_mutex_lock(events.mutex);
	if (!events.started) {
		stream->write_function(stream, "events: not started\n");
		switch_mutex_unlock(events.mutex);
		return;
	}
	stream->write_function(stream, "event streams:\n");
	for (s = events.streams; s; s = s->next) {
		switch_size_t bytes;
		switch_mutex_lock(s->mutex);
		bytes = s->queued_bytes;
		switch_mutex_unlock(s->mutex);
		stream->write_function(stream, "  %-12s %-40s queued=%" SWITCH_UINT64_T_FMT " published=%" SWITCH_UINT64_T_FMT
							   " failed=%" SWITCH_UINT64_T_FMT " dropped=%" SWITCH_UINT64_T_FMT " backlog=%" SWITCH_SIZE_T_FMT "B\n",
							   s->name, s->pub->connected_broker ? s->pub->connected_broker : "(idle)",
							   s->queued, s->published, s->failed, s->dropped, bytes);
	}
	stream->write_function(stream, "event bindings (seen/published/filtered):\n");
	for (b = events.bindings; b; b = b->next) {
		if (!b->seen) continue;
		stream->write_function(stream, "  %-32s %" SWITCH_UINT64_T_FMT "/%" SWITCH_UINT64_T_FMT "/%" SWITCH_UINT64_T_FMT "\n",
							   b->subclass ? b->subclass : switch_event_name(b->type), b->seen, b->published, b->filtered);
	}
	switch_mutex_unlock(events.mutex);
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
