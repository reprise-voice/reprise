%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The confirming publisher's life, with a channel that is a process of
%%% the test's: what it answers before it has a channel, on one, when the
%%% channel goes, and on the next one.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
-module(confirming_publisher_ffi).

-export([lifecycle/0]).

-define(PUBLISHER, 'kazoo_gleam_confirming_publisher').

%% @doc Every step's label and what it came to, in order.
-spec lifecycle() -> [{binary(), any()}].
lifecycle() ->
    Test = self(),
    Hooks = #{'connect' => fun() -> 'ok' end
             ,'attach' => fun(_Channel) -> self() ! {'$server_confirms', 'true'} end
             ,'seqno' => fun(Channel) -> call(Channel, 'next') end
             ,'send' => fun(Channel, Method, Content) -> send(Test, Channel, Method, Content) end
             },
    {'ok', Publisher} = ?PUBLISHER:start_link(Hooks),
    unlink(Publisher),
    try
        Steps = steps(Publisher),
        Steps
    after
        exit(Publisher, 'kill')
    end.

%% What `kz_amqp_channel:publish_on/3' does with the message a prepare
%% function built: a `{count, Target}' is the channel counting one more
%% message, and the test hearing which; an `{answer, Answer}' is the channel
%% refusing it with that answer. A channel gone during the call is
%% `{error, {noproc, _}}', as `publish_on/3' answers.
send(Test, Channel, {'count', Target}, Payload) ->
    try call(Channel, 'published') of
        _ ->
            Test ! {'published', Target, Payload},
            'ok'
    catch
        'exit':Reason -> {'error', Reason}
    end;
send(_Test, _Channel, {'answer', Answer}, _Payload) ->
    Answer.

%% The message a `kapi' prepare function would build, for `send/4'.
count(Target, Payload) -> {{'count', Target}, Payload}.

refused(Answer) -> fun(_Target, Payload) -> {{'answer', Answer}, Payload} end.

steps(Publisher) ->
    Publish = fun count/2,
    One = channel(),
    Before = ?PUBLISHER:publish(Publish, <<"3">>, payload(), 1000),

    Publisher ! {'kz_amqp_assignment', {'new_channel', 'false', One}},
    %% One message, acked.
    A = async(Publish, <<"3">>, payload(), 2000),
    {<<"3">>, _MsgA} = published(),
    Publisher ! {'basic.ack', 1, 'false'},
    Acked = await(A),

    %% Two waiting at once: the second returned, then both acked together.
    B = async(Publish, <<"4">>, payload(), 2000),
    {<<"4">>, _MsgB} = published(),
    C = async(Publish, <<"5">>, payload(<<"given-id">>), 2000),
    {<<"5">>, MsgC} = published(),
    Publisher ! {returned_to(<<"5">>), {'amqp_msg', 'props', json:encode(#{<<"Msg-ID">> => MsgC})}},
    Publisher ! {'basic.ack', 3, 'true'},
    Pair = {await(B), await(C)},

    %% Refused.
    D = async(Publish, <<"6">>, payload(), 2000),
    _ = published(),
    Publisher ! {'basic.nack', 4, 'false', 'false'},
    Nacked = await(D),

    %% Not confirmed in time; the late ack is nobody's.
    E = async(Publish, <<"7">>, payload(), 100),
    _ = published(),
    Late = await(E),
    Publisher ! {'basic.ack', 5, 'false'},

    %% With one message waiting on tag 6, the channel refuses two publishes
    %% -- one it says is blocked, one whose refusal nobody passed on -- and
    %% neither takes tag 6 from the message waiting on it, nor tag 7 from
    %% the next one.
    Waiting = async(Publish, <<"8">>, payload(), 2000),
    _ = published(),
    Blocked = ?PUBLISHER:publish(refused('blocked'), <<"9">>, payload(), 2000),
    Unmoved = ?PUBLISHER:publish(refused('ok'), <<"9">>, payload(), 2000),
    Next = async(Publish, <<"10">>, payload(), 2000),
    _ = published(),
    Publisher ! {'basic.ack', 6, 'false'},
    Publisher ! {'basic.ack', 7, 'false'},
    Refused = {Blocked, Unmoved, await(Waiting), await(Next)},

    %% A message that could not be built is its reason, and nothing went
    %% out: the next message has the next tag.
    Raised = ?PUBLISHER:publish(fun(_Target, _Payload) -> erlang:error('invalid') end, <<"9">>, payload(), 2000),
    NotAMessage = ?PUBLISHER:publish(fun(_Target, _Payload) -> 'ok' end, <<"9">>, payload(), 2000),
    AfterUnbuilt = async(Publish, <<"10">>, payload(), 2000),
    _ = published(),
    Publisher ! {'basic.ack', 8, 'false'},
    Unbuilt = {Raised, NotAMessage, await(AfterUnbuilt)},

    %% The channel goes with a message waiting on it.
    F = async(Publish, <<"11">>, payload(), 5000),
    _ = published(),
    exit(One, 'kill'),
    Dropped = await(F),
    Without = ?PUBLISHER:publish(Publish, <<"12">>, payload(), 1000),

    %% A message's time runs out while its channel is being replaced: the
    %% expiry comes after the next channel's first message, which has the
    %% same tag, and is not that message's.
    Two = channel(),
    Publisher ! {'kz_amqp_assignment', {'new_channel', 'true', Two}},
    G = async(Publish, <<"13">>, payload(), 300),
    _ = published(),
    ok = sys:suspend(Publisher),
    exit(Two, 'kill'),
    Three = channel(),
    Publisher ! {'kz_amqp_assignment', {'new_channel', 'true', Three}},
    H = async(Publish, <<"14">>, payload(), 2000),
    timer:sleep(450),
    ok = sys:resume(Publisher),
    _ = published(),
    Replaced = await(G),
    Publisher ! {'basic.ack', 1, 'false'},
    Again = await(H),

    %% The channel is found gone at the publish: nothing waits for another.
    'ok' = call(Three, 'die_on_next'),
    GoneAtPublish = ?PUBLISHER:publish(Publish, <<"15">>, payload(), 1000),

    %% The channel goes between the sequence number and the publish:
    %% `publish_on/3' answers `noproc', and nothing went out.
    Four = channel(),
    Publisher ! {'kz_amqp_assignment', {'new_channel', 'true', Four}},
    'ok' = call(Four, 'die_after_next'),
    GoneDuringPublish = ?PUBLISHER:publish(Publish, <<"16">>, payload(), 1000),

    [{<<"before a channel">>, Before}
    ,{<<"acked">>, Acked}
    ,{<<"acked with one returned">>, Pair}
    ,{<<"nacked">>, Nacked}
    ,{<<"not confirmed">>, Late}
    ,{<<"refused by the channel">>, Refused}
    ,{<<"not built">>, Unbuilt}
    ,{<<"channel lost">>, Dropped}
    ,{<<"without a channel">>, Without}
    ,{<<"lost while its channel was replaced">>, Replaced}
    ,{<<"the next channel">>, Again}
    ,{<<"channel gone at the publish">>, GoneAtPublish}
    ,{<<"channel gone before the publish">>, GoneDuringPublish}
    ,{<<"still running">>, is_process_alive(Publisher)}
    ].

payload() -> {[{<<"Call-ID">>, <<"call">>}]}.

payload(MsgId) -> {[{<<"Call-ID">>, <<"call">>}, {<<"Msg-ID">>, MsgId}]}.

returned_to(RoutingKey) ->
    {'basic.return', 312, <<"NO_ROUTE">>, <<>>, RoutingKey}.

published() ->
    receive
        {'published', Target, {Props}} ->
            {<<"Msg-ID">>, MsgId} = lists:keyfind(<<"Msg-ID">>, 1, Props),
            {Target, MsgId}
    after 2000 -> error('nothing_published')
    end.

async(PublishFun, Target, Payload, Timeout) ->
    Test = self(),
    Ref = make_ref(),
    _ = spawn(fun() -> Test ! {Ref, ?PUBLISHER:publish(PublishFun, Target, Payload, Timeout)} end),
    Ref.

await(Ref) ->
    receive {Ref, Result} -> Result
    after 5000 -> error('no_result')
    end.

%% A channel: a process that counts what is published on it, and answers
%% the publish sequence number of the next -- or, told to, goes when it is
%% next asked for one, or once it has answered it.
channel() ->
    spawn(fun() -> channel(1) end).

channel(Next) ->
    receive
        {From, Ref, 'next'} -> From ! {Ref, Next}, channel(Next);
        {From, Ref, 'published'} -> From ! {Ref, 'ok'}, channel(Next + 1);
        {From, Ref, 'die_on_next'} -> From ! {Ref, 'ok'}, dying();
        {From, Ref, 'die_after_next'} -> From ! {Ref, 'ok'}, dying_after_next(Next)
    end.

dying() ->
    receive {_From, _Ref, 'next'} -> exit('normal') end.

%% Answers for the sequence number once more, and goes.
dying_after_next(Next) ->
    receive {From, Ref, 'next'} -> From ! {Ref, Next}, exit('normal') end.

%% As a call to a real channel does: `noproc' when it is gone.
call(Channel, Request) ->
    Monitor = erlang:monitor('process', Channel),
    Channel ! {self(), Monitor, Request},
    receive
        {Monitor, Answer} ->
            erlang:demonitor(Monitor, ['flush']),
            Answer;
        {'DOWN', Monitor, 'process', Channel, _Reason} ->
            exit({'noproc', {?MODULE, 'call', [Channel, Request]}})
    after 1000 -> error('channel_silent')
    end.
