%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc Which RECORD_STOP events name a recording FreeSWITCH already deleted.
%%%
%%% FreeSWITCH removes a recording shorter than `record_min_sec' before it
%%% sends RECORD_STOP. Storing it anyway saves a metadata document, fails the
%%% upload and raises a critical alert, so the recorder must leave it alone.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(media_recording_tests).

-include_lib("eunit/include/eunit.hrl").

missing_file_is_discarded_test() ->
    ?assert(media_recording:is_discarded(record_stop([{<<"File-Exists">>, 'false'}]))).

discarded_despite_a_silence_cause_test() ->
    %% silence detection sets the cause before the length check deletes the file
    RecordStop = record_stop([{<<"File-Exists">>, 'false'}
                             ,{<<"Recording">>, kz_json:from_list([{<<"Completion-Cause">>, <<"no-input-timeout">>}])}
                             ]),
    ?assert(media_recording:is_discarded(RecordStop)).

present_file_is_kept_test() ->
    ?assertNot(media_recording:is_discarded(record_stop([{<<"File-Exists">>, 'true'}]))).

event_without_the_field_is_kept_test() ->
    %% an older definition, or file_exists not loaded on the media server
    ?assertNot(media_recording:is_discarded(record_stop([]))).

record_stop(Props) ->
    kz_json:from_list([{<<"Event-Name">>, <<"RECORD_STOP">>} | Props]).
