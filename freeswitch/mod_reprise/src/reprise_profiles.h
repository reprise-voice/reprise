/*
 * reprise_profiles.h -- parsed representation of the kazoo.conf the module
 * fetches over AMQP (see fs-contract-probe samples/kazoo.conf.xml for the
 * concrete schema: connections / amqp-profiles / event-handlers /
 * fetch-handlers / command-handlers / variables / event-dispatcher /
 * event-producer / definitions / caches).
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#ifndef REPRISE_PROFILES_H
#define REPRISE_PROFILES_H

#include <switch.h>
#include "reprise_fields.h"

typedef struct reprise_kv_s {
	char *name;
	char *value;
	struct reprise_kv_s *next;
} reprise_kv_t;

typedef struct reprise_conf_broker_s {
	char *name;
	char *hostname;
	char *virtualhost;
	char *username;
	char *password;
	unsigned int port;
	char *zone;
	int is_primary;
	int is_local;
	int is_federated;
	struct reprise_conf_broker_s *next;
} reprise_conf_broker_t;

typedef struct reprise_exchange_s {
	char *name;
	char *type;
	int durable;
	int auto_delete;
	struct reprise_exchange_s *next;
} reprise_exchange_t;

typedef struct reprise_qbinding_s {
	char *exchange;
	char *routing_key; /* template: may contain ${Core-UUID} etc. */
	int federated;
	struct reprise_qbinding_s *next;
} reprise_qbinding_t;

typedef struct {
	char *name; /* template */
	int exclusive;
	int consume_exclusive;
	int consume_qos;
	reprise_qbinding_t *bindings;
} reprise_queue_t;

/* one part of a routing-key spec: static text, an event field, or a
 * first-of fallback list ("a|b|c") */
typedef struct reprise_rk_field_s {
	char *name;
	char *type;  /* NULL (event field), "static", "first-of", "reference" */
	char *value;
	int encode_part; /* apply kazoo amqp key encoding to this part */
	struct reprise_rk_field_s *next;
} reprise_rk_field_t;

typedef struct {
	reprise_rk_field_t *fields;
	char *hash_event_field; /* event field feeding the hash header */
	char *hash_amqp_header; /* AMQP header name carrying the hash value */
} reprise_routing_key_t;

typedef struct reprise_amqp_profile_s {
	char *name;
	reprise_exchange_t *exchanges;
	reprise_queue_t queue;
	reprise_kv_t *params;
	reprise_kv_t *publisher_fields; /* value templates (e.g. Server-ID) */
	int publisher_delivery_mode;
	int channels;
	uint32_t query_timeout_ms;
	struct reprise_amqp_profile_s *next;
} reprise_amqp_profile_t;

/* one <event> of an event profile: the document it renders and the
 * filters that gate it; a per-event <routing-key> overrides the profile's */
typedef struct reprise_event_s {
	char *name;             /* FS event name, or CUSTOM subclass (sofia::transferee, KZ_CDR) */
	reprise_fields_t *fields;
	reprise_filter_t *filters;
	reprise_routing_key_t routing_key;
	int has_routing_key;
	struct reprise_event_s *next;
} reprise_event_t;

typedef struct reprise_event_profile_s {
	char *name;
	char *amqp_exchange;
	char *amqp_profile;
	reprise_kv_t *params;
	reprise_event_t *events;
	int event_count;
	reprise_filter_t *filters;            /* profile-level gate */
	reprise_fields_t *override_fields;    /* applied after the event's fields */
	reprise_routing_key_t routing_key;
	struct reprise_event_profile_s *next;
} reprise_event_profile_t;

typedef struct reprise_fetch_profile_s {
	char *name;
	char *fetch_section;
	char *amqp_exchange;
	char *amqp_profile;
	uint64_t fetch_timeout_us; /* dialplan path counts in MICROseconds */
	reprise_routing_key_t routing_key;
	reprise_fields_t *fields; /* the request document (references <definitions>) */
	struct reprise_fetch_profile_s *next;
} reprise_fetch_profile_t;

typedef struct {
	switch_memory_pool_t *pool; /* owns every string in this struct */
	char *version;
	char *local_zone;
	reprise_conf_broker_t *brokers;
	reprise_amqp_profile_t *amqp_profiles;
	reprise_event_profile_t *event_profiles;
	reprise_fetch_profile_t *fetch_profiles;
	reprise_kv_t *variables;
	reprise_kv_t *preprocess; /* <X-PRE-PROCESS cmd=".." data=".."/>: name=cmd, value=data, document order */
	reprise_definition_t *definitions;
	int n_brokers, n_amqp_profiles, n_event_profiles, n_fetch_profiles, n_variables, n_definitions, n_preprocess;

	/* lifetime: holders pin it; a retired (replaced) config is freed by
	 * the last release (see reprise_config_hold/release) */
	int refs;
	int retired;
} reprise_config_t;

/* parse the fetched kazoo.conf reply (the full <document> XML). Returns NULL
 * and logs on structural failure. The result owns a dedicated pool. */
reprise_config_t *reprise_config_parse(const char *xml_str);
void reprise_config_destroy(reprise_config_t **config);

/* expand ${Core-UUID} / ${AMQP-Profile-Name} in a template into buf.
 * ${AMQP-Worker-PID} / ${AMQP-Channel-ID} need worker context and are
 * expanded where workers exist (later phases). */
void reprise_expand_template(const char *tpl, const char *profile_name, char *buf, switch_size_t buflen);

#endif /* REPRISE_PROFILES_H */

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
