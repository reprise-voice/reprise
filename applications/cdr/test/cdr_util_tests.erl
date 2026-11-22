%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(cdr_util_tests).

-include_lib("eunit/include/eunit.hrl").

get_cdr_doc_id_test_() ->
    Test = fun cdr_util:get_cdr_doc_id/2,
    Test1 = fun cdr_util:get_cdr_doc_id/3,
    CallId = kz_binary:rand_hex(16),
    {Year, Month, _} = erlang:date(),
    Expected = <<(kz_term:to_binary(Year))/binary, (kz_date:pad_month(Month))/binary, "-", CallId/binary>>,

    [{"Timestamp provided"
     ,?_assertEqual(Expected, Test(kz_time:now_s(), CallId))
     }
    ,{"Year, Month, and CallId provided"
     ,?_assertEqual(Expected, Test1(Year, Month, CallId))
     }
    ].

%%%=============================================================================
%%% Two reports for one Call-ID in one month.
%%%
%%% A call that moves media servers (a pickup or park retrieval redirected to
%%% the server holding the call it takes) has two channels under one Call-ID
%%% and each reports a CDR: first a zero-second stub from the server it
%%% arrived at, then the answered leg from the server it was sent to. Both
%%% get the same document id, so the second save conflicts. The record that
%%% stays must be the answered one, and no report may be dropped in silence.
%%%=============================================================================

-define(ACCOUNT_ID, <<"564f1942d9f1df7209e18c4fd0c7e160">>).
-define(MODB, <<"account%2F56%2F4f%2F1942d9f1df7209e18c4fd0c7e160-202609">>).
-define(CALL_ID, <<"e2e-park-direct-retrieve">>).
-define(DOC_ID, <<"202609-e2e-park-direct-retrieve">>).
-define(STORED_REV, <<"1-9b2a">>).

same_call_id_test_() ->
    {'foreach'
    ,fun() -> meck:new('kazoo_modb', ['passthrough']) end
    ,fun(_) -> meck:unload('kazoo_modb') end
    ,[fun both_reports_share_a_document_id/1
     ,fun an_answered_report_replaces_the_stub/1
     ,fun a_sub_second_answered_report_replaces_the_stub/1
     ,fun a_stored_answered_record_is_kept/1
     ,fun a_stored_sub_second_answered_record_is_kept/1
     ,fun a_repeated_report_is_ignored/1
     ,fun a_second_answered_channel_is_kept_out/1
     ,fun a_replacement_that_conflicts_is_re_evaluated/1
     ,fun a_record_deleted_meanwhile_is_saved_afresh/1
     ,fun an_unreadable_stored_record_is_an_error/1
     ,fun endless_conflicts_are_an_error/1
     ,fun success_alone_is_not_an_answer/1
     ,fun a_stored_success_alone_is_replaced_by_an_answer/1
     ]
    }.

%% SUCCESS with no billing and no endpoint answer: what FreeSWITCH's
%% originate reports for accepted early media or ringing.
success_alone_report() ->
    kz_json:set_value(<<"Endpoint-Disposition">>, <<"EARLY MEDIA">>
                     ,report(63956542387, <<"fs-2.example.invalid">>, <<"SUCCESS">>, <<"NORMAL_CLEARING">>, 0, 0, 1789323189998666)
                     ).

success_alone_is_not_an_answer(_) ->
    {"a SUCCESS report with no billing and no endpoint answer does not replace the stub"
    ,?_test(begin
                database_holding(stored(doc(stub_report()))),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(success_alone_report()))),
                ?assertEqual(1, save_attempts()),
                ?assertEqual([], saved())
            end)
    }.

a_stored_success_alone_is_replaced_by_an_answer(_) ->
    {"a stored SUCCESS record with no billing and no endpoint answer is replaced by the answered report"
    ,?_test(begin
                database_holding(stored(doc(success_alone_report()))),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(answered_report()))),
                [Saved] = saved(),
                ?assertEqual(?STORED_REV, kz_doc:revision(Saved)),
                ?assertEqual(<<"ANSWER">>, kzd_cdrs:disposition(Saved))
            end)
    }.

%% The reports as the media servers published them, cut down to what
%% decides the outcome. The answered report's timestamp is earlier: it is
%% the interaction's, the parked caller's.
stub_report() ->
    report(63956542389, <<"fs-1.example.invalid">>, <<"DELAYED NEGOTIATION">>, <<"NORMAL_UNSPECIFIED">>, 0, 0, 1789323189900140).

answered_report() ->
    report(63956542387, <<"fs-2.example.invalid">>, <<"ANSWER">>, <<"NORMAL_CLEARING">>, 22, 22440, 1789323189998666).

%% Answered and hung up within the second: 0 billing seconds, some hundred
%% milliseconds, and the media server calls it SUCCESS.
sub_second_answered_report() ->
    report(63956542387, <<"fs-2.example.invalid">>, <<"SUCCESS">>, <<"NORMAL_CLEARING">>, 0, 320, 1789323189998666).

report(Timestamp, MediaServer, Disposition, HangupCause, BillingSeconds, BillingMilliSeconds, CreatedTime) ->
    kz_json:from_list([{<<"Call-ID">>, ?CALL_ID}
                      ,{<<"Timestamp">>, Timestamp}
                      ,{<<"Media-Server">>, MediaServer}
                      ,{<<"Disposition">>, Disposition}
                      ,{<<"Hangup-Cause">>, HangupCause}
                      ,{<<"Billing-Seconds">>, BillingSeconds}
                      ,{<<"Billing-Milli-Seconds">>, BillingMilliSeconds}
                      ,{<<"Duration-Seconds">>, BillingSeconds}
                      ,{<<"Channel-Created-Time">>, CreatedTime}
                      ]).

%% What cdr_report hands to cdr_util:save_cdr/2: the report normalized,
%% with the id of its month and Call-ID.
doc(Report) ->
    kz_json:normalize_jobj(cdr_util:set_doc_id(?ACCOUNT_ID, kz_json:get_integer_value(<<"Timestamp">>, Report), Report)).

stored(Doc) ->
    kz_doc:set_revision(Doc, ?STORED_REV).

%% The database as it stands: one record already filed under the id, so
%% a save without its revision conflicts and a save with it succeeds.
database_holding(Stored) ->
    database(fun(?MODB, ?DOC_ID) -> {'ok', Stored} end).

%% A database whose reads are scripted: a save carrying the stored
%% revision succeeds, any other save conflicts.
database(Open) ->
    meck:expect('kazoo_modb', 'open_doc', Open),
    meck:expect('kazoo_modb', 'save_doc'
               ,fun(?MODB, Doc, [{'max_retries', 3}]) ->
                        case kz_doc:revision(Doc) of
                            ?STORED_REV -> {'ok', kz_doc:set_revision(Doc, <<"2-0c4d">>)};
                            _ -> {'error', 'conflict'}
                        end
                end
               ).

%% The stored record has moved on since the first read: the first read
%% returns the first document, every later one the second, and no save
%% ever succeeds against the first revision.
database_changing(First, Second) ->
    meck:expect('kazoo_modb', 'open_doc'
               ,fun(?MODB, ?DOC_ID) ->
                        case meck:num_calls('kazoo_modb', 'open_doc', '_') of
                            0 -> {'ok', First};
                            _ -> {'ok', Second}
                        end
                end
               ),
    meck:expect('kazoo_modb', 'save_doc'
               ,fun(?MODB, Doc, [{'max_retries', 3}]) ->
                        case kz_doc:revision(Doc) of
                            <<"2-0c4d">> -> {'ok', kz_doc:set_revision(Doc, <<"3-77e1">>)};
                            _ -> {'error', 'conflict'}
                        end
                end
               ).

saved() ->
    [Doc || {_Pid, {'kazoo_modb', 'save_doc', [?MODB, Doc, _Opts]}, {'ok', _}} <- meck:history('kazoo_modb')].

save_attempts() ->
    length([Doc || {_Pid, {'kazoo_modb', 'save_doc', [?MODB, Doc, _Opts]}, _Ret} <- meck:history('kazoo_modb')]).

both_reports_share_a_document_id(_) ->
    {"both reports get the document id of their month and Call-ID"
    ,?_test(begin
                ?assertEqual(?DOC_ID, kz_doc:id(doc(stub_report()))),
                ?assertEqual(?DOC_ID, kz_doc:id(doc(answered_report())))
            end)
    }.

an_answered_report_replaces_the_stub(_) ->
    {"the answered report replaces the stored stub, under the stub's revision"
    ,?_test(begin
                database_holding(stored(doc(stub_report()))),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(answered_report()))),
                ?assertEqual(2, save_attempts()),
                [Saved] = saved(),
                ?assertEqual(?STORED_REV, kz_doc:revision(Saved)),
                ?assertEqual(<<"fs-2.example.invalid">>, kzd_cdrs:media_server(Saved)),
                ?assertEqual(<<"ANSWER">>, kzd_cdrs:disposition(Saved)),
                ?assertEqual(22, kzd_cdrs:billing_seconds(Saved))
            end)
    }.

a_stored_answered_record_is_kept(_) ->
    {"a stub arriving after the answered record does not replace it"
    ,?_test(begin
                database_holding(stored(doc(answered_report()))),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(stub_report()))),
                ?assertEqual(1, save_attempts()),
                ?assertEqual([], saved())
            end)
    }.

a_repeated_report_is_ignored(_) ->
    {"the same report delivered again is ignored"
    ,?_test(begin
                database_holding(stored(doc(answered_report()))),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(answered_report()))),
                ?assertEqual(1, save_attempts()),
                ?assertEqual([], saved())
            end)
    }.

a_second_answered_channel_is_kept_out(_) ->
    {"a second answered channel under the Call-ID keeps the stored record"
    ,?_test(begin
                Other = report(63956542387, <<"fs-1.example.invalid">>, <<"ANSWER">>, <<"NORMAL_CLEARING">>, 5, 5120, 1789323189900140),
                database_holding(stored(doc(Other))),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(answered_report()))),
                ?assertEqual(1, save_attempts()),
                ?assertEqual([], saved())
            end)
    }.

a_sub_second_answered_report_replaces_the_stub(_) ->
    {"a call answered and hung up within the second still replaces the stub"
    ,?_test(begin
                database_holding(stored(doc(stub_report()))),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(sub_second_answered_report()))),
                [Saved] = saved(),
                ?assertEqual(?STORED_REV, kz_doc:revision(Saved)),
                ?assertEqual(<<"SUCCESS">>, kzd_cdrs:disposition(Saved)),
                ?assertEqual(0, kzd_cdrs:billing_seconds(Saved))
            end)
    }.

a_stored_sub_second_answered_record_is_kept(_) ->
    {"a stored sub-second answered record is not taken for a stub"
    ,?_test(begin
                database_holding(stored(doc(sub_second_answered_report()))),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(answered_report()))),
                ?assertEqual(1, save_attempts()),
                ?assertEqual([], saved())
            end)
    }.

a_replacement_that_conflicts_is_re_evaluated(_) ->
    {"a replacement that conflicts in turn is re-read and judged against the new record"
    ,?_test(begin
                %% The stub was read, but an answered record from another
                %% channel got in before the replacement: keep that one.
                Other = report(63956542387, <<"fs-1.example.invalid">>, <<"ANSWER">>, <<"NORMAL_CLEARING">>, 5, 5120, 1789323189900140),
                database_changing(stored(doc(stub_report())), kz_doc:set_revision(doc(Other), <<"2-0c4d">>)),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(answered_report()))),
                ?assertEqual(2, save_attempts()),
                ?assertEqual(2, meck:num_calls('kazoo_modb', 'open_doc', '_')),
                ?assertEqual([], saved())
            end)
    }.

a_record_deleted_meanwhile_is_saved_afresh(_) ->
    {"a record gone between the conflict and the read is saved afresh"
    ,?_test(begin
                meck:expect('kazoo_modb', 'open_doc', fun(?MODB, ?DOC_ID) -> {'error', 'not_found'} end),
                meck:expect('kazoo_modb', 'save_doc'
                           ,fun(?MODB, Doc, _) ->
                                    case meck:num_calls('kazoo_modb', 'save_doc', '_') of
                                        0 -> {'error', 'conflict'};
                                        _ -> {'ok', kz_doc:set_revision(Doc, <<"1-5d2c">>)}
                                    end
                            end
                           ),
                ?assertEqual('ok', cdr_util:save_cdr(?MODB, doc(answered_report()))),
                ?assertEqual(2, save_attempts()),
                [Saved] = saved(),
                ?assertEqual('undefined', kz_doc:revision(Saved))
            end)
    }.

an_unreadable_stored_record_is_an_error(_) ->
    {"a stored record that cannot be read leaves the report unresolved, as an error"
    ,?_test(begin
                database(fun(?MODB, ?DOC_ID) -> {'error', 'timeout'} end),
                ?assertEqual({'error', 'timeout'}, cdr_util:save_cdr(?MODB, doc(answered_report()))),
                ?assertEqual(1, save_attempts())
            end)
    }.

endless_conflicts_are_an_error(_) ->
    {"a replacement that keeps conflicting is given up on, as an error"
    ,?_test(begin
                %% The stored stub is re-read every time and never accepts
                %% the replacement.
                meck:expect('kazoo_modb', 'open_doc', fun(?MODB, ?DOC_ID) -> {'ok', stored(doc(stub_report()))} end),
                meck:expect('kazoo_modb', 'save_doc', fun(?MODB, _Doc, _) -> {'error', 'conflict'} end),
                ?assertEqual({'error', 'conflict'}, cdr_util:save_cdr(?MODB, doc(answered_report()))),
                ?assertEqual(4, save_attempts()),
                ?assertEqual(3, meck:num_calls('kazoo_modb', 'open_doc', '_'))
            end)
    }.
