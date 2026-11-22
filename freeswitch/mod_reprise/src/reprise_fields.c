/*
 * reprise_fields.c -- kazoo.conf field/filter grammar: parser, event -> JSON
 * renderer, and the ${...} expansion engine. See reprise_fields.h.
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
#include "reprise.h"
#include "reprise_fields.h"

/*---------------------------------------------------------------------------
 * parsing
 *-------------------------------------------------------------------------*/

static char *pdup(switch_memory_pool_t *pool, const char *s)
{
	return s ? switch_core_strdup(pool, s) : NULL;
}

static void split_list(switch_memory_pool_t *pool, const char *value, reprise_list_t *list)
{
	char *dup;
	if (zstr(value)) {
		list->size = 0;
		return;
	}
	dup = switch_core_strdup(pool, value);
	list->size = switch_separate_string(dup, '|', list->value, REPRISE_LIST_MAX);
}

static void parse_exceptions(switch_memory_pool_t *pool, switch_xml_t node, reprise_list_t *list)
{
	switch_xml_t ex;
	list->size = 0;
	for (ex = switch_xml_child(node, "prefix-exception"); ex && list->size < REPRISE_LIST_MAX; ex = ex->next) {
		const char *value = switch_xml_attr(ex, "value");
		if (!zstr(value)) {
			list->value[list->size++] = pdup(pool, value);
		}
	}
}

reprise_filter_t *reprise_filters_parse(switch_memory_pool_t *pool, switch_xml_t node)
{
	switch_xml_t filters, filter;
	reprise_filter_t *head = NULL, *tail = NULL;

	if (!node || !(filters = switch_xml_child(node, "filters"))) {
		return NULL;
	}

	for (filter = switch_xml_child(filters, "filter"); filter; filter = filter->next) {
		switch_xml_t nested = switch_xml_child(filter, "filters");
		const char *type = switch_xml_attr(filter, "type");
		const char *compare = switch_xml_attr(filter, "compare");
		reprise_filter_t *f = switch_core_alloc(pool, sizeof(*f));

		f->name = pdup(pool, switch_xml_attr(filter, "name"));
		f->value = pdup(pool, switch_xml_attr(filter, "value"));
		f->type = (type && !strcasecmp(type, "include")) ? REPRISE_FILTER_INCLUDE : REPRISE_FILTER_EXCLUDE;
		f->compare = REPRISE_CMP_VALUE;

		if (compare) {
			if (!strcasecmp(compare, "value")) f->compare = REPRISE_CMP_VALUE;
			else if (!strcasecmp(compare, "prefixes")) f->compare = REPRISE_CMP_PREFIXES;
			else if (!strcasecmp(compare, "prefix")) f->compare = REPRISE_CMP_PREFIX;
			else if (!strcasecmp(compare, "list")) f->compare = REPRISE_CMP_LIST;
			else if (!strcasecmp(compare, "exists")) f->compare = REPRISE_CMP_EXISTS;
			else if (!strcasecmp(compare, "contains")) f->compare = REPRISE_CMP_CONTAINS;
			else if (!strcasecmp(compare, "token")) f->compare = REPRISE_CMP_TOKEN;
			else if (!strcasecmp(compare, "regex")) f->compare = REPRISE_CMP_REGEX;
			else if (!strcasecmp(compare, "field")) f->compare = REPRISE_CMP_FIELD;
		}
		if (!f->value) {
			f->compare = REPRISE_CMP_EXISTS;
		}
		if (f->compare == REPRISE_CMP_LIST || f->compare == REPRISE_CMP_PREFIXES) {
			split_list(pool, f->value, &f->list);
		}
		parse_exceptions(pool, filter, &f->exceptions);
		if (nested) {
			const char *scope = switch_xml_attr(nested, "scope");
			f->children = reprise_filters_parse(pool, filter);
			f->children_any = scope && !strcasecmp(scope, "any");
		}

		if (tail) tail->next = f; else head = f;
		tail = f;
	}
	return head;
}

static reprise_definition_t *find_definition(reprise_definition_t *defs, const char *name)
{
	for (; defs; defs = defs->next) {
		if (!strcmp(defs->name, name)) return defs;
	}
	return NULL;
}

static reprise_field_t *parse_field_list(switch_memory_pool_t *pool, switch_xml_t parent, reprise_definition_t *defs);

static reprise_field_t *parse_field(switch_memory_pool_t *pool, switch_xml_t node, reprise_definition_t *defs)
{
	const char *type = switch_xml_attr(node, "type");
	const char *serialize_as = switch_xml_attr(node, "serialize-as");
	const char *as_array = switch_xml_attr(node, "as-array");
	const char *exclude_prefix = switch_xml_attr(node, "exclude-prefix");
	const char *target = switch_xml_attr(node, "target");
	switch_xml_t fields_node;
	reprise_field_t *f = switch_core_alloc(pool, sizeof(*f));

	f->name = pdup(pool, switch_xml_attr(node, "name"));
	f->value = pdup(pool, switch_xml_attr(node, "value"));
	f->as = pdup(pool, switch_xml_attr(node, "as"));
	f->in_type = REPRISE_FIELD_COPY;
	f->out_type = REPRISE_JSON_STRING;

	if (type) {
		if (!strcasecmp(type, "copy")) f->in_type = REPRISE_FIELD_COPY;
		else if (!strcasecmp(type, "static")) f->in_type = REPRISE_FIELD_STATIC;
		else if (!strcasecmp(type, "first-of")) f->in_type = REPRISE_FIELD_FIRST_OF;
		else if (!strcasecmp(type, "expand")) f->in_type = REPRISE_FIELD_EXPAND;
		else if (!strcasecmp(type, "prefixes")) f->in_type = REPRISE_FIELD_PREFIXES;
		else if (!strcasecmp(type, "prefix")) f->in_type = REPRISE_FIELD_PREFIX;
		else if (!strcasecmp(type, "group")) f->in_type = REPRISE_FIELD_GROUP;
		else if (!strcasecmp(type, "reference")) f->in_type = REPRISE_FIELD_REFERENCE;
		else if (!strcasecmp(type, "api")) f->in_type = REPRISE_FIELD_API;
	}
	if (serialize_as) {
		if (!strcasecmp(serialize_as, "number")) f->out_type = REPRISE_JSON_NUMBER;
		else if (!strcasecmp(serialize_as, "boolean")) f->out_type = REPRISE_JSON_BOOLEAN;
		else if (!strcasecmp(serialize_as, "object")) f->out_type = REPRISE_JSON_OBJECT;
		else if (!strcasecmp(serialize_as, "raw")) f->out_type = REPRISE_JSON_RAW;
	}
	f->out_as_array = as_array ? switch_true(as_array) : 0;
	f->exclude_prefix = exclude_prefix ? switch_true(exclude_prefix) : 0;
	f->target_input = target && !strcasecmp(target, "input");
	if (f->target_input && (f->in_type == REPRISE_FIELD_PREFIX || f->in_type == REPRISE_FIELD_PREFIXES)) {
		/* The prefix walk iterates the input's own header list; rewriting the
		 * input in place would free the node under iteration. */
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING, "field %s: target=\"input\" is not supported on %s fields, ignoring\n",
						  switch_str_nil(f->name), type);
		f->target_input = 0;
	}

	f->filters = reprise_filters_parse(pool, node);
	if ((fields_node = switch_xml_child(node, "fields"))) {
		const char *verbose = switch_xml_attr(fields_node, "verbose");
		f->children = switch_core_alloc(pool, sizeof(*f->children));
		f->children->verbose = verbose ? switch_true(verbose) : 0;
		f->children->head = parse_field_list(pool, fields_node, defs);
		if (f->in_type == REPRISE_FIELD_STATIC && !serialize_as) {
			f->out_type = REPRISE_JSON_OBJECT;
		}
	}
	if (f->in_type == REPRISE_FIELD_FIRST_OF || f->in_type == REPRISE_FIELD_PREFIXES) {
		split_list(pool, f->value, &f->list);
	}
	parse_exceptions(pool, node, &f->exceptions);

	if (f->in_type == REPRISE_FIELD_REFERENCE && f->name) {
		f->ref = find_definition(defs, f->name); /* may resolve later (forward refs) */
	}
	return f;
}

static reprise_field_t *parse_field_list(switch_memory_pool_t *pool, switch_xml_t parent, reprise_definition_t *defs)
{
	switch_xml_t node;
	reprise_field_t *head = NULL, *tail = NULL;

	for (node = switch_xml_child(parent, "field"); node; node = node->next) {
		reprise_field_t *f = parse_field(pool, node, defs);
		if (tail) tail->next = f; else head = f;
		tail = f;
	}
	return head;
}

reprise_field_t *reprise_field_list_parse(switch_memory_pool_t *pool, switch_xml_t parent, reprise_definition_t *defs)
{
	return parent ? parse_field_list(pool, parent, defs) : NULL;
}

reprise_fields_t *reprise_fields_parse(switch_memory_pool_t *pool, switch_xml_t node, reprise_definition_t *defs)
{
	switch_xml_t fields_node;
	reprise_fields_t *fields;
	const char *verbose;

	if (!node || !(fields_node = switch_xml_child(node, "fields"))) {
		return NULL;
	}
	verbose = switch_xml_attr(fields_node, "verbose");
	fields = switch_core_alloc(pool, sizeof(*fields));
	fields->verbose = verbose ? switch_true(verbose) : 0;
	fields->head = parse_field_list(pool, fields_node, defs);
	return fields;
}

static void resolve_refs(reprise_field_t *head, reprise_definition_t *defs)
{
	for (; head; head = head->next) {
		if (head->in_type == REPRISE_FIELD_REFERENCE && !head->ref && head->name) {
			if (!(head->ref = find_definition(defs, head->name))) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_WARNING,
								  "kazoo.conf: referenced definition %s not found\n", head->name);
			}
		}
		if (head->children) {
			resolve_refs(head->children->head, defs);
		}
	}
}

enum { VISIT_NONE = 0, VISIT_IN_PROGRESS, VISIT_DONE };

static int sever_cycles(reprise_definition_t *owner, reprise_field_t *head);

/* depth-first over the reference graph; a reference back into a
 * definition still on the stack closes a cycle and is severed */
static int visit_definition(reprise_definition_t *d)
{
	int severed = 0;
	if (d->visit == VISIT_DONE) return 0;
	d->visit = VISIT_IN_PROGRESS;
	severed = sever_cycles(d, d->head);
	d->visit = VISIT_DONE;
	return severed;
}

static int sever_cycles(reprise_definition_t *owner, reprise_field_t *head)
{
	int severed = 0;
	for (; head; head = head->next) {
		if (head->in_type == REPRISE_FIELD_REFERENCE && head->ref) {
			if (head->ref->visit == VISIT_IN_PROGRESS) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
								  "kazoo.conf: definition %s references %s, which references it back; reference dropped\n",
								  owner->name, head->ref->name);
				head->ref = NULL;
				severed++;
			} else {
				severed += visit_definition(head->ref);
			}
		}
		if (head->children) {
			severed += sever_cycles(owner, head->children->head);
		}
	}
	return severed;
}

reprise_definition_t *reprise_definitions_parse(switch_memory_pool_t *pool, switch_xml_t definitions)
{
	switch_xml_t node;
	reprise_definition_t *head = NULL, *tail = NULL, *d;
	int severed = 0;

	if (!definitions) return NULL;

	/* pass 1: names, so forward references resolve */
	for (node = switch_xml_child(definitions, "definition"); node; node = node->next) {
		const char *name = switch_xml_attr(node, "name");
		if (zstr(name)) continue;
		d = switch_core_alloc(pool, sizeof(*d));
		d->name = pdup(pool, name);
		if (tail) tail->next = d; else head = d;
		tail = d;
	}
	/* pass 2: bodies */
	d = head;
	for (node = switch_xml_child(definitions, "definition"); node && d; node = node->next) {
		const char *name = switch_xml_attr(node, "name");
		if (zstr(name)) continue;
		d->filters = reprise_filters_parse(pool, node);
		d->head = parse_field_list(pool, node, head);
		d = d->next;
	}
	for (d = head; d; d = d->next) {
		resolve_refs(d->head, head);
	}
	/* self and mutual references would recurse without end in the
	 * renderer (profile fields only reach definitions, so checking the
	 * definitions covers every path) */
	for (d = head; d; d = d->next) {
		severed += visit_definition(d);
	}
	if (severed) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "kazoo.conf: %d cyclic definition reference(s) dropped\n", severed);
	}
	return head;
}

/*---------------------------------------------------------------------------
 * filters
 *-------------------------------------------------------------------------*/

static int list_has_prefix(reprise_list_t *list, const char *name, const char **matched)
{
	int n;
	for (n = 0; n < list->size; n++) {
		if (!strncmp(name, list->value[n], strlen(list->value[n]))) {
			if (matched) *matched = list->value[n];
			return 1;
		}
	}
	return 0;
}

static int filter_compare(switch_event_t *event, reprise_filter_t *f)
{
	switch_event_header_t *header;
	const char *value = NULL;
	char *expanded = NULL;
	int has = 0, n;

	if (f->name && *f->name == '$'
		&& (f->compare == REPRISE_CMP_VALUE || f->compare == REPRISE_CMP_FIELD
			|| f->compare == REPRISE_CMP_LIST || f->compare == REPRISE_CMP_CONTAINS || f->compare == REPRISE_CMP_TOKEN)) {
		expanded = reprise_expand_headers(event, f->name);
		value = expanded;
		if (expanded == f->name) expanded = NULL;
	} else if (f->name) {
		value = switch_event_get_header(event, f->name);
	}

	switch (f->compare) {
	case REPRISE_CMP_EXISTS:
		has = value != NULL;
		break;
	case REPRISE_CMP_VALUE:
		has = value && f->value && !strcmp(value, f->value);
		break;
	case REPRISE_CMP_FIELD:
		has = value && !strcmp(value, switch_event_get_header_nil(event, f->value));
		break;
	case REPRISE_CMP_CONTAINS:
		has = value && f->value && strstr(value, f->value) != NULL;
		break;
	case REPRISE_CMP_TOKEN:
		if (value && f->value) {
			size_t len = strlen(f->value);
			const char *p = value;
			for (;;) {
				const char *end = strchr(p, '|');
				size_t n = end ? (size_t) (end - p) : strlen(p);
				if (n == len && !strncmp(p, f->value, len)) {
					has = 1;
					break;
				}
				if (!end) break;
				p = end + 1;
			}
		}
		break;
	case REPRISE_CMP_PREFIX:
		for (header = event->headers; header; header = header->next) {
			if (f->value && !strncmp(header->name, f->value, strlen(f->value))
				&& !list_has_prefix(&f->exceptions, header->name, NULL)) {
				has = 1;
				break;
			}
		}
		break;
	case REPRISE_CMP_PREFIXES:
		for (header = event->headers; header; header = header->next) {
			if (list_has_prefix(&f->list, header->name, NULL)
				&& !list_has_prefix(&f->exceptions, header->name, NULL)) {
				has = 1;
				break;
			}
		}
		break;
	case REPRISE_CMP_LIST:
		if (value) {
			for (n = 0; n < f->list.size; n++) {
				if (!strncmp(value, f->list.value[n], strlen(f->list.value[n]))) {
					has = 1;
					break;
				}
			}
		}
		break;
	case REPRISE_CMP_REGEX:
		if (value && f->value) {
			switch_regex_t *re = NULL;
#ifdef SWITCH_PCRE2
			/* 1.11+: pcre2; the match data replaces the caller's ovector and
			 * is handed back (like the compiled re) for the caller to free */
			switch_regex_match_t *match = NULL;
			has = switch_regex_perform(value, f->value, &re, &match) > 0;
			switch_regex_match_safe_free(match);
#else
			int ovector[30];
			has = switch_regex_perform(value, f->value, &re, ovector, sizeof(ovector) / sizeof(ovector[0])) > 0;
#endif
			switch_regex_safe_free(re);
		}
		break;
	}

	switch_safe_free(expanded);
	return has;
}

/* Nested groups apply include/exclude polarity recursively. Under scope=any
 * the first include that holds (a leaf, or one whose child group accepts)
 * satisfies the group and the first exclude that hits rejects it; an include
 * that does not hold only rejects when no sibling satisfies the group. The
 * distributed kazoo_message.c let the first include leaf decide either way. */
static reprise_filter_t *filter_event(switch_event_t *event, reprise_filter_t *filter, int any)
{
 reprise_filter_t *miss = NULL;
 for (; filter; filter = filter->next) {
  int has = filter_compare(event, filter);
  if (filter->type == REPRISE_FILTER_EXCLUDE) {
   if (has && (!filter->children || filter_event(event, filter->children, filter->children_any))) return filter;
  } else if (has && (!filter->children || !filter_event(event, filter->children, filter->children_any))) {
   /* include satisfied: under scope=any that settles the group */
   if (any) return NULL;
  } else if (!any) {
   return filter;
  } else if (!miss) {
   /* under scope=any an unsatisfied include only rejects when no sibling satisfies the group */
   miss = filter;
  }
 }
 return miss;
}

reprise_filter_t *reprise_filters_apply(switch_event_t *event, reprise_filter_t *filters)
{
 return filter_event(event, filters, 0);
}

/*---------------------------------------------------------------------------
 * rendering
 *-------------------------------------------------------------------------*/

static void json_replace(cJSON *object, const char *key, cJSON *item)
{
	cJSON_DeleteItemFromObject(object, key);
	cJSON_AddItemToObject(object, key, item);
}

static cJSON *json_value(reprise_field_out_t type, const char *value)
{
	cJSON *item = NULL;
	switch (type) {
	case REPRISE_JSON_STRING: item = cJSON_CreateString(value); break;
	case REPRISE_JSON_NUMBER: item = cJSON_CreateNumber(strtod(value, NULL)); break;
	case REPRISE_JSON_BOOLEAN: item = cJSON_CreateBool(switch_true(value)); break;
	case REPRISE_JSON_OBJECT: item = cJSON_CreateObject(); break;
	case REPRISE_JSON_RAW:
		if (!(item = cJSON_Parse(value))) {
			item = cJSON_CreateRaw(value);
		}
		break;
	}
	return item;
}

static cJSON *add_value(cJSON *dst, switch_event_t *src, reprise_field_t *f, const char *key, const char *value)
{
	cJSON *item;
	if (f->target_input) {
		/* Copy before deleting: value may belong to the header being replaced. */
		char *copy = switch_safe_strdup(value);
		if (!zstr(copy)) {
			switch_event_del_header(src, key);
			switch_event_add_header_string(src, SWITCH_STACK_BOTTOM, key, copy);
		}
		switch_safe_free(copy);
		return NULL;
	}
	if (!value && f->out_type != REPRISE_JSON_OBJECT) return NULL;
	if ((item = json_value(f->out_type, value))) {
		json_replace(dst, key, item);
	}
	return item;
}

static cJSON *add_header(cJSON *dst, switch_event_t *src, reprise_field_t *f, const char *key, switch_event_header_t *header)
{
	cJSON *item;
	int i;

	if (header->idx) {
		item = cJSON_CreateArray();
		for (i = 0; i < header->idx; i++) {
			cJSON_AddItemToArray(item, json_value(f->out_type, header->array[i]));
		}
		json_replace(dst, key, item);
		return item;
	}
	if (f->out_as_array) {
		item = cJSON_CreateArray();
		cJSON_AddItemToArray(item, json_value(f->out_type, header->value));
		json_replace(dst, key, item);
		return item;
	}
	return add_value(dst, src, f, key, header->value);
}

static void dump_headers(cJSON *dst, switch_event_t *event)
{
	switch_event_header_t *hp;
	for (hp = event->headers; hp; hp = hp->next) {
		if (!strncmp(hp->name, "_json_", 6)) continue;
		if (hp->idx) {
			cJSON *a = cJSON_CreateArray();
			int i;
			for (i = 0; i < hp->idx; i++) cJSON_AddItemToArray(a, cJSON_CreateString(hp->array[i]));
			json_replace(dst, hp->name, a);
		} else {
			json_replace(dst, hp->name, cJSON_CreateString(hp->value));
		}
	}
}

static cJSON *render_field(cJSON *dst, switch_event_t *src, reprise_field_t *f)
{
	const char *key = f->as ? f->as : f->name;
	switch_event_header_t *header, *next;
	cJSON *item = NULL;
	int n;

	switch (f->in_type) {
	case REPRISE_FIELD_COPY:
		if (!f->name) break;
		if (!strcmp(f->name, "_body")) {
			item = add_value(dst, src, f, key, src->body);
		} else if ((header = switch_event_get_header_ptr(src, f->name))) {
			item = add_header(dst, src, f, key, header);
		}
		break;

	case REPRISE_FIELD_EXPAND: {
		char *expanded = reprise_expand_headers(src, f->value);
		if (!zstr(expanded)) {
			item = add_value(dst, src, f, key, expanded);
		}
		if (expanded != f->value) switch_safe_free(expanded);
		break;
	}

	case REPRISE_FIELD_FIRST_OF:
		for (n = 0; n < f->list.size; n++) {
			const char *cand = f->list.value[n];
			if (*cand == '#') { /* literal default */
				item = add_value(dst, src, f, key, cand + 1);
				break;
			}
			if ((header = switch_event_get_header_ptr(src, cand))) {
				item = add_header(dst, src, f, key, header);
				break;
			}
		}
		break;

	case REPRISE_FIELD_PREFIX:
	case REPRISE_FIELD_PREFIXES:
		for (header = src->headers; header; header = next) {
			const char *matched = NULL;
			next = header->next;
			if (f->in_type == REPRISE_FIELD_PREFIX) {
				if (!f->name || strncmp(header->name, f->name, strlen(f->name))) continue;
				matched = f->name;
			} else if (!list_has_prefix(&f->list, header->name, &matched)) {
				continue;
			}
			if (list_has_prefix(&f->exceptions, header->name, NULL)) continue;
			add_header(dst, src, f, f->exclude_prefix ? header->name + strlen(matched) : header->name, header);
		}
		break;

	case REPRISE_FIELD_STATIC:
		item = add_value(dst, src, f, f->name, f->value);
		break;

	case REPRISE_FIELD_GROUP:
		item = dst;
		break;

	case REPRISE_FIELD_API: /* one event-profile use; not rendered */
	case REPRISE_FIELD_REFERENCE:
		break;
	}
	return item;
}

static void fields_add(cJSON *dst, switch_event_t *src, reprise_field_t *head, const char *tag, int depth)
{
	reprise_field_t *f;
	reprise_filter_t *rejected;

	if (depth > REPRISE_FIELDS_MAX_DEPTH) {
		/* cycles are severed at parse time; this is the backstop */
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "%s: field nesting deeper than %d; not rendered\n", tag, REPRISE_FIELDS_MAX_DEPTH);
		return;
	}
	for (f = head; f; f = f->next) {
		if (f->in_type == REPRISE_FIELD_REFERENCE) {
			if (!f->ref) continue;
			if ((rejected = reprise_filters_apply(src, f->ref->filters))) {
				switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "%s: definition %s filtered by %s\n",
								  tag, f->ref->name, switch_str_nil(rejected->name));
				continue;
			}
			fields_add(dst, src, f->ref->head, tag, depth + 1);
			continue;
		}
		if ((rejected = reprise_filters_apply(src, f->filters))) {
			switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_DEBUG1, "%s: field %s filtered by %s\n",
							  tag, switch_str_nil(f->name), switch_str_nil(rejected->name));
			continue;
		}
		{
			cJSON *item = render_field(dst, src, f);
			if (item && f->children) {
				cJSON *target = (f->out_type == REPRISE_JSON_OBJECT) ? item : dst;
				if (f->children->verbose && f->out_type == REPRISE_JSON_OBJECT) {
					dump_headers(item, src);
				}
				fields_add(target, src, f->children->head, tag, depth + 1);
			}
		}
	}
}

void reprise_fields_add(cJSON *dst, switch_event_t *src, reprise_field_t *head, const char *tag)
{
	fields_add(dst, src, head, tag, 0);
}

cJSON *reprise_fields_render(reprise_fields_t *fields, switch_event_t *event, const char *tag)
{
	cJSON *json = cJSON_CreateObject();
	switch_event_header_t *ts;

	if (fields && fields->verbose) {
		dump_headers(json, event);
	}
	if ((ts = switch_event_get_header_ptr(event, "Event-Date-Timestamp"))) {
		json_replace(json, "Event-Timestamp", json_value(REPRISE_JSON_NUMBER, ts->value));
	}
	if (fields) {
		reprise_fields_add(json, event, fields->head, tag);
	}
	return json;
}

/*---------------------------------------------------------------------------
 * expansion: ${header}, ${header:offset}, $${global}, ${func(args)} --
 * FreeSWITCH's switch_event_expand_headers with the API-call form the
 * kazoo.conf grammar uses (regex(...), first-of(...), url_decode(...)).
 * Ported from mod_kazoo's kz_event_expand_headers_check.
 *-------------------------------------------------------------------------*/

/* Update the capacity only after realloc succeeds. A failed growth must
 * never leave the caller writing into the old, smaller allocation. */
#define reprise_resize(l) do { \
	size_t extra = (l), capacity; \
	char *dp; \
	if (extra > SIZE_MAX - len - 1) goto fail; \
	capacity = len + extra + 1; \
	if (capacity <= SIZE_MAX - 128) capacity += 128; \
	cpos = c - data; \
	if (!(dp = realloc(data, capacity))) goto fail; \
	data = dp; \
	olen = capacity; \
	c = data + cpos; \
	memset(c, 0, olen - cpos); \
} while (0)

static switch_status_t expand_api_execute(const char *cmd, const char *arg, switch_stream_handle_t *stream)
{
	switch_api_interface_t *api;
	switch_status_t status;
	char *cmd_used = switch_strip_whitespace(cmd);
	char *arg_used = switch_strip_whitespace(arg);

	if (cmd_used && (api = switch_loadable_module_get_api_interface(cmd_used))) {
		status = api->function(arg_used, NULL, stream);
		UNPROTECT_INTERFACE(api);
	} else {
		status = SWITCH_STATUS_FALSE;
	}
	if (cmd_used != cmd) switch_safe_free(cmd_used);
	if (arg_used != arg) switch_safe_free(arg_used);
	return status;
}

static char *expand_check(switch_event_t *event, const char *in, uint32_t recur)
{
	char *p, *c = NULL;
	char *data, *indup, *endof_indup;
	size_t sp = 0, len = 0, olen = 0, vtype = 0, br = 0, cpos;
	const char *sub_val = NULL;
	char *cloned_sub_val = NULL, *expanded_sub_val = NULL;
	char *func_val = NULL;
	int nv = 0;
	char *gvar = NULL, *sb = NULL;

	if (recur > 100) return NULL;
	if (zstr(in)) {
		return (char *) in;
	}

	nv = switch_string_var_check_const(in) || switch_string_has_escaped_data(in);
	if (!nv) {
		return (char *) in;
	}

	nv = 0;
	olen = strlen(in) + 1;
	indup = strdup(in);
	if (!indup) return NULL;
	endof_indup = end_of_p(indup) + 1;

	if ((data = malloc(olen))) {
		memset(data, 0, olen);
		c = data;
		for (p = indup; p && p < endof_indup && *p; p++) {
			int global = 0;
			vtype = 0;

			if (*p == '\\') {
				if (*(p + 1) == '$') {
					nv = 1;
					p++;
					if (*(p + 1) == '$') {
						p++;
					}
				} else if (*(p + 1) == '\'') {
					p++;
					continue;
				} else if (*(p + 1) == '\\') {
					if (len + 1 >= olen) {
						reprise_resize(1);
					}
					*c++ = *p++;
					len++;
					continue;
				}
			}

			if (*p == '$' && !nv) {
				if (*(p + 1) == '$') {
					p++;
					global++;
				}
				if (*(p + 1)) {
					if (*(p + 1) == '{') {
						vtype = global ? 3 : 1;
					} else {
						nv = 1;
					}
				} else {
					nv = 1;
				}
			}

			if (nv) {
				if (len + 1 >= olen) {
					reprise_resize(1);
				}
				*c++ = *p;
				len++;
				nv = 0;
				continue;
			}

			if (vtype) {
				char *s = p, *e, *vname, *vval = NULL;
				size_t nlen;

				s++;
				if ((vtype == 1 || vtype == 3) && *s == '{') {
					br = 1;
					s++;
				}

				e = s;
				vname = s;
				while (*e) {
					if (br == 1 && *e == '}') {
						br = 0;
						*e++ = '\0';
						break;
					}
					if (br > 0) {
						if (e != s && *e == '{') {
							br++;
						} else if (br > 1 && *e == '}') {
							br--;
						}
					}
					e++;
				}
				p = e > endof_indup ? endof_indup : e;

				vval = NULL;
				for (sb = vname; sb && *sb; sb++) {
					if (*sb == ' ') {
						vval = sb;
						break;
					} else if (*sb == '(') {
						vval = sb;
						br = 1;
						break;
					}
				}

				if (vval) {
					e = vval - 1;
					*vval++ = '\0';
					while (e >= vname && *e == ' ') {
						*e-- = '\0';
					}
					e = vval;
					while (e && *e) {
						if (*e == '(') {
							br++;
						} else if (br > 1 && *e == ')') {
							br--;
						} else if (br == 1 && *e == ')') {
							*e = '\0';
							break;
						}
						e++;
					}
					vtype = 2;
				}

				if (vtype == 1 || vtype == 3) {
					char *expanded = NULL;
					long offset = 0;
					long ooffset = 0;
					char *ptr;
					int idx = -1;

					if ((expanded = expand_check(event, (char *) vname, recur + 1)) == vname) {
						expanded = NULL;
					} else {
						if (!expanded) goto fail;
						vname = expanded;
					}
					if ((ptr = strchr(vname, ':'))) {
						*ptr++ = '\0';
						offset = strtol(ptr, NULL, 10);
						if ((ptr = strchr(ptr, ':'))) {
							ptr++;
							ooffset = strtol(ptr, NULL, 10);
						}
					}
					if ((ptr = strchr(vname, '[')) && strchr(ptr, ']')) {
						*ptr++ = '\0';
						long index = strtol(ptr, NULL, 10);
						idx = index >= 0 && index <= INT_MAX ? (int) index : -1;
					}

					if (vtype == 3 || !(sub_val = switch_event_get_header_idx(event, vname, idx))) {
						switch_safe_free(gvar);
						if ((gvar = switch_core_get_variable_dup(vname))) {
							sub_val = gvar;
						}
						if ((expanded_sub_val = expand_check(event, sub_val, recur + 1)) == sub_val) {
							expanded_sub_val = NULL;
						} else {
							if (sub_val && !expanded_sub_val) {
								switch_safe_free(expanded);
								goto fail;
							}
							sub_val = expanded_sub_val;
						}
					}

					if (sub_val) {
						size_t value_len = strlen(sub_val), start = 0;
						if (offset >= 0) {
							start = (unsigned long) offset < value_len ? (size_t) offset : value_len;
						} else {
							/* Avoid negating LONG_MIN, including strtol underflow. */
							unsigned long magnitude = (unsigned long) (-(offset + 1)) + 1;
							if (magnitude <= value_len) start = value_len - magnitude;
						}
						if (offset || ooffset) {
							cloned_sub_val = strdup(sub_val);
							if (!cloned_sub_val) {
								switch_safe_free(expanded);
								goto fail;
							}
							sub_val = cloned_sub_val;
						}
						sub_val += start;
						if (ooffset > 0 && (unsigned long) ooffset < value_len - start) {
							if ((ptr = (char *) sub_val + ooffset)) {
								*ptr = '\0';
							}
						}
					}
					switch_safe_free(expanded);
				} else {
					char *expanded = NULL;
					char *expanded_vname = NULL;

					if ((expanded_vname = expand_check(event, (char *) vname, recur + 1)) == vname) {
						expanded_vname = NULL;
					} else {
						if (!expanded_vname) goto fail;
						vname = expanded_vname;
					}
					if ((expanded = expand_check(event, vval, recur + 1)) == vval) {
						expanded = NULL;
					} else {
						if (!expanded) {
							switch_safe_free(expanded_vname);
							goto fail;
						}
						vval = expanded;
					}

					{
						switch_stream_handle_t stream = { 0 };
						SWITCH_STANDARD_STREAM(stream);
						stream.param_event = event;
						if (expand_api_execute(vname, vval, &stream) == SWITCH_STATUS_SUCCESS) {
							func_val = stream.data;
							sub_val = func_val;
						} else {
							free(stream.data);
						}
					}
					switch_safe_free(expanded);
					switch_safe_free(expanded_vname);
				}

				if ((nlen = sub_val ? strlen(sub_val) : 0)) {
					if (nlen >= olen - len) {
						reprise_resize(nlen);
					}
					len += nlen;
					strcat(c, sub_val);
					c += nlen;
				}

				switch_safe_free(func_val);
				switch_safe_free(cloned_sub_val);
				switch_safe_free(expanded_sub_val);
				sub_val = NULL;
				vname = NULL;
				br = 0;
			}

			if (sp) {
				if (len + 1 >= olen) {
					reprise_resize(1);
				}
				*c++ = ' ';
				sp = 0;
				len++;
			}

			if (*p == '$') {
				p--;
			} else {
				if (len + 1 >= olen) {
					reprise_resize(1);
				}
				*c++ = *p;
				len++;
			}
		}
	}
	free(indup);
	switch_safe_free(gvar);

	return data;

fail:
	switch_safe_free(func_val);
	switch_safe_free(cloned_sub_val);
	switch_safe_free(expanded_sub_val);
	switch_safe_free(gvar);
	free(indup);
	free(data);
	return NULL;
}

char *reprise_expand_headers(switch_event_t *event, const char *in)
{
	return expand_check(event, in, 0);
}

void reprise_event_decode(switch_event_t *event)
{
	switch_event_header_t *hp;
	int i;
	for (hp = event->headers; hp; hp = hp->next) {
		if (!strncmp(hp->name, "_json_", 6)) continue;
		if (hp->idx) {
			for (i = 0; i < hp->idx; i++) switch_url_decode(hp->array[i]);
		} else {
			switch_url_decode(hp->value);
		}
	}
}

/* first-of a|b|#default: the first header present in the expansion's
 * param event (or the session's channel), or the literal after # */
switch_status_t reprise_first_of_api(const char *cmd, switch_core_session_t *session, switch_stream_handle_t *stream)
{
	char delim = '|';
	char *mycmd, *dup, *argv[REPRISE_LIST_MAX] = {0};
	int argc, n;
	switch_channel_t *channel = session ? switch_core_session_get_channel(session) : NULL;

	if (zstr(cmd)) {
		return SWITCH_STATUS_GENERR;
	}
	dup = mycmd = strdup(cmd);
	if (!dup) return SWITCH_STATUS_MEMERR;
	/* ^^<d>: the delimiter must be there ("^^" alone would read past the NUL) */
	if (*mycmd == '^' && *(mycmd + 1) == '^') {
		if (!mycmd[2]) {
			free(dup);
			return SWITCH_STATUS_GENERR;
		}
		mycmd += 2;
		delim = *mycmd++;
	}
	argc = switch_separate_string(mycmd, delim, argv, REPRISE_LIST_MAX);
	for (n = 0; n < argc; n++) {
		const char *item = argv[n];
		const char *var = NULL;

		if (*item == '#' || *item == '!' || *item == '?') {
			if (*(++item)) {
				stream->write_function(stream, "%s", item);
				break;
			}
			continue;
		}
		if (channel) {
			var = switch_channel_get_variable_dup(channel, item, SWITCH_FALSE, -1);
			if (!var && !strncmp(item, "variable_", 9)) {
				var = switch_channel_get_variable_dup(channel, item + 9, SWITCH_FALSE, -1);
			}
		}
		if (zstr(var) && stream->param_event) {
			var = switch_event_get_header(stream->param_event, item);
		}
		/* an empty value does not win (freeswitch-kazoo 20.23.6) */
		if (!zstr(var)) {
			stream->write_function(stream, "%s", var);
			break;
		}
	}
	free(dup);
	return SWITCH_STATUS_SUCCESS;
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
