/*
 * reprise_prompts.c -- the `prompt://` media scheme. Kazoo 5.4 hands the switch
 * `playback prompt://<account|system_media>/<name>/<lang>` unresolved
 * (ecallmgr_util:media_path passes it through) and expects the switch to
 * turn it into a playable URL. This is a `prompt` file interface: open()
 * asks Kazoo for the prompt with a configuration fetch of tag `prompt`
 * (`ecallmgr_fs_fetch_configuration_prompt` answers `<prompt path=".."
 * value="<url>"/>`), caches the answer for five minutes and delegates the
 * handle to the core's file API on `http_cache://<url>` (mod_http_cache
 * must be loaded). `kz_prompt <path>` shows the resolution,
 * `kz_prompts_list` / `kz_prompts_flush` manage the cache.
 *
 * Ported from the community mod_kazoo's kz_prompts.c (2600hz, MPL 1.1) as
 * shipped in the freeswitch-kazoo 20.23.6 package; the cache mirrors the
 * commercial module's behaviour.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * Portions derived from kz_prompts.c of the community mod_kazoo in
 * 2600hz's freeswitch-kazoo 20.23.6 package, distributed under the Mozilla
 * Public License 1.1.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise_kz.h"

#define REPRISE_PROMPT_CACHE_TTL_US (300 * 1000000LL)

typedef struct {
	char *url;
	switch_time_t expires;
} reprise_prompt_entry_t;

#define REPRISE_PROMPT_SWEEP_US (60 * 1000000LL)

static struct {
	switch_hash_t *hash; /* prompt path -> reprise_prompt_entry_t (malloc'd) */
	switch_memory_pool_t *pool;
	switch_mutex_t *mutex;
	int started;
	int entries;
	switch_time_t next_sweep;
	uint64_t hits, misses, failures, evictions;
} prompts;

/* the playable URL for a <prompt value="..."/> reply, or NULL: an answer
 * that is itself a prompt:// name means "not found" */
char *reprise_prompt_url_from_reply(switch_xml_t node)
{
	const char *value = node ? switch_xml_attr(node, "value") : NULL;

	if (zstr(value) || !strncasecmp(value, "prompt://", 9)) return NULL;
	return switch_mprintf("http_cache://%s", value);
}

/* under prompts.mutex */
static void entry_drop(const char *path, reprise_prompt_entry_t *e)
{
	switch_core_hash_delete(prompts.hash, path);
	free(e->url);
	free(e);
	prompts.entries--;
}

/* under prompts.mutex: drop every expired entry; then, when still at
 * capacity, the entry closest to expiry (the oldest: the TTL is fixed).
 * Distinct resolved paths (per-account prompts, languages) would
 * otherwise accumulate until an explicit flush. */
static void cache_make_room(switch_time_t now)
{
	switch_hash_index_t *hi;
	const void *key;
	void *val;
	char *victim = NULL;
	switch_time_t victim_expires = 0;
	char **expired = NULL;
	int n_expired = 0, cap = 0, i;

	/* two passes: the core's hash iterator reads the current entry's
	 * link to advance, so nothing is deleted while iterating */
	for (hi = switch_core_hash_first(prompts.hash); hi; hi = switch_core_hash_next(&hi)) {
		reprise_prompt_entry_t *e;
		switch_core_hash_this(hi, &key, NULL, &val);
		e = (reprise_prompt_entry_t *) val;
		if (e->expires <= now) {
			if (n_expired == cap) {
				char **grown = realloc(expired, (cap ? cap * 2 : 64) * sizeof(*grown));
				if (!grown) continue; /* swept next time */
				expired = grown;
				cap = cap ? cap * 2 : 64;
			}
			if ((expired[n_expired] = strdup((const char *) key))) n_expired++;
		} else if (!victim || e->expires < victim_expires) {
			victim = (char *) key;
			victim_expires = e->expires;
		}
	}
	if (victim) victim = strdup(victim); /* the key lives in the entry about to be dropped */
	for (i = 0; i < n_expired; i++) {
		reprise_prompt_entry_t *e = switch_core_hash_find(prompts.hash, expired[i]);
		if (e) entry_drop(expired[i], e);
		free(expired[i]);
	}
	free(expired);
	prompts.evictions += n_expired;
	if (prompts.entries >= REPRISE_PROMPT_CACHE_MAX && victim) {
		reprise_prompt_entry_t *e = switch_core_hash_find(prompts.hash, victim);
		if (e) {
			entry_drop(victim, e);
			prompts.evictions++;
		}
	}
	free(victim);
	prompts.next_sweep = now + REPRISE_PROMPT_SWEEP_US;
}

char *kz_prompt_cache_get(const char *path)
{
	reprise_prompt_entry_t *e;
	char *url = NULL;

	if (!prompts.started || zstr(path)) return NULL;
	switch_mutex_lock(prompts.mutex);
	if ((e = switch_core_hash_find(prompts.hash, path))) {
		if (e->expires > switch_micro_time_now()) {
			url = strdup(e->url);
		} else {
			entry_drop(path, e);
		}
	}
	switch_mutex_unlock(prompts.mutex);
	return url;
}

void kz_prompt_cache_put(const char *path, const char *url, switch_time_t ttl_us)
{
	reprise_prompt_entry_t *e, *old;
	switch_time_t now = switch_micro_time_now();

	if (!prompts.started || zstr(path) || zstr(url)) return;
	if (!(e = malloc(sizeof(*e)))) return;
	if (!(e->url = strdup(url))) {
		free(e);
		return;
	}
	e->expires = now + ttl_us;
	switch_mutex_lock(prompts.mutex);
	if ((old = switch_core_hash_find(prompts.hash, path))) {
		entry_drop(path, old);
	}
	if (prompts.entries >= REPRISE_PROMPT_CACHE_MAX || now >= prompts.next_sweep) {
		cache_make_room(now);
	}
	switch_core_hash_insert(prompts.hash, path, e);
	prompts.entries++;
	switch_mutex_unlock(prompts.mutex);
}

int kz_prompt_cache_count(void)
{
	int n;
	if (!prompts.started) return 0;
	switch_mutex_lock(prompts.mutex);
	n = prompts.entries;
	switch_mutex_unlock(prompts.mutex);
	return n;
}

static char *cache_get(const char *path)
{
	return kz_prompt_cache_get(path);
}

static void cache_put(const char *path, const char *url)
{
	kz_prompt_cache_put(path, url, REPRISE_PROMPT_CACHE_TTL_US);
}

static void cache_flush(void)
{
	switch_hash_index_t *hi;
	const void *key;
	void *val;

	switch_mutex_lock(prompts.mutex);
	for (hi = switch_core_hash_first(prompts.hash); hi; hi = switch_core_hash_next(&hi)) {
		reprise_prompt_entry_t *e;
		switch_core_hash_this(hi, &key, NULL, &val);
		e = (reprise_prompt_entry_t *) val;
		free(e->url);
		free(e);
	}
	switch_core_hash_destroy(&prompts.hash);
	switch_core_hash_init_case(&prompts.hash, SWITCH_TRUE);
	prompts.entries = 0;
	switch_mutex_unlock(prompts.mutex);
}

/* resolve a prompt path ("system_media/vm-record_message/en-us") to the
 * URL the core can open; malloc'd, or NULL */
char *kz_prompt_get(const char *path)
{
	char *req_path, *url;
	switch_xml_t xml_root = NULL, xml_node = NULL;

	if (!prompts.started || zstr(path)) return NULL;
	if ((url = cache_get(path))) {
		prompts.hits++;
		return url;
	}
	prompts.misses++;
	req_path = switch_mprintf("prompt://%s", path);
	if (switch_xml_locate("configuration", "prompt", "path", req_path, &xml_root, &xml_node, NULL, SWITCH_FALSE) != SWITCH_STATUS_SUCCESS) {
		prompts.failures++;
		switch_safe_free(req_path);
		return NULL;
	}
	url = reprise_prompt_url_from_reply(xml_node);
	if (url) {
		cache_put(path, url);
	} else {
		prompts.failures++;
	}
	switch_safe_free(req_path);
	switch_xml_free(xml_root);
	return url;
}

SWITCH_STANDARD_API(kz_prompt_api_get)
{
	char *url;

	if (zstr(cmd)) {
		stream->write_function(stream, "-USAGE: kz_prompt <path>\n");
		return SWITCH_STATUS_SUCCESS;
	}
	if ((url = kz_prompt_get(cmd))) {
		stream->write_function(stream, "%s", url);
		free(url);
	} else {
		stream->write_function(stream, "not_found");
	}
	return SWITCH_STATUS_SUCCESS;
}

SWITCH_STANDARD_API(kz_prompts_flush_api)
{
	if (prompts.started) cache_flush();
	stream->write_function(stream, "+OK\n");
	return SWITCH_STATUS_SUCCESS;
}

SWITCH_STANDARD_API(kz_prompts_list_api)
{
	switch_hash_index_t *hi;
	const void *key;
	void *val;
	switch_time_t now = switch_micro_time_now();

	if (!prompts.started) return SWITCH_STATUS_SUCCESS;
	switch_mutex_lock(prompts.mutex);
	for (hi = switch_core_hash_first(prompts.hash); hi; hi = switch_core_hash_next(&hi)) {
		reprise_prompt_entry_t *e;
		switch_core_hash_this(hi, &key, NULL, &val);
		e = (reprise_prompt_entry_t *) val;
		if (e->expires > now) {
			stream->write_function(stream, "%s -> %s (%ds left)\n", (const char *) key, e->url,
								   (int) ((e->expires - now) / 1000000));
		} else {
			stream->write_function(stream, "%s -> %s (expired)\n", (const char *) key, e->url);
		}
	}
	switch_mutex_unlock(prompts.mutex);
	stream->write_function(stream, "entries=%d/%d hits=%" SWITCH_UINT64_T_FMT " misses=%" SWITCH_UINT64_T_FMT
						   " failures=%" SWITCH_UINT64_T_FMT " evictions=%" SWITCH_UINT64_T_FMT "\n",
						   kz_prompt_cache_count(), REPRISE_PROMPT_CACHE_MAX, prompts.hits, prompts.misses, prompts.failures, prompts.evictions);
	return SWITCH_STATUS_SUCCESS;
}

/*---------------------------------------------------------------------------
 * the file interface: a handle over the real one
 *-------------------------------------------------------------------------*/

static switch_status_t prompt_file_open(switch_file_handle_t *handle, const char *path)
{
	switch_status_t ret;
	switch_file_handle_t *context;
	int file_flags = SWITCH_FILE_DATA_SHORT | (switch_test_flag(handle, SWITCH_FILE_FLAG_VIDEO) ? SWITCH_FILE_FLAG_VIDEO : 0);
	char *real_path = kz_prompt_get(path);

	if (!real_path) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "prompt %s: not resolved\n", path);
		return SWITCH_STATUS_NOTFOUND;
	}
	if (!(context = switch_core_alloc(handle->memory_pool, sizeof(*context)))) {
		free(real_path);
		return SWITCH_STATUS_MEMERR;
	}
	file_flags |= switch_test_flag(handle, SWITCH_FILE_FLAG_WRITE) ? SWITCH_FILE_FLAG_WRITE : SWITCH_FILE_FLAG_READ;
	context->pre_buffer_datalen = handle->pre_buffer_datalen;

	ret = switch_core_file_open(context, real_path, handle->channels, handle->samplerate, file_flags, handle->memory_pool);
	if (ret != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "prompt %s: cannot open %s\n", path, real_path);
		free(real_path);
		return ret;
	}
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "prompt %s -> %s\n", path, real_path);
	free(real_path);

	handle->private_info = context;
	handle->samples = context->samples;
	handle->format = context->format;
	handle->sections = context->sections;
	handle->seekable = context->seekable;
	handle->speed = context->speed;
	handle->interval = context->interval;
	handle->channels = context->channels;
	handle->cur_channels = context->real_channels;
	handle->flags |= SWITCH_FILE_NOMUX;
	handle->pre_buffer_datalen = 0;
	if (switch_test_flag(context, SWITCH_FILE_NATIVE)) {
		switch_set_flag_locked(handle, SWITCH_FILE_NATIVE);
	} else {
		switch_clear_flag_locked(handle, SWITCH_FILE_NATIVE);
	}
	if (switch_test_flag(context, SWITCH_FILE_FLAG_VIDEO)) {
		switch_set_flag_locked(handle, SWITCH_FILE_FLAG_VIDEO);
	} else {
		switch_clear_flag_locked(handle, SWITCH_FILE_FLAG_VIDEO);
	}
	return ret;
}

#define PROMPT_CONTEXT(handle) ((switch_file_handle_t *) (handle)->private_info)

static switch_status_t prompt_file_read(switch_file_handle_t *handle, void *data, size_t *len)
{
	return PROMPT_CONTEXT(handle) ? switch_core_file_read(PROMPT_CONTEXT(handle), data, len) : SWITCH_STATUS_GENERR;
}

static switch_status_t prompt_file_read_video(switch_file_handle_t *handle, switch_frame_t *frame, switch_video_read_flag_t flags)
{
	return PROMPT_CONTEXT(handle) ? switch_core_file_read_video(PROMPT_CONTEXT(handle), frame, flags) : SWITCH_STATUS_GENERR;
}

static switch_status_t prompt_file_close(switch_file_handle_t *handle)
{
	return PROMPT_CONTEXT(handle) ? switch_core_file_close(PROMPT_CONTEXT(handle)) : SWITCH_STATUS_GENERR;
}

static switch_status_t prompt_file_seek(switch_file_handle_t *handle, unsigned int *cur_sample, int64_t samples, int whence)
{
	return PROMPT_CONTEXT(handle) ? switch_core_file_seek(PROMPT_CONTEXT(handle), cur_sample, samples, whence) : SWITCH_STATUS_GENERR;
}

static switch_status_t prompt_file_write(switch_file_handle_t *handle, void *data, size_t *len)
{
	return PROMPT_CONTEXT(handle) ? switch_core_file_write(PROMPT_CONTEXT(handle), data, len) : SWITCH_STATUS_GENERR;
}

static switch_status_t prompt_file_write_video(switch_file_handle_t *handle, switch_frame_t *frame)
{
	return PROMPT_CONTEXT(handle) ? switch_core_file_write_video(PROMPT_CONTEXT(handle), frame) : SWITCH_STATUS_GENERR;
}

static char *prompt_supported_formats[] = { "prompt", NULL };

void reprise_prompts_start(switch_loadable_module_interface_t **module_interface)
{
	switch_file_interface_t *file_interface;
	switch_api_interface_t *api;

	if (prompts.started) return;
	switch_core_new_memory_pool(&prompts.pool);
	switch_core_hash_init_case(&prompts.hash, SWITCH_TRUE);
	switch_mutex_init(&prompts.mutex, SWITCH_MUTEX_NESTED, prompts.pool);
	prompts.entries = 0;
	prompts.next_sweep = switch_micro_time_now() + REPRISE_PROMPT_SWEEP_US;
	prompts.started = 1;

	if (module_interface) {
		SWITCH_ADD_API(api, "kz_prompt", "resolve a prompt:// path", kz_prompt_api_get, "<path>");
		SWITCH_ADD_API(api, "kz_prompts_flush", "clear the prompts cache", kz_prompts_flush_api, "");
		SWITCH_ADD_API(api, "kz_prompts_list", "list the prompts cache", kz_prompts_list_api, "");

		file_interface = switch_loadable_module_create_interface(*module_interface, SWITCH_FILE_INTERFACE);
		file_interface->interface_name = REPRISE_APP_NAME;
		file_interface->extens = prompt_supported_formats;
		file_interface->file_open = prompt_file_open;
		file_interface->file_close = prompt_file_close;
		file_interface->file_read = prompt_file_read;
		file_interface->file_read_video = prompt_file_read_video;
		file_interface->file_seek = prompt_file_seek;
		file_interface->file_write = prompt_file_write;
		file_interface->file_write_video = prompt_file_write_video;
	}
}

void reprise_prompts_stop(void)
{
	if (!prompts.started) return;
	prompts.started = 0;
	cache_flush();
	switch_core_hash_destroy(&prompts.hash);
	switch_core_destroy_memory_pool(&prompts.pool);
}

void reprise_prompts_status(switch_stream_handle_t *stream)
{
	stream->write_function(stream, "prompts: %s, cache entries=%d/%d hits=%" SWITCH_UINT64_T_FMT " misses=%" SWITCH_UINT64_T_FMT
						   " failures=%" SWITCH_UINT64_T_FMT " evictions=%" SWITCH_UINT64_T_FMT "\n", prompts.started ? "on" : "off",
						   kz_prompt_cache_count(), REPRISE_PROMPT_CACHE_MAX, prompts.hits, prompts.misses, prompts.failures, prompts.evictions);
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
