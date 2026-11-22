/*
 * reprise_originate.c -- the kz_originate API family ecallmgr drives every
 * Kazoo-initiated originate through (ecallmgr_originate:
 * `async_api kz_originate "<originate-uuid> <dial string> <exten>|&app(args)
 * [dialplan] [context] [cid name] [cid number] [timeout]"`), with the
 * cancel and list companions. The originate uuid names the attempt so
 * `kz_originate_cancel <uuid> [cause]` can abort it while it rings; the
 * reply is `+OK <channel uuid>`.
 *
 * Ported from the community mod_kazoo's kazoo_commands.c (2600hz, MPL 1.1)
 * as shipped in the freeswitch-kazoo 20.23.6 package, onto the stock core:
 * the fork's CF_NO_FLIP (keep the originated leg's caller id unflipped)
 * has no stock equivalent and is dropped, as is the loopback
 * call-forward / failover walk (`kz_cfwd_active` / `kz_failover_active`
 * are never set by Kazoo 5.4). The enterprise (`:_:`) dial-string variant
 * is left to the stock core's own handling.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * Portions derived from mod_kazoo's kazoo_commands.c, distributed under
 * the Mozilla Public License 1.1; Copyright (C) 2005-2012, Anthony
 * Minessale II <anthm@freeswitch.org>. Contributor(s) named in that file:
 * Karl Anderson <karl@2600hz.com>, Darren Schreiber <darren@2600hz.com>.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise_kz.h"

/* the cancel cause of an attempt is read by switch_ivr_originate's poll
 * loop for as long as the attempt runs: it is freed only by the API call
 * that registered it (kz_remove_originate_uuid), never by unload */
static struct {
	switch_hash_t *hash;          /* originate uuid -> malloc'd cancel cause */
	switch_memory_pool_t *pool;
	switch_mutex_t *mutex;
	int started;
	int stopping; /* unload began: no new attempts, running ones cancelled */
} originates;

/* register an attempt; NULL when the uuid is already in flight or the
 * module is unloading */
switch_call_cause_t *kz_add_originate_uuid(const char *uuid)
{
	switch_call_cause_t *cancel;

	if (!originates.started || originates.stopping || zstr(uuid)) return NULL;
	switch_mutex_lock(originates.mutex);
	if (originates.stopping || switch_core_hash_find(originates.hash, uuid)) {
		switch_mutex_unlock(originates.mutex);
		return NULL;
	}
	if (!(cancel = malloc(sizeof(*cancel)))) {
		switch_mutex_unlock(originates.mutex);
		return NULL;
	}
	*cancel = 0;
	switch_core_hash_insert(originates.hash, uuid, cancel);
	switch_mutex_unlock(originates.mutex);
	return cancel;
}

switch_status_t kz_remove_originate_uuid(const char *uuid)
{
	switch_call_cause_t *cancel;

	if (!originates.started || zstr(uuid)) return SWITCH_STATUS_GENERR;
	switch_mutex_lock(originates.mutex);
	if (!(cancel = switch_core_hash_find(originates.hash, uuid))) {
		switch_mutex_unlock(originates.mutex);
		return SWITCH_STATUS_GENERR;
	}
	switch_core_hash_delete(originates.hash, uuid);
	switch_mutex_unlock(originates.mutex);
	free(cancel);
	return SWITCH_STATUS_SUCCESS;
}

/* set the cancel cause of an attempt in flight */
switch_status_t kz_cancel_originate_uuid(const char *uuid, switch_call_cause_t cause)
{
	switch_call_cause_t *cancel;

	if (!originates.started || zstr(uuid)) return SWITCH_STATUS_GENERR;
	switch_mutex_lock(originates.mutex);
	if (!(cancel = switch_core_hash_find(originates.hash, uuid))) {
		switch_mutex_unlock(originates.mutex);
		return SWITCH_STATUS_GENERR;
	}
	*cancel = cause;
	switch_mutex_unlock(originates.mutex);
	return SWITCH_STATUS_SUCCESS;
}

int kz_originate_count(void)
{
	switch_hash_index_t *hi;
	int n = 0;

	if (!originates.started) return 0;
	switch_mutex_lock(originates.mutex);
	for (hi = switch_core_hash_first(originates.hash); hi; hi = switch_core_hash_next(&hi)) n++;
	switch_mutex_unlock(originates.mutex);
	return n;
}

#define KZ_ORIGINATE_SYNTAX "<originate_uuid> <call url> <exten>|&<application_name>(<app_args>) [<dialplan>] [<context>] [<cid_name>] [<cid_num>] [<timeout_sec>]"
SWITCH_STANDARD_API(kz_originate_function)
{
	switch_channel_t *caller_channel;
	switch_core_session_t *caller_session = NULL;
	char *mycmd = NULL, *argv[10] = { 0 };
	int i = 0, x, argc = 0;
	char *uuid, *aleg, *exten, *dp, *context, *cid_name, *cid_num;
	uint32_t timeout = 60;
	switch_call_cause_t cause = SWITCH_CAUSE_NORMAL_CLEARING;
	switch_call_cause_t *cancel_cause = NULL;
	switch_status_t originate_status;

	if (zstr(cmd)) {
		stream->write_function(stream, "-USAGE: %s\n", KZ_ORIGINATE_SYNTAX);
		return SWITCH_STATUS_SUCCESS;
	}
	if (session) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_NOTICE,
						  "Originate can take 60 seconds to complete, and blocks the existing session. Do not confuse with a lockup.\n");
	}

	mycmd = strdup(cmd);
	switch_assert(mycmd);
	argc = kz_switch_separate_string(mycmd, ' ', argv, (sizeof(argv) / sizeof(argv[0])));
	if (argc < 3 || argc > 8) {
		stream->write_function(stream, "-USAGE: %s\n", KZ_ORIGINATE_SYNTAX);
		goto done;
	}
	for (x = 0; x < argc && argv[x]; x++) {
		if (!strcasecmp(argv[x], "undef")) argv[x] = NULL;
	}

	uuid = argv[i++];
	if (!(cancel_cause = kz_add_originate_uuid(uuid))) {
		stream->write_function(stream, "-ERR duplicate originate_uuid %s\n", switch_str_nil(uuid));
		goto done;
	}

	aleg = argv[i++];
	exten = kz_cleanup_separated_string(argv[i++], 0);
	dp = kz_cleanup_separated_string(argv[i++], 0);
	context = kz_cleanup_separated_string(argv[i++], 0);
	cid_name = kz_cleanup_separated_string(argv[i++], 0);
	cid_num = kz_cleanup_separated_string(argv[i++], 0);
	if (zstr(aleg) || zstr(exten)) {
		/* "undef" in either position is a malformed command, not a reason
		 * to abort the switch (the port asserted here) */
		kz_remove_originate_uuid(uuid);
		stream->write_function(stream, "-USAGE: %s\n", KZ_ORIGINATE_SYNTAX);
		goto done;
	}
	if (!dp) dp = "XML";
	if (!context) context = "default";
	if (argv[7]) timeout = (uint32_t) atoi(argv[7]);

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "kz_originate %s: %s -> %s (%us)\n", uuid, aleg, exten, timeout);
	originate_status = switch_ivr_originate(NULL, &caller_session, &cause, aleg, timeout, NULL, cid_name, cid_num,
											NULL, NULL, SOF_NONE, cancel_cause, NULL);
	kz_remove_originate_uuid(uuid);

	if (originate_status != SWITCH_STATUS_SUCCESS || !caller_session) {
		stream->write_function(stream, "-ERR %s\n", switch_channel_cause2str(cause));
		goto done;
	}

	caller_channel = switch_core_session_get_channel(caller_session);
	if (*exten == '&' && *(exten + 1)) {
		switch_caller_extension_t *extension = NULL;
		char *app_name = switch_core_session_strdup(caller_session, (exten + 1));
		char *arg = NULL, *e;

		if ((e = strchr(app_name, ')'))) *e = '\0';
		if ((arg = strchr(app_name, '('))) *arg++ = '\0';
		if (!(extension = switch_caller_extension_new(caller_session, app_name, arg))) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(caller_session), SWITCH_LOG_CRIT, "Memory Error!\n");
			abort();
		}
		switch_caller_extension_add_application(caller_session, extension, app_name, arg);
		switch_channel_set_caller_extension(caller_channel, extension);
		switch_channel_set_state(caller_channel, CS_EXECUTE);
	} else {
		switch_ivr_session_transfer(caller_session, exten, dp, context);
	}

	stream->write_function(stream, "+OK %s\n", switch_core_session_get_uuid(caller_session));
	switch_core_session_rwunlock(caller_session);

  done:
	switch_safe_free(mycmd);
	return SWITCH_STATUS_SUCCESS;
}

#define KZ_ORIGINATE_CANCEL_SYNTAX "<originate_uuid> [<reason>]"
SWITCH_STANDARD_API(kz_originate_cancel_function)
{
	char *mycmd = NULL, *argv[10] = { 0 };
	int argc;
	switch_call_cause_t cause = SWITCH_CAUSE_ORIGINATOR_CANCEL;

	if (zstr(cmd)) {
		stream->write_function(stream, "-USAGE: %s\n", KZ_ORIGINATE_CANCEL_SYNTAX);
		return SWITCH_STATUS_SUCCESS;
	}
	mycmd = strdup(cmd);
	switch_assert(mycmd);
	argc = kz_switch_separate_string(mycmd, ' ', argv, (sizeof(argv) / sizeof(argv[0])));
	if (argc < 1 || argc > 2) {
		stream->write_function(stream, "-USAGE: %s\n", KZ_ORIGINATE_CANCEL_SYNTAX);
		goto done;
	}
	if (argv[1]) cause = switch_channel_str2cause(argv[1]);
	if (kz_cancel_originate_uuid(argv[0], cause) != SWITCH_STATUS_SUCCESS) {
		stream->write_function(stream, "-ERR unknown originate_uuid %s\n", argv[0]);
		goto done;
	}
	stream->write_function(stream, "+OK sent cancel to originate_uuid %s\n", argv[0]);

  done:
	switch_safe_free(mycmd);
	return SWITCH_STATUS_SUCCESS;
}

SWITCH_STANDARD_API(kz_originate_list_function)
{
	switch_hash_index_t *hi;
	const void *key;
	void *val;

	int n = 0;

	if (!originates.started) return SWITCH_STATUS_SUCCESS;
	switch_mutex_lock(originates.mutex);
	for (hi = switch_core_hash_first(originates.hash); hi; hi = switch_core_hash_next(&hi)) {
		switch_core_hash_this(hi, &key, NULL, &val);
		stream->write_function(stream, "%s\n", (const char *) key);
		n++;
	}
	switch_mutex_unlock(originates.mutex);
	/* an empty reply reads as "-ERR no reply" on fs_cli */
	if (!n) stream->write_function(stream, "+OK 0 originates\n");
	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t list_originates_complete(const char *line, const char *cursor, switch_console_callback_match_t **matches)
{
	switch_console_callback_match_t *my_matches = NULL;
	switch_hash_index_t *hi;
	const void *key;
	void *val;

	if (!originates.started) return SWITCH_STATUS_FALSE;
	switch_mutex_lock(originates.mutex);
	for (hi = switch_core_hash_first(originates.hash); hi; hi = switch_core_hash_next(&hi)) {
		switch_core_hash_this(hi, &key, NULL, &val);
		switch_console_push_match(&my_matches, (const char *) key);
	}
	switch_mutex_unlock(originates.mutex);
	if (!my_matches) return SWITCH_STATUS_FALSE;
	*matches = my_matches;
	return SWITCH_STATUS_SUCCESS;
}

void kz_originate_init(void)
{
	if (originates.started) return;
	switch_core_new_memory_pool(&originates.pool);
	switch_core_hash_init_case(&originates.hash, SWITCH_FALSE);
	switch_mutex_init(&originates.mutex, SWITCH_MUTEX_NESTED, originates.pool);
	originates.stopping = 0;
	originates.started = 1;
}

/* unload: close admission, cancel every attempt in flight (its
 * switch_ivr_originate returns within its poll interval) and wait up to
 * max_wait_ms for them to unregister. Whatever is still running after
 * that keeps the registry: freeing a cancel cause under a live originate
 * is a use-after-free, a leaked registry is not. The core's interface
 * refcount holds an ordinary unload while a kz_originate API call is in
 * progress; this covers forced and global shutdown. */
void kz_originate_shutdown_wait(int max_wait_ms)
{
	switch_hash_index_t *hi;
	const void *key;
	void *val;
	int left, waited = 0;

	if (!originates.started) return;
	switch_mutex_lock(originates.mutex);
	originates.stopping = 1;
	for (hi = switch_core_hash_first(originates.hash); hi; hi = switch_core_hash_next(&hi)) {
		switch_call_cause_t *cancel;
		switch_core_hash_this(hi, &key, NULL, &val);
		cancel = (switch_call_cause_t *) val;
		if (!*cancel) *cancel = SWITCH_CAUSE_ORIGINATOR_CANCEL;
	}
	switch_mutex_unlock(originates.mutex);

	while ((left = kz_originate_count()) && waited < max_wait_ms) {
		switch_yield(50000);
		waited += 50;
	}
	if (left) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
						  "%d originate(s) still in flight after %dms; their registry is kept (leaked), not freed under them\n",
						  left, waited);
		return;
	}
	switch_mutex_lock(originates.mutex);
	originates.started = 0;
	switch_core_hash_destroy(&originates.hash);
	switch_mutex_unlock(originates.mutex);
	switch_core_destroy_memory_pool(&originates.pool);
}

void kz_originate_shutdown(void)
{
	/* the completion callback lives in this module's code and the core's
	 * table is process-lifetime: a tab-completion after unload would call
	 * into unmapped memory (mod_sofia deletes its functions the same way) */
	switch_console_set_complete("del kz_originate_cancel ::reprise::list_originate_uuid");
	switch_console_del_complete_func("::reprise::list_originate_uuid");
	kz_originate_shutdown_wait(10000);
}

void reprise_kz_originate_add(switch_loadable_module_interface_t **module_interface)
{
	switch_api_interface_t *api_interface = NULL;

	kz_originate_init();
	SWITCH_ADD_API(api_interface, "kz_originate", "Originate a call", kz_originate_function, KZ_ORIGINATE_SYNTAX);
	SWITCH_ADD_API(api_interface, "kz_originate_cancel", "Cancel an originate", kz_originate_cancel_function, KZ_ORIGINATE_CANCEL_SYNTAX);
	SWITCH_ADD_API(api_interface, "kz_originate_list", "List originates in flight", kz_originate_list_function, "");
	switch_console_add_complete_func("::reprise::list_originate_uuid", list_originates_complete);
	switch_console_set_complete("add kz_originate_cancel ::reprise::list_originate_uuid");
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
