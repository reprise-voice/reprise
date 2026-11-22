%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_registration_state_tests).
-include_lib("eunit/include/eunit.hrl").

%% Keep the fixtures beside the private registration record while exposing a
%% normal test module to the repository's test.<module> / EUnit discovery.
registration_state_test_() ->
    ecallmgr_registrar:registration_state_test_().
