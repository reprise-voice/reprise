/*
 * reprise_workers.c -- per-profile AMQP consumers. Every queue-bearing profile
 * in the fetched kazoo.conf (commands, fetch, nodes, cache, dialog,
 * live-event) gets its own connection, declared exchanges, queue and
 * bindings, and a consume loop with reconnect: one worker and one channel
 * per profile. Deliveries are dispatched by profile name: nodes ->
 * advertise/heartbeat publishing (reprise_node.c), commands -> the
 * api/bgapi/json_api responder (reprise_commands.c), fetch -> the fetch
 * replies (reprise_fetch.c); the rest are counted and logged.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise.h"

/* expand worker-scoped template parts on top of the base expansion; with a
 * single worker per profile the erlang-pid-styled parts become fixed ids */
static void expand_worker_template(const char *tpl, const char *profile_name,
								   char *buf, switch_size_t buflen)
{
	char base[512];
	const char *in;
	switch_size_t used = 0;

	reprise_expand_template(tpl, profile_name, base, sizeof(base));

	for (in = base; *in && used + 1 < buflen;) {
		const char *repl = NULL;
		if (!strncmp(in, "${AMQP-Worker-PID}", 18)) {
			repl = "1";
			in += 18;
		} else if (!strncmp(in, "${AMQP-Channel-ID}", 18)) {
			repl = "1";
			in += 18;
		} else {
			buf[used++] = *in++;
			continue;
		}
		while (*repl && used + 1 < buflen) {
			buf[used++] = *repl++;
		}
	}
	buf[used] = '\0';
}

static char *wdup(switch_memory_pool_t *pool, const char *s)
{
	return s ? switch_core_strdup(pool, s) : NULL;
}

static int brokers_have(reprise_broker_t *list, const char *hostname, unsigned int port)
{
	for (; list; list = list->next) {
		if (list->port == port && !strcasecmp(list->hostname, hostname)) return 1;
	}
	return 0;
}

/* broker list into pool, in failover order: the bootstrap connections
 * first (com.kazoo.conf: the addresses the operator gave THIS media
 * server, which got us the config and are known reachable from here),
 * then the kazoo.conf connections not already listed -- local zone
 * first, then the rest. The fetched document carries ecallmgr's own view
 * of its brokers (often names that resolve only inside ecallmgr's own
 * network), which a media server elsewhere cannot resolve; they are
 * extra failover candidates, never the primary. */
reprise_broker_t *reprise_brokers_snapshot(switch_memory_pool_t *pool, reprise_config_t *config)
{
	reprise_broker_t *head = NULL, **tail = &head;
	reprise_broker_t *boot, *local_tail = NULL;
	reprise_conf_broker_t *cb;

	for (boot = reprise_globals.brokers; boot; boot = boot->next) {
		reprise_broker_t *copy = switch_core_alloc(pool, sizeof(*copy));
		*copy = *boot;
		copy->hostname = wdup(pool, boot->hostname);
		copy->virtualhost = wdup(pool, boot->virtualhost);
		copy->username = wdup(pool, boot->username);
		copy->password = wdup(pool, boot->password);
		copy->next = NULL;
		*tail = copy;
		tail = &copy->next;
	}
	local_tail = NULL; /* fetched local-zone brokers go right after the bootstrap ones */
	for (cb = config ? config->brokers : NULL; cb; cb = cb->next) {
		reprise_broker_t *copy;
		if (brokers_have(head, cb->hostname, cb->port)) continue;
		copy = switch_core_alloc(pool, sizeof(*copy));
		copy->hostname = wdup(pool, cb->hostname);
		copy->virtualhost = wdup(pool, cb->virtualhost);
		copy->username = wdup(pool, cb->username);
		copy->password = wdup(pool, cb->password);
		copy->port = cb->port;
		copy->heartbeat = 30;
		if (cb->is_local) {
			reprise_broker_t **at = local_tail ? &local_tail->next : tail;
			copy->next = *at;
			*at = copy;
			local_tail = copy;
			if (!copy->next) tail = &copy->next;
		} else {
			*tail = copy;
			tail = &copy->next;
		}
	}
	return head;
}

/* the worker list is walked under the global mutex: a restart unlinks
 * and frees it while fetches may still be looking their worker up, so
 * the name is copied out rather than borrowed from the worker's pool */
switch_bool_t reprise_worker_queue_name(const char *profile_name, char *buf, switch_size_t buflen)
{
	reprise_worker_t *worker;
	switch_bool_t found = SWITCH_FALSE;
	switch_mutex_lock(reprise_globals.mutex);
	for (worker = reprise_globals.workers; worker; worker = worker->next) {
		if (!strcmp(worker->name, profile_name)) {
			switch_copy_string(buf, worker->queue_name, buflen);
			found = SWITCH_TRUE;
			break;
		}
	}
	switch_mutex_unlock(reprise_globals.mutex);
	return found;
}

uint32_t reprise_worker_reconnects(const char *profile_name)
{
	reprise_worker_t *worker;
	uint32_t reconnects = 0;
	switch_mutex_lock(reprise_globals.mutex);
	for (worker = reprise_globals.workers; worker; worker = worker->next) {
		if (!strcmp(worker->name, profile_name)) {
			reconnects = worker->reconnects;
			break;
		}
	}
	switch_mutex_unlock(reprise_globals.mutex);
	return reconnects;
}

/* deep-copy the pieces of a parsed profile the worker needs, with all
 * templates expanded, into the worker's own pool */
static reprise_worker_t *worker_snapshot(reprise_amqp_profile_t *profile, reprise_config_t *config)
{
	switch_memory_pool_t *pool = NULL;
	reprise_worker_t *worker;
	reprise_exchange_t *ex, **ex_tail;
	reprise_qbinding_t *b, **b_tail;
	char expanded[512];

	switch_core_new_memory_pool(&pool);
	worker = switch_core_alloc(pool, sizeof(*worker));
	worker->pool = pool;
	worker->name = wdup(pool, profile->name);
	worker->zone = wdup(pool, (config && !zstr(config->local_zone)) ? config->local_zone : "local");

	ex_tail = &worker->exchanges;
	for (ex = profile->exchanges; ex; ex = ex->next) {
		reprise_exchange_t *copy = switch_core_alloc(pool, sizeof(*copy));
		copy->name = wdup(pool, ex->name);
		copy->type = wdup(pool, ex->type);
		copy->durable = ex->durable;
		copy->auto_delete = ex->auto_delete;
		*ex_tail = copy;
		ex_tail = &copy->next;
	}

	expand_worker_template(profile->queue.name, profile->name, expanded, sizeof(expanded));
	worker->queue_name = wdup(pool, expanded);
	worker->exclusive = profile->queue.exclusive;
	worker->consume_exclusive = profile->queue.consume_exclusive;
	worker->consume_qos = profile->queue.consume_qos;

	b_tail = &worker->bindings;
	for (b = profile->queue.bindings; b; b = b->next) {
		reprise_qbinding_t *copy = switch_core_alloc(pool, sizeof(*copy));
		copy->exchange = wdup(pool, b->exchange);
		expand_worker_template(b->routing_key, profile->name, expanded, sizeof(expanded));
		copy->routing_key = wdup(pool, expanded);
		copy->federated = b->federated;
		*b_tail = copy;
		b_tail = &copy->next;
	}

	worker->brokers = reprise_brokers_snapshot(pool, config);

	return worker;
}

static int worker_amqp_error(reprise_worker_t *worker, amqp_rpc_reply_t reply, const char *context)
{
	if (reply.reply_type == AMQP_RESPONSE_NORMAL) return 0;

	if (reply.reply_type == AMQP_RESPONSE_LIBRARY_EXCEPTION) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "worker[%s] %s: %s\n",
						  worker->name, context, amqp_error_string2(reply.library_error));
	} else {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "worker[%s] %s: server exception\n",
						  worker->name, context);
	}
	return 1;
}

static amqp_connection_state_t worker_connect(reprise_worker_t *worker)
{
	reprise_broker_t *broker;
	char who[64];

	switch_snprintf(who, sizeof(who), "worker[%s]", worker->name);
	for (broker = worker->brokers; broker && reprise_globals.running && !worker->stop; broker = broker->next) {
		amqp_connection_state_t state = reprise_amqp_connect(broker, (int) broker->heartbeat, REPRISE_WORKER_CHANNEL, who);

		if (!state) continue;
		worker->connected_broker = switch_core_sprintf(worker->pool, "%s:%u",
													   broker->hostname, broker->port);
		return state;
	}
	return NULL;
}

static switch_status_t worker_setup(reprise_worker_t *worker, amqp_connection_state_t state)
{
	reprise_exchange_t *ex;
	reprise_qbinding_t *b;
	amqp_bytes_t queue = amqp_cstring_bytes(worker->queue_name);

	for (ex = worker->exchanges; ex; ex = ex->next) {
		amqp_exchange_declare(state, REPRISE_WORKER_CHANNEL,
							  amqp_cstring_bytes(ex->name), amqp_cstring_bytes(ex->type),
							  0 /* passive */, ex->durable, ex->auto_delete,
							  0 /* internal */, amqp_empty_table);
		if (worker_amqp_error(worker, amqp_get_rpc_reply(state), "exchange declare")) {
			return SWITCH_STATUS_GENERR;
		}
	}

	/* auto_delete: the XML doesn't say; queue names embed the per-boot
	 * Core-UUID, so undeleted queues would accumulate on the broker after
	 * every switch restart. Self-cleaning until proven wrong. */
	amqp_queue_declare(state, REPRISE_WORKER_CHANNEL, queue,
					   0 /* passive */, 0 /* durable */,
					   worker->exclusive, 1 /* auto_delete */,
					   amqp_empty_table);
	if (worker_amqp_error(worker, amqp_get_rpc_reply(state), "queue declare")) {
		return SWITCH_STATUS_GENERR;
	}

	for (b = worker->bindings; b; b = b->next) {
		amqp_queue_bind(state, REPRISE_WORKER_CHANNEL, queue,
						amqp_cstring_bytes(b->exchange), amqp_cstring_bytes(b->routing_key),
						amqp_empty_table);
		if (worker_amqp_error(worker, amqp_get_rpc_reply(state), "queue bind")) {
			return SWITCH_STATUS_GENERR;
		}
	}

	if (worker->consume_qos > 0) {
		amqp_basic_qos(state, REPRISE_WORKER_CHANNEL, 0, (uint16_t) worker->consume_qos, 0);
		if (worker_amqp_error(worker, amqp_get_rpc_reply(state), "qos")) {
			return SWITCH_STATUS_GENERR;
		}
	}

	amqp_basic_consume(state, REPRISE_WORKER_CHANNEL, queue, amqp_empty_bytes,
					   0 /* no_local */, 1 /* no_ack */,
					   worker->consume_exclusive, amqp_empty_table);
	if (worker_amqp_error(worker, amqp_get_rpc_reply(state), "consume")) {
		return SWITCH_STATUS_GENERR;
	}

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE,
					  "worker[%s] consuming %s on %s\n",
					  worker->name, worker->queue_name, worker->connected_broker);
	return SWITCH_STATUS_SUCCESS;
}

static void worker_dispatch(reprise_worker_t *worker, amqp_connection_state_t state, amqp_envelope_t *envelope)
{
	worker->deliveries++;

	if (!strcmp(worker->name, "commands")) {
		reprise_commands_dispatch(worker, state, envelope);
		return;
	}
	if (!strcmp(worker->name, "nodes")) {
		reprise_nodes_dispatch(worker, envelope);
		return;
	}
	if (!strcmp(worker->name, "fetch")) {
		reprise_fetch_dispatch(worker, envelope);
		return;
	}

	/* cache / dialog / live-event: count + log */
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO,
					  "worker[%s] delivery %" SWITCH_UINT64_T_FMT " on %.*s (%" SWITCH_SIZE_T_FMT " bytes)\n",
					  worker->name, worker->deliveries,
					  (int) envelope->routing_key.len, (char *) envelope->routing_key.bytes,
					  (switch_size_t) envelope->message.body.len);
}

/* periodic work on the worker's own connection, between deliveries (the
 * consume timeout bounds the latency at 500ms) */
static void worker_tick(reprise_worker_t *worker, amqp_connection_state_t state)
{
	if (!strcmp(worker->name, "nodes")) {
		reprise_nodes_tick(worker, state);
	} else if (!strcmp(worker->name, "commands")) {
		reprise_commands_tick(worker, state);
	}
}

/* returns 0 to continue, 1 to tear down and reconnect */
static int worker_consume_once(reprise_worker_t *worker, amqp_connection_state_t state)
{
	amqp_envelope_t envelope;
	amqp_rpc_reply_t res;
	struct timeval timeout = {0, 500 * 1000};

	amqp_maybe_release_buffers(state);
	res = amqp_consume_message(state, &envelope, &timeout, 0);

	if (res.reply_type == AMQP_RESPONSE_LIBRARY_EXCEPTION) {
		switch (res.library_error) {
		case AMQP_STATUS_TIMEOUT:
			return 0;
		case AMQP_STATUS_UNEXPECTED_STATE: {
			/* a non-delivery frame (channel/connection close): read it
			 * off with a bound, never block on a peer that stalls here */
			amqp_frame_t frame;
			struct timeval wait = {0, 500 * 1000};
			if (amqp_simple_wait_frame_noblock(state, &frame, &wait) == AMQP_STATUS_OK
				&& frame.frame_type == AMQP_FRAME_METHOD
				&& (frame.payload.method.id == AMQP_CONNECTION_CLOSE_METHOD || frame.payload.method.id == AMQP_CHANNEL_CLOSE_METHOD)) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "worker[%s] broker closed the %s\n", worker->name,
								  frame.payload.method.id == AMQP_CONNECTION_CLOSE_METHOD ? "connection" : "channel");
				return 1;
			}
			return 0;
		}
		case AMQP_STATUS_SOCKET_ERROR:
		case AMQP_STATUS_CONNECTION_CLOSED:
		case AMQP_STATUS_TCP_ERROR:
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
							  "worker[%s] connection lost (%s)\n",
							  worker->name, amqp_error_string2(res.library_error));
			return 1;
		default:
			return 0;
		}
	}
	if (res.reply_type != AMQP_RESPONSE_NORMAL) {
		return 1;
	}

	worker_dispatch(worker, state, &envelope);
	amqp_destroy_envelope(&envelope);
	return 0;
}

static void *SWITCH_THREAD_FUNC worker_thread(switch_thread_t *thread, void *data)
{
	reprise_worker_t *worker = (reprise_worker_t *) data;
	amqp_connection_state_t state = NULL;

	switch_atomic_inc(&reprise_globals.threads);

	while (reprise_globals.running && !worker->stop) {
		if (!state) {
			if (!(state = worker_connect(worker))
				|| worker_setup(worker, state) != SWITCH_STATUS_SUCCESS) {
				if (state) {
					amqp_channel_close(state, REPRISE_WORKER_CHANNEL, AMQP_REPLY_SUCCESS);
					amqp_connection_close(state, AMQP_REPLY_SUCCESS);
					amqp_destroy_connection(state);
					state = NULL;
				}
				worker->consuming = 0;
				worker->reconnects++;
				if (!reprise_globals.running || worker->stop) break;
				switch_sleep(reprise_globals.reconnect_interval_ms * 1000);
				continue;
			}
			worker->consuming = 1;
			worker->last_advertise = 0; /* announce right away on (re)connect */
		}

		if (worker_consume_once(worker, state)) {
			amqp_destroy_connection(state);
			state = NULL;
			worker->consuming = 0;
			worker->reconnects++;
			if (!reprise_globals.running || worker->stop) break;
			switch_sleep(reprise_globals.reconnect_interval_ms * 1000);
			continue;
		}
		worker_tick(worker, state);
	}

	if (state) {
		amqp_channel_close(state, REPRISE_WORKER_CHANNEL, AMQP_REPLY_SUCCESS);
		amqp_connection_close(state, AMQP_REPLY_SUCCESS);
		amqp_destroy_connection(state);
	}
	worker->consuming = 0;
	switch_atomic_dec(&reprise_globals.threads);
	return NULL;
}

void reprise_workers_start(void)
{
	reprise_amqp_profile_t *profile;
	int started = 0;

	switch_mutex_lock(reprise_globals.mutex);
	if (reprise_globals.workers_started || !reprise_globals.config) {
		switch_mutex_unlock(reprise_globals.mutex);
		if (reprise_globals.workers_started) {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO,
							  "config refetched; workers keep their snapshot (restart not yet implemented)\n");
		}
		return;
	}

	for (profile = reprise_globals.config->amqp_profiles; profile; profile = profile->next) {
		reprise_worker_t *worker;
		switch_threadattr_t *thd_attr = NULL;

		if (zstr(profile->queue.name)) {
			continue; /* publisher-only profile: nothing to consume */
		}

		worker = worker_snapshot(profile, reprise_globals.config);
		switch_threadattr_create(&thd_attr, worker->pool);
		switch_threadattr_stacksize_set(thd_attr, SWITCH_THREAD_STACKSIZE);
		if (switch_thread_create(&worker->thread, thd_attr, worker_thread,
								 worker, worker->pool) != SWITCH_STATUS_SUCCESS) {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
							  "worker[%s] failed to start thread\n", worker->name);
			continue;
		}

		worker->next = reprise_globals.workers;
		reprise_globals.workers = worker;
		started++;
	}
	reprise_globals.workers_started = 1;
	if (!reprise_globals.publisher) {
		switch_memory_pool_t *tmp = NULL;
		switch_core_new_memory_pool(&tmp);
		reprise_globals.publisher = reprise_publisher_create(reprise_brokers_snapshot(tmp, reprise_globals.config));
		switch_core_destroy_memory_pool(&tmp);
	}
	reprise_fetch_start(reprise_globals.config);
	reprise_events_start(reprise_globals.config);
	switch_mutex_unlock(reprise_globals.mutex);

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE,
					  "started %d profile workers\n", started);
}

void reprise_workers_stop(void)
{
	reprise_worker_t *worker, *list;

	/* shutdown has reprise_globals.running at 0 already; a restart leaves it
	 * on and stops the workers one by one */
	for (worker = reprise_globals.workers; worker; worker = worker->next) {
		worker->stop = 1;
	}
	for (worker = reprise_globals.workers; worker; worker = worker->next) {
		if (worker->thread) {
			switch_status_t rv;
			switch_thread_join(&rv, worker->thread);
			worker->thread = NULL;
		}
		/* running bgapi jobs do not touch the worker: their results wait
		 * in reprise_commands' queue for the next commands worker */
	}

	switch_mutex_lock(reprise_globals.mutex);
	list = reprise_globals.workers;
	reprise_globals.workers = NULL;
	reprise_globals.workers_started = 0;
	switch_mutex_unlock(reprise_globals.mutex);

	while ((worker = list)) {
		switch_memory_pool_t *pool = worker->pool;
		list = worker->next;
		switch_core_destroy_memory_pool(&pool);
	}
}

/* a changed kazoo.conf: everything built from the old snapshot goes and
 * comes back from the new one. Fetches in flight give up (their reply
 * queue is about to vanish anyway), events fired during the switch-over
 * are not published, the advertise pauses well inside kz_nodes' expiry,
 * and commands ecallmgr publishes while the commands queue is being
 * re-declared are unroutable (it retries on timeout). The only other
 * user of the publisher is the fetch handler, and reprise_fetch_stop's
 * unbind returns only once every handler in flight has left (the core
 * holds its binding rwlock across the search function), so the
 * publisher can go once that returns; the swap is under the mutex for
 * the CLI's sake. */
void reprise_workers_restart(void)
{
	reprise_publisher_t *pub;

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE,
					  "kazoo.conf changed: restarting workers, publisher, fetch and event streams\n");
	reprise_fetch_stop();
	reprise_events_stop();
	reprise_workers_stop();
	switch_mutex_lock(reprise_globals.mutex);
	pub = reprise_globals.publisher;
	reprise_globals.publisher = NULL;
	switch_mutex_unlock(reprise_globals.mutex);
	reprise_publisher_destroy(&pub);
	reprise_globals.worker_restarts++;
	reprise_workers_start();
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
