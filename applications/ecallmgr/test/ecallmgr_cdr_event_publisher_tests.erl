%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The CDR report of a channel that was redirected to another media
%%% server before it was answered is not published: the same Call-ID arrives
%%% there as a new channel, and that channel reports the call. Every other
%%% report is published as it comes from the media server.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_cdr_event_publisher_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/ecallmgr.hrl").

-define(CALL_ID, <<"e2e-park-direct-retrieve">>).

publish_cdr_test_() ->
    {'foreach'
    ,fun() ->
             meck:new('kapi_cdr', ['passthrough']),
             meck:expect('kapi_cdr', 'publish_report', fun(_JObj) -> 'ok' end)
     end
    ,fun(_) -> meck:unload('kapi_cdr') end
    ,[fun a_report_is_published/1
     ,fun a_stub_of_a_redirected_channel_is_not/1
     ,fun an_answered_redirected_channel_keeps_its_report/1
     ,fun the_marker_alone_does_not_hide_an_answered_report/1
     ,fun a_sub_second_answered_channel_keeps_its_report/1
     ,fun a_sub_second_success_without_billing_keeps_its_report/1
     ,fun success_alone_does_not_keep_a_report/1
     ]
    }.

success_alone_does_not_keep_a_report(_) ->
    {"a marked channel reported SUCCESS with no billing and no endpoint answer is a stub"
    ,?_test(begin
                %% FreeSWITCH's originate reports SUCCESS for accepted early
                %% media or ringing as well, so the word alone proves nothing.
                JObj = report(marked(), <<"SUCCESS">>, 0, 0, <<"EARLY MEDIA">>),
                publish(JObj),
                ?assertEqual([], published())
            end)
    }.

%% The report as the media server sends it after the channel hangs up:
%% CCVs it was given, and the disposition and billing it ended with.
report(CCVs, Disposition, BillingSeconds) ->
    report(CCVs, Disposition, BillingSeconds, BillingSeconds * 1000, Disposition).

report(CCVs, Disposition, BillingSeconds, BillingMilliSeconds, EndpointDisposition) ->
    kz_json:from_list([{<<"Event-Category">>, <<"cdr">>}
                      ,{<<"Event-Name">>, <<"report">>}
                      ,{<<"Call-ID">>, ?CALL_ID}
                      ,{<<"Disposition">>, Disposition}
                      ,{<<"Endpoint-Disposition">>, EndpointDisposition}
                      ,{<<"Billing-Seconds">>, BillingSeconds}
                      ,{<<"Billing-Milli-Seconds">>, BillingMilliSeconds}
                      ,{<<"Custom-Channel-Vars">>, kz_json:from_list(CCVs)}
                      ]).

marked() ->
    [{?REDIRECTED_TO_CCV, <<"sip:10.0.0.2:11000">>}].

a_sub_second_answered_channel_keeps_its_report(_) ->
    {"a marked channel answered and hung up within the second keeps its report"
    ,?_test(begin
                %% As the media server reports such a call: SUCCESS, 0 billing
                %% seconds, a few hundred milliseconds, endpoint ANSWER.
                JObj = report(marked(), <<"SUCCESS">>, 0, 320, <<"ANSWER">>),
                publish(JObj),
                ?assertEqual([JObj], published())
            end)
    }.

a_sub_second_success_without_billing_keeps_its_report(_) ->
    {"a marked channel the media server calls answered keeps its report even without billing"
    ,?_test(begin
                JObj = report(marked(), <<"DELAYED NEGOTIATION">>, 0, 0, <<"ANSWER">>),
                publish(JObj),
                ?assertEqual([JObj], published())
            end)
    }.

publish(JObj) ->
    ecallmgr_cdr_event_publisher:publish_cdr(#{payload => JObj}).

published() ->
    [JObj || {_Pid, {'kapi_cdr', 'publish_report', [JObj]}, _Ret} <- meck:history('kapi_cdr')].

a_report_is_published(_) ->
    {"a report is published"
    ,?_test(begin
                JObj = report([{<<"Account-ID">>, <<"account">>}], <<"ANSWER">>, 22),
                publish(JObj),
                ?assertEqual([JObj], published())
            end)
    }.

a_stub_of_a_redirected_channel_is_not(_) ->
    {"the zero-second report of a channel redirected before it was answered is not"
    ,?_test(begin
                JObj = report([{?REDIRECTED_TO_CCV, <<"sip:10.0.0.2:11000">>}], <<"DELAYED NEGOTIATION">>, 0),
                publish(JObj),
                ?assertEqual([], published())
            end)
    }.

an_answered_redirected_channel_keeps_its_report(_) ->
    {"a marked channel that was billed keeps its report"
    ,?_test(begin
                JObj = report([{?REDIRECTED_TO_CCV, <<"sip:10.0.0.2:11000">>}], <<"ANSWER">>, 5),
                publish(JObj),
                ?assertEqual([JObj], published())
            end)
    }.

the_marker_alone_does_not_hide_an_answered_report(_) ->
    {"a marked channel that answered and hung up within the second keeps its report"
    ,?_test(begin
                JObj = report([{?REDIRECTED_TO_CCV, <<"sip:10.0.0.2:11000">>}], <<"ANSWER">>, 0),
                publish(JObj),
                ?assertEqual([JObj], published())
            end)
    }.
