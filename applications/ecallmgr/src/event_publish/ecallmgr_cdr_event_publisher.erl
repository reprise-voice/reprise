%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2023, 2600Hz
%%% @doc Publishes cdr.report event
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_cdr_event_publisher).

-export([init/0]).
-export([publish_cdr/1]).

-include("ecallmgr.hrl").

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = kazoo_bindings:bind(<<"event_stream.publish.cdr.report">>, ?MODULE, 'publish_cdr'),
    'ok'.

-spec publish_cdr(map()) -> any().
publish_cdr(#{payload := JObj}) ->
    kz_log:put_callid(JObj),
    case redirected_before_answer(JObj) of
        'false' -> kapi_cdr:publish_report(JObj);
        'true' ->
            lager:info("not publishing the cdr of a channel redirected to ~s before it was answered: the channel that arrived there reports the call"
                      ,[kz_evt_freeswitch:ccv(JObj, ?REDIRECTED_TO_CCV)]
                      ),
            'ok'
    end.

%% @doc Whether this is the report of a channel `ecallmgr_channel_redirect'
%% sent to another media server with a 302 before it was answered.
%%
%% The redirected INVITE keeps its Call-ID, so the channel that arrives at
%% the destination reports the call under the same id. This channel's report
%% is a zero-second stub that would only ever be filed over that record, so
%% it is not published. A channel that was answered keeps its report whatever
%% was set on it: the answer means the call happened here.
%% @end
-spec redirected_before_answer(kz_json:object()) -> boolean().
redirected_before_answer(JObj) ->
    kz_evt_freeswitch:ccv(JObj, ?REDIRECTED_TO_CCV) =/= 'undefined'
        andalso not was_answered(JObj).

%% A call answered and hung up within the second bills 0 seconds but some
%% hundred milliseconds, with an endpoint disposition of `ANSWER'. The
%% `Disposition' alone does not settle it: FreeSWITCH's originate reports
%% `SUCCESS' for accepted early media or ringing too, so only billing and
%% the endpoint's `ANSWER' count.
-spec was_answered(kz_json:object()) -> boolean().
was_answered(JObj) ->
    kz_json:get_integer_value(<<"Billing-Milli-Seconds">>, JObj, 0) > 0
        orelse kz_json:get_integer_value(<<"Billing-Seconds">>, JObj, 0) > 0
        orelse kz_json:get_ne_binary_value(<<"Disposition">>, JObj) =:= <<"ANSWER">>
        orelse kz_json:get_ne_binary_value(<<"Endpoint-Disposition">>, JObj) =:= <<"ANSWER">>.
