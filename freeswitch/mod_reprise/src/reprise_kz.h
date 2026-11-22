/*
 * reprise_kz.h -- declarations for the call-machinery files ported from
 * OpenKazoo's mod_kazoo (kazoo_dptools.c, kazoo_commands.c,
 * kazoo_tweaks.c): the kz_* dialplan apps and APIs ecallmgr's dialplans
 * and call-control commands use, and the channel tweaks (interaction id,
 * loopback vars, bridge variables, transfers).
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#ifndef REPRISE_KZ_H
#define REPRISE_KZ_H

#include "reprise.h"
#include "reprise_fields.h"

#define INTERACTION_VARIABLE "Call-Interaction-ID"
/* the kz endpoint's leg bookkeeping (names from the freeswitch-kazoo 20.23.6 binary) */
#define KZ_ORIGINATE_UUID_VARIABLE "kz_originate_aleg_uuid"
#define KZ_ENDPOINT_IDS_VARIABLE "kz-call-endpoint-ids"
#define KZ_BRIDGE_ID "ecallmgr_Bridge-ID"
#define UNIX_EPOCH_IN_GREGORIAN 62167219200
#define UNIX_EPOCH_IN_GREGORIAN_STR "62167219200"
#define KZ_MAX_SEPARATE_STRINGS 10

typedef enum {
	KZ_TWEAK_INTERACTION_ID = 0,
	KZ_TWEAK_EXPORT_VARS,
	KZ_TWEAK_SWITCH_URI,
	KZ_TWEAK_REPLACES_CALL_ID,
	KZ_TWEAK_LOOPBACK_VARS,
	KZ_TWEAK_CALLER_ID,
	KZ_TWEAK_TRANSFERS,
	KZ_TWEAK_BRIDGE,
	KZ_TWEAK_BRIDGE_REPLACES_ALEG,
	KZ_TWEAK_BRIDGE_REPLACES_CALL_ID,
	KZ_TWEAK_BRIDGE_VARIABLES,
	KZ_TWEAK_RESTORE_CALLER_ID_ON_BLIND_XFER,
	KZ_TWEAK_MAX
} kz_tweak_t;

#define kz_test_tweak(flag) (reprise_globals.tweaks[flag] ? 1 : 0)
#define kz_set_tweak(flag) reprise_globals.tweaks[flag] = 1

/* the ported code's expansion entry points map onto reprise_fields */
#define kz_event_expand_headers reprise_expand_headers

/* reprise_kzutils.c */
void kz_check_set_profile_var(switch_channel_t *channel, char *var, char *val);
switch_status_t kz_switch_core_merge_variables(switch_event_t *event);
switch_status_t kz_switch_core_base_headers_for_expand(switch_event_t **event);
char *kz_expand(const char *in, const char *uuid);
switch_status_t kz_switch_event_add_variable_name_printf(switch_event_t *event, switch_stack_t stack, const char *val, const char *fmt, ...);
switch_status_t kz_expand_json_to_event(cJSON *json, switch_event_t *event, char *prefix);
void kz_event_add_interaction(switch_event_t *event);
switch_status_t kz_expand_headers(switch_event_t *resolver, switch_event_t *event);
switch_status_t kz_expand_headers_self(switch_event_t *event);
/* argument splitting with quotes/escapes and the ^^<d> delimiter prefix (kz_* API syntax) */
unsigned int kz_switch_separate_string(char *buf, char delim, char **array, unsigned int arraylen);
char *kz_cleanup_separated_string(char *str, char delim);

/* reprise_tweaks.c: "<gregorian seconds>-<8 alnum>" */
switch_bool_t kz_is_valid_interaction_id(const char *interaction_id);
/* reprise_tweaks.c: the host part of a sofia_profile_uri ("sip:user@host" -> "host"; no '@': the whole string) */
const char *kz_switch_uri_host(const char *profile_url);
/* reprise_kzutils.c: the sample length of a media file for the session's codec (0 if it cannot be opened) */
switch_size_t kz_max_media_samples(switch_core_session_t *session, const char *file);
/* reprise_dptools.c: kz_prefix_unset's prefix list (one, '|'-joined, or ^^<d>) */
int kz_split_prefixes(char *arg, char **argv, int max);
/* reprise_kzcommands.c: kz_put_use_curl_http_version names -> CURLOPT_HTTP_VERSION values, -1 unknown */
long kz_curl_http_version(const char *name);
/* reprise_cdr.c: one originated_legs / originate_causes item as its CDR object */
cJSON *kz_cdr_originated_leg_json(const char *item);
cJSON *kz_cdr_originate_cause_json(const char *item);

/* reprise_originate.c -- kz_originate / kz_originate_cancel / kz_originate_list */
void reprise_kz_originate_add(switch_loadable_module_interface_t **module_interface);
void kz_originate_init(void);
void kz_originate_shutdown(void);
void kz_originate_shutdown_wait(int max_wait_ms); /* cancel in-flight attempts, wait, then free (or keep) the registry */
switch_call_cause_t *kz_add_originate_uuid(const char *uuid); /* NULL: already in flight */
switch_status_t kz_remove_originate_uuid(const char *uuid);
switch_status_t kz_cancel_originate_uuid(const char *uuid, switch_call_cause_t cause);
int kz_originate_count(void);

/* reprise_prompts.c -- the prompt:// file interface */
void reprise_prompts_start(switch_loadable_module_interface_t **module_interface); /* NULL: cache only (tests) */
void reprise_prompts_stop(void);
void reprise_prompts_status(switch_stream_handle_t *stream);
char *kz_prompt_get(const char *path);                 /* malloc'd http_cache:// URL, or NULL */
char *reprise_prompt_url_from_reply(switch_xml_t node);   /* malloc'd, or NULL */
/* the cache itself (bounded: REPRISE_PROMPT_CACHE_MAX entries, expired ones swept) */
void kz_prompt_cache_put(const char *path, const char *url, switch_time_t ttl_us);
char *kz_prompt_cache_get(const char *path);          /* malloc'd, or NULL (missing or expired) */
int kz_prompt_cache_count(void);

/* reprise_compat.c: the 2600hz-fork app-data forms (see the file). Returns 1
 * when rewritten: *pre (malloc, may be NULL) is a `multiset` argument to
 * run before the app, *out (malloc) the app's data */
int kz_app_compat(const char *app, const char *data, char **pre, char **out);
/* sendevent NOTIFY contact-uri in the fork's fs_path form -> stock's; malloc'd or NULL */
char *kz_notify_contact_compat(const char *contact);

/* reprise_endpoints.c -- the "kz" endpoint ecallmgr's bridge strings use (kz/...) */
void reprise_kz_endpoints_add(switch_loadable_module_interface_t **module_interface);
char *kz_endpoint_expand_dial(switch_event_t *event, const char *input); /* owned result or NULL */
int kz_endpoint_context_has_flag(cJSON *ctx, const char *flag);

/* reprise_dptools.c */
void kz_set(switch_core_session_t *session, const char *data, int urldecode);
void kz_multiset(switch_core_session_t *session, const char *data, int urldecode);
void kz_export(switch_core_session_t *session, const char *data, int urldecode);
void kz_uuid_multiset(switch_core_session_t *session, const char *data, int urldecode);
void reprise_kz_dptools_add(switch_loadable_module_interface_t **module_interface);

/* reprise_kzcommands.c */
switch_status_t kz_uuid_setvar(int urldecode, const char *cmd, switch_core_session_t *session, switch_stream_handle_t *stream);
switch_status_t kz_uuid_setvar_multi(int urldecode, const char *cmd, switch_core_session_t *session, switch_stream_handle_t *stream);
void reprise_kz_commands_add(switch_loadable_module_interface_t **module_interface);

/* reprise_cdr.c -- the KZ_CDR event fired on reporting (mod_kazoo's kazoo_cdr.c) */
void kz_cdr_start(void);
void kz_cdr_stop(void);

/* reprise_tweaks.c */
void kz_tweaks_start(void);
void kz_tweaks_stop(void);
const char *kz_tweak_name(kz_tweak_t tweak);
switch_status_t kz_name_tweak(const char *name, kz_tweak_t *type);

#endif /* REPRISE_KZ_H */

int reprise_event_is_suppressed(switch_event_t *event);
