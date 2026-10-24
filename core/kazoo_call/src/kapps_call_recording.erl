%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2025, 2600Hz
%%% @doc Handles endpoint inbound recording
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kapps_call_recording).

-export([record_call_command/2
        ,get_media_name/2
        ,get_format/1
        ,get_timelimit/1
        ,handler_from_url/1
        ,should_store_recording/2
        ,media_recorder/2
        ,start_on_answer_by_default/2
        ]).

-ifdef(TEST).
-export([start_on_answer_unless_answered/2
        ,is_answered/1
        ]).
-endif.

-include("kapps_call_command.hrl").
-include("kapps_call_recording.hrl").

-type store_url() :: 'false' |
                     {'true', 'local'} |
                     {'true', 'other', kz_term:ne_binary()}.
-export_type([store_url/0]).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec get_timelimit(kz_json:object() | kz_term:api_integer()) -> pos_integer().
get_timelimit('undefined') ->
    kz_media_util:max_recording_time_limit();
get_timelimit(TL) when is_integer(TL) ->
    get_timelimit(TL, kz_media_util:max_recording_time_limit());
get_timelimit(JObj) ->
    get_timelimit(kz_json:get_integer_value(<<"time_limit">>, JObj)).

-spec get_timelimit(non_neg_integer(), integer()) -> pos_integer().
get_timelimit(TL, Max) when Max > TL -> TL;
get_timelimit(_TL, Max) when Max > 0 -> Max;
get_timelimit(_TL, Max) -> Max.

-spec get_format(kz_term:api_ne_binary()) -> kz_term:ne_binary().
get_format('undefined') -> kz_media_config:call_recording_extension();
get_format(<<"mp3">> = MP3) -> MP3;
get_format(<<"mp4">> = MP4) -> MP4;
get_format(<<"wav">> = WAV) -> WAV;
get_format(_) -> get_format('undefined').

-spec get_media_name(kz_term:ne_binary(), kz_term:api_ne_binary()) -> kz_term:ne_binary().
get_media_name(Name, Ext) ->
    case filename:extension(Name) of
        Ext -> Name;
        _ -> <<Name/binary, ".", Ext/binary>>
    end.

-spec handler_from_url(kz_term:ne_binary()) ->
          'kz_att_ftp' | 'kz_att_sftp' | 'kz_att_http' | 'undefined'.
handler_from_url(Url) ->
    case kz_http_util:urlsplit(Url) of
        {<<"ftp">>, _, _, _, _} -> 'kz_att_ftp';
        {<<"ftps">>, _, _, _, _} -> 'kz_att_ftp';
        {<<"sftp">>, _, _, _, _} -> 'kz_att_sftp';
        {<<"http">>, _, _, _, _} -> 'kz_att_http';
        {<<"https">>, _, _, _, _} -> 'kz_att_http';
        _ -> 'undefined'
    end.

-spec should_store_recording(kz_term:ne_binary(), kz_term:api_binary()) -> store_url().
should_store_recording(AccountId, Url) ->
    case kz_term:is_empty(Url) of
        'true' -> maybe_storage_plan(AccountId);
        'false' ->
            case handler_from_url(Url) of
                'undefined' ->
                    lager:debug("invalid protocol for url ~s : not saving attachment"
                               ,[kz_log:redactor(Url)]
                               ),
                    'false';
                _ -> {'true', 'other', Url}
            end
    end.

-spec maybe_storage_plan(kz_term:ne_binary()) -> store_url().
maybe_storage_plan(AccountId) ->
    AccountDb = kzs_util:format_account_mod_id(AccountId),
    Plan = kzs_plan:get_dataplan(AccountDb, kzd_call_recordings:type()),
    case maps:get('tag', Plan, <<"local">>) =/= <<"local">>
        orelse maps:is_key('att_handler', Plan)
    of
        'true' -> {'true', 'local'};
        'false' -> should_store_recording()
    end.

-spec should_store_recording() -> store_url().
should_store_recording() ->
    case kz_media_config:should_store_recordings() of
        'true' -> {'true', 'local'};
        'false' -> 'false'
    end.

-spec media_recorder(kz_json:object(), kapps_call:call() | kz_term:ne_binary()) -> kz_term:api_ne_binary().
media_recorder(Data, <<AccountId/binary>>) ->
    Url = kz_json:get_ne_binary_value(<<"url">>, Data),
    case should_store_recording(AccountId, Url) of
        'false' -> 'undefined';
        _ -> ?KZ_RECORDER
    end;
media_recorder(Data, Call) ->
    case kapps_call:kvs_fetch('recording_recorder', Call) of
        'undefined' ->
            media_recorder(Data, kapps_call:account_id(Call));
        Recorder ->
            Recorder
    end.

media_name(Data, Call) ->
    Format = get_format(kz_json:get_ne_binary_value(<<"format">>, Data)),
    DefaultMediaName = get_media_name(kz_binary:rand_hex(16), Format),
    MediaName = kz_json:get_ne_binary_value(?RECORDING_ID_KEY, Data, DefaultMediaName),
    kapps_call:kvs_fetch('recording_media_name', MediaName, Call).

media_doc_id(Data, Call) ->
    {Year, Month, _} = erlang:date(),
    DefaultMediaDocId = ?MATCH_MODB_PREFIX(kz_term:to_binary(Year), kz_date:pad_month(Month), kz_binary:rand_hex(16)),
    MediaDocId = kz_json:get_ne_binary_value(?RECORDING_MEDIA_ID_KEY, Data, DefaultMediaDocId),
    kapps_call:kvs_fetch('recording_media_doc_id', MediaDocId, Call).

-spec record_call_command(kz_json:object(), kapps_call:call()) -> kz_json:object().
record_call_command(Data, Call) ->
    TimeLimit = get_timelimit(kz_json:get_integer_value(<<"time_limit">>, Data)),
    SampleRate = kz_json:get_integer_value(<<"record_sample_rate">>, Data),
    DefaultRecordMinSec = kz_media_config:record_min_sec(),
    RecordMinSec = kz_json:get_integer_value(<<"record_min_sec">>, Data, DefaultRecordMinSec),
    CallId = kapps_call:call_id(Call),
    MediaName = media_name(Data, Call),
    MediaDocId = media_doc_id(Data, Call),
    FollowTransfer = kapps_call:kvs_fetch('recording_follow_transfer', 'false', Call),
    Recorder = media_recorder(Data, Call),
    RecordAsStereo = kapps_call:kvs_fetch('recording_stereo', Call),
    TrackMediaRecording = kapps_call:kvs_fetch('recording_track_media_recordings', 'true', Call),
    Vars = [{<<"Name">>, MediaName}
           ,{<<"Recorder">>, Recorder}
           ,{<<"ID">>, MediaDocId}
           ,{<<"Data">>, base64:encode(term_to_binary(Data))}
           | kapps_call:kvs_fetch('recording_variables', [], Call)
           ],
    Media = [{<<"Application-Name">>, <<"record_call">>}
            ,{<<"Record-Action">>, <<"start">>}
            ,{<<"Follow-Transfer">>, FollowTransfer}
            ,{<<"Time-Limit">>, TimeLimit}
            ,{<<"Media-Name">>, MediaName}
            ,{<<"Media-Recording-ID">>, MediaDocId}
            ,{<<"Record-Sample-Rate">>, SampleRate}
            ,{<<"Record-Min-Sec">>, kz_term:to_binary(RecordMinSec)}
            ,{<<"Record-Silence-Detection">>, silence_detection(Data)}
            ,{<<"Media-Recorder">>, Recorder}
            ,{<<"Recording-Variables">>, kz_json:from_list(Vars)}
            ,{<<"Channels-As-Stereo">>, RecordAsStereo}
            ,{<<"Track-Media-Recording">>, TrackMediaRecording}
            ,{<<"Call-ID">>, CallId}
            ,{<<"Msg-ID">>, kz_binary:rand_hex(16)}
            | kz_api:default_headers(<<"call">>, <<"command">>, ?APP_NAME, ?APP_VERSION)
            ],
    kz_json:from_list(Media).

%%------------------------------------------------------------------------------
%% @doc Recording settings that name neither `record_on_answer' nor
%% `record_on_bridge' start on answer while the call is unanswered.
%%
%% Account and endpoint outbound recordings start on the caller's leg before
%% it is bridged. Started there right away, FreeSWITCH's `record_session'
%% pre-answers that leg, which settles its codec before the callee's leg is
%% offered one. A leg that is already answered (or whose state cannot be
%% read) starts recording now, as before, since its answer has passed.
%% @end
%%------------------------------------------------------------------------------
-spec start_on_answer_by_default(kz_json:object(), kapps_call:call()) -> kz_json:object().
start_on_answer_by_default(Data, Call) ->
    case kz_json:get_first_defined([<<"record_on_answer">>, <<"record_on_bridge">>], Data) of
        'undefined' ->
            IsAnswered = is_answered(kapps_call_command:b_channel_status(Call)),
            start_on_answer_unless_answered(Data, IsAnswered);
        _Set -> Data
    end.

-spec start_on_answer_unless_answered(kz_json:object(), boolean()) -> kz_json:object().
start_on_answer_unless_answered(Data, 'true') -> Data;
start_on_answer_unless_answered(Data, 'false') ->
    lager:debug("call is unanswered, recording will start on answer"),
    kz_json:set_value(<<"record_on_answer">>, 'true', Data).

-spec is_answered(kapps_api_std_return()) -> boolean().
is_answered({'ok', Status}) when is_tuple(Status) ->
    kz_json:is_true(<<"Answered">>, Status);
is_answered(_Unknown) ->
    lager:debug("call state unknown (~p), recording will start now", [_Unknown]),
    'true'.

-spec silence_detection(kz_json:object()) -> kz_term:api_object().
silence_detection(Data) ->
    silence_detection(Data, kz_json:is_true(<<"silence_detection">>, Data)).

silence_detection(_Data, 'false') ->
    'undefined';
silence_detection(Data, 'true') ->
    kz_json:from_list(
      [{<<"Threshold">>, kz_json:get_integer_value(<<"silence_threshold">>, Data, 200)}
      ,{<<"Initial-Timeout">>, kz_json:get_integer_value(<<"silence_initial_timeout">>, Data, 0)}
      ,{<<"Final-Timeout">>, kz_json:get_integer_value(<<"silence_final_timeout">>, Data, 5)}
      ]
     ).
