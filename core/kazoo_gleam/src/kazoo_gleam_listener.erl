%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The one `gen_listener' the Gleam applications share.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% `gen_listener' is a behaviour, and a behaviour is Erlang only, so an
%%% application that wants to consume AMQP has had to write one. This module
%%% is that listener written once and parameterised from Gleam: the bindings,
%%% the queue and its options, the consume options and the prefetch arrive as
%%% a map, and three closures say what to do with a delivery, with everything
%%% else the process is sent, and with the consumer coming and going.
%%% `kazoo/listener' is the typed builder that produces the map; the shape it
%%% produces is documented under `Spec' below, and nothing else should build
%%% one by hand.
%%%
%%% One responder is registered, for `{&lt;&lt;"*"&gt;&gt;, &lt;&lt;"*"&gt;&gt;}'. It runs in a
%%% process `gen_listener' spawns, so all it does is hand the delivery back
%%% here; the closures then run in the listener process itself. That is
%%% deliberate, and it is the convention the Gleam side has to keep to: **a
%%% closure has to be quick and hand the work to a named actor with a typed
%%% call**. Two things follow from it. A closure that blocks stops this
%%% consumer, which with a prefetch is the whole point -- the broker gives
%%% the node no more than it is working on. A closure that crashes takes the
%%% listener with it, the consumer's channel goes, and the broker requeues
%%% whatever was not acked, which is what a crash should mean.
%%%
%%% Node notifications are registered from inside this process because
%%% `kz_nodes' registers the calling process, not one it is handed.
%%%
%%% This module is compiled by the Gleam compiler along with the Gleam
%%% sources, which means no parse transform (so `lager:log/4' by hand, never
%%% `lager:debug/2') and no Kazoo header (so literal atoms, maps and
%%% proplists, never a record from an `.hrl').
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_listener).
-behaviour(gen_listener).

-export([start_link/1
        ,start_link_result/1
        ,stop/1
        ,ack/1
        ,nack/1
        ,redelivered/1
        ,pause/1
        ,resume/1
        ,consuming/1
        ,delivery_listener/1
        ,add_binding/2
        ,rm_binding/2
        ,queue_name/1
        ,notify_new/1
        ,notify_expire/1
        ,notify_heartbeat/1
        ,as_term/1
        ]).

%% The one responder.
-export([on_message/2]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

%% The spec `kazoo/listener' builds. Every key is optional; the defaults are
%% the ones a listener with nothing said about it should have: a queue the
%% broker names, deleted with the connection, acked on delivery.
%%
%% ```
%% #{<<"name">> => atom()                    %% a registered name
%%  ,<<"bindings">> => [#{<<"binding">> := binary()
%%                       ,<<"props">> => [#{<<"key">> := binary()
%%                                         ,<<"value">> := term_spec()
%%                                         }]
%%                       }]
%%  ,<<"queue">> => #{<<"name">> => binary()          %% <<>>: the broker names it
%%                   ,<<"durable">> => boolean()
%%                   ,<<"exclusive">> => boolean()
%%                   ,<<"auto_delete">> => boolean()
%%                   ,<<"ttl">> => integer() | <<"infinity">>
%%                   ,<<"max_length">> => integer() | <<"infinity">>
%%                   }
%%  ,<<"consume">> => #{<<"manual_ack">> => boolean()
%%                     ,<<"exclusive">> => boolean()
%%                     }
%%  ,<<"prefetch">> => integer()             %% 0: leave it to the broker
%%  ,<<"on_event">> => fun((map(), delivery()) -> any())
%%  ,<<"on_info">> => fun((any()) -> any())
%%  ,<<"on_consuming">> => fun((boolean()) -> any())
%%  ,<<"notify">> => [<<"new">> | <<"expire">> | <<"heartbeat">>]
%%  }
%% '''
%%
%% A `term_spec()' is `#{<<"kind">> := <<"text">> | <<"atom">> | <<"int">>
%% | <<"bool">> | <<"list">>, <<"value">> := any()}', which is how a
%% binding property says whether it wants `&lt;&lt;"member_call"&gt;&gt;' or
%% `'member_call''.
-type spec() :: map().

%% What a closure is handed to settle a delivery with. Opaque to Gleam: it
%% carries the listener and the `#'basic.deliver'{}' the broker sent.
-type delivery() :: {'kazoo_gleam_delivery', pid(), any()}.

-record(state, {on_event :: fun((map(), delivery()) -> any()) | 'undefined'
               ,on_info :: fun((any()) -> any()) | 'undefined'
               ,on_consuming :: fun((boolean()) -> any()) | 'undefined'
               ,manual_ack = 'false' :: boolean()
               }).
-type state() :: #state{}.

-export_type([spec/0
             ,delivery/0
             ]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Start a listener from the spec above.
%% @end
%%------------------------------------------------------------------------------
-spec start_link(spec()) -> {'ok', pid()} | {'error', any()} | 'ignore'.
start_link(Spec) ->
    case maps:get(<<"name">>, Spec, 'undefined') of
        'undefined' -> gen_listener:start_link(?MODULE, start_params(Spec), [Spec]);
        Name when is_atom(Name) ->
            gen_listener:start_link({'local', Name}, ?MODULE, start_params(Spec), [Spec])
    end.

%%------------------------------------------------------------------------------
%% @doc The same, in the shape Gleam supervises: a `Result' rather than an
%% OTP `startlink_ret()'.
%%
%% A node with no release around it has no `gen_listener' to start, which is
%% an error and not a crash: `gleam test' and `gleam run' reach this.
%% @end
%%------------------------------------------------------------------------------
-spec start_link_result(spec()) -> {'ok', pid()} | {'error', binary()}.
start_link_result(Spec) ->
    case code:ensure_loaded('gen_listener') of
        {'error', _Reason} -> {'error', <<"unavailable">>};
        {'module', 'gen_listener'} -> start_link_result(Spec, 'started')
    end.

-spec start_link_result(spec(), 'started') -> {'ok', pid()} | {'error', binary()}.
start_link_result(Spec, 'started') ->
    try start_link(Spec) of
        {'ok', Pid} -> {'ok', Pid};
        {'error', {'already_started', Pid}} -> {'ok', Pid};
        {'error', Reason} -> {'error', reason(Reason)};
        'ignore' -> {'error', <<"ignore">>}
    catch
        _E:R -> {'error', reason(R)}
    end.

%%------------------------------------------------------------------------------
%% @doc Stop a listener. The consumer's channel goes with it, so anything it
%% was holding unacked goes back on the queue.
%% @end
%%------------------------------------------------------------------------------
-spec stop(pid()) -> 'nil'.
stop(Srv) ->
    _ = catch gen_listener:stop(Srv),
    'nil'.

%%------------------------------------------------------------------------------
%% @doc Settle a delivery. Only means anything with `manual_ack'; with the
%% default consume options the broker considered it acked when it sent it.
%% @end
%%------------------------------------------------------------------------------
-spec ack(delivery()) -> 'nil'.
ack({'kazoo_gleam_delivery', Srv, Deliver}) ->
    _ = catch gen_listener:ack(Srv, Deliver),
    'nil'.

%%------------------------------------------------------------------------------
%% @doc Refuse a delivery and put it back on the queue for whoever is next.
%%
%% The requeue flag is given by hand: `kz_amqp_util:basic_nack/1' answers a
%% `#'basic.deliver'{}' with a `basic.ack', so the two-argument
%% `gen_listener:nack/2' settles the delivery instead of refusing it. Only
%% `nack/3' actually says no.
%% @end
%%------------------------------------------------------------------------------
-spec nack(delivery()) -> 'nil'.
nack({'kazoo_gleam_delivery', Srv, Deliver}) ->
    _ = catch gen_listener:nack(Srv, Deliver, 'true'),
    'nil'.

%%------------------------------------------------------------------------------
%% @doc Whether the broker has handed this message out before.
%%
%% Read by position out of the `#'basic.deliver'{}' the delivery carries --
%% `{'basic.deliver', ConsumerTag, DeliveryTag, Redelivered, Exchange,
%% RoutingKey}' -- because a file the Gleam compiler builds has no include
%% path and so cannot name the record. Anything else is a first delivery:
%% that covers a delivery built by hand and a shape a later client library
%% might give, and erring that way is a consumer doing its work rather than
%% one assuming somebody else already has.
%% @end
%%------------------------------------------------------------------------------
-spec redelivered(delivery()) -> boolean().
redelivered({'kazoo_gleam_delivery', _Srv, Deliver})
  when is_tuple(Deliver)
       andalso tuple_size(Deliver) >= 4
       andalso element(1, Deliver) =:= 'basic.deliver' ->
    element(4, Deliver) =:= 'true';
redelivered(_Delivery) -> 'false'.

%%------------------------------------------------------------------------------
%% @doc Stop consuming: a `basic.cancel' on every consumer tag the listener
%% holds, leaving its channel and everything unsettled on it alone.
%%
%% A requeued message may be handed straight back to the consumer that
%% refused it -- LavinMQ does exactly that -- so a consumer that wants
%% somebody else to have the message has to be off the queue before it
%% refuses it. Cancelling and refusing are both casts to the listener, so
%% they reach the channel in the order they were sent.
%%
%% `gen_listener' answers `pause_consumers' and `resume_consumers' but
%% exports no function for either, so they are cast by hand. A cast to a
%% listener that is not consuming, or is already, is ignored there.
%% @end
%%------------------------------------------------------------------------------
-spec pause(pid()) -> 'nil'.
pause(Srv) ->
    _ = catch gen_server:cast(Srv, {'pause_consumers'}),
    'nil'.

%%------------------------------------------------------------------------------
%% @doc Consume again, on the queue the listener already has.
%% @end
%%------------------------------------------------------------------------------
-spec resume(pid()) -> 'nil'.
resume(Srv) ->
    _ = catch gen_server:cast(Srv, {'resume_consumers'}),
    'nil'.

%%------------------------------------------------------------------------------
%% @doc Whether the listener has a consumer on its queue right now.
%%
%% A listener that is away or gone is not consuming, which is the answer a
%% caller wants rather than an exit.
%% @end
%%------------------------------------------------------------------------------
-spec consuming(pid()) -> boolean().
consuming(Srv) ->
    try gen_listener:is_consuming(Srv) of
        'true' -> 'true';
        _Not -> 'false'
    catch
        _E:_R -> 'false'
    end.

%%------------------------------------------------------------------------------
%% @doc The listener a delivery came from, so that a closure handed nothing
%% but the delivery can still work on its own consumer.
%% @end
%%------------------------------------------------------------------------------
-spec delivery_listener(delivery()) -> pid().
delivery_listener({'kazoo_gleam_delivery', Srv, _Deliver}) -> Srv.

%%------------------------------------------------------------------------------
%% @doc Bind the listener's queue to one more thing, after it started.
%% @end
%%------------------------------------------------------------------------------
-spec add_binding(pid(), map()) -> 'nil'.
add_binding(Srv, Binding) ->
    {Name, Props} = binding(Binding),
    _ = catch gen_listener:add_binding(Srv, Name, Props),
    'nil'.

%%------------------------------------------------------------------------------
%% @doc Take one binding away again.
%% @end
%%------------------------------------------------------------------------------
-spec rm_binding(pid(), map()) -> 'nil'.
rm_binding(Srv, Binding) ->
    {Name, Props} = binding(Binding),
    _ = catch gen_listener:rm_binding(Srv, Name, Props),
    'nil'.

%%------------------------------------------------------------------------------
%% @doc The queue the listener is consuming, empty until the broker has named
%% one.
%% @end
%%------------------------------------------------------------------------------
-spec queue_name(pid()) -> binary().
queue_name(Srv) ->
    try gen_listener:queue_name(Srv) of
        Queue when is_binary(Queue) -> Queue;
        _Undefined -> <<>>
    catch
        _E:_R -> <<>>
    end.

%%------------------------------------------------------------------------------
%% @doc Ask for the `kz_nodes' notifications after the listener has started.
%%
%% `kz_nodes' registers the calling process, so this is a cast the listener
%% answers by registering itself; the notifications then arrive at the info
%% closure.
%% @end
%%------------------------------------------------------------------------------
-spec notify_new(pid()) -> 'nil'.
notify_new(Srv) -> notify(Srv, <<"new">>).

-spec notify_expire(pid()) -> 'nil'.
notify_expire(Srv) -> notify(Srv, <<"expire">>).

-spec notify_heartbeat(pid()) -> 'nil'.
notify_heartbeat(Srv) -> notify(Srv, <<"heartbeat">>).

-spec notify(pid(), binary()) -> 'nil'.
notify(Srv, What) ->
    _ = catch gen_listener:cast(Srv, {'kazoo_gleam_notify', What}),
    'nil'.

%%------------------------------------------------------------------------------
%% @doc The one place a Gleam value becomes an opaque term for the spec map.
%%
%% The spec is one map with values of every kind, closures included, and a
%% Gleam `Dict' is a map of `Dynamic'. This is the identity function that
%% gets a closure, or a registered name, in there; `kazoo/listener' is typed
%% on both sides of it.
%% @end
%%------------------------------------------------------------------------------
-spec as_term(any()) -> any().
as_term(Term) -> Term.

%%------------------------------------------------------------------------------
%% @doc The responder, for every event on the queue.
%%
%% It runs in a process of its own, so all it does is hand the delivery back
%% to the listener; see the module comment.
%% @end
%%------------------------------------------------------------------------------
-spec on_message(any(), list()) -> 'ok'.
on_message(JObj, Props) ->
    gen_listener:cast(props:get_value('server', Props)
                     ,{'kazoo_gleam_event', JObj, props:get_value('deliver', Props)}
                     ).

%%%=============================================================================
%%% gen_listener callbacks
%%%=============================================================================

-spec init([spec()]) -> {'ok', state()}.
init([Spec]) ->
    _ = [register_notify(What) || What <- maps:get(<<"notify">>, Spec, [])],
    _ = maybe_requisition(maps:get(<<"bindings">>, Spec, [])),
    {'ok', #state{on_event = maps:get(<<"on_event">>, Spec, 'undefined')
                 ,on_info = maps:get(<<"on_info">>, Spec, 'undefined')
                 ,on_consuming = maps:get(<<"on_consuming">>, Spec, 'undefined')
                 ,manual_ack = maps:get(<<"manual_ack">>
                                       ,maps:get(<<"consume">>, Spec, #{})
                                       ,'false'
                                       )
                 }
    }.

-spec handle_call(any(), any(), state()) -> {'reply', {'error', 'not_implemented'}, state()}.
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

-spec handle_cast(any(), state()) -> {'noreply', state()}.
handle_cast({'kazoo_gleam_event', _JObj, Deliver}, #state{on_event = 'undefined'} = State) ->
    %% A listener with bindings and no event closure: nothing is going to
    %% settle this, so settle it here rather than hold a prefetch for good.
    %% Only when the delivery is ours to settle -- acking one the broker
    %% already considers acked closes the channel.
    _ = settle(Deliver, State),
    log('warning', "a delivery was discarded: this listener has no event closure", []),
    {'noreply', State};
handle_cast({'kazoo_gleam_event', JObj, Deliver}, #state{on_event = OnEvent} = State) ->
    _ = OnEvent(kz_json:to_map(JObj), {'kazoo_gleam_delivery', self(), Deliver}),
    {'noreply', State};
handle_cast({'kazoo_gleam_notify', What}, State) ->
    _ = register_notify(What),
    {'noreply', State};
handle_cast({'gen_listener', {'is_consuming', IsConsuming}}, State) ->
    _ = consuming(IsConsuming, State),
    _ = info(#{<<"kind">> => <<"consuming">>, <<"value">> => IsConsuming}, State),
    {'noreply', State};
handle_cast({'gen_listener', {'created_queue', Queue}}, State) ->
    _ = info(#{<<"kind">> => <<"queue_created">>, <<"queue">> => Queue}, State),
    {'noreply', State};
handle_cast({'gen_listener', {'federators_consuming', IsConsuming}}, State) ->
    _ = info(#{<<"kind">> => <<"federators_consuming">>, <<"value">> => IsConsuming}, State),
    {'noreply', State};
handle_cast({'kz_nodes', {Event, Node}}, State) ->
    _ = info(#{<<"kind">> => node_kind(Event), <<"node">> => node_map(Node)}, State),
    {'noreply', State};
handle_cast(Msg, State) ->
    _ = info(Msg, State),
    {'noreply', State}.

-spec handle_info(any(), state()) -> {'noreply', state()}.
handle_info({'basic.cancel', ConsumerTag, _NoWait}, State) ->
    %% The broker cancelled the consumer: its queue was deleted, or the
    %% broker lost it. `gen_listener' has no clause for a server-sent
    %% `basic.cancel', so it reaches the callback module here, and
    %% `gen_listener' goes on believing it consumes. It does not: nothing
    %% more will be delivered, and it will not consume again on its own.
    %% So the closures hear what they hear when the channel goes, and a
    %% listener that ends on losing its consumer ends on this too.
    log('warning', "the broker cancelled consumer ~s", [ConsumerTag]),
    _ = consuming('false', State),
    _ = info(#{<<"kind">> => <<"consuming">>, <<"value">> => 'false'}, State),
    {'noreply', State};
handle_info(Info, State) ->
    _ = info(Info, State),
    {'noreply', State}.

-spec handle_event(any(), state()) -> {'reply', []}.
handle_event(_JObj, _State) ->
    {'reply', []}.

-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    log('debug', "listener terminated: ~p", [_Reason]).

-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%=============================================================================
%%% The closures
%%%=============================================================================

-spec settle(any(), state()) -> any().
settle(_Deliver, #state{manual_ack = 'false'}) -> 'ok';
settle(Deliver, #state{manual_ack = 'true'}) -> catch gen_listener:ack(self(), Deliver).

-spec info(any(), state()) -> any().
info(_Term, #state{on_info = 'undefined'}) -> 'ok';
info(Term, #state{on_info = OnInfo}) -> OnInfo(Term).

-spec consuming(boolean(), state()) -> any().
consuming(_IsConsuming, #state{on_consuming = 'undefined'}) -> 'ok';
consuming(IsConsuming, #state{on_consuming = OnConsuming}) -> OnConsuming(IsConsuming).

%%%=============================================================================
%%% The channel
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Ask for an AMQP channel when nothing else is going to.
%%
%% `gen_listener' requisitions a channel while it adds a binding, and only
%% there, so a listener with a queue and no bindings at all never gets one:
%% it starts, it registers its responder, and it sits there for ever without
%% declaring its queue or consuming from it.
%%
%% A queue with no bindings is not a mistake. It is a plain work queue, fed
%% through the default exchange under its own name -- which is what
%% `kazoo/amqp.publish_to_queue' does -- and consumed by whoever is up. So
%% this asks for the channel in that one case, from inside the listener's own
%% process, which is the process `kz_amqp_assignments' assigns to. With
%% bindings, `gen_listener' has already asked and asking twice is not wanted.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_requisition(list()) -> 'ok'.
maybe_requisition([_Binding | _]) -> 'ok';
maybe_requisition([]) ->
    case code:ensure_loaded('kz_amqp_channel') of
        {'error', _Reason} -> 'ok';
        {'module', 'kz_amqp_channel'} -> kz_amqp_channel:requisition()
    end.

%%%=============================================================================
%%% kz_nodes
%%%=============================================================================

-spec register_notify(binary()) -> 'ok'.
register_notify(What) ->
    case code:ensure_loaded('kz_nodes') of
        {'error', _Reason} -> 'ok';
        {'module', 'kz_nodes'} -> register_loaded_notify(What)
    end.

-spec register_loaded_notify(binary()) -> 'ok'.
register_loaded_notify(<<"new">>) -> kz_nodes:notify_new();
register_loaded_notify(<<"expire">>) -> kz_nodes:notify_expire();
register_loaded_notify(<<"heartbeat">>) -> kz_nodes:notify_heartbeat();
register_loaded_notify(_What) -> 'ok'.

-spec node_kind(atom()) -> binary().
node_kind('new') -> <<"node_new">>;
node_kind('expire') -> <<"node_expire">>;
node_kind('heartbeat') -> <<"node_heartbeat">>;
node_kind(Other) -> iolist_to_binary([<<"node_">>, atom_to_binary(Other, 'utf8')]).

%% A `#kz_node{}' as a map. The record is in `kz_records.hrl', which cannot be
%% included here, and `kz_node:to_json/1' is the projection of it Kazoo itself
%% shows an operator: the node, its zone, the names of its applications and of
%% its media servers, its version and its counts.
-spec node_map(any()) -> map().
node_map(Node) ->
    try kz_json:to_map(kz_node:to_json(Node))
    catch _E:_R -> #{}
    end.

%%%=============================================================================
%%% The spec
%%%=============================================================================

-spec start_params(spec()) -> list().
start_params(Spec) ->
    Queue = maps:get(<<"queue">>, Spec, #{}),
    [{'bindings', [binding(Binding) || Binding <- maps:get(<<"bindings">>, Spec, [])]}
    ,{'responders', [{{?MODULE, 'on_message'}, [{<<"*">>, <<"*">>}]}]}
    ,{'queue_name', maps:get(<<"name">>, Queue, <<>>)}
    ,{'queue_options', queue_options(Queue)}
    ,{'consume_options', consume_options(maps:get(<<"consume">>, Spec, #{}))}
     | basic_qos(maps:get(<<"prefetch">>, Spec, 0))
    ].

%% `kz_amqp_util:new_queue/2' gives every queue an `x-message-ttl' of a
%% minute and an `x-max-length' of a hundred unless it is told otherwise, so
%% a queue that has to hold work says `infinity' for both.
-spec queue_options(map()) -> list().
queue_options(Queue) ->
    [{'durable', maps:get(<<"durable">>, Queue, 'false')}
    ,{'exclusive', maps:get(<<"exclusive">>, Queue, 'false')}
    ,{'auto_delete', maps:get(<<"auto_delete">>, Queue, 'true')}
    ,{'arguments', [{<<"x-message-ttl">>, limit(maps:get(<<"ttl">>, Queue, 'undefined'))}
                   ,{<<"x-max-length">>, limit(maps:get(<<"max_length">>, Queue, 'undefined'))}
                   ]}
    ].

-spec limit(any()) -> any().
limit(<<"infinity">>) -> 'infinity';
limit(Limit) -> Limit.

%% `no_ack' is the switch that matters: `kz_amqp_util:basic_consume/2'
%% defaults it to `true', and the `auto_ack' start parameter is a different
%% thing -- it makes `gen_listener' ack the moment a delivery arrives, which
%% is not what a handler that can fail wants.
-spec consume_options(map()) -> list().
consume_options(Consume) ->
    [{'exclusive', maps:get(<<"exclusive">>, Consume, 'false')}
    ,{'no_ack', not maps:get(<<"manual_ack">>, Consume, 'false')}
    ].

-spec basic_qos(integer()) -> list().
basic_qos(0) -> [];
basic_qos(Prefetch) -> [{'basic_qos', Prefetch}].

%% A binding as `gen_listener' wants it. The name stays a binary --
%% `gen_listener' turns it into `kapi_&lt;name&gt;' itself -- and the property
%% keys become atoms, because that is what a `kapi' module reads them with.
-spec binding(map()) -> {binary(), list()}.
binding(Binding) ->
    {maps:get(<<"binding">>, Binding)
    ,[{binary_to_atom(maps:get(<<"key">>, Prop), 'utf8'), term(maps:get(<<"value">>, Prop))}
      || Prop <- maps:get(<<"props">>, Binding, [])
     ]
    }.

-spec term(map()) -> any().
term(#{<<"kind">> := <<"text">>, <<"value">> := Value}) -> Value;
term(#{<<"kind">> := <<"atom">>, <<"value">> := Value}) -> binary_to_atom(Value, 'utf8');
term(#{<<"kind">> := <<"int">>, <<"value">> := Value}) -> Value;
term(#{<<"kind">> := <<"bool">>, <<"value">> := Value}) -> Value;
term(#{<<"kind">> := <<"list">>, <<"value">> := Value}) -> [term(Element) || Element <- Value].

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

-spec reason(any()) -> binary().
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, 'utf8');
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

%% Kazoo reaches lager through the `lager_transform' parse transform, and the
%% Gleam compiler has no way to apply a parse transform to the `.erl' files it
%% compiles beside the Gleam ones. `lager:log/4' is lager's own documented way
%% in without it.
%% Caught, because a node with no release around it -- `gleam test' -- has
%% no lager, and a log line is never a reason for a listener to end.
-spec log(atom(), string(), list()) -> any().
log(Level, Format, Args) ->
    try lager:log(Level, self(), Format, Args)
    catch _E:_R -> 'ok'
    end.
