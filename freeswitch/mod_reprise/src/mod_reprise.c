/*
 * mod_reprise -- AMQP transport between FreeSWITCH and Kazoo's
 * ecallmgr_extension.
 *
 * Module entry: bootstrap config (reprise.conf), the transport thread
 * (broker failover + kazoo.conf fetch), per-profile workers, and the
 * `reprise` CLI. The node advertises itself to kz_nodes and answers
 * ecallmgr's command stream.
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

reprise_globals_t reprise_globals = {0};

SWITCH_MODULE_LOAD_FUNCTION(mod_reprise_load);
SWITCH_MODULE_SHUTDOWN_FUNCTION(mod_reprise_shutdown);
SWITCH_MODULE_DEFINITION(mod_reprise, mod_reprise_load, mod_reprise_shutdown, NULL);

/* <property name="primary" value="true"/> on a bootstrap connection */
static int reprise_connection_is_primary(switch_xml_t xml)
{
	switch_xml_t prop;
	for (prop = switch_xml_child(xml, "property"); prop; prop = prop->next) {
		if (!strcmp(switch_xml_attr_soft(prop, "name"), "primary")) {
			return switch_true(switch_xml_attr_soft(prop, "value"));
		}
	}
	return 0;
}

static switch_status_t reprise_load_broker(switch_xml_t xml, switch_memory_pool_t *pool, reprise_broker_t **out)
{
	switch_xml_t param;
	reprise_broker_t *broker = switch_core_alloc(pool, sizeof(*broker));

	broker->hostname = "localhost";
	broker->virtualhost = "/";
	broker->username = "guest";
	broker->password = "guest";
	broker->port = 5672;
	broker->heartbeat = 30;

	for (param = switch_xml_child(xml, "param"); param; param = param->next) {
		char *var = (char *) switch_xml_attr_soft(param, "name");
		char *val = (char *) switch_xml_attr_soft(param, "value");

		if (zstr(var) || zstr(val)) {
			continue;
		} else if (!strcmp(var, "hostname")) {
			broker->hostname = switch_core_strdup(pool, val);
		} else if (!strcmp(var, "virtualhost")) {
			broker->virtualhost = switch_core_strdup(pool, val);
		} else if (!strcmp(var, "username")) {
			broker->username = switch_core_strdup(pool, val);
		} else if (!strcmp(var, "password")) {
			broker->password = switch_core_strdup(pool, val);
		} else if (!strcmp(var, "port")) {
			int port = atoi(val);
			if (port > 0) broker->port = (unsigned int) port;
		} else if (!strcmp(var, "heartbeat")) {
			int hb = atoi(val);
			if (hb >= 0) broker->heartbeat = (unsigned int) hb;
		}
	}

	*out = broker;
	return SWITCH_STATUS_SUCCESS;
}

/* bootstrap: the closed module's com.kazoo.conf as kazoo-configs-freeswitch
 * ships it (settings nodename/shortname, <connections local-zone> with
 * <connection> params fed by the kz_amqp_* vars), or this module's own
 * reprise.conf (same shape plus the tuning params). com_kazoo.conf, the
 * name the module's own file had before the module was renamed, is still
 * read so a deployed configuration keeps working. */
static switch_status_t reprise_load_config(void)
{
	const char *cf = "com.kazoo.conf";
	switch_xml_t cfg, xml, settings, param, connections, connection;
	reprise_broker_t *tail = NULL, *primary_tail = NULL;
	const char *nodename = "freeswitch";
	int shortname = 0;

	if (!(xml = switch_xml_open_cfg(cf, &cfg, NULL))) {
		cf = "reprise.conf";
		if (!(xml = switch_xml_open_cfg(cf, &cfg, NULL))) {
			cf = "com_kazoo.conf";
			if (!(xml = switch_xml_open_cfg(cf, &cfg, NULL))) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
								  "Open of com.kazoo.conf / reprise.conf / com_kazoo.conf failed\n");
				return SWITCH_STATUS_TERM;
			}
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING,
							  "bootstrap settings read from com_kazoo.conf; rename it reprise.conf\n");
		}
	}

	reprise_globals.reconnect_interval_ms = REPRISE_DEFAULT_RECONNECT_MS;
	reprise_globals.fetch_timeout_ms = REPRISE_DEFAULT_FETCH_TIMEOUT_MS;
	reprise_globals.advertise_interval_ms = REPRISE_DEFAULT_ADVERTISE_MS;
	reprise_globals.presence_dialog = 1;
	reprise_globals.rtcp_events = 0;

	if ((settings = switch_xml_child(cfg, "settings"))) {
		for (param = switch_xml_child(settings, "param"); param; param = param->next) {
			char *var = (char *) switch_xml_attr_soft(param, "name");
			char *val = (char *) switch_xml_attr_soft(param, "value");

			if (zstr(var) || zstr(val)) {
				continue;
			} else if (!strcmp(var, "node-name")) {
				reprise_globals.node_name = switch_core_strdup(reprise_globals.pool, val);
			} else if (!strcmp(var, "nodename")) {
				nodename = switch_core_strdup(reprise_globals.pool, val);
			} else if (!strcmp(var, "shortname")) {
				shortname = switch_true(val);
			} else if (!strcmp(var, "reconnect-interval-ms")) {
				int ms = atoi(val);
				if (ms > 0) reprise_globals.reconnect_interval_ms = (uint32_t) ms;
			} else if (!strcmp(var, "fetch-timeout-ms")) {
				int ms = atoi(val);
				if (ms > 0) reprise_globals.fetch_timeout_ms = (uint32_t) ms;
			} else if (!strcmp(var, "advertise-interval-ms")) {
				int ms = atoi(val);
				if (ms > 0) reprise_globals.advertise_interval_ms = (uint32_t) ms;
			} else if (!strcmp(var, "trace-fetch")) {
				reprise_globals.trace_fetch = switch_true(val);
			} else if (!strcmp(var, "rtcp-events")) {
				reprise_globals.rtcp_events = switch_true(val);
			} else if (!strcmp(var, "presence-dialog")) {
				reprise_globals.presence_dialog = switch_true(val);
			}
		}
	}

	if ((connections = switch_xml_child(cfg, "connections"))) {
		for (connection = switch_xml_child(connections, "connection"); connection; connection = connection->next) {
			reprise_broker_t *broker = NULL;
			if (reprise_load_broker(connection, reprise_globals.pool, &broker) == SWITCH_STATUS_SUCCESS) {
				if (zstr(broker->hostname) || strchr(broker->hostname, '$')) {
					switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING,
									  "%s: connection %s has no usable hostname (%s) -- kz_amqp_* vars unset?\n",
									  cf, switch_xml_attr_soft(connection, "name"), switch_str_nil(broker->hostname));
					continue;
				}
				/* failover order: primary connections first (the include glob
				 * that pulls kazoo/connections/ files in is alphabetical, not
				 * meaningful), then the rest in file order */
				if (reprise_connection_is_primary(connection)) {
					if (primary_tail) {
						broker->next = primary_tail->next;
						primary_tail->next = broker;
					} else {
						broker->next = reprise_globals.brokers;
						reprise_globals.brokers = broker;
					}
					primary_tail = broker;
					if (!broker->next) tail = broker;
				} else if (tail) {
					tail->next = broker;
					tail = broker;
				} else {
					reprise_globals.brokers = broker;
					tail = broker;
				}
			}
		}
	}

	switch_xml_free(xml);

	if (!reprise_globals.brokers) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "%s has no usable <connections>\n", cf);
		return SWITCH_STATUS_TERM;
	}

	if (!reprise_globals.node_name) {
		reprise_globals.node_name = reprise_default_node_name(reprise_globals.pool, nodename, shortname);
	}
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "bootstrap from %s: node %s, %s broker(s)\n",
					  cf, reprise_globals.node_name, reprise_globals.brokers->next ? "several" : "one");

	return SWITCH_STATUS_SUCCESS;
}

static void reprise_api_profiles(switch_stream_handle_t *stream)
{
	reprise_amqp_profile_t *ap;
	reprise_event_profile_t *ep;
	reprise_fetch_profile_t *fp;
	reprise_conf_broker_t *broker;

	switch_mutex_lock(reprise_globals.mutex);
	if (!reprise_globals.config) {
		stream->write_function(stream, "no kazoo.conf parsed yet\n");
		switch_mutex_unlock(reprise_globals.mutex);
		return;
	}

	stream->write_function(stream, "kazoo.conf version %s, local zone %s\n",
						   reprise_globals.config->version, reprise_globals.config->local_zone);

	stream->write_function(stream, "\nbrokers (%d):\n", reprise_globals.config->n_brokers);
	for (broker = reprise_globals.config->brokers; broker; broker = broker->next) {
		stream->write_function(stream, "  %s:%u zone=%s%s%s%s\n",
							   broker->hostname, broker->port, broker->zone,
							   broker->is_primary ? " primary" : "",
							   broker->is_local ? " local" : "",
							   broker->is_federated ? " federated" : "");
	}

	stream->write_function(stream, "\namqp profiles (%d):\n", reprise_globals.config->n_amqp_profiles);
	for (ap = reprise_globals.config->amqp_profiles; ap; ap = ap->next) {
		char queue_name[512] = "(none)";
		if (!zstr(ap->queue.name)) {
			reprise_expand_template(ap->queue.name, ap->name, queue_name, sizeof(queue_name));
		}
		stream->write_function(stream, "  %-12s channels=%d timeout=%ums queue=%s\n",
							   ap->name, ap->channels, ap->query_timeout_ms, queue_name);
	}

	stream->write_function(stream, "\nevent profiles (%d):\n", reprise_globals.config->n_event_profiles);
	for (ep = reprise_globals.config->event_profiles; ep; ep = ep->next) {
		reprise_event_t *ev;
		stream->write_function(stream, "  %-18s %d events -> %s via %s (hash %s->%s):",
							   ep->name, ep->event_count,
							   ep->amqp_exchange ? ep->amqp_exchange : "?",
							   ep->amqp_profile ? ep->amqp_profile : "?",
							   ep->routing_key.hash_event_field ? ep->routing_key.hash_event_field : "-",
							   ep->routing_key.hash_amqp_header ? ep->routing_key.hash_amqp_header : "-");
		for (ev = ep->events; ev; ev = ev->next) stream->write_function(stream, " %s", ev->name);
		stream->write_function(stream, "\n");
	}

	stream->write_function(stream, "\nfetch profiles (%d):\n", reprise_globals.config->n_fetch_profiles);
	for (fp = reprise_globals.config->fetch_profiles; fp; fp = fp->next) {
		stream->write_function(stream, "  %-14s section=%s exchange=%s profile=%s timeout=%" SWITCH_UINT64_T_FMT "us\n",
							   fp->name, fp->fetch_section, fp->amqp_exchange, fp->amqp_profile,
							   fp->fetch_timeout_us);
	}

	stream->write_function(stream, "\nvariables: %d, definitions: %d\n",
						   reprise_globals.config->n_variables, reprise_globals.config->n_definitions);
	switch_mutex_unlock(reprise_globals.mutex);
}

#define REPRISE_API_SYNTAX "status | profiles | refetch"
SWITCH_STANDARD_API(reprise_api)
{
	if (!zstr(cmd) && !strcasecmp(cmd, "profiles")) {
		reprise_api_profiles(stream);
		return SWITCH_STATUS_SUCCESS;
	}
	if (!zstr(cmd) && !strcasecmp(cmd, "refetch")) { /* what the `config` command does */
		reprise_config_refetch();
		stream->write_function(stream, "+OK kazoo.conf refetch requested\n");
		return SWITCH_STATUS_SUCCESS;
	}

	if (zstr(cmd) || !strcasecmp(cmd, "status")) {
		const char *phase = "disconnected";

		switch_mutex_lock(reprise_globals.mutex);
		switch (reprise_globals.phase) {
		case REPRISE_CONNECTED: phase = "connected"; break;
		case REPRISE_CONFIGURED: phase = "configured"; break;
		default: break;
		}
		stream->write_function(stream, "version: %s\n", REPRISE_VERSION_STRING);
		stream->write_function(stream, "node: %s\n", reprise_globals.node_name);
		stream->write_function(stream, "core-uuid: %s\n", reprise_globals.core_uuid);
		stream->write_function(stream, "phase: %s\n", phase);
		stream->write_function(stream, "broker: %s\n",
							   reprise_globals.connected_broker ? reprise_globals.connected_broker : "(none)");
		stream->write_function(stream, "kazoo.conf: %" SWITCH_SIZE_T_FMT " bytes (%u fetches, %u changed, %u worker restarts%s)\n",
							   reprise_globals.kazoo_config_len, reprise_globals.config_fetches, reprise_globals.config_changes,
							   reprise_globals.worker_restarts, reprise_globals.refetch_requested ? ", refetch pending" : "");
		if (reprise_globals.config) {
			stream->write_function(stream, "parsed: %d brokers, %d amqp / %d event / %d fetch profiles\n",
								   reprise_globals.config->n_brokers,
								   reprise_globals.config->n_amqp_profiles,
								   reprise_globals.config->n_event_profiles,
								   reprise_globals.config->n_fetch_profiles);
		}
		stream->write_function(stream, "reconnects: %u\n", reprise_globals.reconnects);
		if (reprise_globals.publisher) {
			reprise_publisher_t *pub = reprise_globals.publisher;
			reprise_broker_t *b;
			stream->write_function(stream, "publisher: %s publishes=%" SWITCH_UINT64_T_FMT
								   " failures=%" SWITCH_UINT64_T_FMT " connects=%u\n",
								   pub->connected_broker ? pub->connected_broker : "(disconnected)",
								   pub->publishes, pub->failures, pub->reconnects);
			/* the failover order every worker/stream/publisher snapshotted */
			stream->write_function(stream, "failover:");
			for (b = pub->brokers; b; b = b->next) {
				stream->write_function(stream, " %s:%u", b->hostname, b->port);
			}
			stream->write_function(stream, "\n");
		}
		switch_mutex_unlock(reprise_globals.mutex);
		/* each subsystem's status takes its own lock; none of them is
		 * taken under reprise_globals.mutex (fetch: a waking handler takes
		 * fetch.mutex then reads the worker list under the global one,
		 * so the reverse nesting here would be a deadlock) */
		reprise_fetch_status(stream);
		reprise_events_status(stream);
		reprise_presence_status(stream);
		reprise_prompts_status(stream);
		stream->write_function(stream, "originates in flight: %d\n", kz_originate_count());
		switch_mutex_lock(reprise_globals.mutex);
		if (reprise_globals.workers) {
			reprise_worker_t *worker;
			stream->write_function(stream, "workers:\n");
			for (worker = reprise_globals.workers; worker; worker = worker->next) {
				stream->write_function(stream,
									   "  %-12s %-12s queue=%s deliveries=%" SWITCH_UINT64_T_FMT
									   " publishes=%" SWITCH_UINT64_T_FMT " reconnects=%u",
									   worker->name,
									   worker->consuming ? "consuming" : "disconnected",
									   worker->queue_name, worker->deliveries, worker->publishes,
									   worker->reconnects);
				if (!strcmp(worker->name, "nodes")) {
					stream->write_function(stream, " zone=%s last-advertise=%" SWITCH_TIME_T_FMT "s-ago",
										   worker->zone,
										   worker->last_advertise
										   ? (switch_micro_time_now() - worker->last_advertise) / 1000000 : (switch_time_t) -1);
				} else if (!strcmp(worker->name, "commands")) {
					stream->write_function(stream, " bgapi-jobs=%u pending=%u",
										   worker->bg_jobs, reprise_commands_bg_pending());
				}
				stream->write_function(stream, "\n");
			}
		}
		switch_mutex_unlock(reprise_globals.mutex);
	} else {
		stream->write_function(stream, "-USAGE: reprise %s\n", REPRISE_API_SYNTAX);
	}

	return SWITCH_STATUS_SUCCESS;
}

/* `json {"command":"node.info","data":""}` on the CLI shows exactly what
 * the json_api node.info responder sends ecallmgr */
SWITCH_STANDARD_JSON_API(node_info_json_function)
{
	*json_reply = reprise_node_info_json();
	return SWITCH_STATUS_SUCCESS;
}

SWITCH_STANDARD_API(first_of_api)
{
	return reprise_first_of_api(cmd, session, stream);
}

SWITCH_MODULE_LOAD_FUNCTION(mod_reprise_load)
{
	switch_api_interface_t *api_interface;
	switch_json_api_interface_t *json_api_interface;

	memset(&reprise_globals, 0, sizeof(reprise_globals));
	reprise_globals.pool = pool;

	switch_copy_string(reprise_globals.core_uuid, switch_core_get_uuid(), sizeof(reprise_globals.core_uuid));
	reprise_globals.startup_epoch = switch_epoch_time_now(NULL) - (time_t) (switch_core_uptime() / 1000000);
	switch_mutex_init(&reprise_globals.mutex, SWITCH_MUTEX_NESTED, pool);
	reprise_events_init(pool);

	if (reprise_load_config() != SWITCH_STATUS_SUCCESS) {
		return SWITCH_STATUS_TERM;
	}

	*module_interface = switch_loadable_module_create_module_interface(pool, modname);

	SWITCH_ADD_API(api_interface, "reprise", "reprise API", reprise_api, REPRISE_API_SYNTAX);
	SWITCH_ADD_JSON_API(json_api_interface, "node.info", "kz_nodes node info", node_info_json_function, "");
	/* the ${first-of(a|b|#default)} form the kazoo.conf field grammar expands through */
	SWITCH_ADD_API(api_interface, "first-of", "first existing header of a |-list", first_of_api, "a|b|#default");
	/* mod_kazoo's call machinery: kz_* dialplan apps and APIs, channel tweaks */
	reprise_kz_dptools_add(module_interface);
	reprise_kz_commands_add(module_interface);
	reprise_kz_endpoints_add(module_interface);
	reprise_kz_originate_add(module_interface);
	reprise_prompts_start(module_interface);
	memset(reprise_globals.tweaks, 1, sizeof(reprise_globals.tweaks));
	kz_tweaks_start();
	kz_cdr_start();
	if (reprise_globals.presence_dialog) reprise_presence_start();

	reprise_commands_init(pool);

	reprise_globals.running = 1;
	if (reprise_transport_start() != SWITCH_STATUS_SUCCESS) {
		reprise_globals.running = 0;
		return SWITCH_STATUS_TERM;
	}

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_NOTICE,
					  "%s loaded: node %s core-uuid %s\n",
					  REPRISE_VERSION_STRING, reprise_globals.node_name, reprise_globals.core_uuid);

	return SWITCH_STATUS_SUCCESS;
}

/* Teardown order matters: every step below runs with the step before it
 * complete, so no thread is left touching state a later step frees.
 *  1. running=0 and join the transport thread: it is the only caller of
 *     reprise_workers_start/restart, so no configuration application or
 *     restart overlaps the rest of this function.
 *  2. reprise_fetch_stop: waiters are released, and the core's unbind returns
 *     only once no fetch handler is inside the module.
 *  3. join the consumers (commands, fetch replies, nodes).
 *  4. event streams and presence: bindings unbound (no handler inside
 *     after that), stream threads joined, their publishers destroyed.
 *  5. the shared publisher: its users (fetch handlers, streams) are gone.
 *  6. bgapi jobs: admission closed, every job thread joined -- an API
 *     that has not returned holds the unload rather than returning into
 *     unmapped code.
 *  7. originates: in-flight attempts cancelled and waited for; a
 *     registry still in use is kept, never freed under an originate.
 *  8. the rest of the call machinery and the prompt cache. */
SWITCH_MODULE_SHUTDOWN_FUNCTION(mod_reprise_shutdown)
{
	int sanity = 0;

	reprise_globals.running = 0;
	reprise_transport_stop();
	reprise_fetch_stop();
	reprise_workers_stop();
	reprise_events_stop();
	reprise_presence_stop();
	reprise_publisher_destroy(&reprise_globals.publisher);
	reprise_commands_shutdown();
	kz_originate_shutdown();
	kz_cdr_stop();
	kz_tweaks_stop();
	reprise_prompts_stop();

	while (switch_atomic_read(&reprise_globals.threads)) {
		switch_yield(100000);
		if (++sanity >= 100) {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "Unable to stop all threads\n");
			break;
		}
	}

	switch_safe_free(reprise_globals.kazoo_config);
	/* every holder (fetch handlers, the event streams) has left by now;
	 * honour the refcount anyway rather than free under a straggler */
	switch_mutex_lock(reprise_globals.mutex);
	if (reprise_globals.config) {
		reprise_globals.config->retired = 1;
		if (!reprise_globals.config->refs) {
			reprise_config_destroy(&reprise_globals.config);
		} else {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "kazoo.conf still held %d times at unload; leaking it\n",
							  reprise_globals.config->refs);
			reprise_globals.config = NULL;
		}
	}
	switch_mutex_unlock(reprise_globals.mutex);

	return SWITCH_STATUS_SUCCESS;
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
