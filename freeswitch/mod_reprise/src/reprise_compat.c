/*
 * reprise_compat.c -- app-data forms ecallmgr emits for the 2600hz FreeSWITCH
 * fork that stock FreeSWITCH does not parse, rewritten at the points
 * where the module hands app data to the core:
 *
 *  - "/<d>[k=v<d>k=v]<data>": channel variables to set before the app runs
 *    (ecallmgr_call_command:app_variables on record_call & co., the
 *    app_uuid/app_uuid_name scope ecallmgr_fs_bridge puts on kz_bridge).
 *    The stock core knows only the "%[...]" scope form and reads app_uuid
 *    before parsing it, so the block becomes a `multiset` run first.
 *  - record_session "^^<d>path<d>+limit<d>{^^<e>k=v<e>...}": the fork's
 *    delimited argument list; stock wants "path +limit {k=v,k=v}" with the
 *    variables URL-encoded (mod_dptools decodes, then splits on ',').
 *    The multiset before it also decides RECORD_APPEND (record_append_vars).
 *  - sendevent NOTIFY contact-uri "sip:user@realm;fs_path=<sip:proxy>":
 *    the registrar's contact as ecallmgr_fs_notify hands it over; stock
 *    mod_sofia takes the first <...> as the request URI and the NOTIFY is
 *    addressed to the proxy itself (see kz_notify_contact_compat).
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise_kz.h"

static int scoped(const char *data)
{
	return data && data[0] == '/' && (data[1] == '[' || (data[1] && data[2] == '['));
}

/* record_session's delimited list -> stock "path +limit {vars}" */
static char *record_session_args(const char *data)
{
	char delim, *copy, *argv[8] = {0};
	int argc, i;
	switch_stream_handle_t out = {0};
	char *result;

	if (strncmp(data, "^^", 2) || !data[2]) return NULL;
	delim = data[2];
	copy = strdup(data + 3);
	argc = switch_separate_string(copy, delim, argv, (sizeof(argv) / sizeof(argv[0])));
	if (argc < 1 || zstr(argv[0])) {
		free(copy);
		return NULL;
	}
	SWITCH_STANDARD_STREAM(out);
	out.write_function(&out, "%s", argv[0]);
	for (i = 1; i < argc; i++) {
		if (argv[i][0] == '+') {
			out.write_function(&out, " %s", argv[i]);
		} else if (argv[i][0] == '{') {
			/* {^^<e>k=v<e>k=v} -> {k=v,k=v}, values URL-encoded */
			char *inner = argv[i] + 1, *end = strrchr(inner, '}');
			char idelim = ',', *vargv[64] = {0};
			int vargc, n;
			if (end) *end = '\0';
			if (!strncmp(inner, "^^", 2) && inner[2]) {
				idelim = inner[2];
				inner += 3;
			}
			vargc = switch_separate_string(inner, idelim, vargv, (sizeof(vargv) / sizeof(vargv[0])));
			out.write_function(&out, " {");
			for (n = 0; n < vargc; n++) {
				char *eq = strchr(vargv[n], '=');
				char encoded[4096];
				if (!eq) continue;
				*eq++ = '\0';
				switch_url_encode(eq, encoded, sizeof(encoded));
				out.write_function(&out, "%s%s=%s", n ? "," : "", vargv[n], encoded);
			}
			out.write_function(&out, "}");
		}
	}
	free(copy);
	result = strdup((char *) out.data);
	switch_safe_free(out.data);
	return result;
}

/* The variables set before record_session, with RECORD_APPEND added:
 * ecallmgr names the file after the recording, so starting one again under
 * the same name finds the last one's file while its upload is still to
 * come. That file is appended to rather than truncated. A new file is not
 * appended to, so FreeSWITCH applies record_min_sec to it, which it never
 * does to an appended file. The core expands the multiset's data when it
 * runs it, just before record_session, and an execute_on_* variable's only
 * when the event fires, so the file is looked for as the recording starts.
 * args is the rewritten record_session data, the path first. */
static char *record_append_vars(const char *pre, const char *args)
{
	const char *end = strchr(args, ' ');
	int len = end ? (int) (end - args) : (int) strlen(args);

	if (!pre) {
		return switch_mprintf("^^|RECORD_APPEND=${file_exists(%.*s)}", len, args);
	}
	if (!pre[3]) {
		/* "^^<d>" with no variables */
		return switch_mprintf("%sRECORD_APPEND=${file_exists(%.*s)}", pre, len, args);
	}
	return switch_mprintf("%s%cRECORD_APPEND=${file_exists(%.*s)}", pre, pre[2], len, args);
}

/* "sip:user@realm;fs_path=<sip:proxy;transport=udp>" ->
 * "<sip:user@realm;fs_path=sip%3Aproxy%3Btransport%3Dudp>": what stock
 * sofia_glue_get_destination expects (URI in the brackets, the path
 * URL-encoded after it) so the request URI stays the AOR and the proxy
 * becomes NUTAG_PROXY; the 2600hz fork reads the first form. Returns a
 * malloc'd rewrite, or NULL when the contact needs none. */
char *kz_notify_contact_compat(const char *contact)
{
	static const char hex[] = "0123456789ABCDEF";
	const char *fs_path, *path, *end, *p;
	char encoded[1024];
	switch_size_t used = 0;

	if (zstr(contact) || *contact == '<' || !(fs_path = strstr(contact, ";fs_path="))) return NULL;
	path = fs_path + 9;
	if (*path == '<') path++;
	end = path + strlen(path);
	if (end > path && *(end - 1) == '>') end--;
	for (p = path; p < end && used + 4 < sizeof(encoded); p++) {
		unsigned char c = (unsigned char) *p;
		if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == ':' || c == '@' || c == '/') {
			encoded[used++] = (char) c;
		} else {
			encoded[used++] = '%';
			encoded[used++] = hex[c >> 4];
			encoded[used++] = hex[c & 15];
		}
	}
	encoded[used] = '\0';
	return switch_mprintf("<%.*s;fs_path=%s>", (int) (fs_path - contact), contact, encoded);
}

int kz_app_compat(const char *app, const char *data, char **pre, char **out)
{
	const char *rest = data ? data : "";
	char *rewritten = NULL;
	int changed = 0;

	*pre = NULL;
	*out = NULL;
	if (scoped(rest)) {
		char delim = rest[1] == '[' ? ',' : rest[1];
		const char *open = strchr(rest, '[');
		const char *close = open ? strchr(open, ']') : NULL;
		if (close) {
			*pre = switch_mprintf("^^%c%.*s", delim, (int) (close - open - 1), open + 1);
			rest = close + 1;
			while (*rest == ' ') rest++;
			changed = 1;
		}
	}
	if (app && !strcasecmp(app, "record_session") && (rewritten = record_session_args(rest))) {
		char *vars = record_append_vars(*pre, rewritten);
		switch_safe_free(*pre);
		*pre = vars;
		changed = 1;
		rest = rewritten;
	}
	if (changed) {
		*out = strdup(rest);
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "compat %s: %s%s%s -> %.80s\n", switch_str_nil(app),
						  *pre ? "multiset " : "", *pre ? *pre : "", *pre ? "; " : "", *out);
	}
	switch_safe_free(rewritten);
	return changed;
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
