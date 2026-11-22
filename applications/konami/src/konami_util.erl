%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2020, 2600Hz
%%% @doc
%%% @author James Aimonetti
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(konami_util).

-export([listen_on_other_leg/2, with_leg_control/1, set_leg_control/3]).
-export([send_hangup_req/1]).
-export([send_break_req/1]).

-include("konami.hrl").

-spec listen_on_other_leg(kapps_call:call(), kz_term:ne_binaries()) -> 'ok'.
listen_on_other_leg(Call, Events) ->
    %% Current ecallmgr does not expand B-Leg-Events on noop commands.
    %% Register this consumer directly for the known peer instead.
    konami_event_listener:add_call_binding(kapps_call:other_leg_call_id(Call), Events).

-spec send_hangup_req(kz_term:ne_binary()) -> 'ok'.
send_hangup_req(CallId) ->
    API = [{<<"Call-ID">>, CallId}
          ,{<<"Action">>, <<"hangup">>}
          ,{<<"Data">>, kz_json:new()}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    lager:debug("attempting to hangup ~s", [CallId]),
    kz_amqp_worker:cast(API, fun kapi_metaflow:publish_action/1).

-spec send_break_req(kz_term:ne_binary()) -> 'ok'.
send_break_req(CallId) ->
    API = [{<<"Call-ID">>, CallId}
          ,{<<"Action">>, <<"break">>}
          ,{<<"Data">>, kz_json:new()}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    lager:debug("attempting to break ~s", [CallId]),
    kz_amqp_worker:cast(API, fun kapi_metaflow:publish_action/1).

%% A move/intercept response may supply independent control for the B leg.
%% Preserve the logical A/B orientation, but publish commands for that B leg to
%% its own queue instead of the old A-leg controller.
-spec with_leg_control(kapps_call:call()) -> kapps_call:call().
with_leg_control(Call) ->
    Peer = kapps_call:other_leg_call_id(Call),
    case leg_control(Peer, Call) of
        Queue when is_binary(Peer), is_binary(Queue) ->
            kapps_call:set_custom_publish_function(fun publish_leg_command/2, Call);
        _ -> Call
    end.

publish_leg_command(Command, Call) ->
    Plain = kapps_call:clear_custom_publish_function(Call),
    Id = props:get_value(<<"Call-ID">>, Command, kapps_call:call_id(Call)),
    case leg_control(Id, Call) of
        Queue when is_binary(Id), is_binary(Queue) ->
            kapps_call_command:send_command(Command, kapps_call:set_control_queue(Queue, kapps_call:set_call_id(Id, Plain)));
        _ -> kapps_call_command:send_command(Command, Plain)
    end.

-spec set_leg_control(binary(), binary(), kapps_call:call()) -> kapps_call:call().
set_leg_control(Id, Queue, Call) when is_binary(Id), is_binary(Queue) ->
    kapps_call:kvs_store(<<"konami_control:", Id/binary>>, Queue, Call).

leg_control(Id, Call) when is_binary(Id) ->
    kapps_call:kvs_fetch(<<"konami_control:", Id/binary>>, Call);
leg_control(_, _) -> 'undefined'.
