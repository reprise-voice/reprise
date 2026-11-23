%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc One channel in confirm mode for the node's confirmed publishes.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% `kazoo/amqp.publish_to_confirmed' used to take a channel of its own for
%%% every message: a process, a channel from `kz_amqp_assignments', a
%%% `confirm.select', the publish, the wait, and the channel closed again --
%%% for every caller joining a queue. This process holds one channel in
%%% confirm mode for as long as it runs and publishes every confirmed
%%% message on it, one at a time, without waiting for one confirmation
%%% before sending the next.
%%%
%%% == Matching the broker's answers ==
%%%
%%% A message is known by its delivery tag: the channel's publish sequence
%%% number, read from the channel just before the publish, which is what the
%%% broker's `basic.ack' and `basic.nack' carry -- one tag, or every tag up
%%% to it with `multiple'. The number is read again after the publish: a
%%% publish the channel refused -- `blocked' by the broker's flow control, or
%%% `closing' -- does not move it, took no tag, and is answered at once; a
%%% tag already waiting is never given to a second message. A message's time
%%% runs out on a reference of its own, not its tag: tags start again at one
%%% on every channel, and an expiry left over from the last channel settles
%%% nothing on this one. A `basic.return' carries no tag, only the message,
%%% so every message goes out with a `Msg-ID' (its own, or one given here)
%%% and a return is matched on that: the oldest message waiting with that
%%% id. The broker sends the return before the ack of the same message, so
%%% the ack of a returned message is `returned'.
%%%
%%% == Failing ==
%%%
%%% <ul>
%%% <li>no confirmation within the caller's timeout: `no_answer', and a late
%%% one is ignored;</li>
%%% <li>the channel lost with messages waiting: every one of them
%%% `no_answer' -- each went out and may well be on its queue;</li>
%%% <li>no channel, or not in confirm mode yet, or the channel found gone at
%%% the publish: the caller is told so before anything is published, and
%%% publishes on a channel of its own the way it always did
%%% (`kazoo_gleam_amqp_ffi');</li>
%%% <li>the message could not be built: its reason, and nothing went out;</li>
%%% <li>the channel refused the publish under the broker's flow control:
%%% `unavailable', and nothing went out.</li>
%%% </ul>
%%%
%%% == Never waiting for a channel ==
%%%
%%% `kz_amqp_channel:publish' finds its channel through the process's
%%% `$kz_amqp_consumer_channel', and when that one is dead waits for
%%% `kz_amqp_assignments' to give it another, for as long as that takes.
%%% This process does not go that way: the `kapi' module builds the message
%%% without sending it (`kapi_callcenter:prepare_member_call/2'), and it goes
%%% out with `kz_amqp_channel:publish_on/3' on the channel held here, which
%%% says what the channel answered. A dead channel is then a `noproc' at
%%% once, never a wait, and the caller is told `not_ready'.
%%%
%%% `kz_amqp_assignments' gives the process its channel, and a new one when
%%% that one is lost; each new channel is put in confirm mode before
%%% anything is published on it.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_confirming_publisher).
-behaviour(gen_server).

-export([start_link/0, start_link/1
        ,publish/4
        ,replay/1
        ]).
-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ]).

-define(SERVER, ?MODULE).
-define(RETRY_MS, 5000).

-type result() :: {'ok', 'nil'} | {'error', binary()}.
-type entry() :: #{'msg_id' := binary()
                  ,'returned' := boolean()
                  ,'from' := any()
                  ,'timer' := reference() | 'none'
                  ,'expiry' := any()
                  }.
-type pending() :: #{pos_integer() => entry()}.

%% What the process does to a channel, which a test replaces: `attach' makes
%% a new channel this process's and asks for confirm mode, which is
%% answered with `$server_confirms'; `seqno' is the delivery tag the next
%% message published on it will have; `send' publishes a built message on
%% it, and is what the channel answered: `ok', `blocked' or `closing', or
%% `{error, Reason}' when the call to it exited.
-type hooks() :: #{'attach' := fun((pid()) -> any())
                  ,'seqno' := fun((pid()) -> non_neg_integer())
                  ,'send' := fun((pid(), tuple(), tuple()) -> any())
                  ,'connect' := fun(() -> any())
                  }.

-record(state, {channel = 'undefined' :: pid() | 'undefined'
               ,monitor = 'undefined' :: reference() | 'undefined'
               ,confirming = 'false' :: boolean()
               ,pending = #{} :: pending()
               ,hooks :: hooks()
               }).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() -> {'ok', pid()} | {'error', any()}.
start_link() ->
    start_link(#{}).

%% @doc The same, with some of what it does to a channel replaced. For the
%% tests.
-spec start_link(map()) -> {'ok', pid()} | {'error', any()}.
start_link(Hooks) ->
    gen_server:start_link({'local', ?SERVER}, ?MODULE, maps:merge(hooks(), Hooks), []).

-spec hooks() -> hooks().
hooks() ->
    #{'attach' => fun attach/1
     ,'seqno' => fun amqp_channel:next_publish_seqno/1
     ,'send' => fun kz_amqp_channel:publish_on/3
     ,'connect' => fun connect/0
     }.

%%------------------------------------------------------------------------------
%% @doc Publish the message `PrepareFun(Target, Payload)' builds --
%% `{BasicPublish, AmqpMsg}', as `kapi_callcenter:prepare_member_call/2'
%% does -- on the confirming channel and wait for the broker.
%% `{error, not_ready}' when there is no publisher, no channel in confirm
%% mode, or a channel found gone at the publish, and nothing has been
%% published.
%% @end
%%------------------------------------------------------------------------------
-spec publish(fun(), binary(), any(), pos_integer()) -> result() | {'error', 'not_ready'}.
publish(PrepareFun, Target, Payload, Timeout) ->
    case whereis(?SERVER) of
        'undefined' -> {'error', 'not_ready'};
        Pid ->
            try gen_server:call(Pid, {'publish', PrepareFun, Target, Payload, Timeout}, 2 * Timeout + 1000)
            catch
                %% Gone before it took the message: nothing went out.
                'exit':{'noproc', _} -> {'error', 'not_ready'};
                %% Gone, or stuck, with the message: it may be on the queue.
                'exit':_Reason -> {'error', <<"no_answer">>}
            end
    end.

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

-spec init(hooks()) -> {'ok', #state{}}.
init(Hooks) ->
    self() ! 'connect',
    {'ok', #state{hooks = Hooks}}.

-spec handle_call(any(), any(), #state{}) -> {'noreply', #state{}} | {'reply', any(), #state{}}.
handle_call({'publish', PrepareFun, Target, Payload, Timeout}, From, State) ->
    case ready(State) of
        'false' -> {'reply', {'error', 'not_ready'}, State};
        'true' -> {'noreply', publish_now(PrepareFun, Target, Payload, Timeout, From, State)}
    end;
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_ready'}, State}.

-spec handle_cast(any(), #state{}) -> {'noreply', #state{}}.
handle_cast(_Msg, State) ->
    {'noreply', State}.

-spec handle_info(any(), #state{}) -> {'noreply', #state{}}.
handle_info('connect', #state{hooks = #{'connect' := Connect}} = State) ->
    _ = Connect(),
    {'noreply', State};
handle_info({'kz_amqp_assignment', {'new_channel', _Reconnect, Channel}}, State) ->
    {'noreply', new_channel(Channel, lost(State))};
handle_info({'kz_amqp_assignment', 'lost_channel'}, State) ->
    {'noreply', lost(State)};
handle_info({'DOWN', Ref, 'process', _Channel, _Reason}, #state{monitor = Ref} = State) ->
    {'noreply', lost(State)};
handle_info({'$server_confirms', 'true'}, #state{channel = Channel} = State) when is_pid(Channel) ->
    {'noreply', State#state{confirming = 'true'}};
handle_info(Message, #state{pending = Pending} = State) ->
    {Settled, Pending1} = settle(Message, Pending),
    reply(Settled),
    {'noreply', State#state{pending = Pending1}}.

-spec terminate(any(), #state{}) -> 'ok'.
terminate(_Reason, State) ->
    _ = lost(State),
    'ok'.

-spec code_change(any(), #state{}, any()) -> {'ok', #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%=============================================================================
%%% The channel
%%%=============================================================================

%% Ask for a channel; `kz_amqp_assignments' says when there is one, now or
%% once the broker is back, and again whenever it replaces it.
-spec connect() -> any().
connect() ->
    case code:ensure_loaded('kz_amqp_channel') of
        {'error', _Reason} -> 'ok';
        {'module', 'kz_amqp_channel'} ->
            try kz_amqp_channel:requisition()
            catch _E:_R -> erlang:send_after(?RETRY_MS, self(), 'connect')
            end
    end.

%% The channel is this process's to publish on, and in confirm mode once
%% `confirm.select_ok' is answered with `$server_confirms' in this mailbox.
%% The channel itself is asked: `kz_amqp_channel:command/1' finds it through
%% `consumer_channel/0', which waits for another when this one has already
%% gone.
-spec attach(pid()) -> any().
attach(Channel) ->
    try
        _ = kz_amqp_channel:consumer_channel(Channel),
        case amqp_channel:call(Channel, {'confirm.select', 'false'}) of
            {'confirm.select_ok'} -> self() ! {'$server_confirms', 'true'};
            _Refused -> 'ok'
        end
    catch _E:_R -> 'ok'
    end.

-spec new_channel(pid(), #state{}) -> #state{}.
new_channel(Channel, #state{hooks = #{'attach' := Attach}} = State) ->
    Monitor = erlang:monitor('process', Channel),
    _ = Attach(Channel),
    %% Nothing is published on it until it says it is confirming. The
    %% `confirm.select' was this process's own call, so the answer is already
    %% here unless the channel refused.
    Confirming = receive
                     {'$server_confirms', 'true'} -> 'true'
                 after 0 -> 'false'
                 end,
    State#state{channel = Channel, monitor = Monitor, confirming = Confirming}.

%% The channel is gone, or going: whatever was waiting on it is not going to
%% be confirmed on another one.
-spec lost(#state{}) -> #state{}.
lost(#state{monitor = Monitor, pending = Pending} = State) ->
    _ = case Monitor of
            'undefined' -> 'ok';
            _ -> erlang:demonitor(Monitor, ['flush'])
        end,
    {Settled, Pending1} = settle('lost_channel', Pending),
    reply(Settled),
    _ = catch_remove_consumer_channel(),
    State#state{channel = 'undefined'
               ,monitor = 'undefined'
               ,confirming = 'false'
               ,pending = Pending1
               }.

-spec catch_remove_consumer_channel() -> any().
catch_remove_consumer_channel() ->
    try kz_amqp_channel:remove_consumer_channel()
    catch _E:_R -> 'ok'
    end.

-spec ready(#state{}) -> boolean().
ready(#state{channel = Channel, confirming = 'true'}) when is_pid(Channel) ->
    is_process_alive(Channel);
ready(_State) -> 'false'.

-spec publish_now(fun(), binary(), any(), pos_integer(), any(), #state{}) -> #state{}.
publish_now(PrepareFun, Target, Payload, Timeout, From, State) ->
    {MsgId, Payload1} = with_msg_id(Payload),
    try PrepareFun(Target, Payload1) of
        {Method, Content} -> send_now(MsgId, Method, Content, Timeout, From, State);
        _Other ->
            gen_server:reply(From, {'error', <<"not_a_message">>}),
            State
    catch
        _E:R ->
            gen_server:reply(From, {'error', reason(R)}),
            State
    end.

-spec send_now(binary(), tuple(), tuple(), pos_integer(), any(), #state{}) -> #state{}.
send_now(MsgId, Method, Content, Timeout, From, #state{channel = Channel
                                                      ,pending = Pending
                                                      ,hooks = #{'seqno' := Seqno
                                                                ,'send' := Send
                                                                }
                                                      } = State) ->
    Publish = fun() -> Send(Channel, Method, Content) end,
    case published(Channel, Seqno, Publish) of
        {'sent', Tag} ->
            Expiry = make_ref(),
            Timer = erlang:send_after(Timeout, self(), {'expire', Expiry}),
            case add(Tag, MsgId, From, Timer, Expiry, Pending) of
                {'ok', Pending1} -> State#state{pending = Pending1};
                'taken' ->
                    %% Out, and nothing to tell its answer from the one
                    %% already waiting on the tag.
                    _ = cancel(Timer),
                    gen_server:reply(From, {'error', <<"no_answer">>}),
                    State
            end;
        {'not_sent', Reason} ->
            gen_server:reply(From, {'error', Reason}),
            State;
        'unknown' ->
            gen_server:reply(From, {'error', <<"no_answer">>}),
            State
    end.

%% Whether the message went out, and with which delivery tag: the channel's
%% publish sequence number before the publish, if the publish moved it. A
%% channel that refused the publish did not move it. Nothing here waits on
%% anything a dead channel can hold up: the sequence number is a call to
%% the channel, and so is the publish.
-spec published(pid(), fun((pid()) -> non_neg_integer()), fun(() -> any())) ->
          {'sent', pos_integer()} |
          {'not_sent', 'not_ready' | binary()} |
          'unknown'.
published(Channel, Seqno, Publish) ->
    case seqno(Seqno, Channel) of
        'gone' -> {'not_sent', 'not_ready'};
        {'ok', Tag} ->
            Sent = try Publish()
                   catch _E:R -> {'error', R}
                   end,
            case seqno(Seqno, Channel) of
                {'ok', After} when After > Tag -> {'sent', Tag};
                {'ok', _Unmoved} -> {'not_sent', unsent(Sent)};
                'gone' -> gone(Sent)
            end
    end.

-spec seqno(fun((pid()) -> non_neg_integer()), pid()) -> {'ok', non_neg_integer()} | 'gone'.
seqno(Seqno, Channel) ->
    try {'ok', Seqno(Channel)}
    catch _E:_R -> 'gone'
    end.

%% Why a publish the channel did not number went nowhere. `closing' is a
%% channel on its way out, and the caller's own channel will do; `blocked'
%% is the broker holding every publisher back, a channel of the caller's
%% own as much as this one.
-spec unsent(any()) -> 'not_ready' | binary().
unsent('closing') -> 'not_ready';
unsent({'error', Reason}) -> reason(Reason);
unsent(_BlockedOrOtherwise) -> <<"unavailable">>.

%% The channel went with the message being published: nowhere if the
%% channel was gone before it was called, and otherwise it may be on its
%% way.
-spec gone(any()) -> {'not_sent', 'not_ready'} | 'unknown'.
gone({'error', {'noproc', _}}) -> {'not_sent', 'not_ready'};
gone(_Otherwise) -> 'unknown'.

%% The message's own `Msg-ID', or one given it here: `kz_api' would give it
%% one anyway, and this one has to be known to match a return. The payload
%% is a `kz_json' object, `{Proplist}'.
-spec with_msg_id(any()) -> {binary(), any()}.
with_msg_id({Props}) when is_list(Props) ->
    case lists:keyfind(<<"Msg-ID">>, 1, Props) of
        {_, MsgId} when is_binary(MsgId), MsgId =/= <<>> -> {MsgId, {Props}};
        _Otherwise ->
            MsgId = binary:encode_hex(rand:bytes(16), 'lowercase'),
            {MsgId, {[{<<"Msg-ID">>, MsgId} | lists:keydelete(<<"Msg-ID">>, 1, Props)]}}
    end;
with_msg_id(Payload) ->
    {<<>>, Payload}.

-spec reply([{pos_integer(), entry(), result()}]) -> 'ok'.
reply(Settled) ->
    lists:foreach(fun({_Tag, #{'from' := From, 'timer' := Timer}, Result}) ->
                          _ = cancel(Timer),
                          gen_server:reply(From, Result)
                  end
                 ,Settled
                 ).

-spec cancel(reference() | 'none') -> any().
cancel('none') -> 'ok';
cancel(Timer) -> erlang:cancel_timer(Timer).

%%%=============================================================================
%%% Matching, without a channel
%%%=============================================================================

%% A message waiting on its tag, and on `Expiry' for its time to run out. A
%% tag already waiting is not given to another message: the first one's
%% caller would never be answered, and the second's answered for it.
-spec add(pos_integer(), binary(), any(), reference() | 'none', any(), pending()) ->
          {'ok', pending()} | 'taken'.
add(Tag, _MsgId, _From, _Timer, _Expiry, Pending) when is_map_key(Tag, Pending) ->
    'taken';
add(Tag, MsgId, From, Timer, Expiry, Pending) ->
    {'ok', Pending#{Tag => #{'msg_id' => MsgId
                            ,'returned' => 'false'
                            ,'from' => From
                            ,'timer' => Timer
                            ,'expiry' => Expiry
                            }}}.

%%------------------------------------------------------------------------------
%% @doc What one message to the publisher settles: the messages it answers,
%% oldest first, with their answers, and what is still waiting.
%%
%% Records by position, as everywhere a file the Gleam compiler builds has
%% to: `{'basic.return', Code, Text, Exchange, RoutingKey}' arrives with the
%% message as `{BasicReturn, {amqp_msg, Props, Payload}}',
%% `{'basic.ack', Tag, Multiple}', `{'basic.nack', Tag, Multiple, Requeue}'.
%% @end
%%------------------------------------------------------------------------------
-spec settle(any(), pending()) -> {[{pos_integer(), entry(), result()}], pending()}.
settle({{'basic.return', _Code, _Text, _Exchange, _RoutingKey}, AmqpMsg}, Pending) ->
    {[], returned(returned_id(AmqpMsg), Pending)};
settle({'basic.ack', Tag, Multiple}, Pending) ->
    confirm(tags(Tag, Multiple, Pending), Pending, fun acked/1);
settle({'basic.nack', Tag, Multiple, _Requeue}, Pending) ->
    confirm(tags(Tag, Multiple, Pending), Pending, fun(_Entry) -> {'error', <<"nacked">>} end);
settle({'expire', Expiry}, Pending) ->
    Expired = lists:sort([Tag || {Tag, #{'expiry' := E}} <- maps:to_list(Pending), E =:= Expiry]),
    confirm(Expired, Pending, fun(_Entry) -> {'error', <<"no_answer">>} end);
settle('lost_channel', Pending) ->
    confirm(lists:sort(maps:keys(Pending)), Pending, fun(_Entry) -> {'error', <<"no_answer">>} end);
settle(_Other, Pending) ->
    {[], Pending}.

-spec acked(entry()) -> result().
acked(#{'returned' := 'true'}) -> {'error', <<"returned">>};
acked(#{'returned' := 'false'}) -> {'ok', 'nil'}.

-spec tags(pos_integer(), boolean(), pending()) -> [pos_integer()].
tags(Tag, 'false', _Pending) -> [Tag];
tags(Tag, 'true', Pending) -> lists:sort([T || T <- maps:keys(Pending), T =< Tag]).

-spec confirm([pos_integer()], pending(), fun((entry()) -> result())) ->
          {[{pos_integer(), entry(), result()}], pending()}.
confirm(Tags, Pending, Answer) ->
    lists:foldr(fun(Tag, {Settled, Left}) ->
                        case maps:take(Tag, Left) of
                            'error' -> {Settled, Left};
                            {Entry, Left1} -> {[{Tag, Entry, Answer(Entry)} | Settled], Left1}
                        end
                end
               ,{[], Pending}
               ,Tags
               ).

%% The oldest message waiting with that id, not already returned, is the one
%% the broker returned. An id nobody is waiting with -- a message whose
%% caller gave up on it -- changes nothing.
-spec returned(binary() | 'undefined', pending()) -> pending().
returned('undefined', Pending) -> Pending;
returned(MsgId, Pending) ->
    Waiting = lists:sort([Tag || {Tag, #{'msg_id' := Id, 'returned' := 'false'}} <- maps:to_list(Pending)
                                     ,Id =:= MsgId
                         ]),
    case Waiting of
        [] -> Pending;
        [Tag | _] ->
            Entry = maps:get(Tag, Pending),
            Pending#{Tag => Entry#{'returned' => 'true'}}
    end.

-spec returned_id(any()) -> binary() | 'undefined'.
returned_id({'amqp_msg', _Props, Payload}) ->
    try json:decode(iolist_to_binary(Payload)) of
        #{<<"Msg-ID">> := MsgId} when is_binary(MsgId) -> MsgId;
        _Otherwise -> 'undefined'
    catch
        _E:_R -> 'undefined'
    end;
returned_id(_Other) -> 'undefined'.

%%------------------------------------------------------------------------------
%% @doc The answers a run of events on the channel gives, in the order they
%% are given: `{published, Tag, MsgId, Expiry}' for a message going out
%% whose time runs out with `{expire, Expiry}' -- `{published, Tag, MsgId}'
%% when that is `{expire, Tag}' -- and otherwise what the broker and the
%% timers send. A message published on a tag already waiting is answered
%% `no_answer' there and then. For the tests.
%% @end
%%------------------------------------------------------------------------------
-spec replay(list()) -> [{pos_integer(), result()}].
replay(Script) ->
    {Answers, _Pending} =
        lists:foldl(fun({'published', Tag, MsgId}, Acc) ->
                            replay_published(Tag, MsgId, Tag, Acc);
                       ({'published', Tag, MsgId, Expiry}, Acc) ->
                            replay_published(Tag, MsgId, Expiry, Acc);
                       (Message, {Answers, Pending}) ->
                            {Settled, Pending1} = settle(Message, Pending),
                            {Answers ++ [{Tag, Result} || {Tag, _Entry, Result} <- Settled], Pending1}
                    end
                   ,{[], #{}}
                   ,Script
                   ),
    Answers.

-spec replay_published(pos_integer(), binary(), any(), {list(), pending()}) -> {list(), pending()}.
replay_published(Tag, MsgId, Expiry, {Answers, Pending}) ->
    case add(Tag, MsgId, 'none', 'none', Expiry, Pending) of
        {'ok', Pending1} -> {Answers, Pending1};
        'taken' -> {Answers ++ [{Tag, {'error', <<"no_answer">>}}], Pending}
    end.

-spec reason(any()) -> binary().
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, 'utf8');
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
