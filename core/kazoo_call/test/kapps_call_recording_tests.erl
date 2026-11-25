%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc When a recording with no start trigger of its own starts.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kapps_call_recording_tests).

-include_lib("eunit/include/eunit.hrl").

unanswered_call_records_on_answer_test() ->
    Data = kapps_call_recording:start_on_answer_unless_answered(kz_json:new(), 'false'),
    ?assert(kz_json:is_true(<<"record_on_answer">>, Data)).

answered_call_records_now_test() ->
    Data = kapps_call_recording:start_on_answer_unless_answered(kz_json:new(), 'true'),
    ?assertEqual('undefined', kz_json:get_value(<<"record_on_answer">>, Data)).

explicit_record_on_answer_false_is_kept_test() ->
    Data = kz_json:from_list([{<<"record_on_answer">>, 'false'}]),
    ?assertEqual(Data, kapps_call_recording:start_on_answer_by_default(Data, kapps_call:new())).

explicit_record_on_bridge_is_kept_test() ->
    Data = kz_json:from_list([{<<"record_on_bridge">>, 'true'}]),
    ?assertEqual(Data, kapps_call_recording:start_on_answer_by_default(Data, kapps_call:new())).

answered_status_test() ->
    Status = kz_json:from_list([{<<"Answered">>, 'true'}]),
    ?assert(kapps_call_recording:is_answered({'ok', Status})).

unanswered_status_test() ->
    Status = kz_json:from_list([{<<"Answered">>, 'false'}]),
    ?assertNot(kapps_call_recording:is_answered({'ok', Status})).

unknown_status_records_now_test() ->
    ?assert(kapps_call_recording:is_answered({'error', 'not_found'})).
