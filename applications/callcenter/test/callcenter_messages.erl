%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% One well-formed message per `kapi_callcenter' event, as its producer
%% sends it and with every optional header, for the tests of the modules
%% that read them.
-module(callcenter_messages).

-export([events/0, message/1, full/1, defaults/1
        ,account/0, queue/0, agent/0, call/0
        ]).

-define(ACCOUNT, <<"4b1f0c2d7e8a9b0c1d2e3f4051627384">>).
-define(QUEUE, <<"37139638ff5b68f155d8445178524df1">>).
-define(AGENT, <<"f2a1c66b6d2e1f6a4dcd6fa2b45c5a91">>).
-define(CALL, <<"3c2a1f.9e@pbx.example.com">>).
-define(NOW, 63900000000).

account() -> ?ACCOUNT.
queue() -> ?QUEUE.
agent() -> ?AGENT.
%% A SIP Call-ID, dots and all, which is what a carrier's caller has.
call() -> ?CALL.

%% Every event, in the order `kapi_callcenter:api_definitions/0' has them.
events() ->
    [<<"member_call">>, <<"member_cancel">>, <<"member_offer">>
    ,<<"member_connected">>, <<"member_result">>, <<"member_position">>
    ,<<"agent_availability">>, <<"agent_activity">>, <<"agent_offer">>
    ,<<"agent_answered">>, <<"agent_wrapup">>, <<"queue_stats">>
    ,<<"status_req">>, <<"status_resp">>
    ,<<"pickup_req">>, <<"pickup_resp">>
    ].

%% One message per event, as its producer sends it, every optional header
%% included.
message(<<"member_call">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Call">>, {[{<<"Call-ID">>, ?CALL}, {<<"Control-Queue">>, <<"callctl-1">>}]}}
    ,{<<"Callflow-Node">>, <<"kazoo_apps@one">>}
    ,{<<"Joined-Timestamp">>, ?NOW}
    ,{<<"Caller-ID-Name">>, <<"A Caller">>}
    ,{<<"Caller-ID-Number">>, <<"5551234">>}
    ,{<<"Priority">>, 2}
    ,{<<"Shard-Count">>, 64}
    ];
message(<<"member_cancel">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Reason">>, <<"hangup">>}
    ,{<<"Joined-Timestamp">>, ?NOW - 30}
    ,{<<"Cancelled-Timestamp">>, ?NOW}
    ];
message(<<"member_offer">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Agent-IDs">>, [?AGENT]}
    ,{<<"Offer-Timeout">>, 20}
    ,{<<"Joined-Timestamp">>, ?NOW - 30}
    ];
message(<<"member_connected">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Agent-ID">>, ?AGENT}
    ,{<<"Agent-Call-ID">>, <<"agent-leg">>}
    ,{<<"Answered-Timestamp">>, ?NOW}
    ,{<<"Joined-Timestamp">>, ?NOW - 30}
    ];
message(<<"member_result">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Result">>, <<"completed">>}
    ,{<<"Ended-Timestamp">>, ?NOW}
    ,{<<"Agent-ID">>, ?AGENT}
    ,{<<"Agent-Call-ID">>, <<"agent-leg">>}
    ,{<<"Joined-Timestamp">>, ?NOW - 30}
    ];
message(<<"member_position">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Position">>, 1}
    ,{<<"Waiting">>, 3}
    ,{<<"Agents-Available">>, 0}
    ,{<<"Timestamp">>, ?NOW}
    ,{<<"Caller-ID-Name">>, <<"A Caller">>}
    ,{<<"Caller-ID-Number">>, <<"5551234">>}
    ,{<<"Joined-Timestamp">>, ?NOW - 30}
    ,{<<"Media-Node">>, <<"freeswitch@fs1">>}
    ,{<<"Offered">>, 'false'}
    ];
message(<<"agent_availability">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Agent-ID">>, ?AGENT}
    ,{<<"Availability">>, <<"on_break">>}
    ,{<<"Source">>, <<"ui">>}
    ,{<<"Timestamp">>, ?NOW}
    ,{<<"Previous">>, <<"available">>}
    ,{<<"Break-Ends">>, ?NOW + 600}
    ];
message(<<"agent_activity">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Agent-ID">>, ?AGENT}
    ,{<<"Activity">>, <<"on_call">>}
    ,{<<"Timestamp">>, ?NOW}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Queue-Call">>, 'true'}
    ];
message(<<"agent_offer">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Agent-ID">>, ?AGENT}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Offer-Timeout">>, 20}
    ];
message(<<"agent_answered">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Agent-ID">>, ?AGENT}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Agent-Call-ID">>, <<"agent-leg">>}
    ,{<<"Answered-Timestamp">>, ?NOW}
    ];
message(<<"agent_wrapup">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Agent-ID">>, ?AGENT}
    ,{<<"Wrapup-Ends">>, ?NOW + 10}
    ,{<<"Timestamp">>, ?NOW}
    ,{<<"Call-ID">>, ?CALL}
    ];
message(<<"queue_stats">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Waiting">>, 3}
    ,{<<"Longest-Wait">>, 45}
    ,{<<"Agents-Available">>, 1}
    ,{<<"Timestamp">>, ?NOW}
    ];
message(<<"status_req">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ];
message(<<"status_resp">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queues">>, [{[{<<"Queue-ID">>, ?QUEUE}, {<<"Waiting-Count">>, 0}]}]}
    ,{<<"Caller-Delivery">>, <<"controller">>}
    ,{<<"Node">>, <<"kazoo_apps@one">>}
    ,{<<"On-Queue-Call">>, [?AGENT]}
    ,{<<"Shard">>, 7}
    ];
message(<<"pickup_req">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Queue-ID">>, ?QUEUE}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Supervisor-ID">>, ?AGENT}
    ,{<<"Target-Type">>, <<"device">>}
    ,{<<"Target-ID">>, <<"9f8e7d6c5b4a39281706f5e4d3c2b1a0">>}
    ,{<<"Device-IDs">>, [<<"9f8e7d6c5b4a39281706f5e4d3c2b1a0">>]}
    ,{<<"Deadline-Ms">>, 1790000003000}
    ];
message(<<"pickup_resp">>) ->
    [{<<"Account-ID">>, ?ACCOUNT}
    ,{<<"Call-ID">>, ?CALL}
    ,{<<"Result">>, <<"ringing">>}
    ,{<<"Node">>, <<"kazoo_apps@one">>}
    ,{<<"Offer-Timeout">>, 30}
    ,{<<"Reason">>, <<"no_control_queue">>}
    ].

%% The message with the headers every message on the bus carries.
full(EventName) ->
    message(EventName) ++ defaults(EventName).

defaults(EventName) ->
    [{<<"Event-Category">>, <<"callcenter">>}
    ,{<<"Event-Name">>, EventName}
    ,{<<"App-Name">>, <<"callcenter">>}
    ,{<<"App-Version">>, <<"0.1.0">>}
    ,{<<"Msg-ID">>, <<"0123456789abcdef">>}
    ].

