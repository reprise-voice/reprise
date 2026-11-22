/*
 * reprise_endpoint_compat.h -- the definitions reprise_endpoints.c (ported
 * from mod_kazoo) expects from the 2600hz FreeSWITCH fork, mapped onto the
 * stock core plus Reprise's session-handoff patch.
 *
 * Copyright (C) 2026 Vonix LLC
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#pragma once
#ifndef SWITCH_KAZOO_SESSION_SWAP_VERSION
#error "mod_kazoo requires the Reprise session-handoff core patch"
#endif
#define switch_channel_variable switch_channel_get_variable
#define switch_channel_var_true(c,n) switch_true(switch_channel_get_variable((c),(n)))
#define MODNAME "mod_reprise"
#define kz_switch_ivr_originate switch_ivr_originate
static const char *kz_get_variable_from_event_or_channel(switch_event_t *e, switch_channel_t *c, const char *n) {
 const char *v=e?switch_event_get_header(e,n):NULL; return v?v:switch_channel_get_variable(c,n);
}

SWITCH_DECLARE(void) switch_kazoo_session_swap_v1(void);
