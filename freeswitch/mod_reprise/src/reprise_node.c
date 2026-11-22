/*
 * reprise_node.c -- node identity and the JSON that describes this switch to
 * Kazoo: the kz_nodes advertise/heartbeat (published on the `nodes` fanout
 * from the nodes worker) and the `json_api node.info` response (the shape
 * mod_kazoo's kz_node.c produces, which ecallmgr_fs_node reads for
 * Runtime-Info / Modules / Roles.Media.profiles).
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>

/* freeswitch@<hostname -f>: gethostname, then the resolver's canonical
 * name for it (what `hostname -f` prints). The node name is the switch's
 * identity everywhere in Kazoo (kz_nodes, event Node fields, fetches), so
 * it must be stable and match what the rest of the cluster resolves. */
char *reprise_default_node_name(switch_memory_pool_t *pool, const char *nodename, int shortname)
{
	char host[256] = "";
	char fqdn[512] = "";
	struct addrinfo hints, *res = NULL;

	if (gethostname(host, sizeof(host) - 1) || zstr(host)) {
		switch_copy_string(host, "localhost", sizeof(host));
	}
	if (shortname) { /* shortname=true: erlang short names, host without domain */
		char *dot = strchr(host, '.');
		if (dot) *dot = '\0';
		return switch_core_sprintf(pool, "%s@%s", switch_str_nil(nodename), host);
	}

	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_flags = AI_CANONNAME;
	if (!getaddrinfo(host, NULL, &hints, &res) && res) {
		if (!zstr(res->ai_canonname)) {
			switch_copy_string(fqdn, res->ai_canonname, sizeof(fqdn));
		}
		freeaddrinfo(res);
	}
	if (zstr(fqdn)) {
		switch_copy_string(fqdn, host, sizeof(fqdn));
	}

	return switch_core_sprintf(pool, "%s@%s", zstr(nodename) ? "freeswitch" : nodename, fqdn);
}

static int module_name_callback(void *arg, const char *module_name)
{
	if (!strstr(module_name, "CORE")) {
		cJSON_AddItemToArray((cJSON *) arg, cJSON_CreateString(module_name));
	}
	return 0;
}

static int array_has_string(cJSON *array, const char *s)
{
	cJSON *item;
	for (item = array ? array->child : NULL; item; item = item->next) {
		if (item->type == cJSON_String && item->valuestring && !strcmp(item->valuestring, s)) {
			return 1;
		}
	}
	return 0;
}

/* {"loaded": [...], "available": [...]} from the loadable-module API.
 * claim_sofia: the advertise lists mod_sofia even before it is loaded --
 * mod_com_kazoo_monitor runs its node-start command batch whenever
 * mod_sofia is absent from the heartbeat's Modules.loaded, and the node
 * comes up without that batch. */
static cJSON *modules_json(int claim_sofia)
{
	cJSON *modules = cJSON_CreateObject();
	cJSON *loaded = cJSON_CreateArray();
	cJSON *available = cJSON_CreateArray();

	switch_loadable_module_enumerate_loaded(module_name_callback, loaded);
	switch_loadable_module_enumerate_available(SWITCH_GLOBAL_dirs.mod_dir, module_name_callback, available);

	if (claim_sofia && !array_has_string(loaded, "mod_sofia")) {
		cJSON_AddItemToArray(loaded, cJSON_CreateString("mod_sofia"));
	}

	cJSON_AddItemToObject(modules, "loaded", loaded);
	cJSON_AddItemToObject(modules, "available", available);
	return modules;
}

/* the `status` json_api shape from mod_commands, built from the core
 * directly so it does not depend on mod_commands being loaded, plus
 * Core-UUID (what ecallmgr keys the node on) */
static cJSON *runtime_info_json(void)
{
	cJSON *info = cJSON_CreateObject(), *o, *oo;
	switch_core_time_duration_t duration = {0};
	int sps = 0, last_sps = 0, max_sps = 0, max_sps_fivemin = 0;
	int sessions_peak = 0, sessions_peak_fivemin = 0;

	switch_core_measure_time(switch_core_uptime(), &duration);
	switch_core_session_ctl(SCSC_SESSIONS_PEAK, &sessions_peak);
	switch_core_session_ctl(SCSC_SESSIONS_PEAK_FIVEMIN, &sessions_peak_fivemin);
	switch_core_session_ctl(SCSC_LAST_SPS, &last_sps);
	switch_core_session_ctl(SCSC_SPS, &sps);
	switch_core_session_ctl(SCSC_SPS_PEAK, &max_sps);
	switch_core_session_ctl(SCSC_SPS_PEAK_FIVEMIN, &max_sps_fivemin);

	cJSON_AddStringToObject(info, "Core-UUID", reprise_globals.core_uuid);
	cJSON_AddStringToObject(info, "systemStatus", switch_core_ready() ? "ready" : "not ready");

	o = cJSON_CreateObject();
	cJSON_AddNumberToObject(o, "years", duration.yr);
	cJSON_AddNumberToObject(o, "days", duration.day);
	cJSON_AddNumberToObject(o, "hours", duration.hr);
	cJSON_AddNumberToObject(o, "minutes", duration.min);
	cJSON_AddNumberToObject(o, "seconds", duration.sec);
	cJSON_AddNumberToObject(o, "milliseconds", duration.ms);
	cJSON_AddNumberToObject(o, "microseconds", duration.mms);
	cJSON_AddItemToObject(info, "uptime", o);

	cJSON_AddStringToObject(info, "version", switch_version_full_human());

	o = cJSON_CreateObject();
	oo = cJSON_CreateObject();
	cJSON_AddNumberToObject(oo, "total", (double) (switch_core_session_id() - 1));
	cJSON_AddNumberToObject(oo, "active", switch_core_session_count());
	cJSON_AddNumberToObject(oo, "peak", sessions_peak);
	cJSON_AddNumberToObject(oo, "peak5Min", sessions_peak_fivemin);
	cJSON_AddNumberToObject(oo, "limit", switch_core_session_limit(0));
	cJSON_AddItemToObject(o, "count", oo);
	oo = cJSON_CreateObject();
	cJSON_AddNumberToObject(oo, "current", last_sps);
	cJSON_AddNumberToObject(oo, "max", sps);
	cJSON_AddNumberToObject(oo, "peak", max_sps);
	cJSON_AddNumberToObject(oo, "peak5Min", max_sps_fivemin);
	cJSON_AddItemToObject(o, "rate", oo);
	cJSON_AddItemToObject(info, "sessions", o);

	return info;
}

/* Roles.Media = mod_sofia's `sofia.status.info` json_api when it is
 * loaded, else an empty profile map (ecallmgr_fs_node reads
 * Roles.Media.profiles.<name>.info.{url,ext-sip-ip}) */
static cJSON *roles_json(void)
{
	cJSON *roles = cJSON_CreateObject();
	cJSON *media = NULL, *ret = NULL;
	cJSON *req = cJSON_CreateObject();

	cJSON_AddStringToObject(req, "command", "sofia.status.info");
	cJSON_AddStringToObject(req, "data", "");
	if (switch_json_api_execute(req, NULL, &ret) == SWITCH_STATUS_SUCCESS && ret && !cJSON_IsNull(ret)) {
		media = ret;
		ret = NULL;
	}
	if (ret) {
		cJSON_Delete(ret);
	}
	cJSON_Delete(req);

	if (!media) {
		media = cJSON_CreateObject();
		cJSON_AddItemToObject(media, "profiles", cJSON_CreateObject());
	}
	cJSON_AddItemToObject(roles, "Media", media);
	return roles;
}

static cJSON *whapps_json(void)
{
	cJSON *apps = cJSON_CreateObject();
	cJSON *app = cJSON_CreateObject();

	/* kz_nodes converts the freeswitch kapp's Startup from unix seconds */
	cJSON_AddNumberToObject(app, "Startup", (double) reprise_globals.startup_epoch);
	cJSON_AddNumberToObject(app, "Uptime", (double) (switch_core_uptime() / 1000000));
	cJSON_AddItemToObject(apps, "freeswitch", app);
	return apps;
}

cJSON *reprise_node_info_json(void)
{
	cJSON *node = cJSON_CreateObject();

	cJSON_AddItemToObject(node, "WhApps", whapps_json());
	cJSON_AddItemToObject(node, "Runtime-Info", runtime_info_json());
	cJSON_AddItemToObject(node, "Modules", modules_json(0));
	cJSON_AddItemToObject(node, "Roles", roles_json());
	return node;
}

/* resident set + thread count from /proc (Linux); zeros elsewhere */
static void process_stats(uint64_t *rss_bytes, int *threads)
{
	FILE *fp = fopen("/proc/self/status", "r");
	char line[256];

	*rss_bytes = 0;
	*threads = 0;
	if (!fp) {
		return;
	}
	while (fgets(line, sizeof(line), fp)) {
		unsigned long long v;
		if (sscanf(line, "VmRSS: %llu kB", &v) == 1) {
			*rss_bytes = (uint64_t) v * 1024;
		} else if (sscanf(line, "Threads: %llu", &v) == 1) {
			*threads = (int) v;
		}
	}
	fclose(fp);
}

/* the kz_nodes advertise. Ingestion needs: Node, Expires (ms), WhApps
 * containing "freeswitch" (that is what makes us a media server),
 * Runtime-Info.Core-UUID, Modules.loaded, Zone matching ecallmgr's local
 * zone, and a Version that parses >= v1.5 */
cJSON *reprise_node_advertise_json(const char *zone)
{
	cJSON *adv = cJSON_CreateObject();
	char msg_id[SWITCH_UUID_FORMATTED_LENGTH + 1];
	char version[128];
	uint64_t rss = 0;
	int threads = 0;

	switch_uuid_str(msg_id, sizeof(msg_id));
	switch_snprintf(version, sizeof(version), "%s.%s.%s (%s)",
					switch_version_major(), switch_version_minor(), switch_version_micro(),
					sizeof(void *) == 8 ? "64bit" : "32bit");
	process_stats(&rss, &threads);

	cJSON_AddStringToObject(adv, "Event-Category", "nodes");
	cJSON_AddStringToObject(adv, "Event-Name", "advertise");
	cJSON_AddStringToObject(adv, "Node", reprise_globals.node_name);
	cJSON_AddNumberToObject(adv, "Expires", REPRISE_ADVERTISE_EXPIRES_MS);
	cJSON_AddItemToObject(adv, "WhApps", whapps_json());
	cJSON_AddItemToObject(adv, "Runtime-Info", runtime_info_json());
	cJSON_AddItemToObject(adv, "Modules", modules_json(1));
	cJSON_AddStringToObject(adv, "Zone", zstr(zone) ? "local" : zone);
	cJSON_AddStringToObject(adv, "Version", version);
	cJSON_AddNumberToObject(adv, "Used-Memory", (double) rss);
	cJSON_AddNumberToObject(adv, "Processes", threads);
	cJSON_AddNumberToObject(adv, "Ports", 0);
	cJSON_AddNumberToObject(adv, "Channels", switch_core_session_count());
	cJSON_AddNumberToObject(adv, "Conferences", 0);
	cJSON_AddNumberToObject(adv, "Registrations", 0);
	cJSON_AddStringToObject(adv, "Msg-ID", msg_id);
	cJSON_AddStringToObject(adv, "App-Name", REPRISE_APP_NAME);
	cJSON_AddStringToObject(adv, "App-Version", REPRISE_APP_VERSION);
	return adv;
}

/* called from the nodes worker's loop (its connection, its thread):
 * heartbeat every advertise_interval_ms. Routing key = node name (a fanout
 * ignores it, but that is what kz_nodes_listener publishes with). */
void reprise_nodes_tick(reprise_worker_t *worker, amqp_connection_state_t state)
{
	switch_time_t now = switch_micro_time_now();
	cJSON *adv;

	if (worker->last_advertise
		&& now - worker->last_advertise < (switch_time_t) reprise_globals.advertise_interval_ms * 1000) {
		return;
	}

	adv = reprise_node_advertise_json(worker->zone);
	if (reprise_amqp_publish_json(state, REPRISE_WORKER_CHANNEL, REPRISE_EXCHANGE_NODES,
							  reprise_globals.node_name, adv) == SWITCH_STATUS_SUCCESS) {
		worker->publishes++;
		switch_log_printf(SWITCH_CHANNEL_LOG, worker->last_advertise ? SWITCH_LOG_DEBUG : SWITCH_LOG_NOTICE,
						  "advertised %s to kz_nodes (zone %s, expires %dms)\n",
						  reprise_globals.node_name, worker->zone, REPRISE_ADVERTISE_EXPIRES_MS);
	}
	worker->last_advertise = now;
	cJSON_Delete(adv);
}

/* the cluster's heartbeats arrive here off the fanout; they are only
 * counted and logged (the module does not track its peers) */
void reprise_nodes_dispatch(reprise_worker_t *worker, amqp_envelope_t *envelope)
{
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG,
					  "worker[%s] kz_nodes delivery %" SWITCH_UINT64_T_FMT " on %.*s (%" SWITCH_SIZE_T_FMT " bytes)\n",
					  worker->name, worker->deliveries,
					  (int) envelope->routing_key.len, (char *) envelope->routing_key.bytes,
					  (switch_size_t) envelope->message.body.len);
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
