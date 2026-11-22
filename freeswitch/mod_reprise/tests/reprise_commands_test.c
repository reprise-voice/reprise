/*
 * Use the real sendevent conversion and the native FreeSWITCH body accessor.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include <test/switch_test.h>
#include "../src/reprise_commands.c"
/* ci/sanitize.sh links every `make test` binary with --wrap=realloc */
#include "reprise_test_alloc.h"

FST_MINCORE_BEGIN("../conf")
FST_SUITE_BEGIN(reprise_commands)
FST_SETUP_BEGIN() {} FST_SETUP_END()
FST_TEARDOWN_BEGIN() {} FST_TEARDOWN_END()

FST_TEST_BEGIN(notify_body)
{
	const char *bodies[] = {
		"Messages-Waiting: no\r\nVoice-Message: 0/0 (0/0)\r\n",
		"Messages-Waiting: yes\r\nVoice-Message: 1/0 (0/0)\r\n",
		"Messages-Waiting: no\r\nVoice-Message: 0/1 (0/0)\r\n",
		"literal %s %n and UTF-8: \xc3\xa9", ""
	};
	unsigned int i;
	for (i = 0; i < sizeof(bodies)/sizeof(bodies[0]); i++) {
		switch_event_t *event = NULL;
		cJSON *headers = cJSON_CreateObject();
		cJSON_AddStringToObject(headers, "body", bodies[i]);
		cJSON_AddStringToObject(headers, "event-string", "message-summary");
		switch_event_create(&event, SWITCH_EVENT_NOTIFY);
		sendevent_headers(headers, event);
		fst_check_string_equals(switch_str_nil(switch_event_get_body(event)), bodies[i]);
		fst_check_string_equals(switch_event_get_header(event, "event-string"), "message-summary");
		switch_event_destroy(&event);
		cJSON_Delete(headers);
	}
}
FST_TEST_END()

FST_TEST_BEGIN(channel_headers_do_not_become_body)
{
	switch_event_t *event = NULL;
	cJSON *headers = cJSON_Parse("{\"body\":\"channel variable\",\"other\":\"value\"}");
	switch_event_create(&event, SWITCH_EVENT_CHANNEL_DATA);
	json_to_headers(headers, event);
	fst_check(switch_event_get_body(event) == NULL);
	fst_check_string_equals(switch_event_get_header(event, "body"), "channel variable");
	switch_event_destroy(&event);
	cJSON_Delete(headers);
}
FST_TEST_END()

FST_TEST_BEGIN(missing_body)
{
	switch_event_t *event = NULL;
	switch_event_create(&event, SWITCH_EVENT_NOTIFY);
	sendevent_headers(NULL, event);
	fst_check(switch_event_get_body(event) == NULL);
	switch_event_destroy(&event);
}
FST_TEST_END()
FST_SUITE_END()
FST_MINCORE_END()
