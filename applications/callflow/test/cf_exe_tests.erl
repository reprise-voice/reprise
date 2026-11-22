%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc Recording announcement policy regressions.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%-----------------------------------------------------------------------------
-module(cf_exe_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ACCOUNT_ID, <<"account0000000000000000000000001">>).
-define(CALL_ID, <<"recording-announcement-test">>).
-define(PROMPT, <<"test-recording-announcement.wav">>).

recording_announcement_test_() ->
    [{atom_to_list(Merger)
     ,{'foreach'
      ,fun() -> setup(Merger) end
      ,fun(_) -> meck:unload(['kzd_accounts', 'kz_endpoint', 'kapps_call', 'kapps_call_command']) end
      ,announcement_cases()
      }
     }
     || Merger <- ['kz_endpoint_v4', 'kz_endpoint_v5']
    ].

setup(Merger) ->
    meck:new('kzd_accounts', ['passthrough']),
    meck:new('kz_endpoint'),
    %% Exercise the real mergers, including v5 used by the functional lab.
    meck:expect('kz_endpoint', 'merge_call_recording', fun Merger:merge_call_recording/1),
    meck:new('kapps_call'),
    meck:expect('kapps_call', 'account_id', fun('test_call') -> ?ACCOUNT_ID end),
    meck:expect('kapps_call', 'direction', fun('test_call') -> <<"inbound">> end),
    meck:expect('kapps_call', 'inception_type', fun('test_call') -> <<"onnet">> end),
    meck:expect('kapps_call', 'call_id_direct', fun('test_call') -> ?CALL_ID end),
    meck:expect('kapps_call', 'get_prompt',
                fun('test_call', <<"general-call_is_being_recorded">>) -> ?PROMPT end),
    meck:new('kapps_call_command'),
    meck:expect('kapps_call_command', 'noop_id', fun() -> <<"test-noop">> end),
    meck:expect('kapps_call_command', 'send_command', fun(_, 'test_call') -> 'ok' end).

announcement_cases() ->
    Empty = kz_json:new(),
    Enabled = account_policy([<<"inbound">>, <<"onnet">>], 'true'),
    EndpointOnly = kzd_accounts:set_call_recording_endpoint(Empty, kzd_accounts:call_recording_account(Enabled)),
    [{"missing call_recording", ?_test(check_announcement(Empty, 'true', 'false'))}
    ,{"empty call_recording", ?_test(check_announcement(kzd_accounts:set_call_recording(Empty, Empty), 'true', 'false'))}
    ,{"endpoint policy only", ?_test(check_announcement(EndpointOnly, 'true', 'false'))}
    ,{"empty account policy", ?_test(check_announcement(kzd_accounts:set_call_recording_account(Empty, Empty), 'true', 'false'))}
    ,{"announcement disabled", ?_test(check_announcement(account_policy([<<"inbound">>, <<"onnet">>], 'false'), 'true', 'false'))}
    ,{"announcement enabled", ?_test(check_announcement(Enabled, 'true', 'true'))}
    ,{"announcement inherited from any", ?_test(check_announcement(account_policy([<<"any">>, <<"any">>], 'true'), 'true', 'true'))}
    ,{"other direction only", ?_test(check_announcement(account_policy([<<"outbound">>, <<"onnet">>], 'true'), 'true', 'false'))}
    ,{"unrecorded call", ?_test(check_announcement(Enabled, 'false', 'false'))}
    ].

account_policy(Path, Enabled) ->
    Settings = kz_json:set_value(Path ++ [<<"should_announce_when_recording">>], Enabled, kz_json:new()),
    kzd_accounts:set_call_recording_account(kz_json:new(), Settings).

check_announcement(Account, IsRecording, ShouldAnnounce) ->
    meck:expect('kzd_accounts', 'fetch', fun(?ACCOUNT_ID) -> {'ok', Account} end),
    meck:expect('kapps_call', 'is_recording', fun('test_call') -> IsRecording end),
    meck:reset('kzd_accounts'),
    meck:reset('kapps_call_command'),
    ?assertEqual('ok', cf_exe:maybe_announce_call_is_being_recorded('test_call')),
    ?assertEqual(IsRecording, meck:called('kzd_accounts', 'fetch', [?ACCOUNT_ID])),
    ExpectedCommands = case ShouldAnnounce of 'true' -> 1; 'false' -> 0 end,
    ?assertEqual(ExpectedCommands, meck:num_calls('kapps_call_command', 'send_command', 2)),
    case ShouldAnnounce of
        'false' -> 'ok';
        'true' ->
            Command = kz_json:from_list(meck:capture(1, 'kapps_call_command', 'send_command', 2, 1)),
            ?assertEqual(<<"queue">>, kz_json:get_value(<<"Application-Name">>, Command)),
            [_Noop, Play] = kz_json:get_list_value(<<"Commands">>, Command),
            ?assertEqual(<<"play">>, kz_json:get_value(<<"Application-Name">>, Play)),
            ?assertEqual(?PROMPT, kz_json:get_value(<<"Media-Name">>, Play)),
            ?assertEqual(?CALL_ID, kz_json:get_value(<<"Call-ID">>, Play))
    end,
    ?assert(meck:validate(['kzd_accounts', 'kz_endpoint', 'kapps_call', 'kapps_call_command'])).
