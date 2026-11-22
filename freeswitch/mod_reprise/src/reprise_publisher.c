/*
 * reprise_publisher.c -- a publish-only AMQP connection any FreeSWITCH thread
 * can use (fetch requests come from the switch's own threads, events from
 * the stream threads). rabbitmq-c connections are single-threaded, so
 * publishes are serialized by a mutex, and a failed publish reconnects
 * and retries once. The connection logs in with a heartbeat and its
 * owner services it (reprise_publisher_service, a non-blocking frame read a
 * few times per heartbeat): rabbitmq-c only sends and checks heartbeats
 * from its frame-wait loop, and without them a broker that went away
 * behind a load balancer is never noticed -- writes into a dead socket
 * still "succeed" until the kernel gives up, and fetches published in
 * that window are lost (seen in the phase-6 failover test).
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise.h"

#define REPRISE_PUB_CHANNEL 1
#define REPRISE_PUB_HEARTBEAT 10 /* seconds; the broker drops us after two missed */

static void publisher_close(reprise_publisher_t *pub)
{
	if (pub->state) {
		amqp_connection_close(pub->state, AMQP_REPLY_SUCCESS);
		amqp_destroy_connection(pub->state);
		pub->state = NULL;
	}
	pub->connected_broker = NULL;
}

static switch_status_t publisher_open(reprise_publisher_t *pub)
{
	reprise_broker_t *broker;

	for (broker = pub->brokers; broker && reprise_globals.running; broker = broker->next) {
		amqp_connection_state_t state = reprise_amqp_connect(broker, REPRISE_PUB_HEARTBEAT, REPRISE_PUB_CHANNEL, "publisher");

		if (!state) continue;
		pub->state = state;
		pub->connected_broker = switch_core_sprintf(pub->pool, "%s:%u", broker->hostname, broker->port);
		pub->reconnects++;
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE, "publisher connected to %s\n", pub->connected_broker);
		return SWITCH_STATUS_SUCCESS;
	}
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "publisher: no broker reachable\n");
	return SWITCH_STATUS_GENERR;
}

reprise_publisher_t *reprise_publisher_create(reprise_broker_t *brokers)
{
	switch_memory_pool_t *pool = NULL;
	reprise_publisher_t *pub;
	reprise_broker_t *b, **tail;

	switch_core_new_memory_pool(&pool);
	pub = switch_core_alloc(pool, sizeof(*pub));
	pub->pool = pool;
	switch_mutex_init(&pub->mutex, SWITCH_MUTEX_NESTED, pool);

	tail = &pub->brokers;
	for (b = brokers; b; b = b->next) {
		reprise_broker_t *copy = switch_core_alloc(pool, sizeof(*copy));
		copy->hostname = switch_core_strdup(pool, b->hostname);
		copy->virtualhost = switch_core_strdup(pool, b->virtualhost);
		copy->username = switch_core_strdup(pool, b->username);
		copy->password = switch_core_strdup(pool, b->password);
		copy->port = b->port;
		*tail = copy;
		tail = &copy->next;
	}
	return pub;
}

void reprise_publisher_destroy(reprise_publisher_t **pubp)
{
	reprise_publisher_t *pub = pubp ? *pubp : NULL;
	switch_memory_pool_t *pool;

	if (!pub) return;
	switch_mutex_lock(pub->mutex);
	publisher_close(pub);
	switch_mutex_unlock(pub->mutex);
	pool = pub->pool;
	*pubp = NULL;
	switch_core_destroy_memory_pool(&pool);
}

static void add_header(amqp_basic_properties_t *props, amqp_table_entry_t *entries, const char *name, const char *value)
{
	amqp_table_entry_t *entry = &entries[props->headers.num_entries++];
	entry->key = amqp_cstring_bytes(name);
	entry->value.kind = AMQP_FIELD_KIND_UTF8;
	entry->value.value.bytes = amqp_cstring_bytes(value);
	props->_flags |= AMQP_BASIC_HEADERS_FLAG;
	props->headers.entries = entries;
}

static int publish_once(reprise_publisher_t *pub, const char *exchange, const char *routing_key,
						const char *body, const char *header_name, const char *header_value)
{
	amqp_basic_properties_t props;
	amqp_table_entry_t entries[2];
	char pid[128] = "";
	const char *p;

	memset(&props, 0, sizeof(props));
	props._flags = AMQP_BASIC_CONTENT_TYPE_FLAG | AMQP_BASIC_TIMESTAMP_FLAG;
	props.content_type = amqp_cstring_bytes("application/json");
	props.timestamp = (uint64_t) switch_micro_time_now();

	/* pid://<pid>/<queue> -> queue + Deliver-To-PID (kz_amqp_util:basic_routing) */
	if ((p = strstr(routing_key, "pid://"))) {
		const char *pid_start = p + 6;
		const char *slash = strchr(pid_start, '/');
		if (slash && (switch_size_t) (slash - pid_start) < sizeof(pid)) {
			memcpy(pid, pid_start, slash - pid_start);
			pid[slash - pid_start] = '\0';
			routing_key = slash + 1;
			add_header(&props, entries, "Deliver-To-PID", pid);
		}
	}
	if (!zstr(header_name) && !zstr(header_value)) {
		add_header(&props, entries, header_name, header_value);
	}
	return amqp_basic_publish(pub->state, REPRISE_PUB_CHANNEL, amqp_cstring_bytes(exchange),
							  amqp_cstring_bytes(routing_key), 0, 0, &props, amqp_cstring_bytes(body));
}

/* drive heartbeats and notice a dead connection between publishes; called
 * by the owning thread every few hundred ms. Never blocks on the mutex:
 * a publish in progress is servicing the connection itself. */
void reprise_publisher_service(reprise_publisher_t *pub)
{
	amqp_frame_t frame;
	struct timeval now = {0, 0};
	int rc;

	if (!pub || switch_mutex_trylock(pub->mutex) != SWITCH_STATUS_SUCCESS) return;
	if (pub->state) {
		amqp_maybe_release_buffers(pub->state);
		rc = amqp_simple_wait_frame_noblock(pub->state, &frame, &now);
		switch (rc) {
		case AMQP_STATUS_OK:
			if (frame.frame_type == AMQP_FRAME_METHOD && frame.payload.method.id == AMQP_CONNECTION_CLOSE_METHOD) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "publisher: broker %s closed the connection\n",
								  switch_str_nil(pub->connected_broker));
				publisher_close(pub);
			}
			break; /* heartbeats and anything else are consumed */
		case AMQP_STATUS_TIMEOUT:
			break;
		default:
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "publisher: connection to %s lost (%s), will reconnect\n",
							  switch_str_nil(pub->connected_broker), amqp_error_string2(rc));
			publisher_close(pub);
			break;
		}
	}
	switch_mutex_unlock(pub->mutex);
}

switch_status_t reprise_publisher_publish(reprise_publisher_t *pub, const char *exchange, const char *routing_key,
									  cJSON *json, const char *header_name, const char *header_value)
{
	char *body = cJSON_PrintUnformatted(json);
	switch_status_t status;

	if (!body) return SWITCH_STATUS_MEMERR;
	status = reprise_publisher_publish_body(pub, exchange, routing_key, body, header_name, header_value);
	free(body);
	return status;
}

/* wait_us < 0: block for the mutex; else give up after wait_us */
static switch_status_t publish_locked(reprise_publisher_t *pub, const char *exchange, const char *routing_key,
									  const char *body, const char *header_name, const char *header_value,
									  switch_time_t wait_us)
{
	int status = -1, attempt;

	if (wait_us < 0) {
		switch_mutex_lock(pub->mutex);
	} else {
		switch_time_t deadline = switch_micro_time_now() + wait_us;
		while (switch_mutex_trylock(pub->mutex) != SWITCH_STATUS_SUCCESS) {
			if (switch_micro_time_now() >= deadline || !reprise_globals.running) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING,
								  "publisher: busy for %dms (broker %s stalled?); publish to %s [%s] not attempted\n",
								  (int) (wait_us / 1000), switch_str_nil(pub->connected_broker), exchange, routing_key);
				return SWITCH_STATUS_TIMEOUT;
			}
			switch_yield(5000);
		}
	}
	for (attempt = 0; attempt < 2 && reprise_globals.running; attempt++) {
		if (!pub->state && publisher_open(pub) != SWITCH_STATUS_SUCCESS) {
			break;
		}
		if (!(status = publish_once(pub, exchange, routing_key, body, header_name, header_value))) {
			pub->publishes++;
			break;
		}
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "publisher: publish to %s [%s] failed (%s), reconnecting\n",
						  exchange, routing_key, amqp_error_string2(status));
		publisher_close(pub);
	}
	if (status) pub->failures++;
	switch_mutex_unlock(pub->mutex);

	return status ? SWITCH_STATUS_GENERR : SWITCH_STATUS_SUCCESS;
}

switch_status_t reprise_publisher_publish_body(reprise_publisher_t *pub, const char *exchange, const char *routing_key,
										   const char *body, const char *header_name, const char *header_value)
{
	return publish_locked(pub, exchange, routing_key, body, header_name, header_value, -1);
}

switch_status_t reprise_publisher_publish_wait(reprise_publisher_t *pub, const char *exchange, const char *routing_key,
										   cJSON *json, const char *header_name, const char *header_value,
										   switch_time_t wait_us)
{
	char *body = cJSON_PrintUnformatted(json);
	switch_status_t status;

	if (!body) return SWITCH_STATUS_MEMERR;
	status = publish_locked(pub, exchange, routing_key, body, header_name, header_value, wait_us < 0 ? 0 : wait_us);
	free(body);
	return status;
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
