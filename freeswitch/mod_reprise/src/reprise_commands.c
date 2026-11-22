/*
 * reprise_commands.c -- the responder for freeswitch.cmds.<core-uuid>: the
 * kapi_freeswitch command families ecallmgr sends a node (version, api,
 * bgapi, json_api). Runs in the commands worker's thread on its own
 * connection; replies go to the request's Server-ID via `targeted`, echo
 * Msg-ID, and carry Reply-To-PID (the request's Request-From-PID) -- the
 * extension's listener dispatches only API / BACKGROUND_JOB /
 * json_api.reply events (docs/WIRE.md).
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise.h"
#include "reprise_kz.h"

typedef struct {
	const char *event;      /* Event-Name: version | api | bgapi | json_api | ... */
	const char *server_id;  /* reply queue */
	const char *msg_id;
	const char *from_pid;   /* Request-From-PID -> Reply-To-PID */
	const char *cmd;        /* API-Command */
	const char *arg;        /* API-Arguments */
	cJSON *payload;         /* json_api Payload */
} reprise_req_t;

/* a bgapi job: executed on its own (joinable) thread, result handed back
 * to the commands worker through a module-lifetime queue so the
 * BACKGROUND_JOB event is published from the connection's owning thread.
 * The registry outlives the worker on purpose: a kazoo.conf change
 * restarts the workers while jobs may still be running, and ecallmgr
 * waits for the BACKGROUND_JOB reply with no timeout -- the next commands
 * worker publishes whatever finished in between. At most REPRISE_BG_JOBS_MAX
 * run at once (the consumer is no_ack, so the broker's QoS bounds
 * nothing here); unload closes admission and joins every job thread
 * before the module's code goes away -- an API of another module that
 * never returns holds the unload, which beats returning into unmapped
 * code. */
typedef struct reprise_bgjob_s {
	switch_memory_pool_t *pool;
	switch_thread_t *thread; /* NULL: ran inline (thread creation failed) */
	char job_uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
	char *cmd;
	char *arg;
	char *server_id;
	char *msg_id;
	char *from_pid;
	char *result; /* malloc'd output */
	int ok;
	switch_time_t started;
	struct reprise_bgjob_s *next;
} reprise_bgjob_t;

static struct {
	switch_mutex_t *mutex;
	reprise_bgjob_t *running;    /* every job not yet reaped (thread joined, pool freed) */
	uint32_t n_running;
	switch_atomic_t active;  /* job threads still executing their API */
	switch_queue_t *done;    /* finished jobs awaiting their BACKGROUND_JOB */
	int stopping;            /* unload: no admission */
	uint64_t refused;
} bg;

void reprise_commands_init(switch_memory_pool_t *pool)
{
	switch_mutex_init(&bg.mutex, SWITCH_MUTEX_NESTED, pool);
	/* one push per job and never more than REPRISE_BG_JOBS_MAX alive: the
	 * push cannot fail for want of room */
	switch_queue_create(&bg.done, REPRISE_BG_JOBS_MAX, pool);
	bg.stopping = 0;
	bg.running = NULL;
	bg.n_running = 0;
	bg.refused = 0;
}

uint32_t reprise_commands_bg_pending(void)
{
	uint32_t n;
	if (!bg.mutex) return 0;
	switch_mutex_lock(bg.mutex);
	n = bg.n_running;
	switch_mutex_unlock(bg.mutex);
	return n;
}

/* the job's thread is done with it (joined) or never existed: unlink and free */
static void bgjob_reap(reprise_bgjob_t *job)
{
	switch_memory_pool_t *pool = job->pool;
	reprise_bgjob_t **pp;

	if (job->thread) {
		switch_status_t rv;
		switch_thread_join(&rv, job->thread);
		job->thread = NULL;
	}
	switch_mutex_lock(bg.mutex);
	for (pp = &bg.running; *pp; pp = &(*pp)->next) {
		if (*pp == job) {
			*pp = job->next;
			bg.n_running--;
			break;
		}
	}
	switch_mutex_unlock(bg.mutex);
	switch_safe_free(job->result);
	switch_core_destroy_memory_pool(&pool);
}

/* module unload: close admission, wait for every job's API to return
 * (logged every 30 s), join the threads and free what nobody will
 * publish any more */
void reprise_commands_shutdown(void)
{
	void *data;
	int waited = 0;

	if (!bg.mutex) return;
	switch_mutex_lock(bg.mutex);
	bg.stopping = 1;
	switch_mutex_unlock(bg.mutex);

	while (switch_atomic_read(&bg.active)) {
		switch_yield(100000);
		if (++waited % 300 == 0) {
			reprise_bgjob_t *job;
			switch_mutex_lock(bg.mutex);
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "unload waiting for %u bgapi job(s) to return (%ds):\n",
							  switch_atomic_read(&bg.active), waited / 10);
			for (job = bg.running; job; job = job->next) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "  %s: %s %s (%ds)\n", job->job_uuid, job->cmd,
								  switch_str_nil(job->arg), (int) ((switch_micro_time_now() - job->started) / 1000000));
			}
			switch_mutex_unlock(bg.mutex);
		}
	}
	while (bg.done && switch_queue_trypop(bg.done, &data) == SWITCH_STATUS_SUCCESS) {
		reprise_bgjob_t *job = (reprise_bgjob_t *) data;
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "bgapi job %s finished but never reported\n", job->job_uuid);
		bgjob_reap(job);
	}
	/* nothing should be left: every job pushes itself once its API returned */
	while (bg.running) {
		reprise_bgjob_t *job = bg.running;
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "bgapi job %s in the registry but never queued; reaping\n", job->job_uuid);
		bgjob_reap(job);
	}
}

static const char *jstr(cJSON *obj, const char *key)
{
	cJSON *item = obj ? cJSON_GetObjectItem(obj, key) : NULL;
	return (item && item->type == cJSON_String) ? item->valuestring : NULL;
}

static void rtrim(char *s)
{
	size_t len = s ? strlen(s) : 0;
	while (len && (s[len - 1] == '\n' || s[len - 1] == '\r' || s[len - 1] == ' ' || s[len - 1] == '\t')) {
		s[--len] = '\0';
	}
}

/* run an API command through the switch; returns 1 when the command
 * exists (whatever its outcome) and leaves the output in *out (malloc'd) */
static int api_execute(const char *cmd, const char *arg, char **out, switch_status_t *status)
{
	switch_stream_handle_t stream = {0};
	switch_api_interface_t *api;

	if (!(api = switch_loadable_module_get_api_interface(cmd))) {
		*out = NULL;
		*status = SWITCH_STATUS_NOTFOUND;
		return 0;
	}
	UNPROTECT_INTERFACE(api);

	SWITCH_STANDARD_STREAM(stream);
	*status = switch_api_execute(cmd, arg, NULL, &stream);
	if (stream.data) {
		*out = (char *) stream.data; /* malloc'd by the stream: ours now */
	} else if (!(*out = strdup(""))) {
		*status = SWITCH_STATUS_MEMERR;
		return 0;
	}
	rtrim(*out);
	return 1;
}

/* `erlang node <name> option <opt> [value]` / `erlang status`: the node
 * runtime options mod_kazoo exposes (enable-legacy, event-stream-framing,
 * event-stream-keepalive). The AMQP transport has no per-node event
 * socket to tune, so they are accepted and echoed. */
static char *api_erlang(const char *arg)
{
	char *copy = strdup(arg ? arg : "");
	char *argv[8] = {0};
	int argc = switch_separate_string(copy, ' ', argv, (sizeof(argv) / sizeof(argv[0])));
	char *ret;

	if (argc >= 5 && !strcasecmp(argv[0], "node") && !strcasecmp(argv[2], "option")) {
		ret = switch_mprintf("+OK %s", argv[4]);
	} else if (argc >= 4 && !strcasecmp(argv[0], "node") && !strcasecmp(argv[2], "option")) {
		ret = strdup("+OK true"); /* get: the legacy flag reads as enabled */
	} else {
		ret = strdup("+OK");
	}
	free(copy);
	return ret;
}

/* the api dispatcher: real switch commands where they exist, contract
 * shaped fallbacks where the module that answers may not be loaded
 * (conference xml_list must be XML, show ... as json must be JSON).
 * Returns 1 for Result ok, 0 for error; *out is malloc'd. */
static int api_dispatch(const char *cmd, const char *arg, char **out)
{
	switch_status_t status = SWITCH_STATUS_FALSE;
	char *last;
	int found;

	if (!strcasecmp(cmd, "erlang")) {
		*out = api_erlang(arg);
		return 1;
	}

	found = api_execute(cmd, arg, out, &status);

	if (!strcasecmp(cmd, "conference") && arg && !strncasecmp(arg, "xml_list", 8)) {
		/* ecallmgr_fs_conferences xmerl-parses this: never answer non-XML */
		if (!found || status != SWITCH_STATUS_SUCCESS || zstr(*out) || **out != '<') {
			switch_safe_free(*out);
			*out = strdup("<conferences></conferences>");
		}
		return 1;
	}

	if (!strcasecmp(cmd, "show") && arg && strstr(arg, "as json")) {
		if (!found || status != SWITCH_STATUS_SUCCESS || zstr(*out) || (**out != '{' && **out != '[')) {
			switch_safe_free(*out);
			*out = strdup("{\"row_count\":0,\"rows\":[]}");
		}
		return 1;
	}

	if (!found) {
		if (status == SWITCH_STATUS_MEMERR) {
			*out = NULL;
			return 0;
		}
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING,
						  "api %s %s: no such command on this node, answering +OK\n", cmd, switch_str_nil(arg));
		*out = switch_mprintf("+OK %s not available", cmd);
		return 1;
	}

	if (status != SWITCH_STATUS_SUCCESS) {
		if (zstr(*out)) {
			switch_safe_free(*out);
			*out = switch_mprintf("-ERR %s failed", cmd);
		} else if (strncmp(*out, "-ERR", 4)) {
			char *err = switch_mprintf("-ERR %s", *out);
			free(*out);
			*out = err;
		}
		return 0;
	}
	if (zstr(*out)) {
		switch_safe_free(*out);
		if (!(*out = strdup("+OK"))) return 0;
	}
	if (!strncmp(*out, "-ERR", 4)) {
		return 0;
	}
	/* multi-line replies report failure on their LAST line ("load"
	 * prints "+OK Reloading XML" then "-ERR [module load ...]"); the
	 * caller pattern-matches the -ERR prefix, so surface that line */
	if ((last = strrchr(*out, '\n')) && !strncmp(last + 1, "-ERR", 4)) {
		char *err = strdup(last + 1);
		free(*out);
		*out = err;
		return 0;
	}
	return 1;
}

/* publish a reply to Server-ID via targeted; takes ownership of fields */
static void send_reply(reprise_worker_t *worker, amqp_connection_state_t state,
					   const char *server_id, const char *msg_id, const char *from_pid, cJSON *fields)
{
	if (zstr(server_id)) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "command request without Server-ID; cannot reply\n");
		cJSON_Delete(fields);
		return;
	}

	cJSON_AddStringToObject(fields, "Event-Category", "freeswitch");
	cJSON_AddStringToObject(fields, "Msg-ID", switch_str_nil(msg_id));
	cJSON_AddStringToObject(fields, "Reply-To-PID", switch_str_nil(from_pid));
	cJSON_AddStringToObject(fields, "Node", reprise_globals.node_name);
	cJSON_AddStringToObject(fields, "Core-UUID", reprise_globals.core_uuid);
	cJSON_AddStringToObject(fields, "App-Name", REPRISE_APP_NAME);
	cJSON_AddStringToObject(fields, "App-Version", REPRISE_APP_VERSION);

	if (reprise_amqp_publish_json(state, REPRISE_WORKER_CHANNEL, REPRISE_EXCHANGE_TARGETED,
							  server_id, fields) == SWITCH_STATUS_SUCCESS) {
		worker->publishes++;
	}
	cJSON_Delete(fields);
}

static cJSON *api_reply(int ok, const char *ret)
{
	cJSON *fields = cJSON_CreateObject();
	cJSON_AddStringToObject(fields, "Event-Name", "API");
	cJSON_AddStringToObject(fields, "Result", ok ? "ok" : "error");
	cJSON_AddStringToObject(fields, "Return", switch_str_nil(ret));
	return fields;
}

static void handle_version(reprise_worker_t *worker, amqp_connection_state_t state, reprise_req_t *req)
{
	/* "<module> <vX.Y.Z> <bundle>": Release gates >= v1.5, bundle selects
	 * the node-module set (commercial = the AMQP transport) */
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "command: version -> %s\n", REPRISE_VERSION_STRING);
	send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(1, REPRISE_VERSION_STRING));
}

static void handle_api(reprise_worker_t *worker, amqp_connection_state_t state, reprise_req_t *req)
{
	char *out = NULL;
	int ok;

	if (zstr(req->cmd)) {
		send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(0, "-ERR missing API-Command"));
		return;
	}

	ok = api_dispatch(req->cmd, req->arg, &out);
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "command: api %s %s -> %s (%" SWITCH_SIZE_T_FMT " bytes)\n",
					  req->cmd, switch_str_nil(req->arg), ok ? "ok" : "error", (switch_size_t) (out ? strlen(out) : 0));
	send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(ok, out ? out : "-ERR no memory"));
	free(out);
}

static void *SWITCH_THREAD_FUNC bgjob_thread(switch_thread_t *thread, void *data)
{
	reprise_bgjob_t *job = (reprise_bgjob_t *) data;

	job->ok = api_dispatch(job->cmd, job->arg, &job->result);
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "bgapi job %s: %s%s%s -> %s: %s\n",
					  job->job_uuid, job->cmd, zstr(job->arg) ? "" : " ", switch_str_nil(job->arg),
					  job->ok ? "bgok" : "bgerror", switch_str_nil(job->result));

	if (switch_queue_trypush(bg.done, job) != SWITCH_STATUS_SUCCESS) {
		/* cannot happen (queue depth == the admission bound); the job
		 * stays in the registry and unload reaps it */
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "bgapi job %s: result queue full; not reported\n", job->job_uuid);
	}
	switch_atomic_dec(&bg.active);
	return NULL;
}

switch_status_t reprise_commands_bg_start(const char *cmd, const char *arg, const char *server_id,
									  const char *msg_id, const char *from_pid, char *job_uuid, switch_size_t uuid_len)
{
	switch_memory_pool_t *pool = NULL;
	reprise_bgjob_t *job;
	switch_threadattr_t *thd_attr = NULL;

	if (!bg.mutex || zstr(cmd)) return SWITCH_STATUS_FALSE;

	switch_mutex_lock(bg.mutex);
	if (bg.stopping) {
		switch_mutex_unlock(bg.mutex);
		return SWITCH_STATUS_TERM;
	}
	if (bg.n_running >= REPRISE_BG_JOBS_MAX) {
		bg.refused++;
		switch_mutex_unlock(bg.mutex);
		return SWITCH_STATUS_INUSE;
	}
	switch_core_new_memory_pool(&pool);
	job = switch_core_alloc(pool, sizeof(*job));
	job->pool = pool;
	job->started = switch_micro_time_now();
	switch_uuid_str(job->job_uuid, sizeof(job->job_uuid));
	job->cmd = switch_core_strdup(pool, cmd);
	job->arg = switch_core_strdup(pool, switch_str_nil(arg));
	job->server_id = switch_core_strdup(pool, switch_str_nil(server_id));
	job->msg_id = switch_core_strdup(pool, switch_str_nil(msg_id));
	job->from_pid = switch_core_strdup(pool, switch_str_nil(from_pid));
	job->next = bg.running;
	bg.running = job;
	bg.n_running++;
	switch_atomic_inc(&bg.active);
	switch_mutex_unlock(bg.mutex);
	switch_copy_string(job_uuid, job->job_uuid, uuid_len);

	switch_threadattr_create(&thd_attr, pool);
	switch_threadattr_stacksize_set(thd_attr, SWITCH_THREAD_STACKSIZE);
	if (switch_thread_create(&job->thread, thd_attr, bgjob_thread, job, pool) != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "bgapi job %s: cannot start thread, running inline\n", job->job_uuid);
		job->thread = NULL;
		bgjob_thread(NULL, job);
	}
	return SWITCH_STATUS_SUCCESS;
}

/* two-step: an immediate API reply whose Return is "+OK<job-uuid>" (byte
 * identical -- the caller pattern-matches it against the later event),
 * then a BACKGROUND_JOB event once the command has run */
static void handle_bgapi(reprise_worker_t *worker, amqp_connection_state_t state, reprise_req_t *req)
{
	char job_uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
	char ret[SWITCH_UUID_FORMATTED_LENGTH + 4];
	switch_status_t status;

	if (zstr(req->cmd)) {
		send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(0, "-ERR missing API-Command"));
		return;
	}
	status = reprise_commands_bg_start(req->cmd, req->arg, req->server_id, req->msg_id, req->from_pid, job_uuid, sizeof(job_uuid));
	if (status == SWITCH_STATUS_INUSE) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "command: bgapi %s refused: %d jobs already running\n",
						  req->cmd, REPRISE_BG_JOBS_MAX);
		send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(0, "-ERR too many background jobs"));
		return;
	}
	if (status != SWITCH_STATUS_SUCCESS) {
		send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(0, "-ERR shutting down"));
		return;
	}
	worker->bg_jobs++;
	switch_snprintf(ret, sizeof(ret), "+OK%s", job_uuid);
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "command: bgapi %s%s%s (job %s)\n",
					  req->cmd, zstr(req->arg) ? "" : " ", switch_str_nil(req->arg), job_uuid);
	send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(1, ret));
}

/* drain finished bgapi jobs -> BACKGROUND_JOB events (worker thread) */
void reprise_commands_tick(reprise_worker_t *worker, amqp_connection_state_t state)
{
	void *data;

	while (bg.done && switch_queue_trypop(bg.done, &data) == SWITCH_STATUS_SUCCESS) {
		reprise_bgjob_t *job = (reprise_bgjob_t *) data;
		cJSON *fields = cJSON_CreateObject();

		cJSON_AddStringToObject(fields, "Event-Name", "BACKGROUND_JOB");
		cJSON_AddStringToObject(fields, "Job-UUID", job->job_uuid);
		cJSON_AddStringToObject(fields, "Job-Command", job->cmd);
		cJSON_AddStringToObject(fields, "Job-Command-Arg", job->arg);
		cJSON_AddStringToObject(fields, "Job-Result", job->ok ? "bgok" : "bgerror");
		cJSON_AddStringToObject(fields, "Job-Return", switch_str_nil(job->result));
		send_reply(worker, state, job->server_id, job->msg_id, job->from_pid, fields);
		bgjob_reap(job);
	}
}

static void handle_json_api(reprise_worker_t *worker, amqp_connection_state_t state, reprise_req_t *req)
{
	const char *cmd = jstr(req->payload, "command");
	cJSON *fields = cJSON_CreateObject();
	cJSON *response = NULL;

	cJSON_AddStringToObject(fields, "Event-Name", "json_api.reply");

	if (zstr(cmd)) {
		cJSON_AddStringToObject(fields, "status", "error");
		cJSON_AddStringToObject(fields, "message", "missing Payload.command");
	} else if (!strcasecmp(cmd, "node.info")) {
		response = reprise_node_info_json();
	} else {
		/* Payload is already the switch's json_api shape: {command, data} */
		cJSON *request = cJSON_Duplicate(req->payload, 1);
		if (!cJSON_GetObjectItem(request, "data")) {
			cJSON_AddStringToObject(request, "data", "");
		}
		if (switch_json_api_execute(request, NULL, &response) != SWITCH_STATUS_SUCCESS) {
			const char *message = jstr(request, "message");
			if (response) {
				cJSON_Delete(response);
				response = NULL;
			}
			cJSON_AddStringToObject(fields, "status", "error");
			cJSON_AddStringToObject(fields, "message", message ? message : "command failed");
		}
		cJSON_Delete(request);
	}

	if (response) {
		cJSON_AddStringToObject(fields, "status", "success");
		cJSON_AddItemToObject(fields, "response", response);
	}

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "command: json_api %s -> %s\n",
					  switch_str_nil(cmd), response ? "success" : "error");
	send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, fields);
}

/*---------------------------------------------------------------------------
 * call control: sendevent / sendmsg / command / commands -- the JSON
 * objects become event headers exactly as mod_kazoo builds them from
 * Erlang proplists, and land on the session's private event queue
 *-------------------------------------------------------------------------*/

static void json_to_headers(cJSON *obj, switch_event_t *event)
{
	cJSON *item;
	for (item = obj ? obj->child : NULL; item; item = item->next) {
		char *raw = NULL;
		const char *value = NULL;
		char num[64];

		if (!item->string) continue;
		switch (item->type) {
		case cJSON_String: value = item->valuestring; break;
		case cJSON_True: value = "true"; break;
		case cJSON_False: value = "false"; break;
		case cJSON_Number:
			if (item->valuedouble == (double) item->valueint) {
				switch_snprintf(num, sizeof(num), "%d", item->valueint);
			} else {
				switch_snprintf(num, sizeof(num), "%g", item->valuedouble);
			}
			value = num;
			break;
		case cJSON_NULL: continue;
		default: value = raw = cJSON_PrintUnformatted(item); break;
		}
		if (value) {
			switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, item->string, value);
		}
		switch_safe_free(raw);
	}
}

static void log_call_command(const char *kind, const char *uuid, switch_event_t *event)
{
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "command: %s %s call-command=%s app=%s arg=%.80s\n",
					  kind, uuid, switch_event_get_header_nil(event, "call-command"),
					  switch_event_get_header_nil(event, "execute-app-name"),
					  switch_event_get_header_nil(event, "execute-app-arg"));
}

/* The Erlang sendevent API carries the event body in Headers/body. Keep
 * its header representation for compatibility, but populate the native
 * body that event consumers such as mod_sofia actually read. This belongs
 * to sendevent, not the shared converter used for channel commands. */
static void sendevent_headers(cJSON *headers, switch_event_t *event)
{
	cJSON *body = headers ? cJSON_GetObjectItem(headers, "body") : NULL;
	json_to_headers(headers, event);
	if (body && body->type == cJSON_String && body->valuestring) {
		switch_event_add_body(event, "%s", body->valuestring);
	}
}

/* Fire-Event-Name (+ Fire-Event-Subclass for CUSTOM) with Headers, fired
 * into the switch; with a Call-ID the channel's data is attached first */
static void handle_sendevent(reprise_worker_t *worker, amqp_connection_state_t state, reprise_req_t *req, cJSON *json)
{
	const char *name = jstr(json, "Fire-Event-Name");
	const char *subclass = jstr(json, "Fire-Event-Subclass");
	const char *call_id = jstr(json, "Call-ID");
	switch_event_types_t type;
	switch_event_t *event = NULL;
	switch_core_session_t *session;

	if (zstr(name) || switch_name_event(name, &type) != SWITCH_STATUS_SUCCESS) {
		send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(0, "-ERR unknown event name"));
		return;
	}
	if (type == SWITCH_EVENT_CUSTOM) {
		switch_event_create_subclass(&event, type, switch_str_nil(subclass));
	} else {
		switch_event_create(&event, type);
	}
	if (!event) {
		send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(0, "-ERR cannot create event"));
		return;
	}
	if (!zstr(call_id) && (session = switch_core_session_locate(call_id))) {
		switch_channel_event_set_data(switch_core_session_get_channel(session), event);
		switch_core_session_rwunlock(session);
	}
	sendevent_headers(cJSON_GetObjectItem(json, "Headers"), event);
	if (type == SWITCH_EVENT_NOTIFY) {
		/* ecallmgr_fs_notify's contact form (reprise_compat.c) */
		char *fixed = kz_notify_contact_compat(switch_event_get_header(event, "contact-uri"));
		if (fixed) {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "compat NOTIFY contact-uri: %s -> %s\n",
							  switch_event_get_header_nil(event, "contact-uri"), fixed);
			switch_event_del_header(event, "contact-uri");
			switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "contact-uri", fixed);
			free(fixed);
		}
	}
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "command: sendevent %s%s%s\n", name,
					  zstr(subclass) ? "" : " ", switch_str_nil(subclass));
	switch_event_fire(&event);
	send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(1, "+OK"));
}

/* xferext: the core takes `application` headers valued "app data"; app
 * data in the fork's forms (reprise_compat.c) is rewritten, with a multiset
 * of the app's variables inserted ahead of it */
static void expand_xferext_apps(switch_event_t **eventp)
{
	switch_event_t *event = *eventp, *copy = NULL;
	switch_event_header_t *hp;

	switch_event_create(&copy, event->event_id);
	for (hp = event->headers; hp; hp = hp->next) {
		char *pre = NULL, *out = NULL;
		const char *data = NULL;
		if (!strcasecmp(hp->name, "application") && (data = strchr(switch_str_nil(hp->value), ' '))) {
			char *app = switch_mprintf("%.*s", (int) (data - hp->value), hp->value);
			while (*data == ' ') data++;
			if (kz_app_compat(app, data, &pre, &out)) {
				char *value;
				if (pre) {
					value = switch_mprintf("multiset %s", pre);
					switch_event_add_header_string(copy, SWITCH_STACK_BOTTOM, "application", value);
					free(value);
				}
				value = switch_mprintf("%s %s", app, out);
				switch_event_add_header_string(copy, SWITCH_STACK_BOTTOM, "application", value);
				free(value);
				free(app);
				switch_safe_free(pre);
				switch_safe_free(out);
				continue;
			}
			free(app);
		}
		switch_event_add_header_string(copy, SWITCH_STACK_BOTTOM, hp->name, hp->value);
	}
	switch_event_destroy(eventp);
	*eventp = copy;
}

/* Headers -> SEND_MESSAGE on the call's private queue */
static void handle_sendmsg(reprise_worker_t *worker, amqp_connection_state_t state, reprise_req_t *req, cJSON *json)
{
	const char *call_id = jstr(json, "Call-ID");
	switch_core_session_t *session;
	switch_event_t *event = NULL;

	if (zstr(call_id) || !(session = switch_core_session_locate(call_id))) {
		send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(0, "-ERR no such channel"));
		return;
	}
	switch_event_create(&event, SWITCH_EVENT_SEND_MESSAGE);
	json_to_headers(cJSON_GetObjectItem(json, "Headers"), event);
	if (!strcasecmp(switch_event_get_header_nil(event, "call-command"), "xferext")) {
		expand_xferext_apps(&event);
	}
	log_call_command("sendmsg", call_id, event);
	switch_core_session_queue_private_event(session, &event, SWITCH_FALSE);
	switch_core_session_rwunlock(session);
	send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(1, "+OK"));
}

/* Command (one) / Commands (a batch) -> COMMAND events on the call's
 * private queue; the reply carries the event-uuid the last one was
 * tagged with (the others are tagged "null"), and Execute-Now queues
 * them with priority */
static void handle_command(reprise_worker_t *worker, amqp_connection_state_t state, reprise_req_t *req, cJSON *json, int batch)
{
	const char *call_id = jstr(json, "Call-ID");
	cJSON *now = cJSON_GetObjectItem(json, "Execute-Now");
	cJSON *cmds = cJSON_GetObjectItem(json, batch ? "Commands" : "Command");
	switch_bool_t priority = (now && now->type == cJSON_True) ? SWITCH_TRUE : SWITCH_FALSE;
	switch_core_session_t *session;
	char cmd_uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
	char ret[SWITCH_UUID_FORMATTED_LENGTH + 4];
	cJSON *item;
	int n = 0, total = 0;

	if (zstr(call_id) || !(session = switch_core_session_locate(call_id))) {
		send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(0, "-ERR no such channel"));
		return;
	}
	if (!cmds || (batch && cmds->type != cJSON_Array) || (!batch && cmds->type != cJSON_Object)) {
		switch_core_session_rwunlock(session);
		send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(0, "-ERR missing Command"));
		return;
	}
	switch_uuid_str(cmd_uuid, sizeof(cmd_uuid));

	if (batch) {
		for (item = cmds->child; item; item = item->next) total++;
	} else {
		total = 1;
	}
	for (item = batch ? cmds->child : cmds; item; item = batch ? item->next : NULL) {
		switch_event_t *event = NULL;
		const char *app = jstr(item, "execute-app-name");
		char *pre = NULL, *out = NULL;
		switch_event_create(&event, SWITCH_EVENT_COMMAND);
		json_to_headers(item, event);
		/* the fork's app-data forms (reprise_compat.c): a multiset of the
		 * app's variables goes first, as its own command */
		if (app && kz_app_compat(app, jstr(item, "execute-app-arg"), &pre, &out)) {
			if (pre) {
				switch_event_t *setter = NULL;
				switch_event_create(&setter, SWITCH_EVENT_COMMAND);
				switch_event_add_header_string(setter, SWITCH_STACK_BOTTOM, "call-command", "execute");
				switch_event_add_header_string(setter, SWITCH_STACK_BOTTOM, "execute-app-name", "multiset");
				switch_event_add_header_string(setter, SWITCH_STACK_BOTTOM, "execute-app-arg", pre);
				switch_event_add_header_string(setter, SWITCH_STACK_BOTTOM, "event-uuid", "null");
				switch_core_session_queue_private_event(session, &setter, priority);
			}
			switch_event_del_header(event, "execute-app-arg");
			switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "execute-app-arg", out);
			switch_safe_free(pre);
			switch_safe_free(out);
		}
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "event-uuid", (++n == total) ? cmd_uuid : "null");
		log_call_command(batch ? "commands" : "command", call_id, event);
		switch_core_session_queue_private_event(session, &event, priority);
	}
	switch_core_session_rwunlock(session);

	switch_snprintf(ret, sizeof(ret), "+OK%s", cmd_uuid);
	send_reply(worker, state, req->server_id, req->msg_id, req->from_pid, api_reply(1, ret));
}

void reprise_commands_dispatch(reprise_worker_t *worker, amqp_connection_state_t state, amqp_envelope_t *envelope)
{
	char *body;
	cJSON *json;
	reprise_req_t req;

	if (envelope->message.body.len > REPRISE_MAX_COMMAND_BYTES) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
						  "worker[%s] command of %" SWITCH_SIZE_T_FMT " bytes exceeds the %d byte cap; dropped\n",
						  worker->name, (switch_size_t) envelope->message.body.len, REPRISE_MAX_COMMAND_BYTES);
		return;
	}
	if (!(body = malloc(envelope->message.body.len + 1))) {
		return;
	}
	memcpy(body, envelope->message.body.bytes, envelope->message.body.len);
	body[envelope->message.body.len] = '\0';
	json = cJSON_Parse(body);
	free(body);

	if (!json) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING,
						  "worker[%s] undecodable command (%" SWITCH_SIZE_T_FMT " bytes)\n",
						  worker->name, (switch_size_t) envelope->message.body.len);
		return;
	}

	memset(&req, 0, sizeof(req));
	req.event = jstr(json, "Event-Name");
	req.server_id = jstr(json, "Server-ID");
	req.msg_id = jstr(json, "Msg-ID");
	req.from_pid = jstr(json, "Request-From-PID");
	req.cmd = jstr(json, "API-Command");
	req.arg = jstr(json, "API-Arguments");
	req.payload = cJSON_GetObjectItem(json, "Payload");

	if (zstr(req.event)) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "worker[%s] command without Event-Name\n", worker->name);
	} else if (!strcasecmp(req.event, "version")) {
		handle_version(worker, state, &req);
	} else if (!strcasecmp(req.event, "api")) {
		handle_api(worker, state, &req);
	} else if (!strcasecmp(req.event, "bgapi")) {
		handle_bgapi(worker, state, &req);
	} else if (!strcasecmp(req.event, "json_api")) {
		handle_json_api(worker, state, &req);
	} else if (!strcasecmp(req.event, "sendevent")) {
		handle_sendevent(worker, state, &req, json);
	} else if (!strcasecmp(req.event, "sendmsg")) {
		handle_sendmsg(worker, state, &req, json);
	} else if (!strcasecmp(req.event, "command")) {
		handle_command(worker, state, &req, json, 0);
	} else if (!strcasecmp(req.event, "commands")) {
		handle_command(worker, state, &req, json, 1);
	} else if (!strcasecmp(req.event, "config")) {
		/* mod_com_kazoo:config/1 -- a cast (kapi_freeswitch:publish_config
		 * returns ok, nothing waits): fetch kazoo.conf again; a changed
		 * document restarts the workers from the new snapshot. Section is
		 * optional and unused: the whole document is one fetch. */
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "command: config%s%s -> kazoo.conf refetch requested\n",
						  jstr(json, "Section") ? " section=" : "", switch_str_nil(jstr(json, "Section")));
		reprise_config_refetch();
	} else {
		/* anything newer than this contract */
		char *err = switch_mprintf("-ERR %s not implemented", req.event);
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "worker[%s] unhandled command family %s\n",
						  worker->name, req.event);
		send_reply(worker, state, req.server_id, req.msg_id, req.from_pid, api_reply(0, err));
		free(err);
	}

	cJSON_Delete(json);
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
