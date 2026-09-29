%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2025, 2600Hz
%%% @doc Starts a {@link cf_exe} and processes the "flow" sans DB.
%%% @author James Aimonetti
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(cf_route_resume).

-export([handle_req/2]).

-include("callflow.hrl").

%%------------------------------------------------------------------------------
%% @doc Resume a call's callflow on this node, in the executor that runs it.
%%
%% Runs inside `cf_exe:init_cf_exe/2', which enters the executor's loop only
%% on `{ok, Call}'. The call it is given is the one some other process held --
%% a conference participant, a konami metaflow, a callflow node that died --
%% so three things are made this executor's before anything runs:
%%
%% <ul>
%%   <li>its Controller-Queue: the one in the call names the executor that
%%   held it before, which may be gone, so anything addressed to this flow
%%   would reach nobody. It is made from this node's listener queue, as a
%%   route request's is (`cf_route_req:handle_req/2').</li>
%%   <li>its events: the executor binds the request's own `Call-ID', which a
%%   resume need not carry. The call's id is bound here as well.</li>
%%   <li>the answer: `{ok, Call}' when the callflow starts, and an error
%%   (never a crash) when the channel is not up or could not be asked.</li>
%% </ul>
%%
%% It runs on the AMQP channel its listener gave the executor
%% (`cf_exe:init_cf_exe/2' takes it from the request's props), as a route
%% request does. It used to check a worker out of `cf_amqp_pool' first: the
%% pool "Private AMQP pool workers for cf_exe processes" (#5652) added, and
%% "Stabilize bindings to improve RabbitMQ operation" (#6060) took out of
%% `callflow_sup' again, moving `cf_route_req' onto the listener's channel and
%% leaving this behind. With no pool to check out from, every resume failed
%% (`noproc'), republished itself and failed again wherever it landed: the lab
%% of 2026-09-27, `e2e-260927-cca2'.
%% @end
%%------------------------------------------------------------------------------
-spec handle_req(kapi_callflow:resume(), kz_term:proplist()) ->
          {'ok' | 'restricted', kapps_call:call()} | {'error', any()}.
handle_req(ResumeJObj, Props) ->
    'true' = kapi_callflow:resume_v(ResumeJObj),
    kz_log:put_callid(ResumeJObj),
    lager:info("received call resume, taking control"),
    Call = resumed_call(ResumeJObj, Props),
    _ = kz_events:bind_call_id(kapps_call:call_id(Call)),
    handle_if_up(Call, kapps_call_command:b_channel_status(Call)).

%%------------------------------------------------------------------------------
%% @doc The call a resume carries, as this executor runs it: the flow to run,
%% and this executor's own Controller-Queue when the listener that took the
%% resume named its queue.
%% @end
%%------------------------------------------------------------------------------
-spec resumed_call(kapi_callflow:resume(), kz_term:proplist()) -> kapps_call:call().
resumed_call(JObj, Props) ->
    Flow = kz_json:get_json_value(<<"Flow">>, JObj),
    Routines = [{fun kapps_call:kvs_store/3, 'cf_flow', Flow}
               | controller_queue(props:get_value('queue', Props))
               ],
    kapps_call:exec(Routines, kapps_call:from_json(kz_json:get_json_value(<<"Call">>, JObj))).

-spec controller_queue(kz_term:api_ne_binary()) -> [{fun((kapps_call:call(), kz_term:ne_binary()) -> kapps_call:call()), kz_term:ne_binary()}].
controller_queue(<<Queue/binary>>) ->
    [{fun kapps_call:set_controller_queue/2, kapi:encode_pid(Queue)}];
controller_queue(_) -> [].

-spec handle_if_up(kapps_call:call(), {'ok', kz_json:object()} | {'error', any()}) ->
          {'ok' | 'restricted', kapps_call:call()} | {'error', any()}.
handle_if_up(Call, {'ok', _ChannelStatus}) ->
    lager:info("channel is still up"),
    _ = cf_util:flush_control_queue(Call),
    cf_route_win:execute_callflow(Call);
handle_if_up(_Call, {'error', Reason}=Error) ->
    lager:info("channel status failed (~p), not resuming call", [Reason]),
    Error.
