%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2023, 2600Hz
%%% @doc Utility module for CDR operations
%%% @author Ben Wann
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(cdr_util).

-export([get_cdr_doc_id/2
        ,get_cdr_doc_id/3

        ,register_views/0
        ]).
-export([save_cdr/2]).

%% shared functions for prepare_and_save in cdr_report and
%% cdr_channel_destroy
-export([update_ccvs/3
        ,set_doc_id/3
        ,set_recording_url/3
        ,set_call_priority/3
        ,maybe_set_e164_destination/3
        ,maybe_set_e164_origination/3
        ,maybe_set_did_classifier/3
        ,is_conference/3
        ,save_cdr/3
        ,filter_sensitive/3

        ,ccv_path/1
        ]).

-include("cdr.hrl").

-define(CHANNEL_VARS, <<"Custom-Channel-Vars">>).
-define(CCV(Key), [?CHANNEL_VARS, Key]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec get_cdr_doc_id(kz_time:gregorian_seconds(), kz_term:api_binary()) ->
          kz_term:ne_binary().
get_cdr_doc_id(Timestamp, CallId) ->
    kzd_cdrs:create_doc_id(CallId, Timestamp).

-spec get_cdr_doc_id(pos_integer(), pos_integer(), kz_term:api_binary()) -> kz_term:ne_binary().
get_cdr_doc_id(Year, Month, CallId) ->
    kzd_cdrs:create_doc_id(CallId, Year, Month).

-spec save_cdr(kz_term:api_binary(), kz_json:object()) -> 'ok' | {'error', any()}.
save_cdr(?KZ_ANONYMOUS_CDR_DB=Db, Doc) ->
    case kapps_config:get_is_true(?CONFIG_CAT, <<"store_anonymous">>, 'false') of
        'false' -> lager:debug("ignoring storage for anonymous cdr");
        'true' -> do_save_cdr(Db, Doc)
    end;
save_cdr(AccountMOD, Doc) ->
    do_save_cdr(AccountMOD, Doc).

%% How many times a conflicting save is re-read and re-evaluated before the
%% report is given up on: the stored record can change under us (an
%% interaction update, a concurrent report) between the read and the save.
-define(CONFLICT_RETRIES, 3).

-spec do_save_cdr(kz_term:api_binary(), kz_json:object()) -> 'ok' | {'error', any()}.
do_save_cdr(AccountMODb, Doc) ->
    do_save_cdr(AccountMODb, Doc, ?CONFLICT_RETRIES).

-spec do_save_cdr(kz_term:api_binary(), kz_json:object(), non_neg_integer()) -> 'ok' | {'error', any()}.
do_save_cdr(AccountMODb, Doc, Retries) ->
    case kazoo_modb:save_doc(AccountMODb, Doc, [{'max_retries', 3}]) of
        {'ok', _}-> 'ok';
        {'error', 'conflict'} -> resolve_conflict(AccountMODb, Doc, Retries);
        {'error', _E} ->
            lager:debug("failed to save cdr ~s : ~p", [kz_doc:id(Doc), _E]),
            {'error', 'max_save_retries'}
    end.

%% @doc A record is already filed under this report's id.
%%
%% The id is the month and the Call-ID, so this is either the same report
%% delivered again or another channel that carried the Call-ID in the same
%% month: a call that moved media servers, a nightmare transfer. The stored
%% record is never replaced silently. An answered report replaces a record
%% that was never answered, because a channel that was never answered was
%% not the call; anything else keeps the stored record and says so. A
%% replacement that conflicts in turn is re-read and re-evaluated, a bounded
%% number of times; a report that cannot be resolved is an error, not a
%% success.
%% @end
-spec resolve_conflict(kz_term:ne_binary(), kz_json:object(), non_neg_integer()) -> 'ok' | {'error', any()}.
resolve_conflict(_AccountMODb, Doc, 0) ->
    lager:error("cdr ~s kept conflicting with the stored record, giving up on the report from ~s (~s)"
               ,[kz_doc:id(Doc), kzd_cdrs:media_server(Doc), kzd_cdrs:disposition(Doc)]
               ),
    {'error', 'conflict'};
resolve_conflict(AccountMODb, Doc, Retries) ->
    DocId = kz_doc:id(Doc),
    case open_stored_cdr(AccountMODb, DocId) of
        {'ok', Stored} -> resolve_conflict(AccountMODb, Doc, Stored, Retries);
        {'error', 'not_found'} ->
            lager:info("cdr ~s conflicted but no record is stored any more, saving it again", [DocId]),
            do_save_cdr(AccountMODb, kz_json:delete_key(<<"_rev">>, Doc), Retries - 1);
        {'error', _E}=Error ->
            lager:error("cdr ~s conflicted with a stored record that could not be read: ~p", [DocId, _E]),
            Error
    end.

-spec resolve_conflict(kz_term:ne_binary(), kz_json:object(), kz_json:object(), pos_integer()) -> 'ok' | {'error', any()}.
resolve_conflict(AccountMODb, Doc, Stored, Retries) ->
    case {is_same_channel(Doc, Stored), is_answered(Stored), is_answered(Doc)} of
        {'true', _, _} ->
            lager:debug("cdr ~s is already stored, ignoring the repeated report", [kz_doc:id(Doc)]),
            'ok';
        {'false', 'false', 'true'} ->
            lager:info("cdr ~s stored from ~s was ~s and never answered, replacing it with the answered report from ~s"
                      ,[kz_doc:id(Doc), kzd_cdrs:media_server(Stored), kzd_cdrs:disposition(Stored), kzd_cdrs:media_server(Doc)]
                      ),
            do_save_cdr(AccountMODb, kz_doc:set_revision(Doc, kz_doc:revision(Stored)), Retries - 1);
        {'false', _, _} ->
            lager:warning("cdr ~s is already stored from ~s (~s, ~p billing ms), dropping the report from ~s (~s, ~p billing ms)"
                         ,[kz_doc:id(Doc)
                          ,kzd_cdrs:media_server(Stored), kzd_cdrs:disposition(Stored), billing_milli_seconds(Stored)
                          ,kzd_cdrs:media_server(Doc), kzd_cdrs:disposition(Doc), billing_milli_seconds(Doc)
                          ]
                         ),
            'ok'
    end.

-spec open_stored_cdr(kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'ok', kz_json:object()} | {'error', any()}.
open_stored_cdr(?KZ_ANONYMOUS_CDR_DB=Db, DocId) ->
    kz_datamgr:open_doc(Db, DocId);
open_stored_cdr(AccountMODb, DocId) ->
    kazoo_modb:open_doc(AccountMODb, DocId).

%% @doc Whether two records describe the same channel, which is to say the
%% same report delivered twice.
-spec is_same_channel(kz_json:object(), kz_json:object()) -> boolean().
is_same_channel(Doc, Stored) ->
    lists:all(fun(Field) -> Field(Doc) =:= Field(Stored) end
             ,[fun kzd_cdrs:media_server/1
              ,fun kzd_cdrs:disposition/1
              ,fun kzd_cdrs:hangup_cause/1
              ,fun kzd_cdrs:billing_seconds/1
              ,fun kzd_cdrs:channel_created_time/1
              ]
             ).

%% A call answered and hung up within the second bills 0 seconds but some
%% hundred milliseconds, with an endpoint disposition of `ANSWER'. The
%% disposition alone does not settle it: FreeSWITCH's originate reports
%% `SUCCESS' for accepted early media or ringing too, so only billing and
%% the endpoint's `ANSWER' count.
-spec is_answered(kz_json:object()) -> boolean().
is_answered(Doc) ->
    billing_milli_seconds(Doc) > 0
        orelse kzd_cdrs:billing_seconds(Doc, 0) > 0
        orelse kzd_cdrs:disposition(Doc) =:= <<"ANSWER">>
        orelse kz_json:get_ne_binary_value(<<"endpoint_disposition">>, Doc) =:= <<"ANSWER">>.

-spec billing_milli_seconds(kz_json:object()) -> non_neg_integer().
billing_milli_seconds(Doc) ->
    kz_json:get_integer_value(<<"billing_milli_seconds">>, Doc, 0).

-spec register_views() -> 'ok'.
register_views() ->
    kz_datamgr:register_views_from_folder('cdr').

-spec update_ccvs(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
update_ccvs(_AccountId, _Timestamp, JObj) ->
    CCVs = kz_call_event:custom_channel_vars(JObj, kz_json:new()),
    {UpdatedJObj, UpdatedCCVs} =
        kz_json:foldl(fun update_ccvs_foldl/3
                     ,{JObj, CCVs}
                     ,CCVs
                     ),
    kz_json:set_value(?CHANNEL_VARS, UpdatedCCVs, UpdatedJObj).

-spec update_ccvs_foldl(kz_json:get_key(), kz_json:json_term(), {kz_call_event:payload(), kz_json:object()}) ->
          {kz_call_event:payload(), kz_json:object()}.
update_ccvs_foldl(Key, Value,  {JObj, CCVs}=Acc) ->
    case kz_doc:is_private_key(Key) of
        'false' -> Acc;
        'true' ->
            {kz_json:set_value(Key, Value, JObj)
            ,kz_json:delete_key(Key, CCVs)
            }
    end.

-spec set_doc_id(kz_term:api_ne_binary(), 'undefined' | kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
set_doc_id(AccountId, 'undefined', JObj) ->
    set_doc_id(AccountId, kz_time:now_s(), JObj);
set_doc_id(_AcctounId, Timestamp, JObj) ->
    ReportId = kapi_cdr:call_id(JObj),
    %% we should consider adding kz_binary:rand_hex(16) as ReportId
    %% as there may exist the same CallId in different servers
    %% like in the case of nightmare transfers or conference bridges
    DocId = get_cdr_doc_id(Timestamp, ReportId),
    kz_doc:set_id(JObj, DocId).

-spec set_call_priority(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
set_call_priority(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"Call-Priority">>).

-spec set_recording_url(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
set_recording_url(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"Recording-Url">>).

-spec maybe_set_e164_destination(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
maybe_set_e164_destination(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"E164-Destination">>).

-spec maybe_set_e164_origination(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
maybe_set_e164_origination(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"E164-Origination">>).

-spec maybe_set_did_classifier(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
maybe_set_did_classifier(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"DID-Classifier">>).

-spec is_conference(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> kz_call_event:payload().
is_conference(_AccountId, _Timestamp, JObj) ->
    maybe_leak_ccv(JObj, <<"Is-Conference">>, {fun kz_json:is_true/3, 'false'}).

-spec maybe_leak_ccv(kz_call_event:payload(), kz_json:get_key()) -> kz_call_event:payload().
maybe_leak_ccv(JObj, Key) ->
    maybe_leak_ccv(JObj, Key, {fun kz_json:get_value/3, 'undefined'}).

-spec maybe_leak_ccv(kz_call_event:payload(), kz_json:get_key(), {fun(), any()}) -> kz_call_event:payload().
maybe_leak_ccv(JObj, Key, {GetFun, Default}) ->
    case GetFun(?CCV(Key), JObj, Default) of
        'undefined' -> JObj;
        Default -> JObj;
        Value -> kz_json:set_value(Key
                                  ,Value
                                  ,kz_json:delete_key(?CCV(Key), JObj)
                                  )
    end.

-spec ccv_path(kz_json:key()) -> kz_json:path().
ccv_path(Key) -> ?CCV(Key).

-spec save_cdr(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) -> 'ok'.
save_cdr(_AcctId, _Timestamp, JObj) ->
    CDRDb = kz_doc:account_db(JObj),
    case save_cdr(CDRDb, kz_json:normalize_jobj(JObj)) of
        'ok' -> 'ok';
        {'error', _E} ->
            lager:error("failed to store cdr ~s in ~s: ~p", [kz_doc:id(JObj), CDRDb, _E]),
            'ok'
    end.

%% @doc checks for sensitive information and removes it from the payload
-spec filter_sensitive(kz_term:api_ne_binary(), kz_time:gregorian_seconds(), kz_call_event:payload()) ->
          kz_call_event:payload().
filter_sensitive(_AccountId, _Timestamp, JObj) ->
    SensitiveKeys = [[<<"Call-Debug">>, <<"variable_sip_auth_username">>]
                    ,[<<"Call-Debug">>, <<"variable_sip_auth_password">>]

                    ,[<<"Call-Debug">>, <<"variable_ecallmgr_pvt_cost">>]
                    ,[<<"Call-Debug">>, <<"variable_group_confirm_file">>]

                    ,[<<"Call-Debug">>, <<"variable_acl_token">>]
                    ,[<<"Call-Debug">>, <<"variable_sip_acl_token">>]

                     %% could contain bridge string or playback URL
                    ,[<<"Call-Debug">>, <<"variable_last_arg">>]
                    ,[<<"Call-Debug">>, <<"variable_current_application_data">>]
                    ],
    FilteredJObj = kz_json:delete_keys(SensitiveKeys, JObj),
    find_and_filter_sensitive_logs(FilteredJObj).

find_and_filter_sensitive_logs(JObj) ->
    find_and_filter_sensitive_logs(JObj, get_logs(JObj)).

find_and_filter_sensitive_logs(JObj, 'undefined') ->
    JObj;
find_and_filter_sensitive_logs(JObj, Logs) ->
    FilteredLogs = [filter_sensitive_log(LogJObj) || LogJObj <- Logs],
    set_logs(JObj, FilteredLogs).

%% @doc LogJObj = {"app_data":"...", "app_name":"...", "app_stamp":123}
filter_sensitive_log(LogJObj) ->
    filter_sensitive_log(LogJObj
                        ,kz_json:get_value(<<"app_name">>, LogJObj)
                        ,kz_json:get_value(<<"app_data">>, LogJObj)
                        ).

filter_sensitive_log(LogJObj, _Name, <<"http_cache://", _/binary>>) ->
    lager:info("filtering http_cache URL out of app ~s", [_Name]),
    kz_json:set_value(<<"app_data">>, <<"**filtered**">>, LogJObj);
filter_sensitive_log(LogJObj, _Name, _Data) ->
    LogJObj.

get_logs(JObj) ->
    kz_json:get_list_value([<<"Extended-Data">>, <<"Channel-Application-Log">>]
                          ,JObj
                          ).

set_logs(JObj, Logs) ->
    kz_json:set_value([<<"Extended-Data">>, <<"Channel-Application-Log">>]
                     ,Logs
                     ,JObj
                     ).
