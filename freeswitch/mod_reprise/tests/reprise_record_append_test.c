/* record_session as ecallmgr sends it, through the module's rewrite: a new
 * recording shorter than record_min_sec is discarded, and a recording
 * started again under the name of one whose file is still waiting for its
 * upload is appended to that file, not truncated. Real null session, real
 * tone, real wav files; mod_dptools, mod_commands and mod_sndfile loaded.
 * make test-record-append.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include <test/switch_test.h>
#include "reprise_kz.h"
#include "reprise_test_util.h"

#define RECORD_TONE_MS 400

/* An answered null leg whose own thread is parked, so the test drives its media. */
static switch_core_session_t *recorded_caller(void)
{
	switch_core_session_t *session = NULL;
	switch_call_cause_t cause;
	switch_channel_t *channel;

	if (switch_ivr_originate(NULL, &session, &cause, "null/caller", 2, NULL, NULL, NULL, NULL, NULL, SOF_NONE, NULL,
							 NULL) != SWITCH_STATUS_SUCCESS || !session) {
		return NULL;
	}
	channel = switch_core_session_get_channel(session);
	switch_channel_set_state(channel, CS_SOFT_EXECUTE);
	switch_channel_wait_for_state(channel, NULL, CS_SOFT_EXECUTE);
	return session;
}

static void release(switch_core_session_t *session)
{
	if (session) {
		switch_channel_hangup(switch_core_session_get_channel(session), SWITCH_CAUSE_NORMAL_CLEARING);
		switch_core_session_rwunlock(session);
	}
}

/* Record a tone into path the way ecallmgr_call_command asks for it, the
 * app data in the fork's form, and stop; the RECORD_APPEND the switch
 * decided is copied to append. */
static void record(switch_core_session_t *session, const char *path, int min_sec, char *append, size_t append_len)
{
	char *data = switch_mprintf("/^[record_min_sec=%d^enable_file_write_buffering=false]^^#%s#+60", min_sec, path);
	char *pre = NULL, *out = NULL;
	char *tone = switch_mprintf("tone_stream://%%(%d,0,440)", RECORD_TONE_MS);
	switch_channel_t *channel = switch_core_session_get_channel(session);

	switch_assert(kz_app_compat("record_session", data, &pre, &out) && pre && out);
	switch_core_session_execute_application(session, "multiset", pre);
	switch_core_session_execute_application(session, "record_session", out);
	switch_ivr_play_file(session, NULL, tone, NULL);
	switch_ivr_stop_record_session(session, path);
	snprintf(append, append_len, "%s", switch_str_nil(switch_channel_get_variable(channel, "RECORD_APPEND")));

	free(data);
	free(pre);
	free(out);
	free(tone);
}

static long long file_size(const char *path)
{
	struct stat st;
	return stat(path, &st) ? -1 : st.st_size;
}

static char *recording_path(void)
{
	char uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
	switch_uuid_str(uuid, sizeof(uuid));
	return switch_mprintf("/tmp/reprise_record_append_%s.wav", uuid);
}

FST_CORE_BEGIN("../conf")
{
	const char *err = NULL;
	const char *moddir = "/usr/local/freeswitch/lib/freeswitch/mod";

	switch_loadable_module_load_module(moddir, "mod_dptools", SWITCH_FALSE, &err);
	switch_loadable_module_load_module(moddir, "mod_commands", SWITCH_FALSE, &err);
	switch_loadable_module_load_module(moddir, "mod_sndfile", SWITCH_FALSE, &err);
	switch_loadable_module_load_module(moddir, "mod_tone_stream", SWITCH_FALSE, &err);

	FST_SUITE_BEGIN(record_append)

	FST_SETUP_BEGIN()
	{
	}
	FST_SETUP_END()

	FST_TEARDOWN_BEGIN()
	{
		fst_check(reprise_test_drained());
	}
	FST_TEARDOWN_END()

	/* The rewrite adds RECORD_APPEND to the variables, with the path, and
	 * leaves it unexpanded for the core; an app other than record_session
	 * gets nothing. */
	FST_TEST_BEGIN(rewrite_adds_record_append)
	{
		char *pre = NULL, *out = NULL;

		fst_check(kz_app_compat("record_session", "/^[a=1^b=2]^^#/tmp/r.wav#+60", &pre, &out));
		fst_check_string_equals(pre, "^^^a=1^b=2^RECORD_APPEND=${file_exists(/tmp/r.wav)}");
		fst_check_string_equals(out, "/tmp/r.wav +60");
		switch_safe_free(pre);
		switch_safe_free(out);

		fst_check(kz_app_compat("record_session", "^^#/tmp/r.wav#+60", &pre, &out));
		fst_check_string_equals(pre, "^^|RECORD_APPEND=${file_exists(/tmp/r.wav)}");
		switch_safe_free(pre);
		switch_safe_free(out);

		fst_check(kz_app_compat("playback", "/^[a=1]/tmp/r.wav", &pre, &out));
		fst_check_string_equals(pre, "^^^a=1");
		switch_safe_free(pre);
		switch_safe_free(out);
	}
	FST_TEST_END()

	/* A new recording below the minimum is not appended to, so the switch
	 * deletes it. */
	FST_TEST_BEGIN(new_short_recording_is_discarded)
	{
		switch_core_session_t *session = recorded_caller();
		char *path = recording_path();
		char append[16];

		fst_requires(session);
		unlink(path);
		record(session, path, 2, append, sizeof(append));
		fprintf(stderr, "RECORD new append=%s size=%lld\n", append, (long long) file_size(path));
		fst_check_string_equals(append, "false");
		fst_check(file_size(path) < 0);

		unlink(path);
		free(path);
		release(session);
	}
	FST_TEST_END()

	/* A recording started again under the name of one still waiting for its
	 * upload keeps that recording: its file is appended to, even when the
	 * second part alone is below the minimum. */
	FST_TEST_BEGIN(restart_keeps_the_file_awaiting_upload)
	{
		switch_core_session_t *session = recorded_caller();
		char *path = recording_path();
		char append[16];
		long long first;

		fst_requires(session);
		unlink(path);
		record(session, path, 0, append, sizeof(append));
		first = file_size(path);
		fst_check_string_equals(append, "false");
		fst_check(first > 44);

		record(session, path, 2, append, sizeof(append));
		fprintf(stderr, "RECORD restart append=%s first=%lld after=%lld\n", append, (long long) first,
				(long long) file_size(path));
		fst_check_string_equals(append, "true");
		fst_check(file_size(path) > first);

		unlink(path);
		free(path);
		release(session);
	}
	FST_TEST_END()

	FST_SUITE_END()
}
FST_CORE_END()
