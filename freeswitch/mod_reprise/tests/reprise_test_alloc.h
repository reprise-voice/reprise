/*
 * Test-only allocator fault injection for the sanitizer build.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#ifdef REPRISE_ALLOC_TEST
/* GNU ld wraps calls from the module objects. Fail only this test thread's
 * next realloc, so core worker threads are unaffected. */
static _Thread_local int fail_next_realloc;
void *__real_realloc(void *ptr, size_t size);
void *__wrap_realloc(void *ptr, size_t size)
{
	if (fail_next_realloc) {
		fail_next_realloc = 0;
		return NULL;
	}
	return __real_realloc(ptr, size);
}
#endif
