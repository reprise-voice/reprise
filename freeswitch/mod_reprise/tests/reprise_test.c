/*
 * reprise_test.c -- unit tests for the pure parts of the module: the
 * kazoo.conf field/filter grammar and renderer (reprise_fields.c), the ${...}
 * expansion engine, the kazoo.conf parser (reprise_profiles.c), routing keys
 * (reprise_fetch.c) and the presence-dialog derivation (reprise_presence.c).
 * Runs against libfreeswitch's minimal core: no modules, no config.
 *
 *   make test      (runs in tests/run; tests/fixtures/kazoo.conf.xml is
 *                   the served document of the test cluster, password
 *                   scrubbed; REPRISE_TEST_FIXTURE overrides the path)
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include <switch.h>
#include <test/switch_test.h>
#include "reprise.h"
#include "reprise_fields.h"
#include "reprise_kz.h"
#include <curl/curl.h>

#include "reprise_test_alloc.h"

/* the module's globals live in mod_reprise.o (linked in); only the
 * core uuid matters here (template expansion) */

static switch_event_t *make_event(void)
{
	switch_event_t *e = NULL;
	switch_event_create(&e, SWITCH_EVENT_CHANNEL_CREATE);
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Unique-ID", "11111111-2222-3333-4444-555555555555");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Caller-Caller-ID-Number", "15551230000");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Caller-Destination-Number", "15551230001");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Answer-State", "ringing");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Call-Direction", "inbound");
	switch_event_del_header(e, "Event-Date-Timestamp"); /* the core stamps one at creation; headers append */
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Event-Date-Timestamp", "1756900000000000");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_ecallmgr_Account-ID", "946c4d65726167a7a3c581ce0f42e4f3");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_ecallmgr_Realm", "example.com");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_ecallmgr_Authorizing-Type", "device");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_sip_from_tag", "from-tag-1");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_sip_to_tag", "to-tag-1");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Switch-URI", "sip:10.0.0.5:11000");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_presence_id", "reprisesipp@example.com");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Channel-Presence-ID", "reprisesipp@example.com");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_true_flag", "true");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_duration", "42");
	return e;
}

static switch_xml_t parse_xml(const char *xml)
{
	char *dup = strdup(xml);
	switch_xml_t doc = switch_xml_parse_str_dynamic(dup, SWITCH_FALSE);
	return doc; /* dup owned by doc */
}

static const char *jstr(cJSON *json, const char *key)
{
	cJSON *item = cJSON_GetObjectItem(json, key);
	return (item && item->type == cJSON_String) ? item->valuestring : NULL;
}

static cJSON *jobj(cJSON *json, const char *key)
{
	cJSON *item = cJSON_GetObjectItem(json, key);
	return (item && item->type == cJSON_Object) ? item : NULL;
}

static char *read_file(const char *path)
{
	FILE *f = fopen(path, "rb");
	long len;
	char *buf;
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	len = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = malloc(len + 1);
	if (fread(buf, 1, len, f) != (size_t) len) {
		free(buf);
		fclose(f);
		return NULL;
	}
	buf[len] = '\0';
	fclose(f);
	return buf;
}

static reprise_event_profile_t *event_profile(reprise_config_t *config, const char *name)
{
	reprise_event_profile_t *p;
	for (p = config->event_profiles; p; p = p->next) {
		if (!strcmp(p->name, name)) return p;
	}
	return NULL;
}

static reprise_fetch_profile_t *fetch_profile(reprise_config_t *config, const char *name)
{
	reprise_fetch_profile_t *p;
	for (p = config->fetch_profiles; p; p = p->next) {
		if (!strcmp(p->name, name)) return p;
	}
	return NULL;
}

static reprise_amqp_profile_t *amqp_profile(reprise_config_t *config, const char *name)
{
	reprise_amqp_profile_t *p;
	for (p = config->amqp_profiles; p; p = p->next) {
		if (!strcmp(p->name, name)) return p;
	}
	return NULL;
}

static reprise_event_t *profile_event(reprise_event_profile_t *p, const char *name)
{
	reprise_event_t *e;
	for (e = p ? p->events : NULL; e; e = e->next) {
		if (!strcmp(e->name, name)) return e;
	}
	return NULL;
}

/* every reference in a field list resolved to a definition */
static int refs_resolved(reprise_field_t *head)
{
	for (; head; head = head->next) {
		if (head->in_type == REPRISE_FIELD_REFERENCE && !head->ref) return 0;
		if (head->children && !refs_resolved(head->children->head)) return 0;
	}
	return 1;
}

static const char *FIELDS_DOC =
	"<document>"
	"<definitions>"
	"  <definition name=\"CCVs\">"
	"    <field name=\"Custom-Channel-Vars\" type=\"static\" serialize-as=\"object\">"
	"      <fields>"
	"        <field name=\"variable_ecallmgr_\" type=\"prefix\" exclude-prefix=\"true\">"
	"          <prefix-exception value=\"variable_ecallmgr_Authorizing-Type\"/>"
	"        </field>"
	"      </fields>"
	"    </field>"
	"  </definition>"
	"  <definition name=\"only-outbound\">"
	"    <filters><filter name=\"Call-Direction\" type=\"include\" value=\"outbound\"/></filters>"
	"    <field name=\"Call-Direction\" as=\"Outbound-Direction\"/>"
	"  </definition>"
	"  <definition name=\"uses-ccvs\">"
	"    <field name=\"CCVs\" type=\"reference\"/>"
	"    <field name=\"Nested\" type=\"static\" value=\"yes\"/>"
	"  </definition>"
	"</definitions>"
	"<event>"
	"<fields>"
	"  <field name=\"Unique-ID\" as=\"Call-ID\"/>"
	"  <field name=\"Missing-Header\" as=\"Never\"/>"
	"  <field name=\"Event-Category\" type=\"static\" value=\"call_event\"/>"
	"  <field name=\"Answer\" type=\"static\" value=\"42\" serialize-as=\"number\"/>"
	"  <field name=\"variable_true_flag\" as=\"Flag\" serialize-as=\"boolean\"/>"
	"  <field name=\"variable_duration\" as=\"Duration\" serialize-as=\"number\"/>"
	"  <field name=\"Caller-ID\" type=\"first-of\" value=\"Nope|Caller-Caller-ID-Number|Caller-Destination-Number\"/>"
	"  <field name=\"Defaulted\" type=\"first-of\" value=\"Nope|Nada|#dflt\"/>"
	"  <field name=\"Short-ID\" type=\"expand\" value=\"${Unique-ID:0:8}\"/>"
	"  <field name=\"Empty-Expand\" type=\"expand\" value=\"${Nope}\"/>"
	"  <field name=\"uses-ccvs\" type=\"reference\"/>"
	"  <field name=\"only-outbound\" type=\"reference\"/>"
	"  <field name=\"Tags\" type=\"static\" serialize-as=\"object\">"
	"    <fields>"
	"      <field name=\"variable_sip_\" type=\"prefixes\" value=\"variable_sip_from|variable_sip_to\" exclude-prefix=\"false\"/>"
	"    </fields>"
	"  </field>"
	"  <field name=\"Ringing\" type=\"static\" value=\"true\" serialize-as=\"boolean\">"
	"    <filters><filter name=\"Answer-State\" type=\"include\" value=\"ringing\"/></filters>"
	"  </field>"
	"  <field name=\"Answered\" type=\"static\" value=\"true\" serialize-as=\"boolean\">"
	"    <filters><filter name=\"Answer-State\" type=\"include\" value=\"answered\"/></filters>"
	"  </field>"
	"  <field name=\"Caller-Caller-ID-Number\" as=\"Caller-ID-Number\" target=\"input\"/>"
	"  <field name=\"Body\" type=\"static\" serialize-as=\"raw\" value=\"{&quot;a&quot;:1}\"/>"
	"  <field name=\"Listy\" type=\"first-of\" value=\"Caller-Destination-Number\" as-array=\"true\"/>"
	"</fields>"
	"</event>"
	"</document>";

static const char *FILTERS_DOC =
	"<document>"
	"<f name=\"exclude-value\"><filters><filter name=\"Answer-State\" type=\"exclude\" value=\"ringing\"/></filters></f>"
	"<f name=\"include-value\"><filters><filter name=\"Answer-State\" type=\"include\" value=\"ringing\"/></filters></f>"
	"<f name=\"include-exists\"><filters><filter name=\"Unique-ID\" type=\"include\" compare=\"exists\"/></filters></f>"
	"<f name=\"include-missing\"><filters><filter name=\"Nope\" type=\"include\"/></filters></f>"
	"<f name=\"exclude-prefix\"><filters><filter name=\"ccvs\" type=\"exclude\" compare=\"prefix\" value=\"variable_ecallmgr_\"/></filters></f>"
	"<f name=\"exclude-prefix-excepted\"><filters><filter name=\"ccvs\" type=\"exclude\" compare=\"prefix\" value=\"variable_ecallmgr_\">"
	"  <prefix-exception value=\"variable_ecallmgr_Account-ID\"/><prefix-exception value=\"variable_ecallmgr_Realm\"/>"
	"  <prefix-exception value=\"variable_ecallmgr_Authorizing-Type\"/></filter></filters></f>"
	"<f name=\"include-prefixes\"><filters><filter name=\"x\" type=\"include\" compare=\"prefixes\" value=\"variable_sip_|variable_nope_\"/></filters></f>"
	"<f name=\"include-list\"><filters><filter name=\"Caller-Destination-Number\" type=\"include\" compare=\"list\" value=\"1800|1555\"/></filters></f>"
	"<f name=\"exclude-list\"><filters><filter name=\"Caller-Destination-Number\" type=\"exclude\" compare=\"list\" value=\"1800|1900\"/></filters></f>"
	"<f name=\"include-contains\"><filters><filter name=\"variable_presence_id\" type=\"include\" compare=\"contains\" value=\"@example.\"/></filters></f>"
	"<f name=\"include-regex\"><filters><filter name=\"Caller-Destination-Number\" type=\"include\" compare=\"regex\" value=\"^1555123000[0-9]$\"/></filters></f>"
	"<f name=\"exclude-regex-miss\"><filters><filter name=\"Caller-Destination-Number\" type=\"exclude\" compare=\"regex\" value=\"^1800\"/></filters></f>"
	"<f name=\"include-field\"><filters><filter name=\"Channel-Presence-ID\" type=\"include\" compare=\"field\" value=\"variable_presence_id\"/></filters></f>"
	"<f name=\"include-expanded\"><filters><filter name=\"${Caller-Caller-ID-Number}\" type=\"include\" value=\"15551230000\"/></filters></f>"
	"<f name=\"nested-all\"><filters><filter name=\"Call-Direction\" type=\"include\" value=\"inbound\">"
	"  <filters><filter name=\"Answer-State\" value=\"ringing\"/><filter name=\"Nope\" compare=\"exists\"/></filters></filter></filters></f>"
	"<f name=\"nested-any\"><filters><filter name=\"Call-Direction\" type=\"include\" value=\"inbound\">"
	"  <filters scope=\"any\"><filter name=\"Answer-State\" value=\"ringing\"/><filter name=\"Nope\" compare=\"exists\"/></filters></filter></filters></f>"
	"<f name=\"chain\"><filters><filter name=\"Unique-ID\" type=\"include\"/><filter name=\"Answer-State\" type=\"exclude\" value=\"answered\"/></filters></f>"
	"<f name=\"any-second-include\"><filters><filter name=\"Call-Direction\" type=\"include\" value=\"inbound\">"
	"  <filters scope=\"any\"><filter name=\"Answer-State\" type=\"include\" value=\"answered\"/>"
	"  <filter name=\"Answer-State\" type=\"include\" value=\"ringing\"/></filters></filter></filters></f>"
	"<f name=\"any-no-include-holds\"><filters><filter name=\"Call-Direction\" type=\"include\" value=\"inbound\">"
	"  <filters scope=\"any\"><filter name=\"Answer-State\" type=\"include\" value=\"answered\"/>"
	"  <filter name=\"Answer-State\" type=\"include\" value=\"early\"/></filters></filter></filters></f>"
	"<f name=\"any-child-reject-rescued\"><filters><filter name=\"Call-Direction\" type=\"include\" value=\"inbound\">"
	"  <filters scope=\"any\"><filter name=\"Answer-State\" type=\"include\" value=\"ringing\">"
	"    <filters><filter name=\"Nope\" type=\"include\" compare=\"exists\"/></filters></filter>"
	"  <filter name=\"Call-Direction\" type=\"include\" value=\"inbound\"/></filters></filter></filters></f>"
	"<f name=\"include-token\"><filters><filter name=\"Channel-Flags\" type=\"include\" compare=\"token\" value=\"ATTENDED_TRANSFER\"/></filters></f>"
	"<f name=\"include-token-partial\"><filters><filter name=\"Channel-Flags\" type=\"include\" compare=\"token\" value=\"TRANSFER\"/></filters></f>"
	"<f name=\"include-token-last\"><filters><filter name=\"Channel-Flags\" type=\"include\" compare=\"token\" value=\"BRIDGED\"/></filters></f>"
	"</document>";

static const char *CONF_DOC =
	"<document type=\"freeswitch/xml\"><section name=\"configuration\">"
	"<configuration name=\"kazoo.conf\" version=\"5.4.0\">"
	"<connections local-zone=\"z1\">"
	"  <connection name=\"a\"><param name=\"hostname\" value=\"amqp-a\"/><param name=\"port\" value=\"5673\"/>"
	"    <param name=\"username\" value=\"u\"/><param name=\"password\" value=\"p\"/><param name=\"virtualhost\" value=\"/kz\"/>"
	"    <property name=\"primary\" value=\"true\"/><property name=\"is-local\" value=\"true\"/><property name=\"zone\" value=\"z1\"/></connection>"
	"  <connection name=\"b\"><param name=\"hostname\" value=\"amqp-b\"/><property name=\"is-federated\" value=\"true\"/></connection>"
	"</connections>"
	"<amqp-profiles>"
	"  <profile name=\"fetch\" profile-type=\"worker\">"
	"    <declare-exchanges><exchange><param name=\"name\" value=\"targeted\"/><param name=\"type\" value=\"direct\"/><param name=\"durable\" value=\"true\"/></exchange></declare-exchanges>"
	"    <queue><param name=\"name\" value=\"${Core-UUID}-fetch-${AMQP-Profile-Name}\"/><param name=\"exclusive\" value=\"true\"/><param name=\"consume-qos\" value=\"5\"/>"
	"      <binding><param name=\"exchange\" value=\"targeted\"/><param name=\"routing-key\" value=\"${Core-UUID}-fetch\"/></binding>"
	"      <binding><param name=\"exchange\" value=\"freeswitch\"/><param name=\"routing-key\" value=\"freeswitch.fetch.${Core-UUID}.#\"/><param name=\"federated\" value=\"true\"/></binding>"
	"    </queue>"
	"    <params><param name=\"channels\" value=\"3\"/><param name=\"query-timeout-ms\" value=\"1234\"/></params>"
	"    <publisher><params><param name=\"delivery-mode\" value=\"2\"/></params><fields><field name=\"Server-ID\" value=\"${Core-UUID}-fetch\"/></fields></publisher>"
	"  </profile>"
	"  <profile name=\"priority\" profile-type=\"worker\"><params/></profile>"
	"</amqp-profiles>"
	"<definitions>"
	"  <definition name=\"base\"><field name=\"Unique-ID\" as=\"Call-ID\"/></definition>"
	"  <definition name=\"late\"><field name=\"base\" type=\"reference\"/><field name=\"uses-later\" type=\"reference\"/></definition>"
	"  <definition name=\"uses-later\"><field name=\"Call-Direction\"/></definition>"
	"</definitions>"
	"<event-handlers>"
	"  <profile name=\"priority_events\" profile-type=\"event\">"
	"    <params><param name=\"amqp-exchange\" value=\"callevt\"/><param name=\"amqp-profile\" value=\"priority\"/></params>"
	"    <filters><filter name=\"variable_ecallmgr_Account-ID\" type=\"include\" compare=\"exists\"/></filters>"
	"    <override-fields><field name=\"Node\" type=\"static\" value=\"n1\"/></override-fields>"
	"    <routing-key><param name=\"hash-event-field\" value=\"Unique-ID\"/><param name=\"hash-amqp-header\" value=\"call-id\"/>"
	"      <field name=\"call\" type=\"static\" value=\"call\" encode-part=\"false\"/><field name=\"Event-Name\"/><field name=\"Unique-ID\"/></routing-key>"
	"    <events>"
	"      <event name=\"CHANNEL_CREATE\"><fields><field name=\"late\" type=\"reference\"/><field name=\"Event-Name\" type=\"static\" value=\"CHANNEL_CREATE\"/></fields></event>"
	"      <event name=\"CHANNEL_DESTROY\"><filters><filter name=\"Nope\" type=\"include\"/></filters>"
	"        <routing-key><field name=\"gone\" type=\"static\" value=\"gone\"/><field name=\"Unique-ID\"/></routing-key></event>"
	"    </events>"
	"  </profile>"
	"</event-handlers>"
	"<fetch-handlers>"
	"  <profile name=\"dialplan\" profile-type=\"fetch\">"
	"    <fields><field name=\"base\" type=\"reference\"/></fields>"
	"    <params><param name=\"fetch-timeout\" value=\"5000000\"/><param name=\"fetch-section\" value=\"dialplan\"/><param name=\"amqp-exchange\" value=\"freeswitch\"/><param name=\"amqp-profile\" value=\"fetch\"/></params>"
	"    <routing-key><field name=\"prefix\" type=\"static\" value=\"freeswitch.dialplan\" encode-part=\"false\"/><field name=\"Core-UUID\"/></routing-key>"
	"  </profile>"
	"  <profile name=\"directory\" profile-type=\"fetch\"><params/></profile>"
	"</fetch-handlers>"
	"<variables><variable name=\"origination_nested_vars\" value=\"true\"/><variable name=\"x\" value=\"y\"/></variables>"
	"</configuration></section></document>";

static switch_event_t *make_presence_in(const char *direction, const char *status, const char *answer_state)
{
	switch_event_t *e = make_event();
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "proto", "any");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "from", "reprisesipp@example.com");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "status", status);
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "presence-call-direction", direction);
	switch_event_del_header(e, "Answer-State");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Answer-State", answer_state);
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Event-Name", "PRESENCE_IN");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Event-Sequence", "77");
	return e;
}

FST_MINCORE_BEGIN("../conf")

FST_SUITE_BEGIN(reprise)

FST_SETUP_BEGIN()
{
	switch_copy_string(reprise_globals.core_uuid, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", sizeof(reprise_globals.core_uuid));
}
FST_SETUP_END()

FST_TEARDOWN_BEGIN()
{
}
FST_TEARDOWN_END()

/*---------------------------------------------------------------------------
 * filters
 *-------------------------------------------------------------------------*/

FST_TEST_BEGIN(temporary_channel_event_suppression)
{
	switch_event_t *evt = NULL;
	switch_event_create_plain(&evt, SWITCH_EVENT_CHANNEL_CREATE);
	fst_check(!reprise_event_is_suppressed(evt));
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "variable_NO_EVENTS_PLEASE", "true");
	fst_check(reprise_event_is_suppressed(evt));
	switch_event_del_header(evt, "variable_NO_EVENTS_PLEASE");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "NO_EVENTS_PLEASE", "true");
	fst_check(reprise_event_is_suppressed(evt));
	switch_event_del_header(evt, "NO_EVENTS_PLEASE");
	switch_event_add_header_string(evt, SWITCH_STACK_BOTTOM, "NO_EVENTS_PLEASE", "false");
	fst_check(!reprise_event_is_suppressed(evt));
	switch_event_destroy(&evt);
}
FST_TEST_END()

FST_TEST_BEGIN(filters)
{
	switch_memory_pool_t *pool = NULL;
	switch_xml_t doc = parse_xml(FILTERS_DOC), node;
	switch_event_t *event = make_event();
	/* name -> passes (1) / rejected (0). Nested exclude children keep
	 * their polarity, including scope=any (kazoo_message.c filter_event). */
	struct { const char *name; int passes; } expect[] = {
		{"exclude-value", 0}, {"include-value", 1}, {"include-exists", 1}, {"include-missing", 0},
		{"exclude-prefix", 0}, {"exclude-prefix-excepted", 1}, {"include-prefixes", 1},
		{"include-list", 1}, {"exclude-list", 1}, {"include-contains", 1}, {"include-regex", 1},
		{"exclude-regex-miss", 1}, {"include-field", 1}, {"include-expanded", 1},
		{"nested-all", 0}, {"nested-any", 0}, {"chain", 1},
		{"any-second-include", 1}, {"any-no-include-holds", 0}, {"any-child-reject-rescued", 1},
		{"include-token", 1}, {"include-token-partial", 0}, {"include-token-last", 1}, {NULL, 0}
	};
	int i;

	fst_requires(doc);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Channel-Flags", "ANSWERED|ATTENDED_TRANSFER|BRIDGED");
	switch_core_new_memory_pool(&pool);
	for (i = 0; expect[i].name; i++) {
		int found = 0;
		for (node = switch_xml_child(doc, "f"); node; node = node->next) {
			if (!strcmp(switch_xml_attr_soft(node, "name"), expect[i].name)) {
				reprise_filter_t *filters = reprise_filters_parse(pool, node);
				reprise_filter_t *rejected;
				found = 1;
				fst_requires(filters);
				rejected = reprise_filters_apply(event, filters);
				if (expect[i].passes) {
					fst_xcheck(rejected == NULL, expect[i].name);
				} else {
					fst_xcheck(rejected != NULL, expect[i].name);
				}
			}
		}
		fst_xcheck(found, expect[i].name);
	}
	/* no <filters> child: nothing to apply */
	fst_check(reprise_filters_parse(pool, switch_xml_child(doc, "nope")) == NULL);
	fst_check(reprise_filters_apply(event, NULL) == NULL);

	switch_event_destroy(&event);
	switch_xml_free(doc);
	switch_core_destroy_memory_pool(&pool);
}
FST_TEST_END()

/*---------------------------------------------------------------------------
 * fields -> JSON
 *-------------------------------------------------------------------------*/

FST_TEST_BEGIN(fields_render)
{
	switch_memory_pool_t *pool = NULL;
	switch_xml_t doc = parse_xml(FIELDS_DOC);
	switch_event_t *event = make_event();
	reprise_definition_t *defs;
	reprise_fields_t *fields;
	cJSON *json, *ccvs, *tags, *item;

	fst_requires(doc);
	switch_core_new_memory_pool(&pool);
	defs = reprise_definitions_parse(pool, switch_xml_child(doc, "definitions"));
	fst_requires(defs);
	fields = reprise_fields_parse(pool, switch_xml_child(doc, "event"), defs);
	fst_requires(fields);
	fst_check(fields->verbose == 0);
	fst_check(refs_resolved(fields->head));

	json = reprise_fields_render(fields, event, "test");
	fst_requires(json);

	/* copy + as; missing header not emitted */
	fst_check_string_equals(jstr(json, "Call-ID"), "11111111-2222-3333-4444-555555555555");
	fst_check(cJSON_GetObjectItem(json, "Never") == NULL);
	fst_check(cJSON_GetObjectItem(json, "Unique-ID") == NULL);
	/* Event-Timestamp from Event-Date-Timestamp, as a number */
	item = cJSON_GetObjectItem(json, "Event-Timestamp");
	fst_requires(item);
	fst_check(item->type == cJSON_Number);
	fst_xcheck(item->valuedouble == 1756900000000000.0, switch_core_sprintf(fst_pool, "Event-Timestamp %f", item->valuedouble));
	/* static string / number; serialize-as on copies */
	fst_check_string_equals(jstr(json, "Event-Category"), "call_event");
	item = cJSON_GetObjectItem(json, "Answer");
	fst_requires(item);
	fst_check(item->type == cJSON_Number && item->valueint == 42);
	item = cJSON_GetObjectItem(json, "Flag");
	fst_requires(item);
	fst_check(item->type == cJSON_True);
	item = cJSON_GetObjectItem(json, "Duration");
	fst_requires(item);
	fst_check(item->type == cJSON_Number && item->valueint == 42);
	/* first-of: first present header; # literal default */
	fst_check_string_equals(jstr(json, "Caller-ID"), "15551230000");
	fst_check_string_equals(jstr(json, "Defaulted"), "dflt");
	/* expand with offset:length; an empty expansion is not emitted */
	fst_check_string_equals(jstr(json, "Short-ID"), "11111111");
	fst_check(cJSON_GetObjectItem(json, "Empty-Expand") == NULL);
	/* reference -> reference -> static object with a prefix field,
	 * exclude-prefix stripping the prefix, the exception left out */
	ccvs = jobj(json, "Custom-Channel-Vars");
	fst_requires(ccvs);
	fst_check_string_equals(jstr(ccvs, "Account-ID"), "946c4d65726167a7a3c581ce0f42e4f3");
	fst_check_string_equals(jstr(ccvs, "Realm"), "example.com");
	fst_check(cJSON_GetObjectItem(ccvs, "Authorizing-Type") == NULL);
	fst_check(cJSON_GetObjectItem(ccvs, "variable_ecallmgr_Authorizing-Type") == NULL);
	fst_check_string_equals(jstr(json, "Nested"), "yes");
	/* a definition's own filters gate the whole definition */
	fst_check(cJSON_GetObjectItem(json, "Outbound-Direction") == NULL);
	/* prefixes list, prefix kept */
	tags = jobj(json, "Tags");
	fst_requires(tags);
	fst_check_string_equals(jstr(tags, "variable_sip_from_tag"), "from-tag-1");
	fst_check_string_equals(jstr(tags, "variable_sip_to_tag"), "to-tag-1");
	fst_check(cJSON_GetObjectItem(tags, "variable_presence_id") == NULL);
	/* per-field filters */
	item = cJSON_GetObjectItem(json, "Ringing");
	fst_requires(item);
	fst_check(item->type == cJSON_True);
	fst_check(cJSON_GetObjectItem(json, "Answered") == NULL);
	/* Recovered target=input updates the event only, for later fields. */
	fst_check(cJSON_GetObjectItem(json, "Caller-ID-Number") == NULL);
	fst_check_string_equals(switch_event_get_header(event, "Caller-ID-Number"), "15551230000");
	/* raw: parsed JSON */
	item = jobj(json, "Body");
	fst_requires(item);
	fst_check(cJSON_GetObjectItem(item, "a") && cJSON_GetObjectItem(item, "a")->valueint == 1);
	/* as-array wraps a single value */
	item = cJSON_GetObjectItem(json, "Listy");
	fst_requires(item);
	fst_check(item->type == cJSON_Array && cJSON_GetArraySize(item) == 1);
	fst_check_string_equals(cJSON_GetArrayItem(item, 0)->valuestring, "15551230001");

	cJSON_Delete(json);

	/* the same definitions applied to an outbound leg (headers append:
	 * drop the old value first) */
	switch_event_del_header(event, "Call-Direction");
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Call-Direction", "outbound");
	json = reprise_fields_render(fields, event, "test");
	fst_check_string_equals(jstr(json, "Outbound-Direction"), "outbound");
	cJSON_Delete(json);

	/* verbose dumps every header first; fields still win */
	fields->verbose = 1;
	json = reprise_fields_render(fields, event, "test");
	fst_check_string_equals(jstr(json, "Answer-State"), "ringing");
	fst_check_string_equals(jstr(json, "Call-ID"), "11111111-2222-3333-4444-555555555555");
	cJSON_Delete(json);

	/* an unknown reference is skipped, not fatal */
	{
		switch_xml_t bad = parse_xml("<e><fields><field name=\"nope\" type=\"reference\"/><field name=\"K\" type=\"static\" value=\"v\"/></fields></e>");
		reprise_fields_t *bf = reprise_fields_parse(pool, bad, defs);
		fst_requires(bf);
		json = reprise_fields_render(bf, event, "test");
		fst_check_string_equals(jstr(json, "K"), "v");
		cJSON_Delete(json);
		switch_xml_free(bad);
	}
	/* array headers render as arrays; _body renders the body */
	{
		switch_xml_t b = parse_xml("<e><fields><field name=\"Multi\"/><field name=\"_body\" as=\"Body\"/></fields></e>");
		reprise_fields_t *bf = reprise_fields_parse(pool, b, defs);
		switch_event_add_header_string(event, SWITCH_STACK_PUSH, "Multi", "one");
		switch_event_add_header_string(event, SWITCH_STACK_PUSH, "Multi", "two");
		switch_event_add_body(event, "hello");
		json = reprise_fields_render(bf, event, "test");
		item = cJSON_GetObjectItem(json, "Multi");
		fst_requires(item);
		fst_check(item->type == cJSON_Array && cJSON_GetArraySize(item) == 2);
		fst_check_string_equals(jstr(json, "Body"), "hello");
		cJSON_Delete(json);
		switch_xml_free(b);
	}

	switch_event_destroy(&event);
	switch_xml_free(doc);
	switch_core_destroy_memory_pool(&pool);
}
FST_TEST_END()

/*---------------------------------------------------------------------------
 * ${...} expansion
 *-------------------------------------------------------------------------*/

FST_TEST_BEGIN(expand)
{
	switch_event_t *event = make_event();
	const char *in;
	char *out;

	switch_core_set_variable("reprise_test_global", "G");
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Indirect", "Unique-ID");

	/* nothing to expand: the input itself comes back */
	in = "plain text";
	out = reprise_expand_headers(event, in);
	fst_check(out == in);

	out = reprise_expand_headers(event, "id=${Unique-ID}");
	fst_check_string_equals(out, "id=11111111-2222-3333-4444-555555555555");
	switch_safe_free(out);

	out = reprise_expand_headers(event, "${Unique-ID:9:4}|${Unique-ID:-4}");
	fst_check_string_equals(out, "2222|5555");
	switch_safe_free(out);

	out = reprise_expand_headers(event, "[${Nope}]");
	fst_check_string_equals(out, "[]");
	switch_safe_free(out);

	out = reprise_expand_headers(event, "$${reprise_test_global}/${Caller-Caller-ID-Number}");
	fst_check_string_equals(out, "G/15551230000");
	switch_safe_free(out);

	/* a header named by another header */
	out = reprise_expand_headers(event, "${${Indirect}}");
	fst_check_string_equals(out, "11111111-2222-3333-4444-555555555555");
	switch_safe_free(out);

	/* escaped dollar stays literal */
	out = reprise_expand_headers(event, "\\${Unique-ID}");
	fst_check_string_equals(out, "${Unique-ID}");
	switch_safe_free(out);

	/* a global that is not a header */
	out = reprise_expand_headers(event, "${reprise_test_global}");
	fst_check_string_equals(out, "G");
	switch_safe_free(out);

	switch_event_destroy(&event);
}
FST_TEST_END()

FST_TEST_BEGIN(expand_slice_bounds)
{
	switch_event_t *event = make_event();
	const char *inputs[] = {
		"[${Short:4}]", "[${Short:2147483647}]",
		"[${Short:999999999999999999999999999999}]",
		"[${Short:-2147483648}]", "[${Short:-999999999999999999999999999999}]",
		"[${Short:3}]", "[${Short:1:2147483647}]", "[${Short:-1:1}]"
	};
	const char *expected[] = {"[]", "[]", "[]", "[abc]", "[abc]", "[]", "[bc]", "[c]"};
	size_t i;
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Short", "abc");
	for (i = 0; i < sizeof(inputs) / sizeof(inputs[0]); i++) {
		char *out = reprise_expand_headers(event, inputs[i]);
		fst_requires(out != NULL);
		fst_check_string_equals(out, expected[i]);
		if (out != inputs[i]) free(out);
	}
	switch_event_destroy(&event);
}
FST_TEST_END()

FST_TEST_BEGIN(endpoint_json_literal_keys)
{
	switch_event_t *event = make_event();
	cJSON *json = cJSON_Parse("{\"%s\":{\"%n\":\"safe\"},\"ordinary\":{\"value\":42},\"Flags\":[\"direct_call\"]}");
	fst_requires(json != NULL);
	fst_check(kz_expand_json_to_event(json, event, "kz_ctx") == SWITCH_STATUS_SUCCESS);
	fst_check_string_equals(switch_event_get_header(event, "kz_ctx_%s_%n"), "safe");
	fst_check_string_equals(switch_event_get_header(event, "kz_ctx_ordinary_value"), "42");
	fst_check_string_equals(switch_event_get_header(event, "kz_ctx_Flags"), "[\"direct_call\"]");
	cJSON_Delete(json);
	switch_event_destroy(&event);
}
FST_TEST_END()

FST_TEST_BEGIN(expand_growth_and_failure)
{
	switch_event_t *event = make_event();
	char large[8192], *out;
	memset(large, 'a', sizeof(large) - 1);
	large[sizeof(large) - 1] = '\0';
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Large", large);
	out = reprise_expand_headers(event, "${Large}${Large}");
	fst_requires(out != NULL);
	fst_check(strlen(out) == 2 * strlen(large));
	free(out);
#ifdef REPRISE_ALLOC_TEST
	fail_next_realloc = 1;
	out = reprise_expand_headers(event, "${Large}");
	fst_check(fail_next_realloc == 0);
	fst_check(out == NULL);
	free(out);
	fail_next_realloc = 1;
	out = reprise_expand_headers(event, "${${Large}}");
	fst_check(fail_next_realloc == 0);
	fst_check(out == NULL);
	free(out);
#endif
	{
		char nested[512] = "";
		int i;
		for (i = 0; i < 120; i++) strcat(nested, "${");
		strcat(nested, "Large");
		for (i = 0; i < 120; i++) strcat(nested, "}");
		out = reprise_expand_headers(event, nested);
		fst_check(out == NULL);
		free(out);
	}
	switch_event_destroy(&event);
}
FST_TEST_END()

FST_TEST_BEGIN(endpoint_dial_ownership)
{
	switch_event_t *event = make_event();
	const char *values[] = {"sofia/internal/test", "[sip_proxy_uri=sip:proxy,sip_invite_uri=sip:user]sofia/internal/test",
		"[sip_proxy_uri=${Proxy}]sofia/internal/test"};
	const char *expected[] = {"sofia/internal/test", "[sip_route_uri=sip:proxy,sip_invite_req_uri=sip:user]sofia/internal/test",
		"[sip_route_uri=sip:proxy]sofia/internal/test"};
	size_t i;
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Proxy", "sip:proxy");
	for (i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
		char *input = strdup(values[i]);
		char *out = kz_endpoint_expand_dial(event, input);
		fst_requires(out != NULL);
		fst_check(out != input);
		fst_check_string_equals(out, expected[i]);
		fst_check_string_equals(input, values[i]);
		free(out);
		free(input);
	}
	fst_check(kz_endpoint_expand_dial(event, NULL) == NULL);
	switch_event_destroy(&event);
}
FST_TEST_END()

FST_TEST_BEGIN(endpoint_context_types)
{
	const char *inputs[] = {"{}", "[]", "null", "{\"Flags\":\"direct_call\"}",
		"{\"Flags\":[null,42,true,{},[]]}", "{\"Flags\":[null,42,\"direct_call\"]}"};
	size_t i;
	fst_check(!kz_endpoint_context_has_flag(NULL, "direct_call"));
	for (i = 0; i < sizeof(inputs) / sizeof(inputs[0]); i++) {
		cJSON *ctx = cJSON_Parse(inputs[i]);
		fst_requires(ctx != NULL);
		fst_check(kz_endpoint_context_has_flag(ctx, "direct_call") == (i == 5));
		cJSON_Delete(ctx);
	}
	{
		cJSON *root = cJSON_CreateObject(), *current = root;
		switch_event_t *event = make_event();
		for (i = 0; i < 66; i++) {
			cJSON *child = cJSON_CreateObject();
			cJSON_AddItemToObject(current, "nested", child);
			current = child;
		}
		fst_check(kz_expand_json_to_event(root, event, "kz_ctx") != SWITCH_STATUS_SUCCESS);
		cJSON_Delete(root);
		switch_event_destroy(&event);
	}
}
FST_TEST_END()

FST_TEST_BEGIN(first_of_api)
{
	switch_event_t *event = make_event();
	switch_stream_handle_t stream = { 0 };

	SWITCH_STANDARD_STREAM(stream);
	stream.param_event = event;
	fst_check(reprise_first_of_api("Nope|Caller-Destination-Number|#dflt", NULL, &stream) == SWITCH_STATUS_SUCCESS);
	fst_check_string_equals((char *) stream.data, "15551230001");
	switch_safe_free(stream.data);

	SWITCH_STANDARD_STREAM(stream);
	stream.param_event = event;
	reprise_first_of_api("Nope|Nada|#dflt", NULL, &stream);
	fst_check_string_equals((char *) stream.data, "dflt");
	switch_safe_free(stream.data);

	/* ^^; changes the delimiter */
	SWITCH_STANDARD_STREAM(stream);
	stream.param_event = event;
	reprise_first_of_api("^^;Nope;Unique-ID", NULL, &stream);
	fst_check_string_equals((char *) stream.data, "11111111-2222-3333-4444-555555555555");
	switch_safe_free(stream.data);

	SWITCH_STANDARD_STREAM(stream);
	fst_check(reprise_first_of_api("", NULL, &stream) == SWITCH_STATUS_GENERR);
	switch_safe_free(stream.data);

	/* an empty header does not win (freeswitch-kazoo 20.23.6) */
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Empty-One", "");
	SWITCH_STANDARD_STREAM(stream);
	stream.param_event = event;
	reprise_first_of_api("Empty-One|Caller-Destination-Number|#dflt", NULL, &stream);
	fst_check_string_equals((char *) stream.data, "15551230001");
	switch_safe_free(stream.data);

	switch_event_destroy(&event);
}
FST_TEST_END()

FST_TEST_BEGIN(notify_contact_compat)
{
	char *out = kz_notify_contact_compat("sip:reprisesipp2@example.com;fs_path=<sip:192.0.2.3:5060;transport=udp>");
	fst_requires(out);
	fst_check_string_equals(out, "<sip:reprisesipp2@example.com;fs_path=sip:192.0.2.3:5060%3Btransport%3Dudp>");
	switch_safe_free(out);
	out = kz_notify_contact_compat("sip:u@r;fs_path=sip:10.0.0.1");
	fst_requires(out);
	fst_check_string_equals(out, "<sip:u@r;fs_path=sip:10.0.0.1>");
	switch_safe_free(out);
	/* already stock, or no path: untouched */
	fst_check(kz_notify_contact_compat("<sip:u@r;fs_path=sip%3A10.0.0.1>") == NULL);
	fst_check(kz_notify_contact_compat("sip:u@r") == NULL);
	fst_check(kz_notify_contact_compat(NULL) == NULL);
}
FST_TEST_END()

FST_TEST_BEGIN(event_decode)
{
	switch_event_t *event = NULL;
	switch_event_create(&event, SWITCH_EVENT_CHANNEL_CREATE);
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Encoded", "a%20b%40c");
	switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "_json_skip", "%20");
	reprise_event_decode(event);
	fst_check_string_equals(switch_event_get_header(event, "Encoded"), "a b@c");
	fst_check_string_equals(switch_event_get_header(event, "_json_skip"), "%20");
	switch_event_destroy(&event);
}
FST_TEST_END()

/*---------------------------------------------------------------------------
 * kazoo.conf parser
 *-------------------------------------------------------------------------*/

FST_TEST_BEGIN(config_parse)
{
	reprise_config_t *config = reprise_config_parse(CONF_DOC);
	reprise_conf_broker_t *b;
	reprise_amqp_profile_t *ap;
	reprise_event_profile_t *ep;
	reprise_event_t *ev;
	reprise_fetch_profile_t *fp;
	reprise_rk_field_t *rk;
	reprise_kv_t *kv;
	reprise_definition_t *d;
	int n;

	fst_requires(config);
	fst_check_string_equals(config->version, "5.4.0");
	fst_check_string_equals(config->local_zone, "z1");
	fst_check_int_equals(config->n_brokers, 2);
	fst_check_int_equals(config->n_amqp_profiles, 2);
	fst_check_int_equals(config->n_event_profiles, 1);
	fst_check_int_equals(config->n_fetch_profiles, 2);
	fst_check_int_equals(config->n_variables, 2);
	fst_check_int_equals(config->n_definitions, 3);
	fst_check(config->refs == 0 && config->retired == 0);

	/* brokers: params, properties, defaults (list is built head-first) */
	for (b = config->brokers; b && strcmp(b->name, "a"); b = b->next);
	fst_requires(b);
	fst_check_string_equals(b->hostname, "amqp-a");
	fst_check(b->port == 5673);
	fst_check_string_equals(b->username, "u");
	fst_check_string_equals(b->password, "p");
	fst_check_string_equals(b->virtualhost, "/kz");
	fst_check_string_equals(b->zone, "z1");
	fst_check(b->is_primary && b->is_local && !b->is_federated);
	for (b = config->brokers; b && strcmp(b->name, "b"); b = b->next);
	fst_requires(b);
	fst_check(b->port == 5672);
	fst_check_string_equals(b->username, "guest");
	fst_check_string_equals(b->virtualhost, "/");
	fst_check_string_equals(b->zone, "local");
	fst_check(!b->is_primary && !b->is_local && b->is_federated);

	/* amqp profile: exchanges, queue, bindings, params, publisher */
	ap = amqp_profile(config, "fetch");
	fst_requires(ap);
	fst_requires(ap->exchanges);
	fst_check_string_equals(ap->exchanges->name, "targeted");
	fst_check_string_equals(ap->exchanges->type, "direct");
	fst_check(ap->exchanges->durable && !ap->exchanges->auto_delete);
	fst_check_string_equals(ap->queue.name, "${Core-UUID}-fetch-${AMQP-Profile-Name}");
	fst_check(ap->queue.exclusive && !ap->queue.consume_exclusive);
	fst_check_int_equals(ap->queue.consume_qos, 5);
	{
		reprise_qbinding_t *qb;
		int federated = 0;
		for (n = 0, qb = ap->queue.bindings; qb; qb = qb->next, n++) {
			if (qb->federated) {
				federated++;
				fst_check_string_equals(qb->exchange, "freeswitch");
				fst_check_string_equals(qb->routing_key, "freeswitch.fetch.${Core-UUID}.#");
			}
		}
		fst_check_int_equals(n, 2);
		fst_check_int_equals(federated, 1);
	}
	fst_check_int_equals(ap->channels, 3);
	fst_check(ap->query_timeout_ms == 1234);
	fst_check_int_equals(ap->publisher_delivery_mode, 2);
	fst_requires(ap->publisher_fields);
	fst_check_string_equals(ap->publisher_fields->name, "Server-ID");
	fst_check_string_equals(ap->publisher_fields->value, "${Core-UUID}-fetch");
	ap = amqp_profile(config, "priority");
	fst_requires(ap);
	fst_check_int_equals(ap->channels, 1);
	fst_check(ap->query_timeout_ms == REPRISE_DEFAULT_FETCH_TIMEOUT_MS);
	fst_check(ap->exchanges == NULL && ap->queue.name == NULL && ap->publisher_fields == NULL);

	/* definitions: forward references resolve */
	for (d = config->definitions; d && strcmp(d->name, "late"); d = d->next);
	fst_requires(d);
	fst_check(refs_resolved(d->head));

	/* event profile: params, filters, override fields, routing key, events */
	ep = event_profile(config, "priority_events");
	fst_requires(ep);
	fst_check_string_equals(ep->amqp_exchange, "callevt");
	fst_check_string_equals(ep->amqp_profile, "priority");
	fst_check_int_equals(ep->event_count, 2);
	fst_requires(ep->filters);
	fst_check(ep->filters->type == REPRISE_FILTER_INCLUDE && ep->filters->compare == REPRISE_CMP_EXISTS);
	fst_requires(ep->override_fields && ep->override_fields->head);
	fst_check_string_equals(ep->override_fields->head->name, "Node");
	fst_check_string_equals(ep->routing_key.hash_event_field, "Unique-ID");
	fst_check_string_equals(ep->routing_key.hash_amqp_header, "call-id");
	rk = ep->routing_key.fields;
	fst_requires(rk);
	fst_check_string_equals(rk->name, "call");
	fst_check_string_equals(rk->type, "static");
	fst_check(rk->encode_part == 0);
	fst_requires(rk->next);
	fst_check_string_equals(rk->next->name, "Event-Name");
	fst_check(rk->next->type == NULL && rk->next->encode_part == 1);
	fst_requires(rk->next->next && rk->next->next->next == NULL);
	/* events keep document order */
	ev = ep->events;
	fst_requires(ev);
	fst_check_string_equals(ev->name, "CHANNEL_CREATE");
	fst_check(ev->has_routing_key == 0 && ev->filters == NULL);
	fst_requires(ev->fields);
	fst_check(refs_resolved(ev->fields->head));
	ev = profile_event(ep, "CHANNEL_DESTROY");
	fst_requires(ev);
	fst_check(ev->has_routing_key == 1 && ev->filters != NULL && ev->fields == NULL);
	fst_check_string_equals(ev->routing_key.fields->name, "gone");

	/* fetch profiles: params and defaults */
	fp = fetch_profile(config, "dialplan");
	fst_requires(fp);
	fst_check_string_equals(fp->fetch_section, "dialplan");
	fst_check(fp->fetch_timeout_us == 5000000);
	fst_check_string_equals(fp->amqp_exchange, "freeswitch");
	fst_check_string_equals(fp->amqp_profile, "fetch");
	fst_requires(fp->fields && refs_resolved(fp->fields->head));
	fst_requires(fp->routing_key.fields);
	fst_check(fp->routing_key.fields->encode_part == 0);
	fp = fetch_profile(config, "directory");
	fst_requires(fp);
	fst_check_string_equals(fp->fetch_section, "directory");
	fst_check(fp->fetch_timeout_us == 3500000);
	fst_check_string_equals(fp->amqp_exchange, REPRISE_EXCHANGE_FREESWITCH);
	fst_check_string_equals(fp->amqp_profile, "fetch");
	fst_check(fp->fields == NULL);

	/* variables (order is not part of the contract) */
	for (kv = config->variables; kv && strcmp(kv->name, "origination_nested_vars"); kv = kv->next);
	fst_requires(kv);
	fst_check_string_equals(kv->value, "true");

	reprise_config_destroy(&config);
	fst_check(config == NULL);

	/* structural failures */
	fst_check(reprise_config_parse("<document><section name=\"configuration\"/></document>") == NULL);
	fst_check(reprise_config_parse("not xml at all <<<") == NULL);
}
FST_TEST_END()

/* the served document of the test cluster: every profile, every
 * reference resolves, the counts the module logged at bring-up */
FST_TEST_BEGIN(config_parse_served_document)
{
	const char *path = getenv("REPRISE_TEST_FIXTURE") ? getenv("REPRISE_TEST_FIXTURE") : "tests/fixtures/kazoo.conf.xml";
	char *xml = read_file(path);
	reprise_config_t *config;
	reprise_event_profile_t *ep;
	reprise_fetch_profile_t *fp;
	reprise_event_t *ev;
	reprise_definition_t *d;
	int n_events = 0;

	fst_requires(xml);
	config = reprise_config_parse(xml);
	free(xml);
	fst_requires(config);

	fst_check_string_equals(config->version, "5.4.0");
	fst_check_int_equals(config->n_brokers, 1);
	fst_check_int_equals(config->n_amqp_profiles, 10);
	fst_check_int_equals(config->n_event_profiles, 16);
	fst_check_int_equals(config->n_fetch_profiles, 5);
	fst_check_int_equals(config->n_variables, 20);
	fst_check_int_equals(config->n_definitions, 71);

	for (d = config->definitions; d; d = d->next) {
		fst_xcheck(refs_resolved(d->head), d->name);
	}
	for (ep = config->event_profiles; ep; ep = ep->next) {
		fst_xcheck(!zstr(ep->amqp_exchange) && !zstr(ep->amqp_profile), ep->name);
		fst_xcheck(ep->routing_key.fields != NULL || ep->events == NULL || ep->events->has_routing_key, ep->name);
		for (ev = ep->events; ev; ev = ev->next, n_events++) {
			if (ev->fields) fst_xcheck(refs_resolved(ev->fields->head), ev->name);
		}
	}
	fst_check_int_equals(n_events, 44);
	for (fp = config->fetch_profiles; fp; fp = fp->next) {
		fst_xcheck(fp->fields && refs_resolved(fp->fields->head), fp->name);
		fst_xcheck(fp->routing_key.fields != NULL, fp->name);
	}

	/* the rows the parity table depends on */
	ep = event_profile(config, "presence");
	fst_requires(ep);
	fst_check_string_equals(ep->amqp_exchange, "presence");
	fst_check_string_equals(ep->routing_key.hash_event_field, "Unique-ID");
	fst_requires(profile_event(ep, "KZ_PRESENCE_DIALOG"));
	ep = event_profile(config, "rtcp");
	fst_requires(ep);
	fst_check_int_equals(ep->event_count, 2);
	fst_check(profile_event(ep, "RTCP_SEND_PACKET")->has_routing_key);
	ep = event_profile(config, "execute_complete");
	fst_requires(ep);
	fst_requires(profile_event(ep, "CHANNEL_APP_EXECUTE_COMPLETE"));
	fp = fetch_profile(config, "dialplan");
	fst_requires(fp);
	fst_check(fp->fetch_timeout_us == 5000000);
	fst_check_string_equals(fp->routing_key.hash_amqp_header, "call-id");

	reprise_config_destroy(&config);
}
FST_TEST_END()

/*---------------------------------------------------------------------------
 * routing keys and templates
 *-------------------------------------------------------------------------*/

FST_TEST_BEGIN(routing_key)
{
	switch_memory_pool_t *pool = NULL;
	reprise_config_t *config = reprise_config_parse(CONF_DOC);
	reprise_event_profile_t *ep;
	switch_event_t *event = make_event();
	cJSON *json = cJSON_CreateObject();
	char key[256];

	fst_requires(config);
	ep = event_profile(config, "priority_events");
	fst_requires(ep);
	switch_core_new_memory_pool(&pool);

	/* static part verbatim (encode-part=false), the rest from the document
	 * then the event, kz_amqp_util-encoded */
	cJSON_AddStringToObject(json, "Event-Name", "CHANNEL_CREATE");
	reprise_routing_key_build(&ep->routing_key, json, event, key, sizeof(key));
	fst_check_string_equals(key, "call.CHANNEL_CREATE.11111111-2222-3333-4444-555555555555");

	/* a document value wins over the event's; encoding of @ . space */
	cJSON_AddStringToObject(json, "Unique-ID", "a@b.c d");
	reprise_routing_key_build(&ep->routing_key, json, event, key, sizeof(key));
	fst_check_string_equals(key, "call.CHANNEL_CREATE.a%40b%2Ec+d");

	/* missing parts are skipped (the event keeps the Event-Name the core
	 * stamped at creation); * and # pass through unencoded */
	cJSON_DeleteItemFromObject(json, "Event-Name");
	switch_event_del_header(event, "Unique-ID");
	cJSON_DeleteItemFromObject(json, "Unique-ID");
	reprise_routing_key_build(&ep->routing_key, json, event, key, sizeof(key));
	fst_check_string_equals(key, "call.CHANNEL_CREATE");
	switch_event_del_header(event, "Event-Name");
	reprise_routing_key_build(&ep->routing_key, json, event, key, sizeof(key));
	fst_check_string_equals(key, "call");
	cJSON_AddStringToObject(json, "Unique-ID", "*");
	reprise_routing_key_build(&ep->routing_key, json, event, key, sizeof(key));
	fst_check_string_equals(key, "call.*");

	/* first-of parts: the first present in the document, then the event */
	{
		const char *doc = "<document><section name=\"configuration\"><configuration><event-handlers>"
			"<profile name=\"p\"><routing-key><field name=\"call\" type=\"static\" value=\"call\" encode-part=\"false\"/>"
			"<field name=\"event\" type=\"first-of\" value=\"kazoo_event_name|Event-Subclass|Event-Name\"/>"
			"<field name=\"Unique-ID\"/></routing-key></profile></event-handlers></configuration></section></document>";
		reprise_config_t *c2 = reprise_config_parse(doc);
		fst_requires(c2 && c2->event_profiles);
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Unique-ID", "u1");
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Event-Name", "CUSTOM");
		/* the document's * from above still wins for Unique-ID */
		switch_event_add_header_string(event, SWITCH_STACK_BOTTOM, "Event-Subclass", "sofia::transferee");
		reprise_routing_key_build(&c2->event_profiles->routing_key, json, event, key, sizeof(key));
		fst_check_string_equals(key, "call.sofia%3A%3Atransferee.*");
		cJSON_DeleteItemFromObject(json, "Unique-ID");
		reprise_routing_key_build(&c2->event_profiles->routing_key, json, event, key, sizeof(key));
		fst_check_string_equals(key, "call.sofia%3A%3Atransferee.u1");
		reprise_config_destroy(&c2);
	}

	cJSON_Delete(json);
	switch_event_destroy(&event);
	reprise_config_destroy(&config);
	switch_core_destroy_memory_pool(&pool);
}
FST_TEST_END()

FST_TEST_BEGIN(template_expand)
{
	char buf[128];
	reprise_expand_template("${Core-UUID}-fetch-${AMQP-Profile-Name}", "fetch", buf, sizeof(buf));
	fst_check_string_equals(buf, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-fetch-fetch");
	reprise_expand_template("freeswitch.fetch.${Core-UUID}.#", NULL, buf, sizeof(buf));
	fst_check_string_equals(buf, "freeswitch.fetch.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.#");
	reprise_expand_template("plain-${AMQP-Profile-Name}", NULL, buf, sizeof(buf));
	fst_check_string_equals(buf, "plain-");
	/* bounded */
	reprise_expand_template("${Core-UUID}${Core-UUID}", NULL, buf, 10);
	fst_check(strlen(buf) == 9);
}
FST_TEST_END()

/*---------------------------------------------------------------------------
 * presence dialog
 *-------------------------------------------------------------------------*/

FST_TEST_BEGIN(presence_state)
{
	fst_check_string_equals(reprise_presence_state("initiator", "cs_routing", "answered"), "confirmed");
	fst_check_string_equals(reprise_presence_state("recipient", "cs_hangup", "hangup"), "terminated");
	fst_check_string_equals(reprise_presence_state("recipient", "hangup", "ringing"), "terminated");
	fst_check_string_equals(reprise_presence_state("initiator", "cs_routing", "ringing"), "confirmed");
	fst_check_string_equals(reprise_presence_state("recipient", "cs_consume_media", "ringing"), "early");
	fst_check_string_equals(reprise_presence_state("recipient", "cs_execute", "early"), "early");
	fst_check_string_equals(reprise_presence_state("recipient", "hold", "ringing"), "early");
	fst_check_string_equals(reprise_presence_state("initiator", "unhold", "early"), "early");
}
FST_TEST_END()

FST_TEST_BEGIN(presence_dialog_build)
{
	switch_event_t *in, *out;

	/* the caller's leg ringing: confirmed for the initiator */
	in = make_presence_in("inbound", "CS_ROUTING", "ringing");
	out = reprise_presence_dialog_build(in);
	fst_requires(out);
	fst_check(out->event_id == SWITCH_EVENT_CUSTOM);
	fst_check_string_equals(out->subclass_name, "KZ_PRESENCE_DIALOG");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Presence-ID"), "reprisesipp@example.com");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-From"), "sip:reprisesipp@example.com");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Presence-URI"), "sip:reprisesipp@example.com");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-From-User"), "reprisesipp");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Realm"), "example.com");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-To-User"), "15551230001");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-To"), "sip:15551230001@example.com");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-From-Tag"), "from-tag-1");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-To-Tag"), "to-tag-1");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Switch-URI"), "sip:10.0.0.5:11000");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Direction"), "initiator");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-State"), "confirmed");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Expires"), "0");
	/* the channel data rides along (CCVs, interaction id, Unique-ID for the key) */
	fst_check_string_equals(switch_event_get_header(out, "Unique-ID"), "11111111-2222-3333-4444-555555555555");
	fst_check_string_equals(switch_event_get_header(out, "variable_ecallmgr_Account-ID"), "946c4d65726167a7a3c581ce0f42e4f3");
	/* the PRESENCE_IN's delivery stamps are not */
	fst_check(switch_event_get_header(out, "Event-Name") == NULL);
	fst_check(switch_event_get_header(out, "Event-Sequence") == NULL);
	switch_event_destroy(&out);
	switch_event_destroy(&in);

	/* the device's leg ringing: early; To is the caller */
	in = make_presence_in("outbound", "CS_CONSUME_MEDIA", "ringing");
	out = reprise_presence_dialog_build(in);
	fst_requires(out);
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-State"), "early");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Direction"), "recipient");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-To-User"), "15551230000");
	switch_event_destroy(&out);
	switch_event_destroy(&in);

	/* answered, then hung up (Expires 20) */
	in = make_presence_in("outbound", "answered", "answered");
	out = reprise_presence_dialog_build(in);
	fst_requires(out);
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-State"), "confirmed");
	switch_event_destroy(&out);
	switch_event_destroy(&in);
	in = make_presence_in("outbound", "CS_HANGUP", "hangup");
	out = reprise_presence_dialog_build(in);
	fst_requires(out);
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-State"), "terminated");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Expires"), "20");
	switch_event_destroy(&out);
	switch_event_destroy(&in);

	/* the CCV Presence-ID wins over the core's from; realm from the id;
	 * the presence id is re-homed in that realm */
	in = make_presence_in("inbound", "CS_ROUTING", "ringing");
	switch_event_add_header_string(in, SWITCH_STACK_BOTTOM, "variable_ecallmgr_Presence-ID", "1000@other.realm");
	switch_event_add_header_string(in, SWITCH_STACK_BOTTOM, "Channel-Presence-ID", "reprisesipp@example.com");
	out = reprise_presence_dialog_build(in);
	fst_requires(out);
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-From-User"), "1000");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Realm"), "other.realm");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Presence-ID"), "reprisesipp@other.realm");
	switch_event_destroy(&out);
	switch_event_destroy(&in);

	/* a from without a realm takes the channel's (CCV Realm first) */
	in = make_presence_in("inbound", "CS_ROUTING", "ringing");
	switch_event_del_header(in, "from");
	switch_event_del_header(in, "variable_presence_id");
	switch_event_add_header_string(in, SWITCH_STACK_BOTTOM, "variable_presence_id", "2000");
	switch_event_add_header_string(in, SWITCH_STACK_BOTTOM, "variable_sip_to_host", "sip.host");
	out = reprise_presence_dialog_build(in);
	fst_requires(out);
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-From-User"), "2000");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Realm"), "example.com");
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Presence-ID"), "reprisesipp@example.com");
	switch_event_del_header(in, "variable_ecallmgr_Realm");
	switch_event_destroy(&out);
	out = reprise_presence_dialog_build(in);
	fst_requires(out);
	fst_check_string_equals(switch_event_get_header(out, "Presence-Dialog-Realm"), "sip.host");
	switch_event_destroy(&out);
	switch_event_destroy(&in);

	/* not publishable: another proto, no direction, no presence id */
	in = make_presence_in("inbound", "CS_ROUTING", "ringing");
	switch_event_del_header(in, "proto");
	switch_event_add_header_string(in, SWITCH_STACK_BOTTOM, "proto", "sip");
	fst_check(reprise_presence_dialog_build(in) == NULL);
	switch_event_destroy(&in);
	in = make_presence_in("sideways", "CS_ROUTING", "ringing");
	fst_check(reprise_presence_dialog_build(in) == NULL);
	switch_event_destroy(&in);
	in = make_presence_in("inbound", "CS_ROUTING", "ringing");
	switch_event_del_header(in, "Channel-Presence-ID");
	switch_event_del_header(in, "variable_presence_id");
	fst_check(reprise_presence_dialog_build(in) == NULL);
	switch_event_destroy(&in);
}
FST_TEST_END()

FST_TEST_BEGIN(separate_string)
{
	char buf[256], *argv[10] = {0};
	int argc;

	/* the kz_originate argument line: quoted parts keep their spaces */
	switch_copy_string(buf, "0125a053 {origination_caller_id_number=1555}loopback/15551230001/context_2 '&park()' XML context_2 'Reprise Smoke' 15559990000 30", sizeof(buf));
	argc = kz_switch_separate_string(buf, ' ', argv, 10);
	fst_check_int_equals(argc, 8);
	fst_check_string_equals(argv[0], "0125a053");
	fst_check_string_equals(argv[1], "{origination_caller_id_number=1555}loopback/15551230001/context_2");
	fst_check_string_equals(kz_cleanup_separated_string(argv[2], 0), "&park()");
	fst_check_string_equals(kz_cleanup_separated_string(argv[5], 0), "Reprise Smoke");
	fst_check_string_equals(argv[7], "30");

	/* runs of spaces collapse; escapes survive splitting and are cleaned
	 * after (an escaped delimiter is only unescaped for that delimiter) */
	switch_copy_string(buf, "a   b\\ c 'd e'", sizeof(buf));
	argc = kz_switch_separate_string(buf, ' ', argv, 10);
	fst_check_int_equals(argc, 3);
	fst_check_string_equals(kz_cleanup_separated_string(argv[1], ' '), "b c");
	fst_check_string_equals(kz_cleanup_separated_string(argv[2], 0), "d e");

	/* ^^<d> picks the delimiter */
	switch_copy_string(buf, "^^|one|two three|four", sizeof(buf));
	argc = kz_switch_separate_string(buf, ' ', argv, 10);
	fst_check_int_equals(argc, 3);
	fst_check_string_equals(argv[1], "two three");
	fst_check_string_equals(argv[2], "four");

	fst_check_int_equals(kz_switch_separate_string(NULL, ' ', argv, 10), 0);
}
FST_TEST_END()

FST_TEST_BEGIN(originate_registry)
{
	switch_call_cause_t *cancel, *dup;

	kz_originate_init();
	fst_check_int_equals(kz_originate_count(), 0);
	cancel = kz_add_originate_uuid("orig-1");
	fst_requires(cancel);
	fst_check(*cancel == 0);
	dup = kz_add_originate_uuid("orig-1");
	fst_check(dup == NULL);
	fst_check_int_equals(kz_originate_count(), 1);
	/* cancel sets the cause the running originate polls */
	fst_check(kz_cancel_originate_uuid("orig-1", SWITCH_CAUSE_ORIGINATOR_CANCEL) == SWITCH_STATUS_SUCCESS);
	fst_check(*cancel == SWITCH_CAUSE_ORIGINATOR_CANCEL);
	fst_check(kz_cancel_originate_uuid("orig-2", SWITCH_CAUSE_ORIGINATOR_CANCEL) == SWITCH_STATUS_GENERR);
	fst_check(kz_remove_originate_uuid("orig-1") == SWITCH_STATUS_SUCCESS);
	fst_check(kz_remove_originate_uuid("orig-1") == SWITCH_STATUS_GENERR);
	fst_check_int_equals(kz_originate_count(), 0);
	/* a second add after removal is a new attempt */
	fst_requires(kz_add_originate_uuid("orig-1"));
	fst_check(kz_remove_originate_uuid("orig-1") == SWITCH_STATUS_SUCCESS);
	kz_originate_shutdown();
	fst_check_int_equals(kz_originate_count(), 0);

	/* unload with an attempt in flight: admission closes, the attempt is
	 * cancelled, its cancel cause stays valid (the registry is kept, not
	 * freed under the originate) until the attempt unregisters */
	kz_originate_init();
	cancel = kz_add_originate_uuid("orig-live");
	fst_requires(cancel);
	kz_originate_shutdown_wait(0);
	fst_check(*cancel == SWITCH_CAUSE_ORIGINATOR_CANCEL);
	fst_check_int_equals(kz_originate_count(), 1);
	fst_check(kz_add_originate_uuid("orig-late") == NULL);
	fst_check(kz_remove_originate_uuid("orig-live") == SWITCH_STATUS_SUCCESS);
	kz_originate_shutdown_wait(0);
	fst_check_int_equals(kz_originate_count(), 0);
	fst_check(kz_add_originate_uuid("orig-after") == NULL);
}
FST_TEST_END()

/* the bgapi job registry: bounded admission, joined at shutdown */
FST_TEST_BEGIN(bgapi_jobs)
{
	switch_memory_pool_t *pool = NULL;
	char uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
	int i, started = 0;

	switch_core_new_memory_pool(&pool);
	reprise_commands_init(pool);
	/* the minimal core has no `msleep`: the dispatcher answers "+OK msleep
	 * not available" at once; the threads still have to be joined */
	for (i = 0; i < REPRISE_BG_JOBS_MAX + 5; i++) {
		switch_status_t st = reprise_commands_bg_start("msleep", "10", "srv", "msg", "pid", uuid, sizeof(uuid));
		if (st == SWITCH_STATUS_SUCCESS) {
			started++;
			fst_check(strlen(uuid) == 36); /* a formatted uuid; the buffer constant is larger */
		} else {
			fst_check(st == SWITCH_STATUS_INUSE);
		}
	}
	/* jobs are reaped by the commands worker's tick; without one they
	 * stay pending, so the bound holds for the whole batch */
	fst_check_int_equals(started, REPRISE_BG_JOBS_MAX);
	fst_check_int_equals((int) reprise_commands_bg_pending(), REPRISE_BG_JOBS_MAX);
	reprise_commands_shutdown();
	fst_check_int_equals((int) reprise_commands_bg_pending(), 0);
	/* admission is closed after shutdown */
	fst_check(reprise_commands_bg_start("msleep", "10", "srv", "msg", "pid", uuid, sizeof(uuid)) == SWITCH_STATUS_TERM);
	switch_core_destroy_memory_pool(&pool);
}
FST_TEST_END()

/* the prompt cache is bounded and sweeps expired entries */
FST_TEST_BEGIN(prompt_cache_bounds)
{
	char path[64], *url;
	int i;

	reprise_prompts_start(NULL);
	fst_check_int_equals(kz_prompt_cache_count(), 0);
	kz_prompt_cache_put("system_media/a/en-us", "http_cache://http://media/a.wav", 300 * 1000000LL);
	kz_prompt_cache_put("system_media/a/en-us", "http_cache://http://media/a2.wav", 300 * 1000000LL);
	fst_check_int_equals(kz_prompt_cache_count(), 1);
	url = kz_prompt_cache_get("system_media/a/en-us");
	fst_requires(url);
	fst_check_string_equals(url, "http_cache://http://media/a2.wav");
	free(url);
	/* an expired entry is gone on lookup */
	kz_prompt_cache_put("system_media/old/en-us", "http_cache://http://media/old.wav", -1);
	fst_check_int_equals(kz_prompt_cache_count(), 2);
	fst_check(kz_prompt_cache_get("system_media/old/en-us") == NULL);
	fst_check_int_equals(kz_prompt_cache_count(), 1);
	/* distinct paths never exceed the bound: the oldest goes first */
	for (i = 0; i < REPRISE_PROMPT_CACHE_MAX + 100; i++) {
		switch_snprintf(path, sizeof(path), "acct/prompt-%d/en-us", i);
		kz_prompt_cache_put(path, "http_cache://http://media/p.wav", (301 + i) * 1000000LL);
		fst_check(kz_prompt_cache_count() <= REPRISE_PROMPT_CACHE_MAX);
	}
	fst_check_int_equals(kz_prompt_cache_count(), REPRISE_PROMPT_CACHE_MAX);
	fst_check(kz_prompt_cache_get("system_media/a/en-us") == NULL); /* the earliest expiry */
	url = kz_prompt_cache_get("acct/prompt-4103/en-us");
	fst_requires(url);
	free(url);
	reprise_prompts_stop();
	fst_check_int_equals(kz_prompt_cache_count(), 0);

	/* the expiry sweep: a cache full of expired entries is emptied by the
	 * put that finds it at capacity, and only the new entry remains */
	reprise_prompts_start(NULL);
	for (i = 0; i < REPRISE_PROMPT_CACHE_MAX; i++) {
		switch_snprintf(path, sizeof(path), "acct/stale-%d/en-us", i);
		kz_prompt_cache_put(path, "http_cache://http://media/s.wav", -1);
	}
	fst_check_int_equals(kz_prompt_cache_count(), REPRISE_PROMPT_CACHE_MAX);
	kz_prompt_cache_put("acct/fresh/en-us", "http_cache://http://media/f.wav", 300 * 1000000LL);
	fst_check_int_equals(kz_prompt_cache_count(), 1);
	url = kz_prompt_cache_get("acct/fresh/en-us");
	fst_requires(url);
	free(url);
	reprise_prompts_stop();
}
FST_TEST_END()

/* cyclic <definitions> are severed at parse time and the renderer terminates */
FST_TEST_BEGIN(cyclic_definitions)
{
	const char *doc =
		"<document><definitions>"
		"  <definition name=\"self\"><field name=\"self\" type=\"reference\"/><field name=\"S\" type=\"static\" value=\"s\"/></definition>"
		"  <definition name=\"a\"><field name=\"A\" type=\"static\" value=\"a\"/><field name=\"b\" type=\"reference\"/></definition>"
		"  <definition name=\"b\"><field name=\"B\" type=\"static\" value=\"b\"/>"
		"    <field name=\"Obj\" type=\"static\" serialize-as=\"object\"><fields><field name=\"a\" type=\"reference\"/></fields></field>"
		"  </definition>"
		"  <definition name=\"chain\"><field name=\"a\" type=\"reference\"/></definition>"
		"</definitions>"
		"<event><fields><field name=\"self\" type=\"reference\"/><field name=\"chain\" type=\"reference\"/></fields></event>"
		"</document>";
	switch_memory_pool_t *pool = NULL;
	switch_xml_t xml = parse_xml(doc);
	reprise_definition_t *defs, *d;
	reprise_fields_t *fields;
	switch_event_t *event = make_event();
	cJSON *json, *obj;

	fst_requires(xml);
	switch_core_new_memory_pool(&pool);
	defs = reprise_definitions_parse(pool, switch_xml_child(xml, "definitions"));
	fst_requires(defs);
	for (d = defs; d && strcmp(d->name, "self"); d = d->next);
	fst_requires(d);
	fst_check(d->head->ref == NULL);           /* self-reference dropped */
	for (d = defs; d && strcmp(d->name, "b"); d = d->next);
	fst_requires(d);
	fst_check(d->head->next->children->head->ref == NULL); /* b -> a -> b dropped at the back edge */
	for (d = defs; d && strcmp(d->name, "a"); d = d->next);
	fst_requires(d);
	fst_check(d->head->next->ref != NULL);     /* a -> b kept */

	fields = reprise_fields_parse(pool, switch_xml_child(xml, "event"), defs);
	fst_requires(fields);
	json = reprise_fields_render(fields, event, "test");
	fst_requires(json);
	fst_check_string_equals(jstr(json, "S"), "s");
	fst_check_string_equals(jstr(json, "A"), "a");
	fst_check_string_equals(jstr(json, "B"), "b");
	obj = jobj(json, "Obj");
	fst_requires(obj);
	fst_check(cJSON_GetObjectItem(obj, "A") == NULL);
	cJSON_Delete(json);

	switch_event_destroy(&event);
	switch_xml_free(xml);
	switch_core_destroy_memory_pool(&pool);
}
FST_TEST_END()

/* delimiter prefixes at the end of the input, and the switch-uri host */
FST_TEST_BEGIN(input_boundaries)
{
	switch_event_t *event = make_event();
	switch_stream_handle_t stream = { 0 };
	char *argv[8] = { 0 }, *arg;

	/* "^^" with no delimiter: rejected, never read past the NUL */
	SWITCH_STANDARD_STREAM(stream);
	stream.param_event = event;
	fst_check(reprise_first_of_api("^^", NULL, &stream) == SWITCH_STATUS_GENERR);
	switch_safe_free(stream.data);
	SWITCH_STANDARD_STREAM(stream);
	stream.param_event = event;
	fst_check(reprise_first_of_api("^^;", NULL, &stream) == SWITCH_STATUS_SUCCESS);
	fst_check(zstr((char *) stream.data));
	switch_safe_free(stream.data);

	arg = strdup("^^");
	fst_check_int_equals(kz_split_prefixes(arg, argv, 8), 0);
	free(arg);
	arg = strdup("^^,");
	fst_check_int_equals(kz_split_prefixes(arg, argv, 8), 0);
	free(arg);
	arg = strdup("^^,x");
	fst_check_int_equals(kz_split_prefixes(arg, argv, 8), 1);
	fst_check_string_equals(argv[0], "x");
	free(arg);

	fst_check_string_equals(kz_switch_uri_host("sip:10.0.0.5:11000"), "sip:10.0.0.5:11000");
	fst_check_string_equals(kz_switch_uri_host("sip:user@10.0.0.5:11000"), "10.0.0.5:11000");
	fst_check_string_equals(kz_switch_uri_host("@host"), "@host");
	fst_check_string_equals(kz_switch_uri_host(""), "");
	fst_check(kz_switch_uri_host(NULL) == NULL);

	switch_event_destroy(&event);
}
FST_TEST_END()

FST_TEST_BEGIN(prompt_reply)
{
	switch_xml_t doc = parse_xml("<section name=\"configuration\"><prompt path=\"prompt://system_media/vm-record_message/en-us\" value=\"http://media:24517/system_media/vm-record_message.wav\"/></section>");
	switch_xml_t missing = parse_xml("<section name=\"configuration\"><prompt path=\"x\" value=\"prompt://system_media/nope/en-us\"/></section>");
	char *url;

	fst_requires(doc && missing);
	url = reprise_prompt_url_from_reply(switch_xml_child(doc, "prompt"));
	fst_requires(url);
	fst_check_string_equals(url, "http_cache://http://media:24517/system_media/vm-record_message.wav");
	switch_safe_free(url);
	/* an unresolved prompt comes back as a prompt:// name: not playable */
	fst_check(reprise_prompt_url_from_reply(switch_xml_child(missing, "prompt")) == NULL);
	fst_check(reprise_prompt_url_from_reply(NULL) == NULL);
	switch_xml_free(doc);
	switch_xml_free(missing);

	/* no fetch binding in the test core: a lookup fails cleanly */
	reprise_prompts_start(NULL);
	fst_check(kz_prompt_get("system_media/vm-record_message/en-us") == NULL);
	fst_check(kz_prompt_get("") == NULL);
	reprise_prompts_stop();
}
FST_TEST_END()

/* ---- freeswitch-kazoo 20.23.6 re-base: X-PRE-PROCESS, prefix lists, CDR items, curl versions ---- */

FST_TEST_BEGIN(preprocess)
{
	const char *doc =
		"<document type=\"freeswitch/xml\"><section name=\"configuration\"><configuration name=\"com.kazoo.conf\">"
		"<X-PRE-PROCESS cmd=\"set\" data=\" reprise_pp_set = hello world \"/>"
		"<X-PRE-PROCESS cmd=\"env-set\" data=\"reprise_pp_env=$REPRISE_PP_ENV\"/>"
		"<X-PRE-PROCESS cmd=\"exec-set\" data=\"reprise_pp_exec=echo from-exec\"/>"
		"<X-PRE-PROCESS cmd=\"set\" data=\"no-equals-sign\"/>"
		"<X-PRE-PROCESS cmd=\"bogus\" data=\"a=b\"/>"
		"<variables><variable name=\"reprise_pp_var\" value=\"v\"/></variables>"
		"</configuration></section></document>";
	reprise_config_t *config;
	char *keyval, *key, *val;

	/* the key=value splitter trims around '=' and rejects a missing '=' */
	keyval = strdup(" a b = c d ");
	fst_check(kz_split_keyval(keyval, &key, &val) == SWITCH_TRUE);
	fst_check_string_equals(key, "a b");
	fst_check_string_equals(val, "c d ");
	free(keyval);
	keyval = strdup("novalue");
	fst_check(kz_split_keyval(keyval, &key, &val) == SWITCH_FALSE);
	free(keyval);
	keyval = strdup("=x");
	fst_check(kz_split_keyval(keyval, &key, &val) == SWITCH_FALSE);
	free(keyval);

	setenv("REPRISE_PP_ENV", "from-env", 1);
	config = reprise_config_parse(doc);
	fst_requires(config);
	/* the two malformed ones are kept (cmd and data present) and rejected at apply time */
	fst_check_int_equals(config->n_preprocess, 5);
	fst_check_string_equals(config->preprocess->name, "set");
	fst_check_string_equals(config->preprocess->value, " reprise_pp_set = hello world ");
	fst_check_int_equals(config->n_variables, 1);

	reprise_config_apply_variables(config);
	fst_check_string_equals(switch_str_nil(switch_core_get_variable("reprise_pp_set")), "hello world ");
	fst_check_string_equals(switch_str_nil(switch_core_get_variable("reprise_pp_env")), "from-env");
	fst_check_string_equals(switch_str_nil(switch_core_get_variable("reprise_pp_exec")), "from-exec");
	fst_check_string_equals(switch_str_nil(switch_core_get_variable("reprise_pp_var")), "v");
	fst_check(switch_core_get_variable("no-equals-sign") == NULL);
	reprise_config_destroy(&config);

	/* the served document carries the 5.4 stun-set for external_rtp_ip */
	{
		const char *path = getenv("REPRISE_TEST_FIXTURE") ? getenv("REPRISE_TEST_FIXTURE") : "tests/fixtures/kazoo.conf.xml";
		char *xml = read_file(path);
		fst_requires(xml);
		config = reprise_config_parse(xml);
		fst_requires(config);
		fst_check_int_equals(config->n_preprocess, 1);
		fst_check_string_equals(config->preprocess->name, "stun-set");
		fst_check_string_equals(config->preprocess->value, "external_rtp_ip=stun:stun.l.google.com:19302");
		reprise_config_destroy(&config);
		free(xml);
	}
}
FST_TEST_END()

FST_TEST_BEGIN(prefix_list)
{
	char *argv[8] = { 0 }, *arg;
	int n;

	arg = strdup("sip_h_X-A|sip_h_X-B|sip_h_k-cid");
	n = kz_split_prefixes(arg, argv, 8);
	fst_check_int_equals(n, 3);
	fst_check_string_equals(argv[0], "sip_h_X-A");
	fst_check_string_equals(argv[2], "sip_h_k-cid");
	free(arg);
	arg = strdup("^^,sip_h_X-A,sip_h_X-B");
	memset(argv, 0, sizeof(argv));
	n = kz_split_prefixes(arg, argv, 8);
	fst_check_int_equals(n, 2);
	fst_check_string_equals(argv[1], "sip_h_X-B");
	free(arg);
	arg = strdup("sip_h_X-Only");
	memset(argv, 0, sizeof(argv));
	n = kz_split_prefixes(arg, argv, 8);
	fst_check_int_equals(n, 1);
	fst_check_string_equals(argv[0], "sip_h_X-Only");
	free(arg);
	n = kz_split_prefixes(NULL, argv, 8);
	fst_check_int_equals(n, 0);
}
FST_TEST_END()

FST_TEST_BEGIN(cdr_originate_items)
{
	cJSON *j;
	char *out;

	j = kz_cdr_originated_leg_json("11111111-2222-3333-4444-555555555555;Bob;1001");
	fst_requires(j);
	out = cJSON_PrintUnformatted(j);
	fst_check_string_equals(out, "{\"Call-ID\":\"11111111-2222-3333-4444-555555555555\",\"Caller-ID-Name\":\"Bob\",\"Caller-ID-Number\":\"1001\"}");
	free(out); cJSON_Delete(j);

	/* a leg pushed with empty callee fields still reports its uuid */
	j = kz_cdr_originated_leg_json("uuid-a;;");
	fst_requires(j);
	out = cJSON_PrintUnformatted(j);
	fst_check_string_equals(out, "{\"Call-ID\":\"uuid-a\",\"Caller-ID-Name\":\"\",\"Caller-ID-Number\":\"\"}");
	free(out); cJSON_Delete(j);

	j = kz_cdr_originate_cause_json("uuid-a;NO_ANSWER");
	fst_requires(j);
	out = cJSON_PrintUnformatted(j);
	fst_check_string_equals(out, "{\"Call-ID\":\"uuid-a\",\"Result\":\"NO_ANSWER\"}");
	free(out); cJSON_Delete(j);

	fst_check(kz_cdr_originated_leg_json("") == NULL);
	fst_check(kz_cdr_originate_cause_json(NULL) == NULL);
}
FST_TEST_END()

FST_TEST_BEGIN(interaction_inherited_id_derives_child_metadata)
{
	switch_event_t *e = make_event();
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Call-Interaction-ID", "63956145231-30acab7f");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Original-Call-Interaction-ID", "63956145231-c58a4d6d");
	kz_event_add_interaction(e);
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Timestamp"), "63956145231");
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Key"), "30acab7f");
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Is-Root"), "false");
	switch_event_destroy(&e);
}
FST_TEST_END()

FST_TEST_BEGIN(interaction_reassignment_overwrites_stale_headers)
{
	switch_event_t *e = make_event();
	/* August interaction reassigned to a September leg: preserve August. */
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Call-Interaction-ID", "63955439999-aB01zZ89");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Original-Call-Interaction-ID", "63955440000-12345678");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Call-Interaction-ID", "63955440000-12345678");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Call-Interaction-Timestamp", "63955440000");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Call-Interaction-Key", "12345678");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Call-Interaction-Is-Root", "true");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Call-Interaction-Timestamp", "63955440000");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Call-Interaction-Key", "12345678");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Call-Interaction-Is-Root", "true");
	kz_event_add_interaction(e);
	kz_event_add_interaction(e); /* Repeated serialization is idempotent. */
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-ID"), "63955439999-aB01zZ89");
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Timestamp"), "63955439999");
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Key"), "aB01zZ89");
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Is-Root"), "false");
	/* The event helper must not rewrite the channel snapshot itself. */
	fst_check_string_equals(switch_event_get_header(e, "variable_Call-Interaction-Key"), "12345678");
	switch_event_destroy(&e);
}
FST_TEST_END()

FST_TEST_BEGIN(interaction_bare_event_root_requires_matching_original)
{
	switch_event_t *e = make_event();
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Call-Interaction-ID", "63956145231-30acab7f");
	kz_event_add_interaction(e);
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Is-Root"), "false");
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Original-Call-Interaction-ID", "63956145231-30acab7f");
	kz_event_add_interaction(e);
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Is-Root"), "true");
	/* The channel's original ID also outranks a stale bare original. */
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Original-Call-Interaction-ID", "63956145232-30acab7f");
	kz_event_add_interaction(e);
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Is-Root"), "false");
	switch_event_destroy(&e);
}
FST_TEST_END()

FST_TEST_BEGIN(interaction_invalid_id_cannot_reuse_stale_metadata)
{
	const char *invalid[] = {NULL, "", "0-12345678", "-1-12345678", "+1-12345678", " 1-12345678",
		"1-1234567", "1-123456789", "1-1234567_", "1-12345678tail", "1.5-12345678",
		"9007199254740992-12345678", "18446744073709551616-12345678", "00000000000000001-12345678"};
	size_t i;
	for (i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
		switch_event_t *e = make_event();
		if (invalid[i]) switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Call-Interaction-ID", invalid[i]);
		switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Call-Interaction-Timestamp", "63956145231");
		switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Call-Interaction-Key", "30acab7f");
		switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "Call-Interaction-Is-Root", "true");
		kz_event_add_interaction(e);
		fst_check(!switch_event_get_header(e, "Call-Interaction-Timestamp"));
		fst_check(!switch_event_get_header(e, "Call-Interaction-Key"));
		fst_check(!switch_event_get_header(e, "Call-Interaction-Is-Root"));
		switch_event_destroy(&e);
	}
	kz_event_add_interaction(NULL);
}
FST_TEST_END()

FST_TEST_BEGIN(interaction_timestamp_exact_numeric_boundary)
{
	switch_event_t *e = make_event();
	switch_event_add_header_string(e, SWITCH_STACK_BOTTOM, "variable_Call-Interaction-ID", "9007199254740991-12345678");
	kz_event_add_interaction(e);
	fst_check_string_equals(switch_event_get_header(e, "Call-Interaction-Timestamp"), "9007199254740991");
	switch_event_destroy(&e);
}
FST_TEST_END()

FST_TEST_BEGIN(curl_http_version)
{
	fst_check(kz_curl_http_version("1.0") == CURL_HTTP_VERSION_1_0);
	fst_check(kz_curl_http_version("1.1") == CURL_HTTP_VERSION_1_1);
	fst_check(kz_curl_http_version("nope") == -1);
	fst_check(kz_curl_http_version(NULL) == -1);
}
FST_TEST_END()

FST_SUITE_END()

FST_MINCORE_END()

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
