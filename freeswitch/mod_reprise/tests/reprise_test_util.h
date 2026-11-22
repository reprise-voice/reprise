/* Shared helpers for the native call-path suites: the served kazoo.conf
 * fixture, profile lookups and session draining. Every suite runs from
 * tests/run, so fixture paths are relative to that directory.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#ifndef REPRISE_TEST_UTIL_H
#define REPRISE_TEST_UTIL_H

static char *reprise_test_read_file(const char *path)
{
	FILE *file = fopen(path, "rb");
	long size;
	char *text;

	if (!file) return NULL;
	fseek(file, 0, SEEK_END);
	size = ftell(file);
	rewind(file);
	text = calloc(size + 1, 1);
	if (!text || fread(text, 1, size, file) != (size_t) size) {
		free(text);
		fclose(file);
		return NULL;
	}
	fclose(file);
	return text;
}

/* The served document of the test cluster (tests/fixtures/kazoo.conf.xml). */
static reprise_config_t *reprise_test_load_fixture(void)
{
	char *xml = reprise_test_read_file("../fixtures/kazoo.conf.xml");
	reprise_config_t *config;

	switch_assert(xml);
	config = reprise_config_parse(xml);
	free(xml);
	switch_assert(config);
	return config;
}

static reprise_event_profile_t *reprise_test_event_profile(reprise_config_t *config, const char *name)
{
	reprise_event_profile_t *profile;

	for (profile = config->event_profiles; profile; profile = profile->next) {
		if (!strcmp(profile->name, name)) return profile;
	}
	return NULL;
}

static reprise_event_t *reprise_test_profile_event(reprise_event_profile_t *profile, const char *name)
{
	reprise_event_t *event;

	for (event = profile->events; event; event = event->next) {
		if (!strcmp(event->name, name)) return event;
	}
	return NULL;
}

/* Give every session up to two seconds to leave; true once none remain. */
static int reprise_test_drained(void)
{
	switch_time_t end = switch_micro_time_now() + 2000000;

	while (switch_core_session_count() && switch_micro_time_now() < end) {
		switch_yield(10000);
	}
	return switch_core_session_count() == 0;
}

#endif /* REPRISE_TEST_UTIL_H */
