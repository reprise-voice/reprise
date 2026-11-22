/*
 * reprise_transport.c -- the AMQP transport thread: broker connection with
 * failover, the targeted reply queue (Server-ID semantics), and the
 * kazoo.conf fetch RPC. Connection patterns follow FreeSWITCH's in-tree
 * mod_amqp (rabbitmq-c); the wire contract is documented in docs/WIRE.md.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise.h"
#include <sys/socket.h>
#include <netinet/tcp.h>

#define REPRISE_CHANNEL 1

/* the send-side deadline: rabbitmq-c publishes with an infinite deadline
 * (amqp_basic_publish -> amqp_send_frame_inner(..., amqp_time_infinite())),
 * so a peer that stops acknowledging would hold a publisher -- and every
 * thread queued on its mutex -- until the kernel gives up on the
 * connection (minutes). TCP_USER_TIMEOUT (Linux) makes the kernel fail the
 * socket once sent data sits unacknowledged that long; the library then
 * reports a socket error and the owner reconnects. */
static void reprise_socket_deadlines(amqp_connection_state_t state, const char *who)
{
	int fd = amqp_get_sockfd(state);
	if (fd < 0) return;
#ifdef TCP_USER_TIMEOUT
	{
		unsigned int ms = REPRISE_SEND_TIMEOUT_MS;
		if (setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &ms, sizeof(ms))) {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "%s: TCP_USER_TIMEOUT: %s\n", who, strerror(errno));
		}
	}
#else
	(void) who;
#endif
}

amqp_connection_state_t reprise_amqp_connect(reprise_broker_t *broker, int heartbeat, amqp_channel_t channel, const char *who)
{
	amqp_connection_state_t state = amqp_new_connection();
	amqp_socket_t *socket;
	struct timeval connect_tv = {REPRISE_CONNECT_TIMEOUT_MS / 1000, (REPRISE_CONNECT_TIMEOUT_MS % 1000) * 1000};
	struct timeval rpc_tv = {REPRISE_RPC_TIMEOUT_MS / 1000, (REPRISE_RPC_TIMEOUT_MS % 1000) * 1000};
	amqp_rpc_reply_t reply;
	int status;

	if (!state) return NULL;
	if (!(socket = amqp_tcp_socket_new(state))) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_CRIT, "%s: could not create TCP socket\n", who);
		amqp_destroy_connection(state);
		return NULL;
	}
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "%s: trying AMQP broker %s:%u\n", who, broker->hostname, broker->port);
	if ((status = amqp_socket_open_noblock(socket, broker->hostname, (int) broker->port, &connect_tv))) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "%s: broker %s:%u: %s\n",
						  who, broker->hostname, broker->port, amqp_error_string2(status));
		amqp_destroy_connection(state);
		return NULL;
	}
	reprise_socket_deadlines(state, who);
	/* login, channel open and every declare/bind/consume RPC after this */
	amqp_set_rpc_timeout(state, &rpc_tv);

	reply = amqp_login(state, broker->virtualhost, 0, 131072, heartbeat, AMQP_SASL_METHOD_PLAIN,
					   broker->username, broker->password);
	if (reply.reply_type != AMQP_RESPONSE_NORMAL) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "%s: login to %s:%u failed (%s)\n", who, broker->hostname, broker->port,
						  reply.reply_type == AMQP_RESPONSE_LIBRARY_EXCEPTION ? amqp_error_string2(reply.library_error) : "server exception");
		amqp_destroy_connection(state);
		return NULL;
	}
	amqp_channel_open(state, channel);
	reply = amqp_get_rpc_reply(state);
	if (reply.reply_type != AMQP_RESPONSE_NORMAL) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "%s: channel open on %s:%u failed (%s)\n", who, broker->hostname, broker->port,
						  reply.reply_type == AMQP_RESPONSE_LIBRARY_EXCEPTION ? amqp_error_string2(reply.library_error) : "server exception");
		amqp_connection_close(state, AMQP_REPLY_SUCCESS);
		amqp_destroy_connection(state);
		return NULL;
	}
	return state;
}

typedef struct {
	amqp_connection_state_t state;
	reprise_broker_t *broker;         /* the broker we are connected to */
	amqp_bytes_t reply_queue;     /* server-named queue bound to `targeted` */
	char fetch_uuid[SWITCH_UUID_FORMATTED_LENGTH + 1]; /* outstanding config fetch */
} reprise_conn_t;

static int reprise_amqp_error(amqp_rpc_reply_t reply, const char *context)
{
	switch (reply.reply_type) {
	case AMQP_RESPONSE_NORMAL:
		return 0;
	case AMQP_RESPONSE_NONE:
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "%s: missing RPC reply\n", context);
		break;
	case AMQP_RESPONSE_LIBRARY_EXCEPTION:
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "%s: %s\n",
						  context, amqp_error_string2(reply.library_error));
		break;
	case AMQP_RESPONSE_SERVER_EXCEPTION:
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "%s: server exception (method %u)\n",
						  context, reply.reply.id);
		break;
	}
	return 1;
}

static void reprise_conn_close(reprise_conn_t *conn)
{
	if (conn->state) {
		amqp_channel_close(conn->state, REPRISE_CHANNEL, AMQP_REPLY_SUCCESS);
		amqp_connection_close(conn->state, AMQP_REPLY_SUCCESS);
		amqp_destroy_connection(conn->state);
		conn->state = NULL;
	}
	if (conn->reply_queue.bytes) {
		amqp_bytes_free(conn->reply_queue);
		conn->reply_queue.bytes = NULL;
		conn->reply_queue.len = 0;
	}
	conn->broker = NULL;

	switch_mutex_lock(reprise_globals.mutex);
	reprise_globals.phase = REPRISE_DISCONNECTED;
	reprise_globals.connected_broker = NULL;
	switch_mutex_unlock(reprise_globals.mutex);
}

/* walk the broker list until a TCP connect + login succeeds */
static switch_status_t reprise_conn_open(reprise_conn_t *conn)
{
	reprise_broker_t *broker;

	for (broker = reprise_globals.brokers; broker && reprise_globals.running; broker = broker->next) {
		amqp_connection_state_t state = reprise_amqp_connect(broker, (int) broker->heartbeat, REPRISE_CHANNEL, "transport");

		if (!state) continue;

		conn->state = state;
		conn->broker = broker;

		switch_mutex_lock(reprise_globals.mutex);
		reprise_globals.phase = REPRISE_CONNECTED;
		reprise_globals.connected_broker = switch_core_sprintf(reprise_globals.pool, "%s:%u",
														   broker->hostname, broker->port);
		switch_mutex_unlock(reprise_globals.mutex);

		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE, "Connected to AMQP broker %s:%u\n",
						  broker->hostname, broker->port);
		return SWITCH_STATUS_SUCCESS;
	}

	return SWITCH_STATUS_GENERR;
}

/* server-named queue bound to the `targeted` direct exchange by its own
 * name -- this queue name is our Server-ID in every request we publish */
static switch_status_t reprise_reply_queue_setup(reprise_conn_t *conn)
{
	amqp_queue_declare_ok_t *declared;

	declared = amqp_queue_declare(conn->state, REPRISE_CHANNEL,
								  amqp_empty_bytes, /* server-named */
								  0 /* passive */, 0 /* durable */,
								  1 /* exclusive */, 1 /* auto_delete */,
								  amqp_empty_table);
	if (reprise_amqp_error(amqp_get_rpc_reply(conn->state), "reply queue declare")) {
		return SWITCH_STATUS_GENERR;
	}

	conn->reply_queue = amqp_bytes_malloc_dup(declared->queue);
	if (!conn->reply_queue.bytes) {
		return SWITCH_STATUS_MEMERR;
	}

	amqp_queue_bind(conn->state, REPRISE_CHANNEL, conn->reply_queue,
					amqp_cstring_bytes(REPRISE_EXCHANGE_TARGETED), conn->reply_queue,
					amqp_empty_table);
	if (reprise_amqp_error(amqp_get_rpc_reply(conn->state), "reply queue bind")) {
		return SWITCH_STATUS_GENERR;
	}

	amqp_basic_consume(conn->state, REPRISE_CHANNEL, conn->reply_queue,
					   amqp_empty_bytes, 0 /* no_local */, 1 /* no_ack */,
					   0 /* exclusive */, amqp_empty_table);
	if (reprise_amqp_error(amqp_get_rpc_reply(conn->state), "reply queue consume")) {
		return SWITCH_STATUS_GENERR;
	}

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "Reply queue %.*s bound to %s\n",
					  (int) conn->reply_queue.len, (char *) conn->reply_queue.bytes,
					  REPRISE_EXCHANGE_TARGETED);
	return SWITCH_STATUS_SUCCESS;
}

switch_status_t reprise_amqp_publish_json(amqp_connection_state_t state, amqp_channel_t channel,
									  const char *exchange, const char *routing_key, cJSON *json)
{
	amqp_basic_properties_t props;
	char *body = cJSON_PrintUnformatted(json);
	int status;

	if (!body) {
		return SWITCH_STATUS_MEMERR;
	}

	memset(&props, 0, sizeof(props));
	props._flags = AMQP_BASIC_CONTENT_TYPE_FLAG | AMQP_BASIC_TIMESTAMP_FLAG;
	props.content_type = amqp_cstring_bytes("application/json");
	props.timestamp = (uint64_t) switch_micro_time_now();

	status = amqp_basic_publish(state, channel,
								amqp_cstring_bytes(exchange),
								amqp_cstring_bytes(routing_key),
								0 /* mandatory */, 0 /* immediate */,
								&props, amqp_cstring_bytes(body));
	free(body);

	if (status) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "Publish to %s [%s]: %s\n",
						  exchange, routing_key, amqp_error_string2(status));
		return SWITCH_STATUS_GENERR;
	}
	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t reprise_publish_json(reprise_conn_t *conn, const char *exchange,
										const char *routing_key, cJSON *json)
{
	return reprise_amqp_publish_json(conn->state, REPRISE_CHANNEL, exchange, routing_key, json);
}

/* fetch our own kazoo.conf over AMQP: publish a configuration fetch for
 * com.kazoo.conf; the reply arrives on the targeted reply queue as
 * text/xml with message_id echoing Fetch-UUID */
static switch_status_t reprise_config_fetch_request(reprise_conn_t *conn)
{
	cJSON *json = cJSON_CreateObject();
	char routing_key[512];
	char server_id[512] = "";
	switch_status_t status;

	switch_copy_string(server_id, conn->reply_queue.bytes,
					   conn->reply_queue.len >= sizeof(server_id) ? sizeof(server_id) : conn->reply_queue.len + 1);

	switch_uuid_str(conn->fetch_uuid, sizeof(conn->fetch_uuid));
	switch_snprintf(routing_key, sizeof(routing_key), "%s.configuration.fetch.%s.%s",
					REPRISE_EXCHANGE_FREESWITCH, reprise_globals.core_uuid, conn->fetch_uuid);

	cJSON_AddStringToObject(json, "Event-Category", "fetch");
	cJSON_AddStringToObject(json, "Event-Name", "GENERAL");
	cJSON_AddStringToObject(json, "Fetch-Section", "configuration");
	cJSON_AddStringToObject(json, "Fetch-Tag", "configuration");
	cJSON_AddStringToObject(json, "Fetch-Version", "commercial");
	cJSON_AddStringToObject(json, "Fetch-Key-Name", "name");
	cJSON_AddStringToObject(json, "Fetch-Key-Value", "com.kazoo.conf");
	cJSON_AddStringToObject(json, "Fetch-UUID", conn->fetch_uuid);
	cJSON_AddNumberToObject(json, "Fetch-Timeout", (double) reprise_globals.fetch_timeout_ms);
	cJSON_AddNumberToObject(json, "Fetch-Timestamp-Micro", (double) switch_micro_time_now());
	cJSON_AddStringToObject(json, "Core-UUID", reprise_globals.core_uuid);
	cJSON_AddStringToObject(json, "Node", reprise_globals.node_name);
	cJSON_AddStringToObject(json, "Server-ID", server_id);
	cJSON_AddStringToObject(json, "Msg-ID", conn->fetch_uuid);
	cJSON_AddStringToObject(json, "App-Name", REPRISE_APP_NAME);
	cJSON_AddStringToObject(json, "App-Version", REPRISE_APP_VERSION);

	status = reprise_publish_json(conn, REPRISE_EXCHANGE_FREESWITCH, routing_key, json);
	cJSON_Delete(json);

	if (status == SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO,
						  "Requested kazoo.conf (fetch %s)\n", conn->fetch_uuid);
	}
	return status;
}

static void reprise_config_fetch_reply(reprise_conn_t *conn, amqp_envelope_t *envelope)
{
	char *body;
	reprise_config_t *config, *old_config;
	int changed, first;

	if (envelope->message.body.len > REPRISE_MAX_CONFIG_BYTES) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
						  "kazoo.conf reply of %" SWITCH_SIZE_T_FMT " bytes exceeds the %d byte cap; ignored\n",
						  (switch_size_t) envelope->message.body.len, REPRISE_MAX_CONFIG_BYTES);
		conn->fetch_uuid[0] = '\0';
		return;
	}
	/* the fetch is answered whatever we make of the reply: leaving
	 * fetch_uuid set would gate every later refetch (`config`, the CLI)
	 * off until the connection happens to drop */
	conn->fetch_uuid[0] = '\0';
	if (!(body = malloc(envelope->message.body.len + 1))) {
		return;
	}
	memcpy(body, envelope->message.body.bytes, envelope->message.body.len);
	body[envelope->message.body.len] = '\0';

	if (!(config = reprise_config_parse(body))) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
						  "kazoo.conf reply rejected (%" SWITCH_SIZE_T_FMT " bytes); `reprise refetch` asks again\n",
						  (switch_size_t) envelope->message.body.len);
		free(body);
		return;
	}

	switch_mutex_lock(reprise_globals.mutex);
	changed = !reprise_globals.kazoo_config
		|| reprise_globals.kazoo_config_len != envelope->message.body.len
		|| memcmp(reprise_globals.kazoo_config, body, envelope->message.body.len);
	switch_safe_free(reprise_globals.kazoo_config);
	reprise_globals.kazoo_config = body; /* ownership moves to globals */
	reprise_globals.kazoo_config_len = envelope->message.body.len;
	old_config = reprise_globals.config;
	first = !old_config;
	reprise_globals.config = config;
	reprise_globals.config_fetches++;
	if (changed && old_config) reprise_globals.config_changes++;
	reprise_globals.phase = REPRISE_CONFIGURED;
	switch_mutex_unlock(reprise_globals.mutex);

	/* the CLI copies under the mutex and workers snapshot at start; the
	 * fetch handler pins the config it renders with, so a replaced config
	 * lives until its last holder releases it */
	if (old_config) {
		switch_mutex_lock(reprise_globals.mutex);
		old_config->retired = 1;
		if (!old_config->refs) {
			reprise_config_destroy(&old_config);
		}
		switch_mutex_unlock(reprise_globals.mutex);
	}
	conn->fetch_uuid[0] = '\0';

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE,
					  "kazoo.conf fetched over AMQP (%" SWITCH_SIZE_T_FMT " bytes%s)\n",
					  reprise_globals.kazoo_config_len,
					  first ? "" : changed ? ", changed" : ", unchanged");

	/* first document: bring everything up. A later one (the `config`
	 * command, a transport reconnect) only matters when it differs: the
	 * workers, publisher, fetch binding and event streams all hold
	 * snapshots of the document they started from. Only this thread
	 * starts or restarts them; unload joins this thread before it tears
	 * anything down, so the check below is the whole admission control. */
	if (!reprise_globals.running) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE, "kazoo.conf fetched during unload; not applied\n");
	} else if (!reprise_globals.workers_started) {
		reprise_config_apply_variables(config);
		reprise_workers_start();
	} else if (changed) {
		reprise_config_apply_variables(config);
		reprise_workers_restart();
	}
}

void reprise_config_refetch(void)
{
	reprise_globals.refetch_requested = 1;
}

reprise_config_t *reprise_config_hold(void)
{
	reprise_config_t *config;

	switch_mutex_lock(reprise_globals.mutex);
	if ((config = reprise_globals.config)) {
		config->refs++;
	}
	switch_mutex_unlock(reprise_globals.mutex);
	return config;
}

void reprise_config_release(reprise_config_t *config)
{
	if (!config) return;
	switch_mutex_lock(reprise_globals.mutex);
	if (--config->refs <= 0 && config->retired) {
		reprise_config_destroy(&config);
	}
	switch_mutex_unlock(reprise_globals.mutex);
}

static void reprise_handle_delivery(reprise_conn_t *conn, amqp_envelope_t *envelope)
{
	if (conn->fetch_uuid[0]
		&& (envelope->message.properties._flags & AMQP_BASIC_MESSAGE_ID_FLAG)
		&& envelope->message.properties.message_id.len == strlen(conn->fetch_uuid)
		&& !memcmp(envelope->message.properties.message_id.bytes, conn->fetch_uuid,
				   envelope->message.properties.message_id.len)) {
		reprise_config_fetch_reply(conn, envelope);
		return;
	}

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG,
					  "Unhandled delivery on %.*s (%" SWITCH_SIZE_T_FMT " bytes)\n",
					  (int) envelope->routing_key.len, (char *) envelope->routing_key.bytes,
					  (switch_size_t) envelope->message.body.len);
}

/* returns 0 to keep consuming on this connection, 1 to tear down */
static int reprise_consume_once(reprise_conn_t *conn)
{
	amqp_envelope_t envelope;
	amqp_rpc_reply_t res;
	struct timeval timeout = {0, 500 * 1000};

	amqp_maybe_release_buffers(conn->state);
	res = amqp_consume_message(conn->state, &envelope, &timeout, 0);

	if (res.reply_type == AMQP_RESPONSE_LIBRARY_EXCEPTION) {
		switch (res.library_error) {
		case AMQP_STATUS_TIMEOUT:
			return 0;
		case AMQP_STATUS_UNEXPECTED_STATE: {
			/* a non-delivery frame (channel/connection close): read it
			 * off with a bound, never block on a peer that stalls here */
			amqp_frame_t frame;
			struct timeval wait = {0, 500 * 1000};
			if (amqp_simple_wait_frame_noblock(conn->state, &frame, &wait) == AMQP_STATUS_OK
				&& frame.frame_type == AMQP_FRAME_METHOD
				&& (frame.payload.method.id == AMQP_CONNECTION_CLOSE_METHOD || frame.payload.method.id == AMQP_CHANNEL_CLOSE_METHOD)) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "AMQP broker closed the %s, reconnecting\n",
								  frame.payload.method.id == AMQP_CONNECTION_CLOSE_METHOD ? "connection" : "channel");
				return 1;
			}
			return 0;
		}
		case AMQP_STATUS_SOCKET_ERROR:
		case AMQP_STATUS_CONNECTION_CLOSED:
		case AMQP_STATUS_TCP_ERROR:
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
							  "AMQP connection lost (%s), reconnecting\n",
							  amqp_error_string2(res.library_error));
			return 1;
		default:
			return 0;
		}
	}

	if (res.reply_type != AMQP_RESPONSE_NORMAL) {
		return 1;
	}

	reprise_handle_delivery(conn, &envelope);
	amqp_destroy_envelope(&envelope);
	return 0;
}

static void *SWITCH_THREAD_FUNC reprise_transport_thread(switch_thread_t *thread, void *data)
{
	reprise_conn_t conn = {0};

	switch_atomic_inc(&reprise_globals.threads);

	while (reprise_globals.running) {
		if (!conn.state) {
			if (reprise_conn_open(&conn) != SWITCH_STATUS_SUCCESS
				|| reprise_reply_queue_setup(&conn) != SWITCH_STATUS_SUCCESS
				|| reprise_config_fetch_request(&conn) != SWITCH_STATUS_SUCCESS) {
				reprise_conn_close(&conn);
				switch_mutex_lock(reprise_globals.mutex);
				reprise_globals.reconnects++;
				switch_mutex_unlock(reprise_globals.mutex);
				switch_sleep(reprise_globals.reconnect_interval_ms * 1000);
				continue;
			}
		}

		if (reprise_consume_once(&conn)) {
			reprise_conn_close(&conn);
			switch_mutex_lock(reprise_globals.mutex);
			reprise_globals.reconnects++;
			switch_mutex_unlock(reprise_globals.mutex);
			switch_sleep(reprise_globals.reconnect_interval_ms * 1000);
			continue;
		}
		/* the switch-thread publisher has no thread of its own: its
		 * heartbeats ride on this loop (500 ms consume timeout) */
		reprise_publisher_service(reprise_globals.publisher);
		/* a refetch asked for while a fetch is outstanding waits for it;
		 * a reconnect fetches anyway */
		if (reprise_globals.refetch_requested && conn.state && !conn.fetch_uuid[0]) {
			reprise_globals.refetch_requested = 0;
			if (reprise_config_fetch_request(&conn) != SWITCH_STATUS_SUCCESS) {
				reprise_globals.refetch_requested = 1;
			}
		}
	}

	reprise_conn_close(&conn);
	switch_atomic_dec(&reprise_globals.threads);
	return NULL;
}

switch_status_t reprise_transport_start(void)
{
	switch_threadattr_t *thd_attr = NULL;

	switch_threadattr_create(&thd_attr, reprise_globals.pool);
	switch_threadattr_stacksize_set(thd_attr, SWITCH_THREAD_STACKSIZE);

	if (switch_thread_create(&reprise_globals.transport_thread, thd_attr,
							 reprise_transport_thread, NULL, reprise_globals.pool) != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "Failed to start transport thread\n");
		return SWITCH_STATUS_GENERR;
	}
	return SWITCH_STATUS_SUCCESS;
}

/* joins the transport thread. It leaves its loop within a consume
 * timeout (500 ms), a reconnect sleep, or the connect/RPC deadlines of a
 * broker attempt; a restart it is in the middle of completes first. */
void reprise_transport_stop(void)
{
	if (reprise_globals.transport_thread) {
		switch_status_t rv;
		switch_thread_join(&rv, reprise_globals.transport_thread);
		reprise_globals.transport_thread = NULL;
	}
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
