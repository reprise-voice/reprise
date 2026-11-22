/*
 * mod_reprise -- AMQP transport between FreeSWITCH and Kazoo's
 * ecallmgr_extension, implementing the open wire contract recovered from
 * kazoo-ecallmgr-extension (see docs/WIRE.md and the fs-contract-probe).
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#ifndef REPRISE_H
#define REPRISE_H

#include <switch.h>
#include <switch_json.h>

/* rabbitmq-c 0.12 moved its headers under rabbitmq-c/ and left the old
 * names behind as #warning stubs, which -Werror turns into errors (Debian
 * trixie ships 0.15; bookworm and Ubuntu 24.04 ship 0.11, which has only
 * the old names). */
#if __has_include(<rabbitmq-c/amqp.h>)
#include <rabbitmq-c/amqp.h>
#include <rabbitmq-c/framing.h>
#include <rabbitmq-c/tcp_socket.h>
#else
#include <amqp.h>
#include <amqp_framing.h>
#include <amqp_tcp_socket.h>
#endif

#define REPRISE_APP_NAME "mod_reprise"
#define REPRISE_APP_VERSION "0.1.0"

/* "<module> <vX.Y.Z> <bundle>": the Release token gates ecallmgr's minimum
 * switch version (>= v1.5) and the BUNDLE token selects the node-module set
 * (configuration.<bundle>.modules) -- "commercial" wires the AMQP transport */
#define REPRISE_VERSION_STRING "mod_reprise v5.4.0 commercial"
#define REPRISE_RELEASE "v5.4.0"
#define REPRISE_BUNDLE "commercial" /* Kazoo-Bundle -> Fetch-Version: selects the extension's fetch handlers */

#define REPRISE_EXCHANGE_FREESWITCH "freeswitch"
#define REPRISE_EXCHANGE_TARGETED "targeted"
#define REPRISE_EXCHANGE_NODES "nodes"
#define REPRISE_EXCHANGE_CALLEVT "callevt"

#define REPRISE_DEFAULT_FETCH_TIMEOUT_MS 3500
#define REPRISE_DEFAULT_RECONNECT_MS 2000
#define REPRISE_DEFAULT_ADVERTISE_MS 5000
/* kz_nodes expires us when now_ms > last_heartbeat + Expires: MILLISECONDS */
#define REPRISE_ADVERTISE_EXPIRES_MS 30000

#define REPRISE_WORKER_CHANNEL 1

/* network deadlines on every broker connection (transport, workers,
 * publishers): TCP connect, the AMQP RPCs (login, declares, binds,
 * consume) and -- rabbitmq-c sends with no deadline of its own -- the
 * time a sent frame may sit unacknowledged (TCP_USER_TIMEOUT) */
#define REPRISE_CONNECT_TIMEOUT_MS 5000
#define REPRISE_RPC_TIMEOUT_MS 10000
#define REPRISE_SEND_TIMEOUT_MS 15000

/* bounds on work driven by the broker. A body larger than the cap is
 * dropped after consumption: rabbitmq-c has already allocated it by then
 * (it sizes the buffer from the header frame), so the broker's own
 * max_message_size is the limit that protects the process; this one
 * bounds what the module copies, parses and keeps. */
#define REPRISE_MAX_COMMAND_BYTES (1024 * 1024)
#define REPRISE_MAX_FETCH_REPLY_BYTES (4 * 1024 * 1024)
#define REPRISE_MAX_CONFIG_BYTES (8 * 1024 * 1024)
/* bgapi jobs running at once. ecallmgr's originates are bgapi
 * kz_originate calls that hold their job for the whole ring time, so
 * this is also the ceiling on simultaneous Kazoo-initiated originates
 * per media server; beyond it a request is answered -ERR at once. */
#define REPRISE_BG_JOBS_MAX 256
#define REPRISE_STREAM_QUEUE_LEN 20000                 /* event messages queued per stream */
#define REPRISE_STREAM_QUEUE_BYTES (64 * 1024 * 1024)  /* ... and their total body bytes */
#define REPRISE_PROMPT_CACHE_MAX 4096                  /* resolved prompt paths kept */

#define REPRISE_EVENT_PRESENCE_DIALOG "KZ_PRESENCE_DIALOG"
#define REPRISE_PRESENCE_DEFAULT_REALM "nodomain.com" /* ecallmgr's default_realm */

#include "reprise_profiles.h"

typedef struct reprise_broker_s {
	char *hostname;
	char *virtualhost;
	char *username;
	char *password;
	unsigned int port;
	unsigned int heartbeat; /* seconds */
	struct reprise_broker_s *next;
} reprise_broker_t;

typedef enum {
	REPRISE_DISCONNECTED = 0,
	REPRISE_CONNECTED,
	REPRISE_CONFIGURED
} reprise_conn_phase_t;

typedef struct {
	switch_memory_pool_t *pool;
	int running;
	switch_atomic_t threads;

	/* identity */
	char core_uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
	char *node_name; /* freeswitch@<fqdn>, what kz_nodes will know us as */

	time_t startup_epoch; /* unix seconds FS came up (now - uptime) */

	/* bootstrap config */
	reprise_broker_t *brokers;
	uint32_t reconnect_interval_ms;
	uint32_t fetch_timeout_ms;
	uint32_t advertise_interval_ms;
	int trace_fetch; /* log every fetch document and reply at INFO */
	int rtcp_events;     /* bind the rtcp profile's events and turn fire_rtcp_events on (off: nothing in Kazoo reads them) */
	int presence_dialog; /* fire KZ_PRESENCE_DIALOG from PRESENCE_IN (reprise_presence.c) */
	uint8_t tweaks[16]; /* kz_tweak_t flags (reprise_kz.h); all on by default */

	/* transport state (owned by the transport thread; phase guarded by mutex) */
	switch_mutex_t *mutex;
	reprise_conn_phase_t phase;
	char *connected_broker; /* "host:port" of the active broker, pool-dup'd */
	char *kazoo_config;     /* the fetched kazoo.conf XML (malloc'd) */
	switch_size_t kazoo_config_len;
	reprise_config_t *config;   /* parsed form (own pool; swapped on refetch) */
	uint32_t config_fetches;
	uint32_t config_changes; /* refetches whose document differed */
	volatile int refetch_requested; /* `config` command / CLI: ask again */
	uint32_t reconnects;

	switch_thread_t *transport_thread;

	/* per-profile workers (reprise_workers.c) */
	struct reprise_worker_s *workers;
	int workers_started;
	uint32_t worker_restarts; /* kazoo.conf changed under running workers */

	/* publish-only connection for the switch's own threads (reprise_publisher.c) */
	struct reprise_publisher_s *publisher;
} reprise_globals_t;

extern reprise_globals_t reprise_globals;

/* one consumer per queue-bearing amqp profile: own connection, own
 * snapshot of everything it needs (config swaps must not touch it) */
typedef struct reprise_worker_s {
	switch_memory_pool_t *pool; /* owns every string/list in the snapshot */
	char *name;

	/* snapshot, templates expanded */
	reprise_exchange_t *exchanges;
	char *queue_name;
	int exclusive;
	int consume_exclusive;
	int consume_qos;
	reprise_qbinding_t *bindings;
	reprise_broker_t *brokers;

	/* nodes worker: the zone we advertise in (kazoo.conf local-zone) */
	char *zone;

	/* runtime */
	switch_thread_t *thread;
	volatile int stop; /* restart: leave the loop, keep reprise_globals.running */
	volatile int consuming;
	char *connected_broker;
	uint64_t deliveries;
	uint64_t publishes;
	uint32_t reconnects;
	switch_time_t last_advertise;  /* nodes worker, micro */
	uint32_t bg_jobs;              /* commands worker: bgapi jobs started */
	struct reprise_worker_s *next;
} reprise_worker_t;

typedef struct reprise_publisher_s {
	switch_memory_pool_t *pool;
	switch_mutex_t *mutex;
	amqp_connection_state_t state;
	reprise_broker_t *brokers;
	char *connected_broker;
	uint64_t publishes;
	uint64_t failures;
	uint32_t reconnects;
} reprise_publisher_t;

/* reprise_transport.c */
switch_status_t reprise_transport_start(void);
void reprise_transport_stop(void); /* joins the transport thread (reprise_globals.running must be 0) */
/* TCP connect + login + channel open against one broker with the
 * deadlines above applied (connect, RPC, unacknowledged send); NULL when
 * the broker is unreachable or refuses us. `who` tags the log lines. */
amqp_connection_state_t reprise_amqp_connect(reprise_broker_t *broker, int heartbeat, amqp_channel_t channel, const char *who);
/* ask the transport thread to fetch kazoo.conf again (the `config` command
 * family, the CLI); a changed document restarts the workers */
void reprise_config_refetch(void);
/* the current parsed kazoo.conf, pinned: a refetch cannot free it until
 * every holder releases it */
reprise_config_t *reprise_config_hold(void);
void reprise_config_release(reprise_config_t *config);
void reprise_config_apply_variables(reprise_config_t *config); /* <variables> -> core globals */
/* reprise_kzutils.c: one <X-PRE-PROCESS cmd="set|exec-set|stun-set|env-set" data="key=value"/> (kz_xml_process) */
void kz_xml_preprocess(const char *cmd, const char *data);
/* "key = value" -> trimmed key and value (in place); SWITCH_FALSE without an '=' */
switch_bool_t kz_split_keyval(char *keyval, char **key, char **val);
/* publish a JSON body (application/json) on the given connection/channel;
 * rabbitmq-c connections are single-threaded: only call from the thread
 * that owns `state` */
switch_status_t reprise_amqp_publish_json(amqp_connection_state_t state, amqp_channel_t channel,
									  const char *exchange, const char *routing_key, cJSON *json);

/* reprise_workers.c */
void reprise_workers_start(void); /* idempotent; snapshots reprise_globals.config */
void reprise_workers_stop(void);
/* tear down workers, publisher, fetch binding and event streams and start
 * them again from the current reprise_globals.config (transport thread) */
void reprise_workers_restart(void);
/* copy the worker's queue name out under the global mutex (a restart
 * frees the worker's pool); SWITCH_FALSE when no such worker */
switch_bool_t reprise_worker_queue_name(const char *profile_name, char *buf, switch_size_t buflen);
uint32_t reprise_worker_reconnects(const char *profile_name);
reprise_broker_t *reprise_brokers_snapshot(switch_memory_pool_t *pool, reprise_config_t *config);

/* reprise_publisher.c */
reprise_publisher_t *reprise_publisher_create(reprise_broker_t *brokers);
void reprise_publisher_destroy(reprise_publisher_t **pub);
/* a `pid://<pid>/<queue>` routing key is rewritten the way kz_amqp_util
 * does it: key = queue, header Deliver-To-PID = pid (gen_listener hands
 * the message straight to that process) */
switch_status_t reprise_publisher_publish(reprise_publisher_t *pub, const char *exchange, const char *routing_key,
									  cJSON *json, const char *header_name, const char *header_value);
switch_status_t reprise_publisher_publish_body(reprise_publisher_t *pub, const char *exchange, const char *routing_key,
										   const char *body, const char *header_name, const char *header_value);
/* the same, but give up (SWITCH_STATUS_TIMEOUT) when the publisher's
 * mutex is not free within wait_us: callers with their own deadline (the
 * fetch handler) must not queue behind a publish stuck on a stalled
 * broker */
switch_status_t reprise_publisher_publish_wait(reprise_publisher_t *pub, const char *exchange, const char *routing_key,
										   cJSON *json, const char *header_name, const char *header_value,
										   switch_time_t wait_us);
void reprise_publisher_service(reprise_publisher_t *pub); /* heartbeats; call every few 100 ms from the owner */

/* reprise_fetch.c -- XML fetch requests served over AMQP */
void reprise_fetch_start(reprise_config_t *config); /* binds the search function once */
void reprise_fetch_stop(void);                    /* unbinds; waiters give up */
int reprise_fetch_waiting(void);                  /* fetches still blocked in the handler */
void reprise_fetch_dispatch(reprise_worker_t *worker, amqp_envelope_t *envelope); /* fetch worker deliveries */
void reprise_fetch_status(switch_stream_handle_t *stream);
/* render a <routing-key> spec against a document (falling back to the
 * event's headers), kz_amqp_util-encoding each part unless told not to */
void reprise_routing_key_build(reprise_routing_key_t *spec, cJSON *json, switch_event_t *event, char *out, switch_size_t outlen);

/* reprise_events.c -- event streams per the event profiles. Lock order:
 * reprise_globals.mutex may be held when the events mutex is taken (start
 * runs under it); the events mutex is never held while taking
 * reprise_globals.mutex or fetch's. */
void reprise_events_init(switch_memory_pool_t *pool); /* module load: the lifetime mutex */
void reprise_events_start(reprise_config_t *config);
void reprise_events_stop(void);
void reprise_events_status(switch_stream_handle_t *stream);

/* reprise_presence.c -- KZ_PRESENCE_DIALOG from the core's PRESENCE_IN */
void reprise_presence_start(void);
void reprise_presence_stop(void);
void reprise_presence_status(switch_stream_handle_t *stream);
switch_event_t *reprise_presence_dialog_build(switch_event_t *presence_in); /* NULL: not publishable */
const char *reprise_presence_state(const char *direction, const char *status, const char *answer_state);

/* reprise_node.c -- node identity + the JSON describing this switch */
char *reprise_default_node_name(switch_memory_pool_t *pool, const char *nodename, int shortname); /* <nodename>@<hostname [-f]> */
cJSON *reprise_node_info_json(void);                          /* json_api node.info response */
cJSON *reprise_node_advertise_json(const char *zone);         /* kz_nodes advertise/heartbeat */
void reprise_nodes_tick(reprise_worker_t *worker, amqp_connection_state_t state);
void reprise_nodes_dispatch(reprise_worker_t *worker, amqp_envelope_t *envelope);

/* reprise_commands.c -- the freeswitch.cmds.<core-uuid> responder */
void reprise_commands_init(switch_memory_pool_t *pool); /* module load: the bgapi job registry */
void reprise_commands_shutdown(void);                    /* module unload: stop admission, join every job thread */
uint32_t reprise_commands_bg_pending(void);
/* start a bgapi job (bounded by REPRISE_BG_JOBS_MAX, refused once shutdown
 * began); on success *job_uuid names it. Split out for the tests. */
switch_status_t reprise_commands_bg_start(const char *cmd, const char *arg, const char *server_id,
									  const char *msg_id, const char *from_pid, char *job_uuid, switch_size_t uuid_len);
void reprise_commands_dispatch(reprise_worker_t *worker, amqp_connection_state_t state, amqp_envelope_t *envelope);
void reprise_commands_tick(reprise_worker_t *worker, amqp_connection_state_t state);

#endif /* REPRISE_H */

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
