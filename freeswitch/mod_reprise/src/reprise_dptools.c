/*
 * FreeSWITCH Modular Media Switching Software Library / Soft-Switch Application
 * Copyright (C) 2005-2012, Anthony Minessale II <anthm@freeswitch.org>
 *
 * Version: MPL 1.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is FreeSWITCH Modular Media Switching Software Library / Soft-Switch Application
 *
 * The Initial Developer of the Original Code is
 * Anthony Minessale II <anthm@freeswitch.org>
 * Portions created by the Initial Developer are Copyright (C)
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Karl Anderson <karl@2600hz.com>
 * Darren Schreiber <darren@2600hz.com>
 * Vonix LLC (port to the stock FreeSWITCH core for Reprise, 2026)
 *
 *
 * kazoo_dptools.c -- clones of mod_dptools commands slightly modified for kazoo
 *
 */
#include "reprise_kz.h"

#if !defined(SWITCH_KAZOO_INTERCEPT_VERSION) || SWITCH_KAZOO_INTERCEPT_VERSION < 4
#error "mod_kazoo requires the matching Reprise intercept core patch"
#endif
SWITCH_DECLARE(void) switch_kazoo_intercept_v4(void);

#define SET_SHORT_DESC "Set a channel variable"
#define SET_LONG_DESC "Set a channel variable for the channel calling the application."
#define SET_SYNTAX "<varname>=<value>"

#define MULTISET_SHORT_DESC "Set many channel variables"
#define MULTISET_LONG_DESC "Set many channel variables for the channel calling the application"
#define MULTISET_SYNTAX "[^^<delim>]<varname>=<value> <var2>=<val2>"

#define UNSET_SHORT_DESC "Unset a channel variable"
#define UNSET_LONG_DESC "Unset a channel variable for the channel calling the application."
#define UNSET_SYNTAX "<varname>"

#define MULTIUNSET_SHORT_DESC "Unset many channel variables"
#define MULTIUNSET_LONG_DESC "Unset many channel variables for the channel calling the application."
#define MULTIUNSET_SYNTAX "[^^<delim>]<varname> <var2> <var3>"

#define EXPORT_SHORT_DESC "Export many channel variables"
#define EXPORT_LONG_DESC "Export many channel variables for the channel calling the application"
#define EXPORT_SYNTAX "[^^<delim>]<varname>=<value> <var2>=<val2>"

#define PREFIX_UNSET_SHORT_DESC "clear variables by prefix"
#define PREFIX_UNSET_LONG_DESC "clears the channel variables that start with prefix supplied"
#define PREFIX_UNSET_SYNTAX "<prefix>"

#define UUID_MULTISET_SHORT_DESC "Set many channel variables"
#define UUID_MULTISET_LONG_DESC "Set many channel variables for a specific channel"
#define UUID_MULTISET_SYNTAX "<uuid> [^^<delim>]<varname>=<value> <var2>=<val2>"

#define KZ_ENDLESS_PLAYBACK_SHORT_DESC "Playback File Endlessly until break"
#define KZ_ENDLESS_PLAYBACK_LONG_DESC "Endlessly Playback a file to the channel until a break occurs"
#define KZ_ENDLESS_PLAYBACK_SYNTAX "<path>"

#define NOOP_SHORT_DESC "no operation"
#define NOOP_LONG_DESC "no operation. serves as a control point"
#define NOOP_SYNTAX "[<noop-id>]"

/* an execute_on_* variable holds "app data" the core runs later; app data
 * in the fork's forms (reprise_compat.c) is rewritten here, the multiset of
 * the app's variables becoming its own execute_on_* variable placed just
 * before it (the core runs them in variable order). Returns 1 when the
 * variable was set here. */
static int kz_set_execute_on_compat(switch_channel_t *channel, const char *var, const char *value, switch_stack_t stack)
{
	const char *data;
	char *app, *pre = NULL, *out = NULL, *composed;

	if (zstr(var) || strncasecmp(var, "execute_on_", 11) || zstr(value) || !(data = strchr(value, ' '))) return 0;
	app = switch_mprintf("%.*s", (int) (data - value), value);
	while (*data == ' ') data++;
	if (!kz_app_compat(app, data, &pre, &out)) {
		free(app);
		return 0;
	}
	if (pre) {
		char *setter_var = switch_mprintf("%s_vars", var);
		composed = switch_mprintf("multiset %s", pre);
		switch_channel_add_variable_var_check(channel, setter_var, composed, SWITCH_FALSE, stack);
		free(composed);
		free(setter_var);
	}
	composed = switch_mprintf("%s %s", app, out);
	switch_channel_add_variable_var_check(channel, var, composed, SWITCH_FALSE, stack);
	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG, "%s: %s%s%s -> %.80s\n", var, pre ? "multiset " : "",
					  switch_str_nil(pre), pre ? "; " : "", composed);
	free(composed);
	free(app);
	switch_safe_free(pre);
	switch_safe_free(out);
	return 1;
}

static void base_set (switch_core_session_t *session, const char *data, int urldecode, switch_stack_t stack)
{
	char *var, *val = NULL;

	if (zstr(data)) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_ERROR, "No variable name specified.\n");
	} else {
		switch_channel_t *channel = switch_core_session_get_channel(session);
		char *expanded = NULL;

		var = switch_core_session_strdup(session, data);

		if (!(val = strchr(var, '='))) {
			val = strchr(var, ',');
		}

		if (val) {
			*val++ = '\0';
			if (zstr(val)) {
				val = NULL;
			}
		}

		if (val) {
			if(urldecode) {
				switch_url_decode(val);
			}
			expanded = switch_channel_expand_variables(channel, val);
		}

		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "%s SET [%s]=[%s] => [%s]\n", switch_channel_get_name(channel), var, val,
						  expanded ? expanded : "UNDEF");
		if (!kz_set_execute_on_compat(channel, var, expanded, stack)) {
			switch_channel_add_variable_var_check(channel, var, expanded, SWITCH_FALSE, stack);
		}
		kz_check_set_profile_var(channel, var, expanded);
		if (expanded && expanded != val) {
			switch_safe_free(expanded);
		}
	}
}

static int kz_is_exported(switch_core_session_t *session, char *varname)
{
	char *array[256] = {0};
	int i, argc;
	switch_channel_t *channel = switch_core_session_get_channel(session);
	const char *exports = switch_channel_get_variable(channel, SWITCH_EXPORT_VARS_VARIABLE);
	char *arg = switch_core_session_strdup(session, exports);
	argc = switch_split(arg, ',', array);
	for(i=0; i < argc; i++) {
		if(!strcasecmp(array[i], varname))
			return 1;
	}

	return 0;
}

static void base_export (switch_core_session_t *session, const char *data, int urldecode, switch_stack_t stack)
{
        char *var, *val = NULL;

        if (zstr(data)) {
                switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_ERROR, "No variable name specified.\n");
        } else {
                switch_channel_t *channel = switch_core_session_get_channel(session);
                char *expanded = NULL;

                var = switch_core_session_strdup(session, data);

                if (!(val = strchr(var, '='))) {
                        val = strchr(var, ',');
                }

                if (val) {
                        *val++ = '\0';
                        if (zstr(val)) {
                                val = NULL;
                        }
                }

				if (val) {
					if(urldecode) {
						switch_url_decode(val);
					}
					expanded = switch_channel_expand_variables(channel, val);

					if(!kz_is_exported(session, var)) {
						switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "%s EXPORT [%s]=[%s]\n", switch_channel_get_name(channel), var, expanded ? expanded : "UNDEF");
						switch_channel_export_variable_var_check(channel, var, expanded, SWITCH_EXPORT_VARS_VARIABLE, SWITCH_FALSE);
					} else {
						if(strcmp(switch_str_nil(switch_channel_get_variable_dup(channel, var, SWITCH_FALSE, -1)), expanded)) {
							switch_channel_set_variable(channel, var, expanded);
						}
					}
					if (expanded && expanded != val) {
						switch_safe_free(expanded);
					}
				}
        }
}

/* kz_prefix_unset's argument: one prefix, or several separated by '|'
 * (ecallmgr's unset_custom_sip_headers joins "sip_h_<name>" with '|'),
 * or ^^<d> followed by <d>-separated prefixes; in place */
int kz_split_prefixes(char *arg, char **argv, int max)
{
	char delim = '|';

	if (zstr(arg)) return 0;
	if (*arg == '^' && *(arg + 1) == '^') {
		if (!arg[2]) return 0; /* "^^" alone: no delimiter, nothing after it */
		arg += 2;
		delim = *arg++;
	}
	return switch_separate_string(arg, delim, argv, max);
}

SWITCH_STANDARD_APP(prefix_unset_function)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_event_header_t *ei = NULL;
	switch_event_t *clear = NULL;
	int argc = 0, i;
	char *dup = NULL, *argv[64] = { 0 };

	if (zstr(data) || (dup = strdup(data)) == NULL) {
		goto end;
	}
	if (switch_event_create(&clear, SWITCH_EVENT_CLONE) != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_ERROR, "error creating event\n");
		goto end;
	}
	argc = kz_split_prefixes(dup, argv, (sizeof(argv) / sizeof(argv[0])));

	for (ei = switch_channel_variable_first(channel); ei; ei = ei->next) {
		const char *name = ei->name;
		char *value = ei->value;
		for (i = 0; i < argc; i++) {
			if (!zstr(argv[i]) && !strncasecmp(name, argv[i], strlen(argv[i]))) {
				switch_event_add_header_string(clear, SWITCH_STACK_BOTTOM, name, value);
				break;
			}
		}
	}

	switch_channel_variable_last(channel);
	for (ei = clear->headers; ei; ei = ei->next) {
		char *varname = ei->name;
		switch_channel_set_variable(channel, varname, NULL);
	}

end:
	if (clear) {
		switch_event_destroy(&clear);
	}
	switch_safe_free(dup);
}

void kz_multiset(switch_core_session_t *session, const char* data, int urldecode)
{
	char delim = ' ';
	char *arg = (char *) data;
	switch_event_t *event;

	if (!zstr(arg) && *arg == '^' && *(arg+1) == '^') {
		/* "^^" alone: delim stays NUL and arg points at that NUL (never past it) */
		delim = arg[2];
		arg += delim ? 3 : 2;
	}

	if(delim != '\0') {
		switch_channel_t *channel = switch_core_session_get_channel(session);
		if (arg) {
			char *array[256] = {0};
			int i, argc;

			arg = switch_core_session_strdup(session, arg);
			argc = switch_split(arg, delim, array);

			if (argc > 0) {
				for(i = 0; i < argc; i++) {
					base_set(session, array[i], urldecode, SWITCH_STACK_BOTTOM);
				}
				/* the CHANNEL_DATA only when something was set (freeswitch-kazoo 20.23.6) */
				if (switch_event_create(&event, SWITCH_EVENT_CHANNEL_DATA) == SWITCH_STATUS_SUCCESS) {
					switch_channel_event_set_data(channel, event);
					switch_event_fire(&event);
				}
			}
		}
	} else {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "multiset with empty args\n");
	}
}

SWITCH_STANDARD_APP(multiset_function)
{
	kz_multiset(session, data, 0);
}

SWITCH_STANDARD_APP(multiset_encoded_function)
{
	kz_multiset(session, data, 1);
}

void kz_uuid_multiset(switch_core_session_t *session, const char* data, int urldecode)
{
	char delim = ' ';
	char *arg0 = (char *) data;
	char *arg;
	switch_event_t *event;

	if (zstr(data)) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "uuid_multiset with no args\n");
		return;
	}
	if ((arg = strchr(arg0, ' ')) == NULL) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "uuid_multiset with invalid args\n");
		return;
	}
	*arg = '\0';
	arg++;

	if(zstr(arg0)) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "uuid_multiset with invalid uuid\n");
		return;
	}


	if (!zstr(arg) && *arg == '^' && *(arg+1) == '^') {
		/* "^^" alone: delim stays NUL and arg points at that NUL (never past it) */
		delim = arg[2];
		arg += delim ? 3 : 2;
	}

	if(delim != '\0') {
		switch_core_session_t *uuid_session = NULL;
		if ((uuid_session = switch_core_session_locate(arg0)) != NULL) {
			switch_channel_t *uuid_channel = switch_core_session_get_channel(uuid_session);
			if (arg) {
				char *array[256] = {0};
				int i, argc;

				arg = switch_core_session_strdup(session, arg);
				argc = switch_split(arg, delim, array);

				for(i = 0; i < argc; i++) {
					base_set(uuid_session, array[i], urldecode, SWITCH_STACK_BOTTOM);
				}
			}
			if (switch_event_create(&event, SWITCH_EVENT_CHANNEL_DATA) == SWITCH_STATUS_SUCCESS) {
				switch_channel_event_set_data(uuid_channel, event);
				switch_event_fire(&event);
			}
			switch_core_session_rwunlock(uuid_session);
		} else {
			base_set(session, data, urldecode, SWITCH_STACK_BOTTOM);
		}
	} else {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "multiset with empty args\n");
	}
}

SWITCH_STANDARD_APP(uuid_multiset_function)
{
	kz_uuid_multiset(session, data, 0);
}

SWITCH_STANDARD_APP(uuid_multiset_encoded_function)
{
	kz_uuid_multiset(session, data, 1);
}

void kz_set(switch_core_session_t *session, const char* data, int urldecode) {
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_event_t *event;

	base_set(session, data, urldecode, SWITCH_STACK_BOTTOM);

	if (switch_event_create(&event, SWITCH_EVENT_CHANNEL_DATA) == SWITCH_STATUS_SUCCESS) {
		switch_channel_event_set_data(channel, event);
		switch_event_fire(&event);
	}
}

SWITCH_STANDARD_APP(set_function)
{
	kz_set(session, data, 0);
}

SWITCH_STANDARD_APP(set_encoded_function)
{
	kz_set(session, data, 1);
}

SWITCH_STANDARD_APP(unset_function) {
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_event_t *event;

	if (zstr(data)) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_ERROR, "No variable name specified.\n");
	} else {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "UNSET [%s]\n", (char *) data);
		switch_channel_set_variable(switch_core_session_get_channel(session), data, NULL);
	}

	if (switch_event_create(&event, SWITCH_EVENT_CHANNEL_DATA) == SWITCH_STATUS_SUCCESS) {
		switch_channel_event_set_data(channel, event);
		switch_event_fire(&event);
	}
}

SWITCH_STANDARD_APP(multiunset_function) {
	char delim = ' ';
	char *arg = (char *) data;

	if (!zstr(arg) && *arg == '^' && *(arg+1) == '^') {
		/* "^^" alone: delim stays NUL and arg points at that NUL (never past it) */
		delim = arg[2];
		arg += delim ? 3 : 2;
	}

	if(delim != '\0') {
		if (arg) {
			char *array[256] = {0};
			int i, argc;

			arg = switch_core_session_strdup(session, arg);
			argc = switch_split(arg, delim, array);

			for(i = 0; i < argc; i++) {
				switch_channel_set_variable(switch_core_session_get_channel(session), array[i], NULL);
			}

		} else {
			switch_channel_set_variable(switch_core_session_get_channel(session), arg, NULL);
		}
	} else {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "multiunset with empty args\n");
	}
}


void kz_export(switch_core_session_t *session, const char* data, int urldecode)
{
    char delim = ' ';
    char *arg = (char *) data;

    if (!zstr(arg) && *arg == '^' && *(arg+1) == '^') {
            /* "^^" alone: delim stays NUL and arg points at that NUL (never past it) */
            delim = arg[2];
            arg += delim ? 3 : 2;
    }

    if(delim != '\0') {
		if (arg) {
				char *array[256] = {0};
				int i, argc;

				arg = switch_core_session_strdup(session, arg);
				argc = switch_split(arg, delim, array);

				for(i = 0; i < argc; i++) {
						base_export(session, array[i], urldecode, SWITCH_STACK_BOTTOM);
				}
		} else {
				base_export(session, data, urldecode, SWITCH_STACK_BOTTOM);
		}
    } else {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "export with empty args\n");
    }
}

SWITCH_STANDARD_APP(export_function)
{
	kz_export(session, data, 0);
}

SWITCH_STANDARD_APP(export_encoded_function)
{
	kz_export(session, data, 1);
}

/* A digit pressed while kz_endless_playback runs. The core publishes its
 * DTMF event when a digit is taken off the channel, and a playback given
 * no input arguments never takes one: a caller's key sat on the channel
 * until the hold was broken, and whoever was waiting for the event (a
 * queue with exit keys) heard it only then. This takes each digit as it
 * arrives, so the event is published at once, and keeps playing: the key
 * means whatever the holder decides, never the end of the music. The digit
 * itself is neither logged nor kept: the core has already logged its
 * arrival, and keeps a sensitive one (sensitive_dtmf) out of the log and
 * the event, which this must not undo. */
static switch_status_t kz_endless_playback_on_input(switch_core_session_t *session, void *input, switch_input_type_t itype,
													void *buf, unsigned int buflen)
{
	return SWITCH_STATUS_SUCCESS;
}

// copied from mod_dptools with allow SWITCH_STATUS_BREAK
SWITCH_STANDARD_APP(kz_endless_playback_function)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_status_t status = SWITCH_STATUS_SUCCESS;
	switch_input_args_t args = { 0 };
	const char *file = data;

	args.input_callback = kz_endless_playback_on_input;

	while (switch_channel_ready(channel)) {
		status = switch_ivr_play_file(session, NULL, file, &args);

		if (status != SWITCH_STATUS_SUCCESS) {
			break;
		}
	}

	switch (status) {
	case SWITCH_STATUS_SUCCESS:
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "FILE PLAYED");
		break;
	case SWITCH_STATUS_BREAK:
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "PLAYBACK_INTERRUPTED");
		break;
	case SWITCH_STATUS_NOTFOUND:
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "FILE NOT FOUND");
		break;
	default:
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "PLAYBACK ERROR");
		break;
	}

}

/* kz_moh <file>: hold music that resumes where it left off across
 * hold/unhold. freeswitch-kazoo 20.23.6's form: the resolution of an
 * http_cache:// file and its length are kept once per channel in a
 * private (kz_moh_ctrl) instead of the moh_playback_samples variable;
 * moh_playback_random=true starts at a random offset; a break resumes at
 * the file position unless the file is shorter than MOH_RESTART_MIN_SIZE
 * samples; an unresolved http_cache:// fetch is retried on the next
 * execution. */
#define KZ_MOH_CTRL_KEY "kz_moh_ctrl"
#define MOH_RESTART_MIN_SIZE 100000

typedef struct kz_moh_control {
	const char *data;
	switch_size_t max_samples;
	int64_t start_at;
	switch_bool_t resolved;
	switch_bool_t retry;
} kz_moh_control_t;

static void kz_moh_control_init(kz_moh_control_t *ctrl, switch_core_session_t *session, const char *data)
{
	char *my_data = NULL, *resolve = NULL;
	switch_channel_t *channel = switch_core_session_get_channel(session);

	ctrl->retry = SWITCH_FALSE;
	if (!strncmp(data, "http_cache://", 13)) {
		resolve = switch_mprintf("${http_get({prefetch=true}%s)}", data + 13);
		my_data = switch_channel_expand_variables_check(channel, resolve, NULL, NULL, 0);
		if (!zstr(my_data)) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "moh resolved => %s\n", my_data);
			ctrl->max_samples = kz_max_media_samples(session, my_data);
			if (ctrl->max_samples) {
				ctrl->resolved = SWITCH_TRUE;
				if (switch_channel_var_true(channel, "moh_playback_random")) {
					ctrl->start_at = (int64_t) (random() % ctrl->max_samples);
					switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "moh random start => %" SWITCH_INT64_T_FMT " of %" SWITCH_SIZE_T_FMT "\n", ctrl->start_at, ctrl->max_samples);
				}
			}
			ctrl->data = switch_core_session_strdup(session, my_data);
		} else {
			ctrl->retry = SWITCH_TRUE;
			if (!ctrl->data) {
				ctrl->data = switch_core_session_strdup(session, data);
			}
		}
	} else {
		ctrl->data = switch_core_session_strdup(session, data);
	}
	if (resolve && resolve != my_data) {
		switch_safe_free(resolve);
	}
	switch_safe_free(my_data);
}

static kz_moh_control_t *get_kz_moh_control(switch_core_session_t *session, const char *data)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	kz_moh_control_t *ctrl = switch_channel_get_private(channel, KZ_MOH_CTRL_KEY);

	if (!ctrl) {
		ctrl = switch_core_session_alloc(session, sizeof(*ctrl));
		switch_assert(ctrl);
		kz_moh_control_init(ctrl, session, data);
		switch_channel_set_private(channel, KZ_MOH_CTRL_KEY, ctrl);
	} else if (ctrl->retry) {
		kz_moh_control_init(ctrl, session, data);
	}
	return ctrl;
}

static void kz_moh_set_resume(switch_core_session_t *session, kz_moh_control_t *ctrl, switch_file_handle_t *fh)
{
	if (!ctrl->resolved) return;
	ctrl->start_at = ctrl->max_samples ? (ctrl->max_samples < MOH_RESTART_MIN_SIZE ? 0 : fh->pos) : fh->pos;
	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "moh set file position %" SWITCH_INT64_T_FMT "\n", ctrl->start_at);
}

SWITCH_STANDARD_APP(kz_moh_function)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_status_t status = SWITCH_STATUS_SUCCESS;
	switch_file_handle_t fh = { 0 };
	kz_moh_control_t *ctrl;

	if (zstr(data)) {
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "MOH FILE NOT FOUND");
		return;
	}
	ctrl = get_kz_moh_control(session, data);
	if (ctrl->start_at) {
		fh.samples = (unsigned int) ctrl->start_at;
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "moh starting at sample %" SWITCH_INT64_T_FMT "\n", ctrl->start_at);
	}

	switch_channel_set_variable(channel, SWITCH_PLAYBACK_TERMINATOR_USED, "");

	status = switch_ivr_play_file(session, &fh, ctrl->data, NULL);

	switch_assert(!(fh.flags & SWITCH_FILE_OPEN));
	ctrl->start_at = 0;

	switch (status) {
	case SWITCH_STATUS_SUCCESS:
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "MOH FILE PLAYED");
		break;
	case SWITCH_STATUS_BREAK:
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "MOH FILE PLAYED");
		kz_moh_set_resume(session, ctrl, &fh);
		break;
	case SWITCH_STATUS_NOTFOUND:
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "moh file not found: %s\n", ctrl->data);
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "MOH FILE NOT FOUND");
		break;
	default:
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "MOH FILE PLAYED");
		kz_moh_set_resume(session, ctrl, &fh);
		break;
	}

	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG1, "MOH pos %" SWITCH_INT64_T_FMT " samples %d sample_count %" SWITCH_SIZE_T_FMT "\n", fh.pos, fh.samples, fh.sample_count);
}

SWITCH_STANDARD_APP(noop_function)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	char uuid_str[SWITCH_UUID_FORMATTED_LENGTH + 1];
	const char *response = uuid_str;

	if (zstr(data)) {
		switch_uuid_str(uuid_str, sizeof(uuid_str));
	} else {
		response = data;
	}

	switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, response);
}

SWITCH_STANDARD_APP(kz_restore_caller_id_function)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_caller_profile_t *cp = switch_channel_get_caller_profile(channel);

	/* the fork also skips the restore when the leg's last caller profile
	 * came from an originator (LP_ORIGINATOR, a fork-only profile type) */
	if (switch_channel_var_true(channel, "skip_restore_caller_id")) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "skipping restore caller_id\n");
		return;
	}
	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "restoring caller_id \"%s\" %s => \"%s\" %s\n",
					  switch_str_nil(cp->caller_id_name), switch_str_nil(cp->caller_id_number),
					  switch_str_nil(cp->orig_caller_id_name), switch_str_nil(cp->orig_caller_id_number));
	cp->caller_id_name = cp->orig_caller_id_name;
	cp->caller_id_number = cp->orig_caller_id_number;
}

/* The directory/callflow pickup target is the ringing device leg. Select its
 * caller after the originate handoff, as the distributed mod_kazoo does.
 * Keep UUIDs in our session pool across unlocks; never retain unlocked channels. */
/* Nested kz originates retain their caller in this third partner field.
 * Stock FreeSWITCH only resolves the two generic signal-bond fields. */
static const char *kz_intercept_partner(switch_channel_t *channel)
{
 const char *uuid = switch_channel_get_partner_uuid(channel);
 return zstr(uuid) ? switch_channel_get_variable(channel, KZ_ORIGINATE_UUID_VARIABLE) : uuid;
}
/* The intercept_* policy variables: forbidden lives on the target, the rest on the picker. */
static int kz_intercept_refused(switch_channel_t *channel, switch_channel_t *target_channel)
{
	return switch_true(switch_channel_get_variable(target_channel, "intercept_forbidden")) ||
		(switch_true(switch_channel_get_variable(channel, "intercept_unbridged_only")) && switch_channel_test_flag(target_channel, CF_BRIDGED)) ||
		(switch_true(switch_channel_get_variable(channel, "intercept_unanswered_only")) && switch_channel_test_flag(target_channel, CF_ANSWERED));
}
#define KZ_INTERCEPT_SYNTAX "[-bleg] <uuid>"
SWITCH_STANDARD_APP(kz_intercept_function)
{
	char *argv[4] = { 0 }, *mydata;
	const char *uuid = NULL;
	switch_bool_t bleg = SWITCH_FALSE;
	switch_status_t status = SWITCH_STATUS_FALSE;
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_core_session_t *target = NULL;

	switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, "ERROR");
	if (!zstr(data) && (mydata = switch_core_session_strdup(session, data))) {
		if (switch_separate_string(mydata, ' ', argv, 4) >= 1) {
			bleg = !strcasecmp(argv[0], "-bleg");
			uuid = bleg ? argv[1] : argv[0];
		}
	}
	if (zstr(uuid) || !strcmp(uuid, switch_core_session_get_uuid(session))) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_ERROR, "Usage: %s (target must differ from caller)\n", KZ_INTERCEPT_SYNTAX);
		return;
	}
	if (bleg) {
		/* -bleg names a leg whose bridge partner is the real target. Resolve
		 * that partner here (the core cannot see the kz originate uuid), check
		 * the policy on it and hand the partner itself to the core: the pickup
		 * flow below is written for a named ringing device and would answer
		 * and drop the caller instead. */
		switch_core_session_t *named = switch_core_session_locate(uuid);
		const char *partner = NULL;
		if (!named) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "intercept -bleg %s is absent\n", uuid);
			return;
		}
		partner = switch_channel_get_variable(switch_core_session_get_channel(named), SWITCH_ORIGINATE_SIGNAL_BOND_VARIABLE);
		if (zstr(partner)) partner = kz_intercept_partner(switch_core_session_get_channel(named));
		partner = zstr(partner) ? NULL : switch_core_session_strdup(session, partner);
		switch_core_session_rwunlock(named);
		if (!partner || !strcmp(partner, switch_core_session_get_uuid(session))) {
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "no uuid bridged to %s to intercept\n", uuid);
			return;
		}
		if ((target = switch_core_session_locate(partner))) {
			int refused = kz_intercept_refused(channel, switch_core_session_get_channel(target));
			switch_core_session_rwunlock(target);
			if (refused) return;
		}
		status = switch_ivr_intercept_session(session, partner, SWITCH_FALSE);
		switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE,
			status == SWITCH_STATUS_SUCCESS ? "SUCCESS" : "ERROR");
		return;
	}
	if (!(target = switch_core_session_locate(uuid))) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "intercept target %s is absent\n", uuid);
		return;
	}
	{
		switch_channel_t *target_channel = switch_core_session_get_channel(target);
		const char *partner = kz_intercept_partner(target_channel);
		/* Check eligibility on the requested leg before accepting an originate.
		 * The original caller may already be answered while this device rings. */
		if (kz_intercept_refused(channel, target_channel)) {
			switch_core_session_rwunlock(target);
			return;
		}
		uuid = switch_core_session_strdup(session, uuid);
		if (switch_channel_direction(channel) == SWITCH_CALL_DIRECTION_INBOUND && !zstr(partner)) {
			switch_core_session_t *bridge = switch_core_session_locate(partner);
			if (bridge) {
				const char *initial_partner = switch_core_session_strdup(session, partner);
				switch_core_session_t *selected;
                switch_channel_t *bridge_channel = switch_core_session_get_channel(bridge);
                const char *saved = switch_channel_get_variable(bridge_channel, "satt_uuid");
                if (switch_channel_test_flag(bridge_channel, CF_ORIGINATING_XFER) && !zstr(saved)) {
                    switch_core_session_t *original;
                    uuid = switch_core_session_strdup(session, saved);
                    switch_channel_clear_flag(bridge_channel, CF_ORIGINATING_XFER);
                    switch_channel_clear_flag(bridge_channel, CF_XFER_ZOMBIE);
                    switch_channel_set_variable(bridge_channel, SWITCH_SOFT_HOLDING_UUID_VARIABLE, NULL);
                    switch_channel_set_variable(bridge_channel, SWITCH_HOLDING_UUID_VARIABLE, NULL);
                    switch_channel_hangup(target_channel, SWITCH_CAUSE_PICKED_OFF);
                    if ((original = switch_core_session_locate(uuid))) {
                        switch_channel_mark_hold(switch_core_session_get_channel(original), SWITCH_FALSE);
                        switch_core_session_kill_channel(original, SWITCH_SIG_BREAK);
                        switch_core_session_rwunlock(original);
                    }
                } else {
				switch_channel_set_flag(target_channel, CF_GROUP_ACCEPTED);
				switch_channel_answer(target_channel);
				switch_channel_wait_for_state_timeout(target_channel, CS_CONSUME_MEDIA, 5000);
				partner = kz_intercept_partner(target_channel);
				selected = zstr(partner) ? NULL : switch_core_session_locate(partner);
				if (selected) {
					uuid = switch_core_session_strdup(session, switch_core_session_get_uuid(selected));
					switch_core_session_rwunlock(selected);
				} else {
					uuid = initial_partner;
				}
				switch_channel_hangup(target_channel, SWITCH_CAUSE_PICKED_OFF);
                }
				switch_core_session_rwunlock(bridge);
			}
		}
	}
	switch_core_session_rwunlock(target);
	if (strcmp(uuid, switch_core_session_get_uuid(session))) {
		status = switch_ivr_intercept_session(session, uuid, bleg);
	}
	switch_channel_set_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE,
		status == SWITCH_STATUS_SUCCESS ? "SUCCESS" : "ERROR");
}

SWITCH_STANDARD_APP(kz_audio_bridge_function)
{
	switch_channel_t *caller_channel = switch_core_session_get_channel(session);
	switch_core_session_t *peer_session = NULL;
	switch_call_cause_t cause = SWITCH_CAUSE_NORMAL_CLEARING;
	switch_status_t status = SWITCH_STATUS_FALSE;

	if (zstr(data)) {
		return;
	}

	status = switch_ivr_originate(session, &peer_session, &cause, data, 0, NULL, NULL, NULL, NULL, NULL, SOF_NONE, NULL, NULL);

	if (status != SWITCH_STATUS_SUCCESS) {
		switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_INFO, "Originate Failed.  Cause: %s\n", switch_channel_cause2str(cause));

		switch_channel_set_variable(caller_channel, "originate_failed_cause", switch_channel_cause2str(cause));
		switch_channel_set_variable(caller_channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, switch_channel_cause2str(cause));
		switch_channel_handle_cause(caller_channel, cause);

		return;
	} else {
		const char* uuid = switch_core_session_get_uuid(session);
		const char* peer_uuid = switch_core_session_get_uuid(peer_session);


		switch_channel_t *peer_channel = switch_core_session_get_channel(peer_session);
		if (switch_true(switch_channel_get_variable(caller_channel, SWITCH_BYPASS_MEDIA_AFTER_BRIDGE_VARIABLE)) ||
			switch_true(switch_channel_get_variable(peer_channel, SWITCH_BYPASS_MEDIA_AFTER_BRIDGE_VARIABLE))) {
			switch_channel_set_flag(caller_channel, CF_BYPASS_MEDIA_AFTER_BRIDGE);
		}

		while(1) {
			const char *xfer_uuid;
			switch_channel_state_t a_state , a_running_state;
			switch_channel_state_t b_state , b_running_state;
			status = switch_ivr_multi_threaded_bridge(session, peer_session, NULL, NULL, NULL);

			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "BRIDGE RESULT %i\n", status);
			if(status  != 0) {
				break;
			}

			a_state = switch_channel_get_state(caller_channel);
			a_running_state = switch_channel_get_running_state(caller_channel);

			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "A STATE %s  %s =>  %s , %s\n", switch_channel_state_name(a_running_state), switch_channel_state_name(a_state), uuid, peer_uuid);

			if(a_state >= CS_HANGUP) {
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "A HANGUP =  %s , %s\n", uuid, peer_uuid);
				break;
			}

			b_state = switch_channel_get_state(peer_channel);
			b_running_state = switch_channel_get_running_state(peer_channel);

			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "B STATE %s  %s =>  %s , %s\n", switch_channel_state_name(b_running_state), switch_channel_state_name(b_state), uuid, peer_uuid);

			if(b_state >= CS_HANGUP) {
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "B HANGUP = %s , %s\n", uuid, peer_uuid);
				switch_channel_set_variable(caller_channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE, switch_channel_cause2str(switch_channel_get_cause(peer_channel)));
				break;
			}

			if(!(xfer_uuid=switch_channel_get_variable(caller_channel, "att_xfer_peer_uuid"))) {
				if(!(xfer_uuid=switch_channel_get_variable(peer_channel, "att_xfer_peer_uuid"))) {
					switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "XFER UUID NULL\n");
					break;
				}
			}

			switch_channel_set_variable(caller_channel, "att_xfer_peer_uuid", NULL);
			switch_channel_set_variable(peer_channel, "att_xfer_peer_uuid", NULL);

			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "WAIT 1\n");

			switch_channel_clear_flag(peer_channel, CF_UUID_BRIDGE_ORIGINATOR);
			switch_channel_set_state(peer_channel, CS_RESET);
			switch_channel_wait_for_state(peer_channel, NULL, CS_RESET);
			switch_channel_clear_state_handler(peer_channel, NULL);

			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "WAIT 3\n");

			switch_channel_set_flag(caller_channel, CF_UUID_BRIDGE_ORIGINATOR);
			switch_channel_clear_flag(caller_channel, CF_TRANSFER);
			switch_channel_clear_flag(caller_channel, CF_REDIRECT);
			switch_channel_set_flag(peer_channel, CF_UUID_BRIDGE_ORIGINATOR);
			switch_channel_clear_flag(peer_channel, CF_TRANSFER);
			switch_channel_clear_flag(peer_channel, CF_REDIRECT);

			if(!switch_channel_media_up(caller_channel)) {
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "A MEDIA DOWN HANGUP = %s, %s , %s\n", xfer_uuid, uuid, peer_uuid);
			}
			if(!switch_channel_media_up(peer_channel)) {
				switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "B MEDIA DOWN HANGUP = %s, %s , %s\n", xfer_uuid, uuid, peer_uuid);
			}
			switch_channel_set_state(caller_channel, CS_EXECUTE);
			switch_channel_set_state(peer_channel, CS_EXECUTE);


			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "XFER LOOP %s %s , %s\n", xfer_uuid, uuid, peer_uuid);

		}

		if (peer_session) {
			switch_core_session_rwunlock(peer_session);
		}
	}
}

SWITCH_STANDARD_APP(kz_audio_bridge_uuid_function)
{
	switch_core_session_t *peer_session = NULL;
	const char * peer_uuid = NULL;

	if (zstr(data)) {
		return;
	}

	peer_uuid = switch_core_session_strdup(session, data);
	if (peer_uuid && (peer_session = switch_core_session_locate(peer_uuid))) {
		switch_ivr_multi_threaded_bridge(session, peer_session, NULL, NULL, NULL);
	}

	if (peer_session) {
		switch_core_session_rwunlock(peer_session);
	}
}


struct kz_att_keys {
	const char *attxfer_cancel_key;
	const char *attxfer_hangup_key;
	const char *attxfer_conf_key;
};

static switch_status_t kz_att_xfer_on_dtmf(switch_core_session_t *session, void *input, switch_input_type_t itype, void *buf, unsigned int buflen)
{
	switch_core_session_t *peer_session = (switch_core_session_t *) buf;
	if (!buf || !peer_session) {
		return SWITCH_STATUS_SUCCESS;
	}

	switch (itype) {
	case SWITCH_INPUT_TYPE_DTMF:
		{
			switch_dtmf_t *dtmf = (switch_dtmf_t *) input;
			switch_channel_t *channel = switch_core_session_get_channel(session);
			switch_channel_t *peer_channel = switch_core_session_get_channel(peer_session);
			struct kz_att_keys *keys = switch_channel_get_private(channel, "__kz_keys");

			if (dtmf->digit == *keys->attxfer_hangup_key) {
				switch_channel_hangup(channel, SWITCH_CAUSE_ATTENDED_TRANSFER);
				return SWITCH_STATUS_FALSE;
			}

			if (dtmf->digit == *keys->attxfer_cancel_key) {
				switch_channel_hangup(peer_channel, SWITCH_CAUSE_NORMAL_CLEARING);
				return SWITCH_STATUS_FALSE;
			}

			if (dtmf->digit == *keys->attxfer_conf_key) {
				switch_caller_extension_t *extension = NULL;
				const char *app = "three_way";
				const char *app_arg = switch_core_session_get_uuid(session);
				const char *holding = switch_channel_get_variable(channel, SWITCH_SOFT_HOLDING_UUID_VARIABLE);
				switch_core_session_t *b_session;

				if (holding && (b_session = switch_core_session_locate(holding))) {
					switch_channel_t *b_channel = switch_core_session_get_channel(b_session);
					if (!switch_channel_ready(b_channel)) {
						app = "intercept";
					}
					switch_core_session_rwunlock(b_session);
				}

				if ((extension = switch_caller_extension_new(peer_session, app, app_arg)) == 0) {
					switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_CRIT, "Memory Error!\n");
					abort();
				}

				switch_caller_extension_add_application(peer_session, extension, app, app_arg);
				switch_channel_set_caller_extension(peer_channel, extension);
				switch_channel_set_state(peer_channel, CS_RESET);
				switch_channel_wait_for_state(peer_channel, channel, CS_RESET);
				switch_channel_set_state(peer_channel, CS_EXECUTE);
				switch_channel_set_variable(channel, SWITCH_HANGUP_AFTER_BRIDGE_VARIABLE, NULL);
				return SWITCH_STATUS_FALSE;
			}

		}
		break;
	default:
		break;
	}

	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t kz_att_xfer_tmp_hanguphook(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_channel_state_t state = switch_channel_get_state(channel);

	if (state == CS_HANGUP || state == CS_ROUTING) {
		const char *bond = switch_channel_get_variable(channel, SWITCH_SOFT_HOLDING_UUID_VARIABLE);

		if (!zstr(bond)) {
			switch_core_session_t *b_session;

			if ((b_session = switch_core_session_locate(bond))) {
				switch_channel_t *b_channel = switch_core_session_get_channel(b_session);
				if (switch_channel_up(b_channel)) {
					switch_channel_set_flag(b_channel, CF_REDIRECT);
				}
				switch_core_session_rwunlock(b_session);
			}
		}

		switch_core_event_hook_remove_state_change(session, kz_att_xfer_tmp_hanguphook);
	}

	return SWITCH_STATUS_SUCCESS;
}

static switch_status_t kz_att_xfer_hanguphook(switch_core_session_t *session)
{
	switch_channel_t *channel = switch_core_session_get_channel(session);
	switch_channel_state_t state = switch_channel_get_state(channel);
	const char *id = NULL;
	const char *peer_uuid = NULL;

	if (state == CS_HANGUP || state == CS_ROUTING) {
		if ((id = switch_channel_get_variable(channel, "xfer_uuids"))) {
			switch_stream_handle_t stream = { 0 };
			SWITCH_STANDARD_STREAM(stream);
			if ((peer_uuid = switch_channel_get_variable(channel, "xfer_peer_uuid"))) {
				switch_core_session_t *peer_session = NULL;
				if ((peer_session = switch_core_session_locate(peer_uuid)) != NULL ) {
					switch_ivr_transfer_recordings(session, peer_session);
					switch_core_session_rwunlock(peer_session);
				}
			}
			switch_api_execute("uuid_bridge", id, NULL, &stream);
			switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "\nHangup Command uuid_bridge(%s):\n%s\n", id,
							  switch_str_nil((char *) stream.data));
			switch_safe_free(stream.data);
		}

		switch_core_event_hook_remove_state_change(session, kz_att_xfer_hanguphook);
	}
	return SWITCH_STATUS_SUCCESS;
}


static void kz_att_xfer_set_result(switch_channel_t *channel, switch_status_t status)
{
	switch_channel_set_variable(channel, SWITCH_ATT_XFER_RESULT_VARIABLE, status == SWITCH_STATUS_SUCCESS ? "success" : "failure");
}

struct kz_att_obj {
	switch_core_session_t *session;
	const char *data;
	int running;
};

void *SWITCH_THREAD_FUNC kz_att_thread_run(switch_thread_t *thread, void *obj)
{
	struct kz_att_obj *att = (struct kz_att_obj *) obj;
	struct kz_att_keys *keys = NULL;
	switch_core_session_t *session = att->session;
	switch_core_session_t *peer_session = NULL;
	const char *data = att->data;
	switch_call_cause_t cause = SWITCH_CAUSE_NORMAL_CLEARING;
	switch_channel_t *channel = switch_core_session_get_channel(session), *peer_channel = NULL;
	const char *bond = NULL;
	switch_bool_t follow_recording = switch_true(switch_channel_get_variable(channel, "recording_follow_attxfer"));
	const char *attxfer_cancel_key = NULL, *attxfer_hangup_key = NULL, *attxfer_conf_key = NULL;
	int br = 0;
	switch_event_t *event = NULL;
	switch_core_session_t *b_session = NULL;
	switch_channel_t *b_channel = NULL;

	att->running = 1;

	if (switch_core_session_read_lock(session) != SWITCH_STATUS_SUCCESS) {
		return NULL;
	}

	bond = switch_channel_get_partner_uuid(channel);
	if ((b_session = switch_core_session_locate(bond)) == NULL) {
		switch_core_session_rwunlock(session);
		return NULL;
	}
	switch_channel_set_variable(channel, SWITCH_SOFT_HOLDING_UUID_VARIABLE, bond);
	switch_core_event_hook_add_state_change(session, kz_att_xfer_tmp_hanguphook);

	if (switch_ivr_originate(session, &peer_session, &cause, data, 0, NULL, NULL, NULL, NULL, NULL, SOF_NONE, NULL, NULL)
		!= SWITCH_STATUS_SUCCESS || !peer_session) {
		switch_channel_set_variable(channel, SWITCH_SIGNAL_BOND_VARIABLE, bond);
		goto end;
	}

	peer_channel = switch_core_session_get_channel(peer_session);
	switch_channel_set_flag(peer_channel, CF_INNER_BRIDGE);
	switch_channel_set_flag(channel, CF_INNER_BRIDGE);

	if (!(attxfer_cancel_key = switch_channel_get_variable(channel, "attxfer_cancel_key"))) {
		if (!(attxfer_cancel_key = switch_channel_get_variable(peer_channel, "attxfer_cancel_key"))) {
			attxfer_cancel_key = "#";
		}
	}

	if (!(attxfer_hangup_key = switch_channel_get_variable(channel, "attxfer_hangup_key"))) {
		if (!(attxfer_hangup_key = switch_channel_get_variable(peer_channel, "attxfer_hangup_key"))) {
			attxfer_hangup_key = "*";
		}
	}

	if (!(attxfer_conf_key = switch_channel_get_variable(channel, "attxfer_conf_key"))) {
		if (!(attxfer_conf_key = switch_channel_get_variable(peer_channel, "attxfer_conf_key"))) {
			attxfer_conf_key = "0";
		}
	}

	keys = switch_core_session_alloc(session, sizeof(*keys));
	keys->attxfer_cancel_key = switch_core_session_strdup(session, attxfer_cancel_key);
	keys->attxfer_hangup_key = switch_core_session_strdup(session, attxfer_hangup_key);
	keys->attxfer_conf_key = switch_core_session_strdup(session, attxfer_conf_key);
	switch_channel_set_private(channel, "__kz_keys", keys);

	switch_channel_set_variable(channel, "att_xfer_peer_uuid", switch_core_session_get_uuid(peer_session));

	switch_ivr_multi_threaded_bridge(session, peer_session, kz_att_xfer_on_dtmf, peer_session, NULL);

	switch_channel_clear_flag(peer_channel, CF_INNER_BRIDGE);
	switch_channel_clear_flag(channel, CF_INNER_BRIDGE);

	if (switch_channel_down(peer_channel)) {
		switch_core_session_rwunlock(peer_session);
		switch_channel_set_variable(channel, SWITCH_SIGNAL_BOND_VARIABLE, bond);
		goto end;
	}

	/*
	 * we're emiting the transferee event so that callctl can update
	 */
	b_channel = switch_core_session_get_channel(b_session);
	if (switch_event_create_subclass(&event, SWITCH_EVENT_CUSTOM, "sofia::transferee") == SWITCH_STATUS_SUCCESS) {
		switch_channel_event_set_data(b_channel, event);
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "att_xfer_replaced_call_id", switch_core_session_get_uuid(peer_session));
		switch_event_fire(&event);
	}

	if (!switch_channel_ready(channel)) {
		switch_status_t status;

		if (follow_recording) {
			switch_ivr_transfer_recordings(session, peer_session);
		}
		status = switch_ivr_uuid_bridge(switch_core_session_get_uuid(peer_session), bond);
		kz_att_xfer_set_result(peer_channel, status);
		br++;
	} else {
		// switch_channel_set_variable_printf(b_channel, "xfer_uuids", "%s %s", switch_core_session_get_uuid(peer_session), switch_core_session_get_uuid(session));
		switch_channel_set_variable_printf(channel, "xfer_uuids", "%s %s", switch_core_session_get_uuid(peer_session), bond);
		switch_channel_set_variable(channel, "xfer_peer_uuid", switch_core_session_get_uuid(peer_session));

		switch_core_event_hook_add_state_change(session, kz_att_xfer_hanguphook);
		// switch_core_event_hook_add_state_change(b_session, kz_att_xfer_hanguphook);
	}

/*
 * this was commented so that the existing bridge
 * doesn't end
 *
		if (!br) {
			switch_status_t status = switch_ivr_uuid_bridge(switch_core_session_get_uuid(session), bond);
			att_xfer_set_result(channel, status);
		}
*/

	switch_core_session_rwunlock(peer_session);

  end:

	switch_core_event_hook_remove_state_change(session, kz_att_xfer_tmp_hanguphook);

	switch_channel_set_variable(channel, SWITCH_SOFT_HOLDING_UUID_VARIABLE, NULL);
	switch_channel_clear_flag(channel, CF_XFER_ZOMBIE);

	switch_core_session_rwunlock(b_session);
	switch_core_session_rwunlock(session);
	att->running = 0;

	return NULL;
}

SWITCH_STANDARD_APP(kz_att_xfer_function)
{
	switch_thread_t *thread;
	switch_threadattr_t *thd_attr = NULL;
	switch_memory_pool_t *pool = switch_core_session_get_pool(session);
	struct kz_att_obj *att;
	switch_channel_t *channel = switch_core_session_get_channel(session);

	switch_threadattr_create(&thd_attr, pool);
	switch_threadattr_detach_set(thd_attr, 1);
	switch_threadattr_stacksize_set(thd_attr, SWITCH_THREAD_STACKSIZE);
	switch_threadattr_detach_set(thd_attr, 1);

	att = switch_core_session_alloc(session, sizeof(*att));
	att->running = -1;
	att->session = session;
	att->data = switch_core_session_strdup(session, data);
	switch_thread_create(&thread, thd_attr, kz_att_thread_run, att, pool);

	while(att->running && switch_channel_up(channel)) {
		switch_yield(100000);
	}
}

/* kz_deliver_event: ecallmgr's dialplan.apps.event -- fire an event built
 * from "Name=Value,..." with the channel's data attached (Event-Name and
 * Event-Subclass select the type; mod_dptools' `event` app semantics).
 * The route-win dialplan fires ROUTE_WINNER through it. */
SWITCH_STANDARD_APP(kz_deliver_event_function)
{
	switch_event_t *event = NULL;
	char *argv[32] = {0};
	char *vals[32] = {0};
	char *lbuf;
	int argc, x;
	const char *name = NULL, *subclass = NULL;
	switch_event_types_t type = SWITCH_EVENT_CHANNEL_APPLICATION;

	if (zstr(data) || !(lbuf = switch_core_session_strdup(session, data))) {
		return;
	}
	argc = switch_separate_string(lbuf, ',', argv, (sizeof(argv) / sizeof(argv[0])));
	for (x = 0; x < argc; x++) {
		char *val = strchr(argv[x], '=');
		if (!val) continue;
		*val++ = '\0';
		vals[x] = val;
		if (!strcasecmp(argv[x], "Event-Name")) name = val;
		else if (!strcasecmp(argv[x], "Event-Subclass")) subclass = val;
	}
	if (name && switch_name_event(name, &type) != SWITCH_STATUS_SUCCESS) {
		type = SWITCH_EVENT_CUSTOM;
		subclass = name;
	}
	if (type == SWITCH_EVENT_CUSTOM) {
		switch_event_create_subclass(&event, type, switch_str_nil(subclass));
	} else {
		switch_event_create(&event, type);
	}
	if (!event) return;
	switch_channel_event_set_data(switch_core_session_get_channel(session), event);
	for (x = 0; x < argc; x++) {
		if (!vals[x] || zstr(argv[x])) continue;
		if (!strcasecmp(argv[x], "Event-Name") || !strcasecmp(argv[x], "Event-Subclass")) continue;
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, argv[x], vals[x]);
	}
	switch_log_printf(SWITCH_CHANNEL_SESSION_LOG(session), SWITCH_LOG_DEBUG, "kz_deliver_event %s%s%s\n",
					  switch_event_name(type), subclass ? " " : "", switch_str_nil(subclass));
	switch_event_fire(&event);
}

void reprise_kz_dptools_add(switch_loadable_module_interface_t **module_interface) {
	switch_kazoo_intercept_v4();
	switch_application_interface_t *app_interface = NULL;
	SWITCH_ADD_APP(app_interface, "kz_set", SET_SHORT_DESC, SET_LONG_DESC, set_function, SET_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_set_encoded", SET_SHORT_DESC, SET_LONG_DESC, set_encoded_function, SET_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_multiset", MULTISET_SHORT_DESC, MULTISET_LONG_DESC, multiset_function, MULTISET_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_multiset_encoded", MULTISET_SHORT_DESC, MULTISET_LONG_DESC, multiset_encoded_function, MULTISET_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_unset", UNSET_SHORT_DESC, UNSET_LONG_DESC, unset_function, UNSET_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_multiunset", MULTISET_SHORT_DESC, MULTISET_LONG_DESC, multiunset_function, MULTIUNSET_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_export", EXPORT_SHORT_DESC, EXPORT_LONG_DESC, export_function, EXPORT_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_export_encoded", EXPORT_SHORT_DESC, EXPORT_LONG_DESC, export_encoded_function, EXPORT_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_prefix_unset", PREFIX_UNSET_SHORT_DESC, PREFIX_UNSET_LONG_DESC, prefix_unset_function, PREFIX_UNSET_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_uuid_multiset", UUID_MULTISET_SHORT_DESC, UUID_MULTISET_LONG_DESC, uuid_multiset_function, UUID_MULTISET_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_uuid_multiset_encoded", UUID_MULTISET_SHORT_DESC, UUID_MULTISET_LONG_DESC, uuid_multiset_encoded_function, UUID_MULTISET_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_endless_playback", KZ_ENDLESS_PLAYBACK_SHORT_DESC, KZ_ENDLESS_PLAYBACK_LONG_DESC, kz_endless_playback_function, KZ_ENDLESS_PLAYBACK_SYNTAX, SAF_NONE);
	SWITCH_ADD_APP(app_interface, "kz_restore_caller_id", NOOP_SHORT_DESC, NOOP_LONG_DESC, kz_restore_caller_id_function, NOOP_SYNTAX, SAF_NONE);
	SWITCH_ADD_APP(app_interface, "noop", NOOP_SHORT_DESC, NOOP_LONG_DESC, noop_function, NOOP_SYNTAX, SAF_NONE);
	SWITCH_ADD_APP(app_interface, "kz_bridge", "Bridge Audio", "Bridge the audio between two sessions", kz_audio_bridge_function, "<channel_url>", SAF_SUPPORT_NOMEDIA|SAF_SUPPORT_TEXT_ONLY);
	SWITCH_ADD_APP(app_interface, "kz_bridge_uuid", "Bridge Audio", "Bridge the audio between two sessions", kz_audio_bridge_uuid_function, "<channel_url>", SAF_SUPPORT_NOMEDIA|SAF_SUPPORT_TEXT_ONLY);
	SWITCH_ADD_APP(app_interface, "kz_att_xfer", "Attended Transfer", "Attended Transfer", kz_att_xfer_function, "<channel_url>", SAF_NONE);
	SWITCH_ADD_APP(app_interface, "kz_intercept", "intercept", "intercept a Kazoo call", kz_intercept_function, KZ_INTERCEPT_SYNTAX, SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_deliver_event", "Deliver an event", "Fire an event with the channel's data", kz_deliver_event_function, "Event-Name=X,Event-Subclass=Y,...", SAF_SUPPORT_NOMEDIA | SAF_ROUTING_EXEC | SAF_ZOMBIE_EXEC);
	SWITCH_ADD_APP(app_interface, "kz_moh", "Kazoo MOH Playback", "Kazoo MOH Playback", kz_moh_function, "", SAF_NONE);
}
