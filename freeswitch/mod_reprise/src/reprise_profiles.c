/*
 * reprise_profiles.c -- parse the AMQP-fetched kazoo.conf into transport
 * structure. Schema reference: fs-contract-probe samples/kazoo.conf.xml.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "reprise.h"
#include "reprise_profiles.h"

static char *pdup(switch_memory_pool_t *pool, const char *s)
{
	return s ? switch_core_strdup(pool, s) : NULL;
}

/* <param name=... value=...> children of node -> kv list (prepends) */
static reprise_kv_t *parse_params(switch_memory_pool_t *pool, switch_xml_t node, const char *tag)
{
	switch_xml_t param;
	reprise_kv_t *head = NULL;

	if (!node) return NULL;

	for (param = switch_xml_child(node, tag); param; param = param->next) {
		const char *name = switch_xml_attr_soft(param, "name");
		const char *value = switch_xml_attr_soft(param, "value");
		reprise_kv_t *kv;

		if (zstr(name)) continue;
		kv = switch_core_alloc(pool, sizeof(*kv));
		kv->name = pdup(pool, name);
		kv->value = pdup(pool, value);
		kv->next = head;
		head = kv;
	}
	return head;
}

static const char *kv_get(reprise_kv_t *kvs, const char *name, const char *dflt)
{
	for (; kvs; kvs = kvs->next) {
		if (!strcmp(kvs->name, name)) return kvs->value;
	}
	return dflt;
}

static int kv_true(reprise_kv_t *kvs, const char *name, int dflt)
{
	const char *v = kv_get(kvs, name, NULL);
	return v ? switch_true(v) : dflt;
}

static int kv_int(reprise_kv_t *kvs, const char *name, int dflt)
{
	const char *v = kv_get(kvs, name, NULL);
	return v ? atoi(v) : dflt;
}

static reprise_conf_broker_t *parse_connections(switch_memory_pool_t *pool, switch_xml_t connections, int *count)
{
	switch_xml_t conn;
	reprise_conf_broker_t *head = NULL;

	for (conn = switch_xml_child(connections, "connection"); conn; conn = conn->next) {
		reprise_kv_t *params = parse_params(pool, conn, "param");
		reprise_kv_t *props = parse_params(pool, conn, "property");
		reprise_conf_broker_t *broker = switch_core_alloc(pool, sizeof(*broker));

		broker->name = pdup(pool, switch_xml_attr_soft(conn, "name"));
		broker->hostname = pdup(pool, kv_get(params, "hostname", "localhost"));
		broker->virtualhost = pdup(pool, kv_get(params, "virtualhost", "/"));
		broker->username = pdup(pool, kv_get(params, "username", "guest"));
		broker->password = pdup(pool, kv_get(params, "password", "guest"));
		broker->port = (unsigned int) kv_int(params, "port", 5672);
		broker->zone = pdup(pool, kv_get(params, "zone", kv_get(props, "zone", "local")));
		broker->is_primary = kv_true(props, "primary", 0);
		broker->is_local = kv_true(props, "is-local", 0);
		broker->is_federated = kv_true(props, "is-federated", 0);
		broker->next = head;
		head = broker;
		(*count)++;
	}
	return head;
}

static reprise_exchange_t *parse_exchanges(switch_memory_pool_t *pool, switch_xml_t declares)
{
	switch_xml_t exchange;
	reprise_exchange_t *head = NULL;

	if (!declares) return NULL;

	for (exchange = switch_xml_child(declares, "exchange"); exchange; exchange = exchange->next) {
		reprise_kv_t *params = parse_params(pool, exchange, "param");
		reprise_exchange_t *ex = switch_core_alloc(pool, sizeof(*ex));

		ex->name = pdup(pool, kv_get(params, "name", ""));
		ex->type = pdup(pool, kv_get(params, "type", "topic"));
		ex->durable = kv_true(params, "durable", 0);
		ex->auto_delete = kv_true(params, "auto_delete", 0);
		ex->next = head;
		head = ex;
	}
	return head;
}

static void parse_queue(switch_memory_pool_t *pool, switch_xml_t queue, reprise_queue_t *out)
{
	switch_xml_t binding;
	reprise_kv_t *params;

	if (!queue) return;

	params = parse_params(pool, queue, "param");
	out->name = pdup(pool, kv_get(params, "name", ""));
	out->exclusive = kv_true(params, "exclusive", 0);
	out->consume_exclusive = kv_true(params, "consume-exclusive", 0);
	out->consume_qos = kv_int(params, "consume-qos", 0);

	for (binding = switch_xml_child(queue, "binding"); binding; binding = binding->next) {
		reprise_kv_t *bparams = parse_params(pool, binding, "param");
		reprise_qbinding_t *b = switch_core_alloc(pool, sizeof(*b));

		b->exchange = pdup(pool, kv_get(bparams, "exchange", ""));
		b->routing_key = pdup(pool, kv_get(bparams, "routing-key", ""));
		b->federated = kv_true(bparams, "federated", 0);
		b->next = out->bindings;
		out->bindings = b;
	}
}

static void parse_routing_key(switch_memory_pool_t *pool, switch_xml_t rk, reprise_routing_key_t *out)
{
	switch_xml_t field;
	reprise_kv_t *params;
	reprise_rk_field_t *tail = NULL;

	if (!rk) return;

	/* field order is the key part order: keep document order */
	for (field = switch_xml_child(rk, "field"); field; field = field->next) {
		const char *encode = switch_xml_attr(field, "encode-part");
		reprise_rk_field_t *f = switch_core_alloc(pool, sizeof(*f));

		f->name = pdup(pool, switch_xml_attr_soft(field, "name"));
		f->type = pdup(pool, switch_xml_attr(field, "type"));
		f->value = pdup(pool, switch_xml_attr(field, "value"));
		f->encode_part = encode ? switch_true(encode) : 1;

		if (tail) {
			tail->next = f;
		} else {
			out->fields = f;
		}
		tail = f;
	}

	params = parse_params(pool, rk, "param");
	out->hash_event_field = pdup(pool, kv_get(params, "hash-event-field", NULL));
	out->hash_amqp_header = pdup(pool, kv_get(params, "hash-amqp-header", NULL));
}

static reprise_amqp_profile_t *parse_amqp_profiles(switch_memory_pool_t *pool, switch_xml_t section, int *count)
{
	switch_xml_t prof;
	reprise_amqp_profile_t *head = NULL;

	for (prof = switch_xml_child(section, "profile"); prof; prof = prof->next) {
		switch_xml_t publisher = switch_xml_child(prof, "publisher");
		reprise_amqp_profile_t *p = switch_core_alloc(pool, sizeof(*p));

		p->name = pdup(pool, switch_xml_attr_soft(prof, "name"));
		p->exchanges = parse_exchanges(pool, switch_xml_child(prof, "declare-exchanges"));
		parse_queue(pool, switch_xml_child(prof, "queue"), &p->queue);
		p->params = parse_params(pool, switch_xml_child(prof, "params"), "param");
		p->channels = kv_int(p->params, "channels", 1);
		p->query_timeout_ms = (uint32_t) kv_int(p->params, "query-timeout-ms", REPRISE_DEFAULT_FETCH_TIMEOUT_MS);

		if (publisher) {
			reprise_kv_t *pub_params = parse_params(pool, switch_xml_child(publisher, "params"), "param");
			p->publisher_delivery_mode = kv_int(pub_params, "delivery-mode", 0);
			p->publisher_fields = parse_params(pool, switch_xml_child(publisher, "fields"), "field");
		}

		p->next = head;
		head = p;
		(*count)++;
	}
	return head;
}

static reprise_event_profile_t *parse_event_profiles(switch_memory_pool_t *pool, switch_xml_t section,
												 reprise_definition_t *defs, int *count)
{
	switch_xml_t prof;
	reprise_event_profile_t *head = NULL;

	for (prof = switch_xml_child(section, "profile"); prof; prof = prof->next) {
		switch_xml_t events = switch_xml_child(prof, "events");
		switch_xml_t event, override;
		reprise_event_t **tail;
		reprise_event_profile_t *p = switch_core_alloc(pool, sizeof(*p));

		p->name = pdup(pool, switch_xml_attr_soft(prof, "name"));
		p->params = parse_params(pool, switch_xml_child(prof, "params"), "param");
		p->amqp_exchange = pdup(pool, kv_get(p->params, "amqp-exchange", NULL));
		p->amqp_profile = pdup(pool, kv_get(p->params, "amqp-profile", NULL));
		parse_routing_key(pool, switch_xml_child(prof, "routing-key"), &p->routing_key);
		p->filters = reprise_filters_parse(pool, prof);
		if ((override = switch_xml_child(prof, "override-fields"))) {
			p->override_fields = switch_core_alloc(pool, sizeof(*p->override_fields));
			p->override_fields->head = reprise_field_list_parse(pool, override, defs);
		}

		tail = &p->events;
		for (event = events ? switch_xml_child(events, "event") : NULL; event; event = event->next) {
			switch_xml_t rk = switch_xml_child(event, "routing-key");
			reprise_event_t *e = switch_core_alloc(pool, sizeof(*e));

			e->name = pdup(pool, switch_xml_attr_soft(event, "name"));
			e->fields = reprise_fields_parse(pool, event, defs);
			e->filters = reprise_filters_parse(pool, event);
			if (rk) {
				parse_routing_key(pool, rk, &e->routing_key);
				e->has_routing_key = 1;
			}
			*tail = e;
			tail = &e->next;
			p->event_count++;
		}

		p->next = head;
		head = p;
		(*count)++;
	}
	return head;
}

static reprise_fetch_profile_t *parse_fetch_profiles(switch_memory_pool_t *pool, switch_xml_t section,
												 reprise_definition_t *defs, int *count)
{
	switch_xml_t prof;
	reprise_fetch_profile_t *head = NULL;

	for (prof = switch_xml_child(section, "profile"); prof; prof = prof->next) {
		reprise_kv_t *params = parse_params(pool, switch_xml_child(prof, "params"), "param");
		reprise_fetch_profile_t *p = switch_core_alloc(pool, sizeof(*p));

		p->name = pdup(pool, switch_xml_attr_soft(prof, "name"));
		p->fetch_section = pdup(pool, kv_get(params, "fetch-section", p->name));
		p->amqp_exchange = pdup(pool, kv_get(params, "amqp-exchange", REPRISE_EXCHANGE_FREESWITCH));
		p->amqp_profile = pdup(pool, kv_get(params, "amqp-profile", "fetch"));
		p->fetch_timeout_us = (uint64_t) kv_int(params, "fetch-timeout", 3500000);
		parse_routing_key(pool, switch_xml_child(prof, "routing-key"), &p->routing_key);
		p->fields = reprise_fields_parse(pool, prof, defs);

		p->next = head;
		head = p;
		(*count)++;
	}
	return head;
}

reprise_config_t *reprise_config_parse(const char *xml_str)
{
	switch_memory_pool_t *pool = NULL;
	reprise_config_t *config = NULL;
	switch_xml_t doc = NULL, section, configuration, node;
	char *dup = strdup(xml_str);

	if (!dup) return NULL;

	if (!(doc = switch_xml_parse_str_dynamic(dup, SWITCH_FALSE))) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR, "kazoo.conf: unparseable XML\n");
		free(dup);
		return NULL;
	}
	/* dup is now owned by doc (dup=FALSE) and freed by switch_xml_free */

	if (!(section = switch_xml_child(doc, "section"))
		|| !(configuration = switch_xml_child(section, "configuration"))) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_ERROR,
						  "kazoo.conf: missing section/configuration structure\n");
		switch_xml_free(doc);
		return NULL;
	}

	switch_core_new_memory_pool(&pool);
	config = switch_core_alloc(pool, sizeof(*config));
	config->pool = pool;
	config->version = pdup(pool, switch_xml_attr_soft(configuration, "version"));

	if ((node = switch_xml_child(configuration, "connections"))) {
		config->local_zone = pdup(pool, switch_xml_attr_soft(node, "local-zone"));
		config->brokers = parse_connections(pool, node, &config->n_brokers);
	}
	if ((node = switch_xml_child(configuration, "amqp-profiles"))) {
		config->amqp_profiles = parse_amqp_profiles(pool, node, &config->n_amqp_profiles);
	}
	if ((node = switch_xml_child(configuration, "definitions"))) {
		reprise_definition_t *d;
		config->definitions = reprise_definitions_parse(pool, node);
		for (d = config->definitions; d; d = d->next) config->n_definitions++;
	}
	if ((node = switch_xml_child(configuration, "event-handlers"))) {
		config->event_profiles = parse_event_profiles(pool, node, config->definitions, &config->n_event_profiles);
	}
	if ((node = switch_xml_child(configuration, "fetch-handlers"))) {
		config->fetch_profiles = parse_fetch_profiles(pool, node, config->definitions, &config->n_fetch_profiles);
	}
	/* X-PRE-PROCESS elements (the community module's kz_xml_process:
	 * set / exec-set / stun-set / env-set), kept in document order and
	 * applied before the <variables> when the document is applied */
	{
		reprise_kv_t *tail = NULL;
		for (node = switch_xml_child(configuration, "X-PRE-PROCESS"); node; node = node->next) {
			const char *cmd = switch_xml_attr(node, "cmd"), *data = switch_xml_attr(node, "data");
			reprise_kv_t *kv;
			if (zstr(cmd) || zstr(data)) continue;
			kv = switch_core_alloc(pool, sizeof(*kv));
			kv->name = switch_core_strdup(pool, cmd);
			kv->value = switch_core_strdup(pool, data);
			if (tail) tail->next = kv; else config->preprocess = kv;
			tail = kv;
			config->n_preprocess++;
		}
	}
	if ((node = switch_xml_child(configuration, "variables"))) {
		reprise_kv_t *kv;
		config->variables = parse_params(pool, node, "variable");
		for (kv = config->variables; kv; kv = kv->next) config->n_variables++;
	}

	switch_xml_free(doc);

	switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO,
					  "kazoo.conf parsed: version %s, %d brokers (zone %s), %d amqp profiles, "
					  "%d event profiles, %d fetch profiles, %d variables, %d definitions\n",
					  config->version, config->n_brokers, config->local_zone,
					  config->n_amqp_profiles, config->n_event_profiles,
					  config->n_fetch_profiles, config->n_variables, config->n_definitions);
	return config;
}

/* the document's <variables>: the closed module set them as core
 * globals. origination_nested_vars is a stock core switch (relaxes the
 * originate variable checks); the sofia-profile-override-* entries are
 * read by the 2600hz fork's mod_sofia only and are harmless here. */
void reprise_config_apply_variables(reprise_config_t *config)
{
	reprise_kv_t *kv;
	int applied = 0;

	if (!config) return;
	for (kv = config->preprocess; kv; kv = kv->next) {
		kz_xml_preprocess(kv->name, kv->value);
	}
	for (kv = config->variables; kv; kv = kv->next) {
		if (zstr(kv->name)) continue;
		switch_core_set_variable(kv->name, switch_str_nil(kv->value));
		applied++;
	}
	if (applied || config->n_preprocess) {
		switch_log_printf(SWITCH_CHANNEL_LOG, SWITCH_LOG_INFO, "kazoo.conf: %d X-PRE-PROCESS applied, %d variables set as core globals\n", config->n_preprocess, applied);
	}
}

void reprise_config_destroy(reprise_config_t **config)
{
	if (config && *config) {
		switch_memory_pool_t *pool = (*config)->pool;
		*config = NULL;
		switch_core_destroy_memory_pool(&pool);
	}
}

void reprise_expand_template(const char *tpl, const char *profile_name, char *buf, switch_size_t buflen)
{
	const char *in = tpl;
	switch_size_t used = 0;

	buf[0] = '\0';
	while (*in && used + 1 < buflen) {
		const char *repl = NULL;
		if (!strncmp(in, "${Core-UUID}", 12)) {
			repl = reprise_globals.core_uuid;
			in += 12;
		} else if (!strncmp(in, "${AMQP-Profile-Name}", 20)) {
			repl = profile_name ? profile_name : "";
			in += 20;
		} else {
			buf[used++] = *in++;
			continue;
		}
		while (*repl && used + 1 < buflen) {
			buf[used++] = *repl++;
		}
	}
	buf[used] = '\0';
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
