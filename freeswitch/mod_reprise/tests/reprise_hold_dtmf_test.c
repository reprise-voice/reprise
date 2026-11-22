/* A digit pressed during kz_endless_playback is published as the core's
 * DTMF event while the music still plays, and the music stops only when
 * the playback is broken; a sensitive digit is taken off the channel just
 * the same but reaches neither the event stream nor the log. Real null
 * session, real tone playback; the application is compiled in so the test
 * can run it on its own thread.
 *
 * The same caller rung for by kz_bridge, as a queue offer rings an agent:
 * the core's originate takes the caller's digits off the channel only when
 * origination_cancel_key is set, and with one no keypad sends it publishes
 * every digit and rings on. cf_callcenter's ring_keys depends on exactly
 * that; the second ring test is the premise, the digit left waiting.
 * Requires the matching FreeSWITCH core; make test-hold-dtmf.
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
#include "../src/reprise_dptools.c"

#define HOLD_TONE "tone_stream://%(500,0,440)"
#define HOLD_DIGIT '#'

/* The DTMF event the core fired, by channel uuid, and every log line that
 * named the digit for the channel under test. */
static switch_mutex_t *seen_mutex;
static char seen_uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
static char seen_digit;
static switch_time_t seen_at;
static char logged_uuid[SWITCH_UUID_FORMATTED_LENGTH + 1];
static int logged_digits;

static void on_dtmf_event(switch_event_t *event)
{
	const char *uuid = switch_event_get_header(event, "Unique-ID");
	const char *digit = switch_event_get_header(event, "DTMF-Digit");

	switch_mutex_lock(seen_mutex);
	if (uuid && digit && !seen_digit) {
		snprintf(seen_uuid, sizeof(seen_uuid), "%s", uuid);
		seen_digit = *digit;
		seen_at = switch_micro_time_now();
	}
	switch_mutex_unlock(seen_mutex);
}

static switch_status_t hold_log(const switch_log_node_t *node, switch_log_level_t level)
{
	if (getenv("REPRISE_TEST_TRACE")) fprintf(stderr, "%s", node->data);
	switch_mutex_lock(seen_mutex);
	if (node->userdata && logged_uuid[0] && !strcmp(node->userdata, logged_uuid) && node->data &&
		strchr(node->data, HOLD_DIGIT)) {
		logged_digits++;
	}
	switch_mutex_unlock(seen_mutex);
	return SWITCH_STATUS_SUCCESS;
}

static char seen(void)
{
	char digit;

	switch_mutex_lock(seen_mutex);
	digit = seen_digit;
	switch_mutex_unlock(seen_mutex);
	return digit;
}

static int digits_logged(void)
{
	int count;

	switch_mutex_lock(seen_mutex);
	count = logged_digits;
	switch_mutex_unlock(seen_mutex);
	return count;
}

static void watch_log_of(const char *uuid)
{
	switch_mutex_lock(seen_mutex);
	snprintf(logged_uuid, sizeof(logged_uuid), "%s", uuid);
	logged_digits = 0;
	switch_mutex_unlock(seen_mutex);
}

/* The hold application, run on its own thread as the channel's thread would. */
struct hold_control {
	switch_core_session_t *session;
	switch_atomic_t finished;
	char response[64];
	switch_memory_pool_t *pool;
	switch_thread_t *thread;
};

static void *SWITCH_THREAD_FUNC hold(switch_thread_t *thread, void *obj)
{
	struct hold_control *control = obj;
	switch_channel_t *channel = switch_core_session_get_channel(control->session);

	kz_endless_playback_function(control->session, HOLD_TONE);
	snprintf(control->response, sizeof(control->response), "%s",
			 switch_str_nil(switch_channel_get_variable(channel, SWITCH_CURRENT_APPLICATION_RESPONSE_VARIABLE)));
	switch_atomic_set(&control->finished, 1);
	return NULL;
}

static void start_hold(struct hold_control *control, switch_core_session_t *session)
{
	switch_threadattr_t *attr = NULL;

	memset(control, 0, sizeof(*control));
	control->session = session;
	switch_atomic_set(&control->finished, 0);
	switch_core_new_memory_pool(&control->pool);
	switch_threadattr_create(&attr, control->pool);
	switch_thread_create(&control->thread, attr, hold, control, control->pool);
}

static int finished(struct hold_control *control)
{
	return switch_atomic_read(&control->finished) != 0;
}

/* Break the hold as uuid_break would, and wait for the application to return. */
static int end_hold(struct hold_control *control)
{
	switch_time_t end = switch_micro_time_now() + 2000000;
	switch_status_t joined;

	switch_channel_set_flag(switch_core_session_get_channel(control->session), CF_BREAK);
	while (!finished(control) && switch_micro_time_now() < end) {
		switch_yield(5000);
	}
	switch_thread_join(&joined, control->thread);
	switch_core_destroy_memory_pool(&control->pool);
	return finished(control);
}

/* A queue's ring: kz_bridge from the caller to a phone that never answers,
 * run on its own thread as the channel's thread would run it. The leg rings
 * for two seconds; the caller continues on failure, as ecallmgr sets it. */
#define RING_DIAL "[null_enable_auto_answer=false,leg_timeout=2]null/agent"
#define NO_KEYPAD_KEY "x"

struct ring_control {
	switch_core_session_t *session;
	switch_atomic_t finished;
	switch_memory_pool_t *pool;
	switch_thread_t *thread;
};

static void *SWITCH_THREAD_FUNC ring_agent(switch_thread_t *thread, void *obj)
{
	struct ring_control *control = obj;

	kz_audio_bridge_function(control->session, RING_DIAL);
	switch_atomic_set(&control->finished, 1);
	return NULL;
}

static void start_ring(struct ring_control *control, switch_core_session_t *session)
{
	switch_threadattr_t *attr = NULL;

	memset(control, 0, sizeof(*control));
	control->session = session;
	switch_atomic_set(&control->finished, 0);
	switch_channel_set_variable(switch_core_session_get_channel(session), "continue_on_fail", "true");
	switch_core_new_memory_pool(&control->pool);
	switch_threadattr_create(&attr, control->pool);
	switch_thread_create(&control->thread, attr, ring_agent, control, control->pool);
}

static int ring_over(struct ring_control *control)
{
	return switch_atomic_read(&control->finished) != 0;
}

/* Wait out the leg's ring timeout. */
static int end_ring(struct ring_control *control)
{
	switch_time_t end = switch_micro_time_now() + 5000000;
	switch_status_t joined;

	while (!ring_over(control) && switch_micro_time_now() < end) {
		switch_yield(10000);
	}
	switch_thread_join(&joined, control->thread);
	switch_core_destroy_memory_pool(&control->pool);
	return ring_over(control);
}

static int wait_for_digit(switch_time_t timeout_us)
{
	switch_time_t end = switch_micro_time_now() + timeout_us;

	while (!seen() && switch_micro_time_now() < end) {
		switch_yield(5000);
	}
	return seen() != 0;
}

/* An answered null leg whose own thread is parked, so the test drives its media. */
static switch_core_session_t *held_caller(void)
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
	watch_log_of(switch_core_session_get_uuid(session));
	return session;
}

static void release(switch_core_session_t *session)
{
	if (session) {
		switch_channel_hangup(switch_core_session_get_channel(session), SWITCH_CAUSE_NORMAL_CLEARING);
		switch_core_session_rwunlock(session);
	}
}

FST_CORE_BEGIN("../conf")
{
	const char *err = NULL;
	switch_memory_pool_t *seen_pool = NULL;

	switch_core_new_memory_pool(&seen_pool);
	switch_mutex_init(&seen_mutex, SWITCH_MUTEX_NESTED, seen_pool);
	switch_log_bind_logger(hold_log, SWITCH_LOG_DEBUG, SWITCH_FALSE);
	switch_loadable_module_load_module("/usr/local/freeswitch/lib/freeswitch/mod", "mod_loopback", SWITCH_FALSE, &err);
	switch_loadable_module_load_module("/usr/local/freeswitch/lib/freeswitch/mod", "mod_tone_stream", SWITCH_FALSE,
									   &err);
	switch_event_bind("reprise_hold_dtmf_test", SWITCH_EVENT_DTMF, SWITCH_EVENT_SUBCLASS_ANY, on_dtmf_event, NULL);

	FST_SUITE_BEGIN(hold_dtmf)

	FST_SETUP_BEGIN()
	{
		switch_mutex_lock(seen_mutex);
		seen_uuid[0] = '\0';
		seen_digit = 0;
		seen_at = 0;
		logged_uuid[0] = '\0';
		logged_digits = 0;
		switch_mutex_unlock(seen_mutex);
	}
	FST_SETUP_END()

	FST_TEARDOWN_BEGIN()
	{
		fst_check(reprise_test_drained());
	}
	FST_TEARDOWN_END()

	/* The key is published while the music plays, and the music plays on. */
	FST_TEST_BEGIN(digit_is_published_during_hold_music)
	{
		switch_core_session_t *session = held_caller();
		switch_channel_t *channel;
		struct hold_control control;
		switch_dtmf_t dtmf = {HOLD_DIGIT, 0, 0, SWITCH_DTMF_ENDPOINT};
		switch_time_t pressed_at;

		fst_requires(session);
		channel = switch_core_session_get_channel(session);
		start_hold(&control, session);

		/* Let the music start, then press the key as the endpoint would. */
		switch_yield(300000);
		fst_check(!finished(&control));
		pressed_at = switch_micro_time_now();
		fst_check(switch_channel_queue_dtmf(channel, &dtmf) == SWITCH_STATUS_SUCCESS);

		fst_check(wait_for_digit(1000000));
		fprintf(stderr, "HOLD digit=%c published_after_us=%lld finished=%d\n", seen() ? seen() : '-',
				seen() ? (long long) (seen_at - pressed_at) : -1LL, finished(&control));
		fst_check(seen() == HOLD_DIGIT);
		fst_check_string_equals(seen_uuid, switch_core_session_get_uuid(session));
		fst_check(seen_at - pressed_at < 500000);

		/* The key did not stop the music. */
		switch_yield(300000);
		fst_check(!finished(&control));
		fst_check(!switch_channel_has_dtmf(channel));

		/* Only a break does, as uuid_break would. */
		fst_check(end_hold(&control));
		fst_check_string_equals(control.response, "PLAYBACK_INTERRUPTED");

		release(session);
	}
	FST_TEST_END()

	/* A sensitive digit is taken off the channel too, and named nowhere. */
	FST_TEST_BEGIN(sensitive_digit_is_neither_published_nor_logged)
	{
		switch_core_session_t *session = held_caller();
		switch_channel_t *channel;
		struct hold_control control;
		switch_dtmf_t dtmf = {HOLD_DIGIT, 0, 0, SWITCH_DTMF_ENDPOINT};

		fst_requires(session);
		channel = switch_core_session_get_channel(session);
		switch_channel_set_variable(channel, SWITCH_SENSITIVE_DTMF_VARIABLE, "true");
		start_hold(&control, session);

		switch_yield(300000);
		fst_check(!finished(&control));
		fst_check(switch_channel_queue_dtmf(channel, &dtmf) == SWITCH_STATUS_SUCCESS);

		/* Long enough for the event and the log line the plain digit gets. */
		fst_check(!wait_for_digit(500000));
		fprintf(stderr, "HOLD sensitive published=%d logged_digits=%d finished=%d\n", seen() != 0, digits_logged(),
				finished(&control));
		fst_check(!switch_channel_has_dtmf(channel));
		fst_check(digits_logged() == 0);
		fst_check(!finished(&control));

		fst_check(end_hold(&control));
		fst_check_string_equals(control.response, "PLAYBACK_INTERRUPTED");

		release(session);
	}
	FST_TEST_END()

	/* A caller whose channel asks the ring to read keys has their digit
	 * published while the agent's phone rings, and the ring goes on: only
	 * its timeout, or the queue calling it off, ends it. */
	FST_TEST_BEGIN(digit_is_published_during_a_ring_that_reads_keys)
	{
		switch_core_session_t *session = held_caller();
		switch_channel_t *channel;
		struct ring_control control;
		switch_dtmf_t dtmf = {HOLD_DIGIT, 0, 0, SWITCH_DTMF_ENDPOINT};
		switch_time_t pressed_at;

		fst_requires(session);
		channel = switch_core_session_get_channel(session);
		switch_channel_set_variable(channel, "origination_cancel_key", NO_KEYPAD_KEY);
		start_ring(&control, session);

		switch_yield(300000);
		fst_check(!ring_over(&control));
		pressed_at = switch_micro_time_now();
		fst_check(switch_channel_queue_dtmf(channel, &dtmf) == SWITCH_STATUS_SUCCESS);

		fst_check(wait_for_digit(1000000));
		fprintf(stderr, "RING digit=%c published_after_us=%lld over=%d\n", seen() ? seen() : '-',
				seen() ? (long long) (seen_at - pressed_at) : -1LL, ring_over(&control));
		fst_check(seen() == HOLD_DIGIT);
		fst_check_string_equals(seen_uuid, switch_core_session_get_uuid(session));
		fst_check(seen_at - pressed_at < 500000);
		fst_check(!switch_channel_has_dtmf(channel));

		/* The digit did not end the ring. */
		switch_yield(300000);
		fst_check(!ring_over(&control));

		fst_check(end_ring(&control));
		release(session);
	}
	FST_TEST_END()

	/* Without it the ring leaves the digit on the channel, unpublished, for
	 * whatever runs after the ring: an exit key that used to be heard only
	 * when the ring timed out. */
	FST_TEST_BEGIN(digit_waits_out_a_ring_that_does_not_read_keys)
	{
		switch_core_session_t *session = held_caller();
		switch_channel_t *channel;
		struct ring_control control;
		switch_dtmf_t dtmf = {HOLD_DIGIT, 0, 0, SWITCH_DTMF_ENDPOINT};

		fst_requires(session);
		channel = switch_core_session_get_channel(session);
		start_ring(&control, session);

		switch_yield(300000);
		fst_check(!ring_over(&control));
		fst_check(switch_channel_queue_dtmf(channel, &dtmf) == SWITCH_STATUS_SUCCESS);

		fst_check(!wait_for_digit(500000));
		fst_check(switch_channel_has_dtmf(channel));

		fst_check(end_ring(&control));
		fprintf(stderr, "RING without key published=%d waiting=%d\n", seen() != 0,
				switch_channel_has_dtmf(channel) != 0);
		fst_check(!seen());
		fst_check(switch_channel_has_dtmf(channel));

		release(session);
	}
	FST_TEST_END()

	FST_SUITE_END()
}
FST_CORE_END()
