/*
 * reprise_kzutils.c -- the handful of mod_kazoo helpers the ported dptools,
 * commands and tweaks lean on (kazoo_utils.c lineage).
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * Portions derived from FreeSWITCH's mod_kazoo (kazoo_utils.c),
 * distributed under the Mozilla Public License 1.1; Copyright (C)
 * 2005-2012, Anthony Minessale II <anthm@freeswitch.org> and the mod_kazoo
 * contributors.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise_kz.h"
#include <switch_stun.h>

/* variables with these prefixes also set the caller profile field the
 * rest of the name spells (mod_kazoo's kazoo-var-prefix default) */
static const char *profile_vars_prefixes[] = {"effective_", "origination_", NULL};

void kz_check_set_profile_var(switch_channel_t *channel, char *var, char *val)
{
	int idx;
	for (idx = 0; profile_vars_prefixes[idx]; idx++) {
		const char *prefix = profile_vars_prefixes[idx];
		if (!strncasecmp(var, prefix, strlen(prefix))) {
			switch_channel_set_profile_var(channel, var + strlen(prefix), val);
		}
	}
}

switch_status_t kz_switch_core_merge_variables(switch_event_t *event)
{
	switch_event_t *global_vars;
	switch_status_t status = switch_core_get_variables(&global_vars);
	if (status == SWITCH_STATUS_SUCCESS) {
		switch_event_merge(event, global_vars);
		switch_event_destroy(&global_vars);
	}
	return status;
}

switch_status_t kz_switch_core_base_headers_for_expand(switch_event_t **event)
{
	switch_status_t status = SWITCH_STATUS_GENERR;
	*event = NULL;
	if (switch_event_create(event, SWITCH_EVENT_GENERAL) == SWITCH_STATUS_SUCCESS) {
		status = kz_switch_core_merge_variables(*event);
	}
	return status;
}

/* expand against the core variables plus, when a uuid is given, that
 * channel's data */
char *kz_expand(const char *in, const char *uuid)
{
	switch_event_t *event = NULL;
	char *ret;

	kz_switch_core_base_headers_for_expand(&event);
	if (uuid) {
		switch_core_session_t *nsession;
		if ((nsession = switch_core_session_locate(uuid))) {
			switch_channel_event_set_data(switch_core_session_get_channel(nsession), event);
			switch_core_session_rwunlock(nsession);
		}
	}
	ret = reprise_expand_headers(event, in);
	if (ret == in) ret = strdup(in);
	switch_event_destroy(&event);
	return ret;
}

switch_status_t kz_switch_event_add_variable_name_printf(switch_event_t *event, switch_stack_t stack, const char *val, const char *fmt, ...)
{
	char *varname;
	va_list ap;
	int ret;
	switch_status_t status;

	va_start(ap, fmt);
	ret = switch_vasprintf(&varname, fmt, ap);
	va_end(ap);
	if (ret == -1) return SWITCH_STATUS_MEMERR;
	status = switch_event_add_header_string(event, stack, varname, val);
	free(varname);
	return status;
}

/* JSON object -> event headers, nested objects joined with '_' (the kz
 * endpoint turns Custom-Channel-Vars into channel variables this way) */
static switch_status_t expand_json_to_event(cJSON *json, switch_event_t *event, const char *prefix, unsigned int depth)
{
	cJSON *item;
	if (!event || !json || json->type != cJSON_Object || depth > 64) return SWITCH_STATUS_GENERR;
	cJSON_ArrayForEach(item, json) {
		char *name, *response;
		switch_status_t status;
		if (!item->string) return SWITCH_STATUS_GENERR;
		/* JSON keys are data, including any '%' in a parent key. */
		name = switch_mprintf("%s%s%s", prefix ? prefix : "", prefix ? "_" : "", item->string);
		if (!name) return SWITCH_STATUS_MEMERR;
		if (item->type == cJSON_Object) {
			status = expand_json_to_event(item, event, name, depth + 1);
		} else {
			response = item->type == cJSON_String ? strdup(item->valuestring) : cJSON_PrintUnformatted(item);
			if (!response) {
				free(name);
				return SWITCH_STATUS_MEMERR;
			}
			status = switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, name, response);
			free(response);
		}
		free(name);
		if (status != SWITCH_STATUS_SUCCESS) return status;
	}
	return SWITCH_STATUS_SUCCESS;
}

switch_status_t kz_expand_json_to_event(cJSON *json, switch_event_t *event, char *prefix)
{
	return expand_json_to_event(json, event, prefix, 0);
}

/* expand every header value of event against resolver, in place */
switch_status_t kz_expand_headers(switch_event_t *resolver, switch_event_t *event)
{
	switch_event_t *clone = NULL;
	switch_event_header_t *header;

	if (switch_event_create_plain(&clone, event->event_id) != SWITCH_STATUS_SUCCESS) return SWITCH_STATUS_MEMERR;
	for (header = event->headers; header; header = header->next) {
		char *expanded = reprise_expand_headers(resolver, header->value);
		if (header->value && !expanded) {
			switch_event_destroy(&clone);
			return SWITCH_STATUS_GENERR;
		}
		if (expanded != header->value) {
			switch_status_t status = switch_event_add_header_string(clone, SWITCH_STACK_BOTTOM, header->name, expanded);
			switch_safe_free(expanded);
			if (status != SWITCH_STATUS_SUCCESS) {
				switch_event_destroy(&clone);
				return status;
			}
		}
	}
	for (header = clone->headers; header; header = header->next) {
		switch_event_del_header(event, header->name);
	}
	switch_event_merge(event, clone);
	switch_event_destroy(&clone);
	return SWITCH_STATUS_SUCCESS;
}

switch_status_t kz_expand_headers_self(switch_event_t *event)
{
	return kz_expand_headers(event, event);
}

/* The renderer serializes numbers as doubles. Accept a positive timestamp
 * only when it is exactly representable, followed by the eight ASCII key
 * characters used by the interaction-ID contract. Do not guess a timestamp
 * for malformed IDs (in particular, do not move a CDR to the current month). */
static switch_bool_t kz_split_interaction_id(const char *id, char timestamp[17], char key[9])
{
	uint64_t value = 0;
	size_t n = 0, i;
	if (!id) return SWITCH_FALSE;
	while (id[n] >= '0' && id[n] <= '9') {
		unsigned digit = id[n] - '0';
		if (n == 16 || value > (UINT64_C(9007199254740991) - digit) / 10) return SWITCH_FALSE;
		value = value * 10 + digit;
		n++;
	}
	if (!value || id[n] != '-' || strlen(id + n + 1) != 8) return SWITCH_FALSE;
	for (i = 0; i < 8; i++) {
		char c = id[n + 1 + i];
		if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return SWITCH_FALSE;
	}
	memcpy(timestamp, id, n);
	timestamp[n] = '\0';
	memcpy(key, id + n + 1, 9);
	return SWITCH_TRUE;
}

/* Restore mod_kazoo's event-time derivation. An asynchronous child may inherit
 * only the ID, and transfers may replace it after channel initialization.
 * Channel snapshots take precedence over cached bare headers; bare-only
 * events remain supported. Never trust previously split metadata. */
void kz_event_add_interaction(switch_event_t *event)
{
	static const char *names[] = {"Call-Interaction-ID", "Call-Interaction-Timestamp",
								  "Call-Interaction-Key", "Call-Interaction-Is-Root", NULL};
	const char *current, *original;
	char *id, timestamp[17], key[9];
	switch_bool_t root, valid;
	int i;
	if (!event) return;
	current = switch_event_get_header(event, "variable_Call-Interaction-ID");
	if (!current) current = switch_event_get_header(event, names[0]);
	original = switch_event_get_header(event, "variable_Original-Call-Interaction-ID");
	if (!original) original = switch_event_get_header(event, "Original-Call-Interaction-ID");
	root = current && original && !strcmp(current, original);
	valid = kz_split_interaction_id(current, timestamp, key);
	/* current can point into a header about to be replaced. */
	id = current ? strdup(current) : NULL;
	for (i = 0; names[i]; i++) switch_event_del_header(event, names[i]);
	if (id) switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, names[0], id);
	if (valid) {
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, names[1], timestamp);
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, names[2], key);
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, names[3], root ? "true" : "false");
	}
	switch_safe_free(id);
}

/*---------------------------------------------------------------------------
 * argument splitting for the kz_* APIs: like switch_separate_string, but
 * quotes and backslash escapes protect the delimiter and a leading ^^<d>
 * picks the delimiter. Ported from the community mod_kazoo's kazoo_utils.c
 * (2600hz, MPL 1.1).
 *-------------------------------------------------------------------------*/

#define KZ_ESCAPE_META '\\'

static char kz_unescape_char(char escaped)
{
	switch (escaped) {
	case 'n': return '\n';
	case 'r': return '\r';
	case 't': return '\t';
	case 's': return ' ';
	default: return escaped;
	}
}

/* strip quotes, escapes and leading/trailing spaces from one separated part */
char *kz_cleanup_separated_string(char *str, char delim)
{
	char *ptr, *dest, *start, *end = NULL;
	int inside_quotes = 0;

	if (!str) return str;
	for (ptr = str; *ptr == ' '; ++ptr);
	for (start = dest = ptr; *ptr; ++ptr) {
		char e;
		int esc = 0;

		if (*ptr == KZ_ESCAPE_META) {
			e = *(ptr + 1);
			if (e == '\'' || e == '"' || (delim && e == delim) || e == KZ_ESCAPE_META || (e = kz_unescape_char(*(ptr + 1))) != *(ptr + 1)) {
				++ptr;
				*dest++ = e;
				end = dest;
				esc++;
			}
		}
		if (!esc) {
			if (*ptr == '\'' && (inside_quotes || strchr(ptr + 1, '\''))) {
				if ((inside_quotes = (1 - inside_quotes))) end = dest;
			} else {
				*dest++ = *ptr;
				if (*ptr != ' ' || inside_quotes) end = dest;
			}
		}
	}
	if (end) *end = '\0';
	return start;
}

static unsigned int kz_separate_string_char_delim(char *buf, char delim, char **array, unsigned int arraylen)
{
	enum { START, FIND_DELIM } state = START;
	unsigned int count = 0;
	char *ptr = buf;
	int inside_quotes = 0;

	while (*ptr && count < arraylen) {
		switch (state) {
		case START:
			array[count++] = ptr;
			state = FIND_DELIM;
			break;
		case FIND_DELIM:
			if (*ptr == KZ_ESCAPE_META) {
				if (*(ptr + 1)) ++ptr; /* the escaped char is not a delimiter */
			} else if (*ptr == '\'' && (inside_quotes || strchr(ptr + 1, '\''))) {
				inside_quotes = (1 - inside_quotes);
			} else if (*ptr == delim && !inside_quotes) {
				*ptr = '\0';
				state = START;
			}
			++ptr;
			break;
		}
	}
	return count;
}

static unsigned int kz_separate_string_blank_delim(char *buf, char **array, unsigned int arraylen)
{
	enum { START, SKIP_INITIAL_SPACE, FIND_DELIM, SKIP_ENDING_SPACE } state = START;
	unsigned int count = 0;
	char *ptr = buf;
	int inside_quotes = 0;

	while (*ptr && count < arraylen) {
		switch (state) {
		case START:
			array[count++] = ptr;
			state = SKIP_INITIAL_SPACE;
			break;
		case SKIP_INITIAL_SPACE:
			if (*ptr == ' ') ++ptr; else state = FIND_DELIM;
			break;
		case FIND_DELIM:
			if (*ptr == KZ_ESCAPE_META) {
				if (*(ptr + 1)) ++ptr;
			} else if (*ptr == '\'') {
				inside_quotes = (1 - inside_quotes);
			} else if (*ptr == ' ' && !inside_quotes) {
				*ptr = '\0';
				state = SKIP_ENDING_SPACE;
			}
			++ptr;
			break;
		case SKIP_ENDING_SPACE:
			if (*ptr == ' ') ++ptr; else state = START;
			break;
		}
	}
	return count;
}

unsigned int kz_switch_separate_string(char *buf, char delim, char **array, unsigned int arraylen)
{
	if (!buf || !array || !arraylen) return 0;
	if (*buf == '^' && *(buf + 1) == '^') {
		char *p = buf + 2;
		if (*p && *(p + 1)) {
			buf = p;
			delim = *buf++;
		}
	}
	memset(array, 0, arraylen * sizeof(*array));
	return delim == ' ' ? kz_separate_string_blank_delim(buf, array, arraylen) : kz_separate_string_char_delim(buf, delim, array, arraylen);
}

/*---------------------------------------------------------------------------
 * X-PRE-PROCESS (the community module's kz_xml_process, freeswitch-kazoo
 * 20.23.6): the served kazoo.conf can carry
 *   <X-PRE-PROCESS cmd="set" data="name=value"/>       -> core global
 *   <X-PRE-PROCESS cmd="exec-set" data="name=command"/> -> global = command output
 *   <X-PRE-PROCESS cmd="stun-set" data="name=stun:host:port"/> -> global = STUN-mapped address
 *   <X-PRE-PROCESS cmd="env-set" data="name=$ENV"/>    -> global = getenv(ENV)
 * (the 5.4 document ships external_rtp_ip=stun:stun.l.google.com:19302)
 *-------------------------------------------------------------------------*/

switch_bool_t kz_split_keyval(char *keyval, char **key, char **val)
{
	char *eq, *ve;

	*key = *val = NULL;
	if (zstr(keyval) || !(eq = strchr(keyval, '='))) return SWITCH_FALSE;
	*val = eq + 1;
	while (**val == ' ') (*val)++;
	ve = eq;
	*ve = '\0';
	while (ve > keyval && *(ve - 1) == ' ') *--ve = '\0';
	*key = keyval;
	while (**key == ' ') (*key)++;
	return zstr(*key) ? SWITCH_FALSE : SWITCH_TRUE;
}

static void kz_trim_trailing(char *str)
{
	size_t len = zstr(str) ? 0 : strlen(str);
	while (len > 0 && (str[len - 1] == ' ' || str[len - 1] == '\n' || str[len - 1] == '\r')) str[--len] = '\0';
}

void kz_xml_preprocess(const char *cmd, const char *data)
{
	char *keyval, *key, *val;

	if (zstr(cmd) || zstr(data) || !(keyval = strdup(data))) return;
	if (!kz_split_keyval(keyval, &key, &val)) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "X-PRE-PROCESS %s: no key=value in [%s]\n", cmd, data);
		free(keyval);
		return;
	}
	if (!strcasecmp(cmd, "set")) {
		switch_core_set_variable(key, val);
	} else if (!strcasecmp(cmd, "exec-set")) {
		switch_stream_handle_t exec_result = { 0 };
		SWITCH_STANDARD_STREAM(exec_result);
		if (switch_stream_system(val, &exec_result) == 0) {
			if (!zstr((char *) exec_result.data)) {
				kz_trim_trailing((char *) exec_result.data);
				switch_core_set_variable(key, (char *) exec_result.data);
			}
		} else {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "X-PRE-PROCESS exec-set %s: error executing [%s]\n", key, val);
		}
		switch_safe_free(exec_result.data);
	} else if (!strcasecmp(cmd, "stun-set")) {
		char *external_ip = NULL;
		switch_memory_pool_t *pool;
		switch_core_new_memory_pool(&pool);
		if (switch_stun_ip_lookup(&external_ip, val, pool) == SWITCH_STATUS_SUCCESS && !zstr(external_ip)) {
			kz_trim_trailing(external_ip);
			switch_core_set_variable(key, external_ip);
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "X-PRE-PROCESS stun-set %s=%s (%s)\n", key, external_ip, val);
		} else {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "X-PRE-PROCESS stun-set %s: lookup through %s failed\n", key, val);
		}
		switch_core_destroy_memory_pool(&pool);
	} else if (!strcasecmp(cmd, "env-set")) {
		const char *env = *val == '$' ? getenv(val + 1) : NULL;
		if (env) {
			switch_core_set_variable(key, env);
		} else {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "X-PRE-PROCESS env-set %s: [%s] is not a set $ENV\n", key, val);
		}
	} else {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "X-PRE-PROCESS: unknown cmd %s\n", cmd);
	}
	free(keyval);
}

/* the length in samples of a media file at the session's write codec
 * (open, seek to the end, read the position); 0 when it cannot be opened.
 * kz_moh uses it for a random start offset and to decide whether to
 * resume a short file from its start. */
switch_size_t kz_max_media_samples(switch_core_session_t *session, const char *file)
{
	unsigned int pos = 0;
	unsigned int flags = SWITCH_FILE_FLAG_READ | SWITCH_FILE_DATA_SHORT;
	switch_file_handle_t fh = { 0 };
	switch_codec_implementation_t write_impl = { 0 };
	switch_size_t samples = 0;

	switch_core_session_get_write_impl(session, &write_impl);

	if (switch_core_file_open(&fh, file, write_impl.number_of_channels, write_impl.actual_samples_per_second, flags, switch_core_session_get_pool(session)) != SWITCH_STATUS_SUCCESS) {
		return 0;
	}
	samples = fh.samples;
	if (!samples) samples = fh.max_samples;
	if (!samples) samples = fh.sample_count;
	if (!samples) samples = fh.offset_pos;
	if (!samples) samples = fh.pos;
	if (switch_core_file_seek(&fh, &pos, 0, SWITCH_SEEK_END) == SWITCH_STATUS_SUCCESS) {
		samples = fh.samples;
		if (!samples) samples = fh.max_samples;
		if (!samples) samples = fh.sample_count;
		if (!samples) samples = fh.offset_pos;
		if (!samples) samples = fh.pos;
	}
	switch_core_file_close(&fh);
	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "kz_max_media_samples %s => %" SWITCH_SIZE_T_FMT "\n", file, samples);
	return samples;
}
