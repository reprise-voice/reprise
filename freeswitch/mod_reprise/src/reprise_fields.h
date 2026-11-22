/*
 * reprise_fields.h -- the kazoo.conf field/filter grammar: <definitions>,
 * <fields>/<field>, <filters>/<filter>, rendered from a FreeSWITCH event
 * into the JSON kz_api message Kazoo expects. Ported from mod_kazoo's
 * kazoo_config.c / kazoo_message.c, extended for the closed module's
 * additions (prefixes, contains, prefix-exception, non-verbose default).
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * Portions derived from FreeSWITCH's mod_kazoo (kazoo_config.c,
 * kazoo_message.c), distributed under the Mozilla Public License 1.1;
 * Copyright (C) 2005-2012, Anthony Minessale II <anthm@freeswitch.org>
 * and the mod_kazoo contributors.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#ifndef REPRISE_FIELDS_H
#define REPRISE_FIELDS_H

#include <switch.h>
#include <switch_json.h>

#define REPRISE_LIST_MAX 32

typedef struct {
	char *value[REPRISE_LIST_MAX];
	int size;
} reprise_list_t;

typedef enum {
	REPRISE_FILTER_EXCLUDE = 0,
	REPRISE_FILTER_INCLUDE
} reprise_filter_type_t;

typedef enum {
	REPRISE_CMP_VALUE = 0,
	REPRISE_CMP_PREFIX,
	REPRISE_CMP_PREFIXES,
	REPRISE_CMP_LIST,
	REPRISE_CMP_EXISTS,
	REPRISE_CMP_CONTAINS,
	REPRISE_CMP_TOKEN, /* one whole |-separated token, e.g. a Channel-Flags name */
	REPRISE_CMP_REGEX,
	REPRISE_CMP_FIELD
} reprise_filter_cmp_t;

typedef struct reprise_filter_s {
	reprise_filter_type_t type;
	reprise_filter_cmp_t compare;
	char *name;
	char *value;
	reprise_list_t list;       /* list / prefixes values */
	reprise_list_t exceptions; /* prefix-exception values */
	struct reprise_filter_s *children; /* nested filters retain include/exclude polarity */
	int children_any;              /* recovered scope="any" evaluation (default: all) */
	struct reprise_filter_s *next;
} reprise_filter_t;

typedef enum {
	REPRISE_FIELD_COPY = 0,
	REPRISE_FIELD_STATIC,
	REPRISE_FIELD_FIRST_OF,
	REPRISE_FIELD_EXPAND,
	REPRISE_FIELD_PREFIX,
	REPRISE_FIELD_PREFIXES,
	REPRISE_FIELD_GROUP,
	REPRISE_FIELD_REFERENCE,
	REPRISE_FIELD_API
} reprise_field_in_t;

typedef enum {
	REPRISE_JSON_STRING = 0,
	REPRISE_JSON_NUMBER,
	REPRISE_JSON_BOOLEAN,
	REPRISE_JSON_OBJECT,
	REPRISE_JSON_RAW
} reprise_field_out_t;

struct reprise_fields_s;
struct reprise_definition_s;

typedef struct reprise_field_s {
	char *name;
	char *value;
	char *as;
	reprise_field_in_t in_type;
	reprise_field_out_t out_type;
	int out_as_array;
	int exclude_prefix;
	int target_input; /* target="input": replace an event header for subsequent fields */
	reprise_list_t list;       /* first-of names / prefixes */
	reprise_list_t exceptions; /* prefix-exception values */
	reprise_filter_t *filters;
	struct reprise_definition_s *ref; /* type=reference, resolved by name */
	struct reprise_fields_s *children;
	struct reprise_field_s *next;
} reprise_field_t;

typedef struct reprise_fields_s {
	reprise_field_t *head;
	int verbose; /* dump every event header first (closed module: off unless verbose="true") */
} reprise_fields_t;

typedef struct reprise_definition_s {
	char *name;
	reprise_field_t *head;
	reprise_filter_t *filters;
	int visit; /* cycle check scratch (reprise_definitions_parse) */
	struct reprise_definition_s *next;
} reprise_definition_t;

/* renderer recursion bound: nested <fields> plus reference chains */
#define REPRISE_FIELDS_MAX_DEPTH 32

/* parse <definitions> (all of them, references resolved afterwards). A
 * reference that closes a cycle (a definition reaching itself through
 * references) is severed and logged: the renderer follows references
 * recursively and must terminate. */
reprise_definition_t *reprise_definitions_parse(switch_memory_pool_t *pool, switch_xml_t definitions);
/* parse the <fields> child of node against the definitions; NULL if absent */
reprise_fields_t *reprise_fields_parse(switch_memory_pool_t *pool, switch_xml_t node, reprise_definition_t *defs);
/* parse the <filters> child of node; NULL if absent */
reprise_filter_t *reprise_filters_parse(switch_memory_pool_t *pool, switch_xml_t node);
/* parse the <field> children of parent (an <override-fields>, say) */
reprise_field_t *reprise_field_list_parse(switch_memory_pool_t *pool, switch_xml_t parent, reprise_definition_t *defs);

/* the filter that rejected the event, or NULL when it passes */
reprise_filter_t *reprise_filters_apply(switch_event_t *event, reprise_filter_t *filters);
/* render an event through a field list into a new JSON object */
cJSON *reprise_fields_render(reprise_fields_t *fields, switch_event_t *event, const char *tag);
/* add fields to an existing object */
void reprise_fields_add(cJSON *dst, switch_event_t *event, reprise_field_t *head, const char *tag);

/* ${header} / ${func(args)} / $${global} expansion against an event.
 * Returns `in` itself when nothing expands (do not free), else malloc'd.
 * Returns NULL on allocation failure or excessive nesting. Positive slice
 * offsets past the value return an empty slice; negative offsets preceding
 * the value retain the existing whole-value behavior. */
char *reprise_expand_headers(switch_event_t *event, const char *in);
/* url-decode every header value in place */
void reprise_event_decode(switch_event_t *event);

/* the first-of API ("first-of a|b|#default") the expand grammar calls */
switch_status_t reprise_first_of_api(const char *cmd, switch_core_session_t *session, switch_stream_handle_t *stream);

#endif /* REPRISE_FIELDS_H */

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
