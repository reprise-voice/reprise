#!/usr/bin/env escript
%%! -env ERL_LIBS /opt/kazoo/lib +A 2
%% Copyright (C) 2026, Vonix LLC
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% fs-contract-probe: a fake FreeSWITCH speaking the mod_reprise AMQP wire
%% contract against a live ecallmgr_extension (written before the module,
%% to pin the contract down).
%%
%% Raw amqp_client + jiffy — no kz_amqp, no gen_listener — because it plays
%% the role the C module will play. Runs inside the kazoo image.
%%
%% Modes:
%%   (default)     fetch-RPC checks against the extension (no node created)
%%   --advertise   full fake-node lifecycle: kz_nodes advertise/heartbeat,
%%                 answer the command stream, then run the fetch-RPC battery
%%                 (dialplan / directory / location / channels) and a
%%                 CHANNEL_CREATE/DESTROY event sequence.
%%                 Creates a fake media server in ecallmgr — test clusters only.
-mode(compile).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(DEFAULT_URI, "amqp://guest:guest@127.0.0.1:5672").
-define(REPLY_TIMEOUT_MS, 5000).
-define(HEARTBEAT_MS, 5000).
-define(RUN_SECS_DEFAULT, 90).
-define(CHANNEL_HOLD_MS, 15000).

main(Args) ->
    Mode = case Args of
               ["--advertise" | _] -> advertise;
               ["--dump", Path | _] -> {dump, Path};
               _ -> basic
           end,
    Results =
        try run(Mode)
        catch C:E:ST ->
                io:format("EXCEPTION ~p:~p~n~p~n", [C, E, ST]),
                [{<<"exception">>, fail}]
        end,
    Failed = [N || {N, fail} <- Results],
    io:format("~n~b/~b checks passed~n", [length(Results) - length(Failed), length(Results)]),
    case Failed of
        [] -> halt(0);
        _ -> io:format("FAILED: ~p~n", [Failed]), halt(1)
    end.

run(Mode) ->
    URI = os:getenv("PROBE_AMQP_URI", ?DEFAULT_URI),
    %% amqp_client 4.x: amqp_uri:parse/1 needs amqp_auth_mechanisms loaded
    _ = code:ensure_loaded(amqp_auth_mechanisms),
    {ok, Params} = amqp_uri:parse(URI),
    {ok, Conn} = amqp_connection:start(Params),
    {ok, Ch} = amqp_connection:open_channel(Conn),
    pass(<<"connect">>, io_lib:format("broker ~s", [redact(URI)])),

    <<R:32, _/binary>> = crypto:strong_rand_bytes(4),
    CoreUUID = list_to_binary(io_lib:format("probe-~8.16.0b", [R])),

    #'queue.declare_ok'{queue = ReplyQ} =
        amqp_channel:call(Ch, #'queue.declare'{queue = <<>>, exclusive = true, auto_delete = true}),
    #'queue.bind_ok'{} =
        amqp_channel:call(Ch, #'queue.bind'{queue = ReplyQ, exchange = <<"targeted">>, routing_key = ReplyQ}),
    #'basic.consume_ok'{consumer_tag = ReplyTag} =
        amqp_channel:subscribe(Ch, #'basic.consume'{queue = ReplyQ, no_ack = true}, self()),
    consume_ok(),
    pass(<<"reply-queue">>, ReplyQ),

    Base = [{<<"connect">>, ok}, {<<"reply-queue">>, ok}],
    case Mode of
        basic -> Base ++ basic_checks(Ch, CoreUUID, ReplyQ);
        {dump, Path} -> Base ++ dump_config(Ch, CoreUUID, ReplyQ, Path);
        advertise -> Base ++ advertise_checks(Conn, Ch, CoreUUID, ReplyQ, ReplyTag)
    end.

%% fetch kazoo.conf and write the raw XML body to Path
dump_config(Ch, CoreUUID, ReplyQ, Path) ->
    {FetchId, RK, Headers, Fields} = config_fetch_payload(CoreUUID, ReplyQ, <<"com.kazoo.conf">>),
    publish(Ch, <<"freeswitch">>, RK, enc(Fields), Headers),
    receive
        {#'basic.deliver'{}, #amqp_msg{props = Props, payload = Body}}
          when Props#'P_basic'.message_id =:= FetchId ->
            ok = file:write_file(Path, Body),
            pass(<<"config-dump">>, io_lib:format("~b bytes -> ~s", [byte_size(Body), Path])),
            [{<<"config-dump">>, ok}]
    after ?REPLY_TIMEOUT_MS ->
            io:format("FAIL config-dump: no reply~n"),
            [{<<"config-dump">>, fail}]
    end.

%%%=============================================================================
%%% basic mode: config fetch RPC without a node
%%%=============================================================================

basic_checks(Ch, CoreUUID, ReplyQ) ->
    R1 = sync_fetch_check(<<"config-fetch com.kazoo.conf">>, Ch, ReplyQ,
                          config_fetch_payload(CoreUUID, ReplyQ, <<"com.kazoo.conf">>),
                          [{<<"content-type text/xml">>, fun(P, _B) -> P#'P_basic'.content_type =:= <<"text/xml">> end}
                          ,{<<"xml document root">>, has(<<"<document type=\"freeswitch/xml\"">>)}
                          ,{<<"has configuration">>, has(<<"configuration">>)}
                          ,{<<"has amqp profile">>, has(<<"profile">>)}
                          ]),
    R2 = sync_fetch_check(<<"config-fetch unknown key -> not found">>, Ch, ReplyQ,
                          config_fetch_payload(CoreUUID, ReplyQ, <<"no.such.conf">>),
                          [{<<"not-found result">>, has(<<"not found">>)}]),
    [R1, R2].

config_fetch_payload(CoreUUID, ReplyQ, KeyValue) ->
    FetchId = uuid(),
    RK = <<"freeswitch.configuration.fetch.", CoreUUID/binary, ".", FetchId/binary>>,
    {FetchId, RK, [],
     base_fetch(CoreUUID, ReplyQ, FetchId,
                #{<<"Event-Name">> => <<"GENERAL">>
                 ,<<"Fetch-Section">> => <<"configuration">>
                 ,<<"Fetch-Tag">> => <<"configuration">>
                 ,<<"Fetch-Version">> => <<"commercial">>
                 ,<<"Fetch-Key-Name">> => <<"name">>
                 ,<<"Fetch-Key-Value">> => KeyValue
                 })}.

base_fetch(CoreUUID, ReplyQ, FetchId, Extra) ->
    maps:merge(#{<<"Event-Category">> => <<"fetch">>
                ,<<"Fetch-UUID">> => FetchId
                ,<<"Fetch-Timeout">> => 3500
                ,<<"Fetch-Timestamp-Micro">> => erlang:system_time(microsecond)
                ,<<"Core-UUID">> => CoreUUID
                ,<<"Node">> => <<"freeswitch@", CoreUUID/binary, ".probe.internal">>
                ,<<"Server-ID">> => ReplyQ
                ,<<"Msg-ID">> => FetchId
                ,<<"App-Name">> => <<"fs_contract_probe">>
                ,<<"App-Version">> => <<"0.1.0">>
                }, Extra).

sync_fetch_check(Name, Ch, _ReplyQ, {FetchId, RK, Headers, Fields}, Assertions) ->
    T0 = erlang:monotonic_time(microsecond),
    publish(Ch, <<"freeswitch">>, RK, enc(Fields), Headers),
    receive
        {#'basic.deliver'{}, #amqp_msg{props = Props, payload = Body}}
          when Props#'P_basic'.message_id =:= FetchId ->
            Micros = erlang:monotonic_time(microsecond) - T0,
            Bad = [A || {A, F} <- Assertions, not F(Props, Body)],
            case Bad of
                [] -> pass(Name, io_lib:format("~.1fms, ~b bytes", [Micros / 1000, byte_size(Body)])),
                      {Name, ok};
                _ -> io:format("FAIL ~s: ~p~n", [Name, Bad]), {Name, fail}
            end
    after ?REPLY_TIMEOUT_MS ->
            io:format("FAIL ~s: no reply in ~bms~n", [Name, ?REPLY_TIMEOUT_MS]),
            {Name, fail}
    end.

%%%=============================================================================
%%% advertise mode: fake node lifecycle + fetch battery + channel events
%%%=============================================================================

advertise_checks(_Conn, Ch, CoreUUID, ReplyQ, ReplyTag) ->
    NodeName = <<"freeswitch@", CoreUUID/binary, ".probe.internal">>,
    CmdQ = <<"freeswitch.cmds.", CoreUUID/binary>>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Ch, #'queue.declare'{queue = CmdQ, auto_delete = true}),
    #'queue.bind_ok'{} =
        amqp_channel:call(Ch, #'queue.bind'{queue = CmdQ
                                           ,exchange = <<"freeswitch">>
                                           ,routing_key = <<"freeswitch.commands.", CoreUUID/binary>>}),
    #'basic.consume_ok'{consumer_tag = CmdTag} =
        amqp_channel:subscribe(Ch, #'basic.consume'{queue = CmdQ, no_ack = true}, self()),
    consume_ok(),
    io:format("advertising as ~s (core ~s), cmd queue ~s~n", [NodeName, CoreUUID, CmdQ]),

    heartbeat(Ch, NodeName, CoreUUID),
    erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
    RunSecs = list_to_integer(os:getenv("PROBE_RUN_SECS", integer_to_list(?RUN_SECS_DEFAULT))),
    erlang:send_after(RunSecs * 1000, self(), done),

    State = #{ch => Ch, core => CoreUUID, node => NodeName, replyq => ReplyQ
             ,reply_tag => ReplyTag, cmd_tag => CmdTag
             ,node_info_seen => false, api_seen => [], bg_seen => []
             ,checks => not_started, current => none, results => []
             ,chan_state => idle, chan_id => uuid()},
    Final = loop(State),
    summarize(Final).

loop(#{ch := Ch, node := NodeName, core := CoreUUID} = State) ->
    receive
        heartbeat ->
            heartbeat(Ch, NodeName, CoreUUID),
            erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
            loop(maybe_start_checks(State));
        {#'basic.deliver'{consumer_tag = Tag, routing_key = RK}, #amqp_msg{props = Props, payload = Body}} ->
            loop(handle_delivery(Tag, RK, Props, Body, State));
        {check_timeout, FetchId} ->
            loop(check_timed_out(FetchId, State));
        chan_destroy ->
            loop(channel_destroy(State));
        chan_done ->
            State;
        done ->
            State;
        _Other ->
            loop(State)
    end.

handle_delivery(Tag, _RK, _Props, Body, #{cmd_tag := Tag} = State) ->
    Req = jiffy:decode(Body, [return_maps]),
    Event = maps:get(<<"Event-Name">>, Req, <<"?">>),
    handle_command(Event, Req, State);
handle_delivery(_Tag, _RK, Props, Body, #{current := {Name, FetchId, T0}} = State)
  when Props#'P_basic'.message_id =:= FetchId ->
    Ms = (erlang:monotonic_time(microsecond) - T0) / 1000,
    io:format("<- ~s reply (~s, ~b bytes, ~.1fms): ~ts~n"
             ,[Name, Props#'P_basic'.content_type, byte_size(Body), Ms, snippet(Body)]),
    record_result(Name, {ok, Ms, Body}, State);
handle_delivery(_Tag, RK, _Props, Body, State) ->
    io:format("<- reply-queue message on ~s: ~ts...~n", [RK, snippet(Body)]),
    State.

%%%-----------------------------------------------------------------------------
%%% fetch battery (runs once the node listener is up)
%%%-----------------------------------------------------------------------------

maybe_start_checks(#{checks := not_started, api_seen := Seen} = State) when Seen =/= [] ->
    io:format("~n=== node is up; starting fetch battery ===~n"),
    next_check(State#{checks => pending_checks()});
maybe_start_checks(State) -> State.

pending_checks() ->
    [{<<"dialplan-fetch (hashed exchange, 604 reply)">>, fun dialplan_fetch/1, 10000}
    ,{<<"directory-fetch sip_auth unknown user">>, fun directory_fetch/1, 10000}
    ,{<<"location-fetch unknown endpoint">>, fun location_fetch/1, 8000}
    ,{<<"channels-fetch unknown uuid">>, fun channels_fetch/1, 8000}
    ].

next_check(#{checks := []} = State) ->
    io:format("=== fetch battery done; starting channel event sequence ===~n"),
    channel_create(State#{checks => drained, current => none});
next_check(#{checks := [{Name, Fun, TimeoutMs} | Rest], ch := Ch} = State) ->
    {FetchId, RK, Headers, Fields} = Fun(State),
    io:format("-> ~s (~s)~n", [Name, RK]),
    publish(Ch, <<"freeswitch">>, RK, enc(Fields), Headers),
    erlang:send_after(TimeoutMs, self(), {check_timeout, FetchId}),
    State#{checks => Rest, current => {Name, FetchId, erlang:monotonic_time(microsecond)}}.

check_timed_out(FetchId, #{current := {Name, FetchId, _}} = State) ->
    io:format("<- ~s: NO REPLY (timeout)~n", [Name]),
    record_result(Name, timeout, State);
check_timed_out(_FetchId, State) -> State. %% stale timer for an answered check

record_result(Name, Result, #{results := Results} = State) ->
    next_check(State#{results => [{Name, Result} | Results], current => none}).

dialplan_fetch(#{core := CoreUUID, replyq := ReplyQ, node := NodeName}) ->
    FetchId = uuid(),
    CallId = uuid(),
    RK = <<"freeswitch.dialplan.fetch.", CoreUUID/binary, ".", FetchId/binary>>,
    %% the dialplan fetch IS the kapi_route request: ecallmgr republishes the
    %% payload as-is, and kapi validation requires Event-Category "dialplan"
    %% and Event-Name "route_req" literally (mismatch crashes publish_req)
    Fields = base_fetch(CoreUUID, ReplyQ, FetchId,
                        #{<<"Event-Category">> => <<"dialplan">>
                         ,<<"Event-Name">> => <<"route_req">>
                         ,<<"Fetch-Section">> => <<"dialplan">>
                         ,<<"Fetch-Key-Name">> => <<"context">>
                         ,<<"Fetch-Key-Value">> => <<"context_2">>
                         %% dialplan timeout math is in MICROseconds
                         ,<<"Fetch-Timeout">> => 5000000
                         ,<<"Node">> => NodeName
                         ,<<"Call-ID">> => CallId
                         ,<<"Caller-Unique-ID">> => CallId
                         %% kapi_route req required headers
                         ,<<"From">> => <<"probe@probe-realm.invalid">>
                         ,<<"To">> => <<"15551230000@probe-realm.invalid">>
                         ,<<"Request">> => <<"15551230000@probe-realm.invalid">>
                         ,<<"Caller-ID-Name">> => <<"Probe">>
                         ,<<"Caller-ID-Number">> => <<"15559990000">>
                         ,<<"Call-Direction">> => <<"inbound">>
                         ,<<"Caller-Context">> => <<"context_2">>
                         ,<<"Caller-Destination-Number">> => <<"15551230000">>
                         %% no default: absence crashes the route_req
                         %% routing-key builder (get_route_req_realm_routing)
                         ,<<"Resource-Type">> => <<"audio">>
                         }),
    {FetchId, RK, [{<<"call-id">>, longstr, CallId}], Fields}.

directory_fetch(#{core := CoreUUID, replyq := ReplyQ}) ->
    FetchId = uuid(),
    RK = <<"freeswitch.directory.fetch.", CoreUUID/binary, ".", FetchId/binary>>,
    Fields = base_fetch(CoreUUID, ReplyQ, FetchId,
                        #{<<"Event-Name">> => <<"REQUEST_PARAMS">>
                         ,<<"Fetch-Section">> => <<"directory">>
                         ,<<"Fetch-Tag">> => <<"domain">>
                         ,<<"Fetch-Key-Name">> => <<"name">>
                         ,<<"Fetch-Key-Value">> => <<"probe-realm.invalid">>
                         ,<<"Action">> => <<"sip_auth">>
                         ,<<"user">> => <<"probe-user">>
                         ,<<"domain">> => <<"probe-realm.invalid">>
                         ,<<"sip_auth_username">> => <<"probe-user">>
                         ,<<"sip_auth_realm">> => <<"probe-realm.invalid">>
                         }),
    {FetchId, RK, [], Fields}.

location_fetch(#{core := CoreUUID, replyq := ReplyQ}) ->
    FetchId = uuid(),
    RK = <<"freeswitch.directory.fetch.", CoreUUID/binary, ".", FetchId/binary>>,
    Fields = base_fetch(CoreUUID, ReplyQ, FetchId,
                        #{<<"Event-Name">> => <<"REQUEST_PARAMS">>
                         ,<<"Fetch-Section">> => <<"directory">>
                         ,<<"Fetch-Tag">> => <<"location">>
                         ,<<"Fetch-Key-Name">> => <<"id">>
                         ,<<"Fetch-Key-Value">> => <<"probe-user@probe-realm.invalid">>
                         ,<<"Action">> => <<"call">>
                         }),
    {FetchId, RK, [], Fields}.

channels_fetch(#{core := CoreUUID, replyq := ReplyQ}) ->
    FetchId = uuid(),
    RK = <<"freeswitch.channels.fetch.", CoreUUID/binary, ".", FetchId/binary>>,
    Fields = base_fetch(CoreUUID, ReplyQ, FetchId,
                        #{<<"Event-Name">> => <<"CHANNEL_REQ">>
                         ,<<"Fetch-Section">> => <<"channels">>
                         ,<<"Fetch-Tag">> => <<"channel">>
                         ,<<"Fetch-Key-Name">> => <<"uuid">>
                         ,<<"Fetch-Key-Value">> => uuid()
                         ,<<"replaces-call-id">> => uuid()
                         }),
    {FetchId, RK, [], Fields}.

%%%-----------------------------------------------------------------------------
%%% channel event sequence: CHANNEL_CREATE, hold, CHANNEL_DESTROY
%%%-----------------------------------------------------------------------------

channel_create(#{ch := Ch, core := CoreUUID, node := NodeName, chan_id := CallId} = State) ->
    io:format("-> CHANNEL_CREATE ~s (holding ~bms for out-of-band channel_summary check)~n"
             ,[CallId, ?CHANNEL_HOLD_MS]),
    publish_channel_event(Ch, CoreUUID, NodeName, CallId, <<"CHANNEL_CREATE">>),
    erlang:send_after(?CHANNEL_HOLD_MS, self(), chan_destroy),
    State#{chan_state => created}.

channel_destroy(#{ch := Ch, core := CoreUUID, node := NodeName, chan_id := CallId} = State) ->
    io:format("-> CHANNEL_DESTROY ~s~n", [CallId]),
    publish_channel_event(Ch, CoreUUID, NodeName, CallId, <<"CHANNEL_DESTROY">>),
    erlang:send_after(3000, self(), chan_done),
    State#{chan_state => destroyed}.

publish_channel_event(Ch, CoreUUID, NodeName, CallId, EventName) ->
    %% call events ride the CALLEVT topic exchange with kapi_call keys
    %% (call.<EVENT>.<callid>) — the extension's event streams bind kapi_call,
    %% NOT the freeswitch exchange's event.* keys
    RK = <<"call.", EventName/binary, ".", CallId/binary>>,
    Payload = enc(#{<<"Event-Category">> => <<"call_event">>
                   ,<<"Event-Name">> => EventName
                   ,<<"Node">> => NodeName
                   ,<<"Core-UUID">> => CoreUUID
                   ,<<"Call-ID">> => CallId
                   ,<<"Unique-ID">> => CallId
                   ,<<"Caller-Unique-ID">> => CallId
                   ,<<"Call-Direction">> => <<"inbound">>
                   ,<<"Caller-Direction">> => <<"inbound">>
                   ,<<"Caller-Logical-Direction">> => <<"inbound">>
                   ,<<"Answer-State">> => <<"ringing">>
                   ,<<"Channel-Call-State">> => <<"RINGING">>
                   ,<<"Channel-State">> => <<"CS_NEW">>
                   ,<<"Caller-Caller-ID-Name">> => <<"Probe">>
                   ,<<"Caller-Caller-ID-Number">> => <<"15559990000">>
                   ,<<"Caller-Destination-Number">> => <<"15551230000">>
                   ,<<"Caller-Context">> => <<"context_2">>
                   ,<<"Event-Timestamp">> => erlang:system_time(microsecond)
                   ,<<"Msg-ID">> => uuid()
                   ,<<"App-Name">> => <<"fs_contract_probe">>
                   ,<<"App-Version">> => <<"0.1.0">>
                   }),
    publish(Ch, <<"callevt">>, RK, Payload, [{<<"call-id">>, longstr, CallId}]).

%%%-----------------------------------------------------------------------------
%%% command responder
%%%-----------------------------------------------------------------------------

handle_command(<<"json_api">>, Req, #{ch := Ch, core := CoreUUID} = State) ->
    Payload = maps:get(<<"Payload">>, Req, #{}),
    Cmd = maps:get(<<"command">>, Payload, <<"?">>),
    io:format("<- json_api ~s~n", [Cmd]),
    reply(Ch, Req, #{<<"Event-Name">> => <<"json_api.reply">>
                    ,<<"status">> => <<"success">>
                    ,<<"response">> => json_api_response(Cmd, CoreUUID)
                    }),
    State#{node_info_seen => maps:get(node_info_seen, State) orelse Cmd =:= <<"node.info">>};
handle_command(<<"api">>, Req, #{ch := Ch, api_seen := Seen} = State) ->
    Cmd = maps:get(<<"API-Command">>, Req, <<"?">>),
    Args = maps:get(<<"API-Arguments">>, Req, <<>>),
    io:format("<- api ~s ~s~n", [Cmd, Args]),
    reply(Ch, Req, #{<<"Event-Name">> => <<"API">>
                    ,<<"Result">> => <<"ok">>
                    ,<<"Return">> => api_return(Cmd, Args)
                    }),
    State#{api_seen => [{Cmd, Args} | Seen]};
handle_command(<<"bgapi">>, Req, #{ch := Ch, bg_seen := Seen} = State) ->
    Cmd = maps:get(<<"API-Command">>, Req, <<"?">>),
    Args = maps:get(<<"API-Arguments">>, Req, <<>>),
    JobId = uuid(),
    io:format("<- bgapi ~s ~s (job ~s)~n", [Cmd, Args, JobId]),
    reply(Ch, Req, #{<<"Event-Name">> => <<"API">>
                    ,<<"Result">> => <<"ok">>
                    ,<<"Return">> => <<"+OK", JobId/binary>>
                    }),
    reply(Ch, Req, #{<<"Event-Name">> => <<"BACKGROUND_JOB">>
                    ,<<"Job-UUID">> => JobId
                    ,<<"Job-Result">> => <<"bgok">>
                    ,<<"Job-Return">> => <<"+OK">>
                    }),
    State#{bg_seen => [{Cmd, Args} | Seen]};
handle_command(<<"version">>, Req, #{ch := Ch} = State) ->
    io:format("<- version~n"),
    %% "<module> <vX.Y.Z> <bundle>": Release gates >= v1.5 and the bundle
    %% token selects the node-module set; commercial = the AMQP transport
    reply(Ch, Req, #{<<"Event-Name">> => <<"API">>
                    ,<<"Result">> => <<"ok">>
                    ,<<"Return">> => <<"mod_reprise v5.4.0 commercial">>
                    }),
    State;
handle_command(Event, Req, #{ch := Ch} = State) ->
    io:format("<- unhandled command event ~s (answering +OK): ~ts~n", [Event, snippet(jiffy:encode(Req))]),
    reply(Ch, Req, #{<<"Event-Name">> => <<"API">>
                    ,<<"Result">> => <<"ok">>
                    ,<<"Return">> => <<"+OK probe">>
                    }),
    State.

%% replies address by Reply-To-PID (echo of Request-From-PID), Msg-ID echoed,
%% published to the request's Server-ID via the targeted exchange
reply(Ch, Req, Fields) ->
    case maps:get(<<"Server-ID">>, Req, undefined) of
        undefined -> io:format("   (no Server-ID in request — cannot reply)~n");
        ServerId ->
            Payload = enc(Fields#{<<"Event-Category">> => <<"freeswitch">>
                                 ,<<"Msg-ID">> => maps:get(<<"Msg-ID">>, Req, <<>>)
                                 ,<<"Reply-To-PID">> => maps:get(<<"Request-From-PID">>, Req, <<>>)
                                 ,<<"App-Name">> => <<"fs_contract_probe">>
                                 ,<<"App-Version">> => <<"0.1.0">>
                                 }),
            publish(Ch, <<"targeted">>, ServerId, Payload, [])
    end.

json_api_response(<<"node.info">>, CoreUUID) ->
    #{<<"Runtime-Info">> => #{<<"Core-UUID">> => CoreUUID
                             ,<<"version">> => <<"1.10.11 (probe)">>
                             ,<<"uptime">> => #{<<"seconds">> => 42}
                             ,<<"sessions">> => #{<<"count">> => #{<<"total">> => 0}}
                             }
     ,<<"Modules">> => #{<<"loaded">> => loaded_modules(), <<"available">> => []}
     ,<<"Roles">> => #{<<"Media">> => #{<<"profiles">> => #{}}}
     };
json_api_response(_Cmd, _CoreUUID) ->
    #{}.

api_return(<<"show">>, <<"channels as json">>) -> <<"{\"row_count\":0,\"rows\":[]}">>;
api_return(<<"show">>, <<"conferences as json">>) -> <<"{\"row_count\":0,\"rows\":[]}">>;
%% ecallmgr_fs_conferences xmerl-parses this — "+OK" crashes it
api_return(<<"conference">>, <<"xml_list">>) -> <<"<conferences></conferences>">>;
api_return(_, _) -> <<"+OK probe">>.

loaded_modules() ->
    [<<"mod_sofia">>, <<"mod_kazoo">>, <<"mod_dptools">>, <<"mod_commands">>, <<"mod_event_socket">>].

heartbeat(Ch, NodeName, CoreUUID) ->
    %% Expires is in MILLISECONDS (kz_nodes_ets: now_ms > last_heartbeat + expires)
    Payload = enc(#{<<"Node">> => NodeName
                   ,<<"Expires">> => 30000
                   ,<<"WhApps">> => #{<<"freeswitch">> => #{<<"Startup">> => erlang:system_time(second)}}
                   ,<<"Runtime-Info">> => #{<<"Core-UUID">> => CoreUUID}
                   ,<<"Modules">> => #{<<"loaded">> => loaded_modules()}
                   ,<<"Zone">> => <<"local">>
                   %% must parse >= v1.5 (checked from the advertise too)
                   ,<<"Version">> => <<"1.10.11 (64bit)">>
                   ,<<"Used-Memory">> => 1
                   ,<<"Processes">> => 1
                   ,<<"Ports">> => 1
                   ,<<"Channels">> => 0
                   ,<<"Conferences">> => 0
                   ,<<"Registrations">> => 0
                   ,<<"Event-Category">> => <<"nodes">>
                   ,<<"Event-Name">> => <<"advertise">>
                   ,<<"App-Name">> => <<"fs_contract_probe">>
                   ,<<"App-Version">> => <<"0.1.0">>
                   ,<<"Msg-ID">> => uuid()
                   }),
    publish(Ch, <<"nodes">>, NodeName, Payload, []).

%%%-----------------------------------------------------------------------------
%%% summary
%%%-----------------------------------------------------------------------------

summarize(#{node_info_seen := NodeInfo, api_seen := Api, results := Results, chan_state := ChanState, chan_id := CallId}) ->
    R1 = case NodeInfo of
             true -> pass(<<"advertise -> node.info requested">>, <<"bring-up initiated">>),
                     {<<"advertise -> node.info requested">>, ok};
             false -> io:format("FAIL advertise: node.info never requested~n"),
                      {<<"advertise -> node.info requested">>, fail}
         end,
    R2 = case Api of
             [] -> io:format("FAIL node listener: no api commands observed~n"),
                   {<<"node listener started (api stream)">>, fail};
             _ -> pass(<<"node listener started (api stream)">>, io_lib:format("~b api cmds", [length(Api)])),
                  {<<"node listener started (api stream)">>, ok}
         end,
    Rs = [case Result of
              {ok, Ms, _Body} -> pass(Name, io_lib:format("~.1fms", [Ms])), {Name, ok};
              timeout -> io:format("FAIL ~s: no reply~n", [Name]), {Name, fail}
          end || {Name, Result} <- lists:reverse(Results)],
    R3 = case ChanState of
             destroyed -> pass(<<"channel event sequence sent">>, CallId),
                          {<<"channel event sequence sent">>, ok};
             created -> io:format("FAIL channel sequence: destroy never sent~n"),
                        {<<"channel event sequence sent">>, fail};
             idle -> io:format("FAIL channel sequence: never started (node not up?)~n"),
                     {<<"channel event sequence sent">>, fail}
         end,
    [R1, R2 | Rs] ++ [R3].

%%%=============================================================================
%%% helpers
%%%=============================================================================

publish(Ch, Exchange, RK, Payload, Headers) ->
    Props = #'P_basic'{content_type = <<"application/json">>
                      ,timestamp = erlang:system_time(microsecond)
                      ,headers = case Headers of [] -> undefined; _ -> Headers end
                      },
    ok = amqp_channel:cast(Ch
                          ,#'basic.publish'{exchange = Exchange, routing_key = RK}
                          ,#amqp_msg{props = Props, payload = Payload}).

consume_ok() ->
    receive #'basic.consume_ok'{} -> ok after 2000 -> throw(no_consume_ok) end.

has(Pattern) ->
    fun(_Props, Body) -> binary:match(Body, Pattern) =/= nomatch end.

enc(Map) -> jiffy:encode(Map).

snippet(Bin) when byte_size(Bin) > 160 -> binary:part(Bin, 0, 160);
snippet(Bin) -> Bin.

pass(Name, Detail) ->
    io:format("PASS ~s (~s)~n", [Name, Detail]).

uuid() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    list_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E])).

redact(URI) ->
    re:replace(URI, "//[^@]*@", "//***@", [{return, list}]).
