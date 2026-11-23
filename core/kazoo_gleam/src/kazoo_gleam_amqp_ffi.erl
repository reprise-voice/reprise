%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc What Gleam publishes, and what it asks the cluster.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% Every message on the bus belongs to a `kapi' module: it says what the
%%% fields are, validates them and knows the routing key. Those modules are
%%% declarative and stay in Erlang by design, so this does not replace them --
%%% it calls one by name. `publish("call", "channel_status_req", Payload)'
%%% reaches `kapi_call:publish_channel_status_req/1', and nothing here knows
%%% anything about calls.
%%%
%%% The payload arrives as JSON text, as everything crossing this boundary
%%% does, and becomes a `kz_json' object with `kz_json:from_map/1'; responses
%%% go back the other way with `kz_json:to_map/1'.
%%%
%%% Publishing goes through `kz_amqp_worker' rather than the calling
%%% process's own channel: a Gleam actor is not a `gen_listener' and has no
%%% channel of its own.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_amqp_ffi).

-export([publish/3
        ,publish_to/4
        ,publish_to_confirmed/5
        ,start_confirming_publisher/0
        ,confirmations/1
        ,confirmed/2
        ,publish_to_queue/2
        ,call/4
        ,call_collect/6
        ,default_headers/3
        ]).

%%------------------------------------------------------------------------------
%% @doc Publish `kapi_&lt;Module&gt;:publish_&lt;Function&gt;/1' and do not wait.
%% @end
%%------------------------------------------------------------------------------
-spec publish(binary(), binary(), binary()) -> {'ok', 'nil'} | {'error', binary()}.
publish(Module, Function, Json) ->
    case publisher(Module, Function) of
        {'error', _Reason} = Error -> Error;
        {'ok', PublishFun} ->
            try kz_amqp_worker:cast(payload(Json), PublishFun) of
                'ok' -> {'ok', 'nil'};
                {'error', Reason} -> {'error', reason(Reason)}
            catch
                _E:R -> {'error', reason(R)}
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Publish `kapi_&lt;Module&gt;:publish_&lt;Function&gt;/2' at one queue.
%%
%% Every answer on the bus is published this way: the request carried a
%% `Server-ID', and that is the queue the answer goes to.
%% @end
%%------------------------------------------------------------------------------
-spec publish_to(binary(), binary(), binary(), binary()) -> {'ok', 'nil'} | {'error', binary()}.
publish_to(Target, Module, Function, Json) ->
    case publisher(Module, Function, 2) of
        {'error', _Reason} = Error -> Error;
        {'ok', PublishFun} ->
            Targeted = fun(Payload) -> PublishFun(Target, Payload) end,
            try kz_amqp_worker:cast(payload(Json), Targeted) of
                'ok' -> {'ok', 'nil'};
                {'error', Reason} -> {'error', reason(Reason)}
            catch
                _E:R -> {'error', reason(R)}
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Publish `kapi_&lt;Module&gt;:publish_&lt;Function&gt;/2' at one queue, and wait
%% for the broker to take it.
%%
%% `kz_amqp_worker' publishes on a pooled channel, which is not in confirm
%% mode unless the whole pool is, and it drops a `basic.return' nobody is
%% waiting on; a message published there and routed nowhere is simply gone.
%% So this publishes from a process of its own, on a channel of its own:
%% `kz_amqp_assignments' registers the process as the channel's return and
%% confirm handler, the channel is put in confirm mode, and the process
%% waits for the broker's `basic.ack'. A `mandatory' message -- which the
%% `kapi' function says, as `publish_member_call/2' does -- that could not be
%% routed comes back as a `basic.return' first, and the answer is
%% `returned'. A `basic.nack' is `nacked'. No confirmation within `Timeout'
%% is `no_answer': the message went out and may well be on the queue. The
%% channel is closed with the process.
%%
%% Nothing here is `kazoo_amqp''s own: the channel, its handlers, confirm
%% mode and `mandatory' are all things it already does, asked for from a
%% process that is there to hear the answer.
%%
%% That process is the node's `kazoo_gleam_confirming_publisher' when one is
%% running with its channel in confirm mode, and the `kapi' module builds the
%% message without sending it with `prepare_&lt;Function&gt;/2', as
%% `kapi_callcenter:prepare_member_call/2' does: one channel for every
%% confirmed message rather than one each. Without one, or before its
%% channel is ready, or for a `kapi' function with no `prepare_', the
%% message goes out from a process and a channel of its own, as described
%% above.
%% @end
%%------------------------------------------------------------------------------
-spec publish_to_confirmed(binary(), binary(), binary(), binary(), pos_integer()) ->
          {'ok', 'nil'} | {'error', binary()}.
publish_to_confirmed(Target, Module, Function, Json, Timeout) ->
    case publisher(Module, Function, 2) of
        {'error', _Reason} = Error -> Error;
        {'ok', PublishFun} ->
            Payload = payload(Json),
            case on_confirming_publisher(Target, Module, Function, Payload, Timeout) of
                {'error', 'not_ready'} ->
                    in_own_process(fun() -> PublishFun(Target, Payload) end, Timeout);
                Result -> Result
            end
    end.

-spec on_confirming_publisher(binary(), binary(), binary(), any(), pos_integer()) ->
          {'ok', 'nil'} | {'error', binary() | 'not_ready'}.
on_confirming_publisher(Target, Module, Function, Payload, Timeout) ->
    case kapi_publisher(<<"kapi_", Module/binary>>, <<"prepare_", Function/binary>>, 2) of
        {'ok', PrepareFun} ->
            kazoo_gleam_confirming_publisher:publish(PrepareFun, Target, Payload, Timeout);
        {'error', _Reason} -> {'error', 'not_ready'}
    end.

%% @doc The node's confirming publisher, for a supervisor: `{ok, Pid}' as a
%% Gleam `Result'.
-spec start_confirming_publisher() -> {'ok', pid()} | {'error', binary()}.
start_confirming_publisher() ->
    case kazoo_gleam_confirming_publisher:start_link() of
        {'ok', Pid} -> {'ok', Pid};
        {'error', Reason} -> {'error', reason(Reason)}
    end.

%% @doc What the confirming publisher answers over a run of events. For the
%% tests; see `kazoo_gleam_confirming_publisher:replay/1'.
-spec confirmations(list()) -> [{pos_integer(), {'ok', 'nil'} | {'error', binary()}}].
confirmations(Script) ->
    kazoo_gleam_confirming_publisher:replay(Script).

-spec in_own_process(fun(() -> any()), pos_integer()) -> {'ok', 'nil'} | {'error', binary()}.
in_own_process(Publish, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} =
        spawn_monitor(fun() ->
                              Parent ! {Ref, publish_confirmed(Publish, Timeout)},
                              %% `shutdown', so that the channel assignment
                              %% is released without a word in the log.
                              exit('shutdown')
                      end),
    receive
        {Ref, Result} ->
            erlang:demonitor(Monitor, ['flush']),
            Result;
        {'DOWN', Monitor, 'process', Pid, Reason} ->
            {'error', reason(Reason)}
    after 2 * Timeout + 1000 ->
            erlang:demonitor(Monitor, ['flush']),
            exit(Pid, 'kill'),
            {'error', <<"no_answer">>}
    end.

-spec publish_confirmed(fun(() -> any()), pos_integer()) -> {'ok', 'nil'} | {'error', binary()}.
publish_confirmed(Publish, Timeout) ->
    case own_channel(Timeout) of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            _ = try kz_amqp_channel:command({'confirm.select', 'false'})
                catch _:_ -> 'ok'
                end,
            receive
                {'$server_confirms', 'true'} -> publish_and_wait(Publish, Timeout)
            after 0 ->
                    %% The channel would not go into confirm mode. The message
                    %% goes out as it would have through the pool, and nothing
                    %% is waited for: there is nothing to wait for.
                    try Publish() of
                        _ -> {'ok', 'nil'}
                    catch
                        _E:R -> {'error', reason(R)}
                    end
            end
    end.

-spec publish_and_wait(fun(() -> any()), pos_integer()) -> {'ok', 'nil'} | {'error', binary()}.
publish_and_wait(Publish, Timeout) ->
    try Publish() of
        _ -> await_confirm('false', erlang:monotonic_time('millisecond') + Timeout)
    catch
        _E:R -> {'error', reason(R)}
    end.

-spec await_confirm(boolean(), integer()) -> {'ok', 'nil'} | {'error', binary()}.
await_confirm(Returned, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time('millisecond')),
    receive
        Message ->
            case confirmation(Returned, Message) of
                {'continue', StillReturned} -> await_confirm(StillReturned, Deadline);
                {'done', Result} -> Result
            end
    after Left -> {'error', <<"no_answer">>}
    end.

%%------------------------------------------------------------------------------
%% @doc What the broker's messages to a confirming publisher come to, in the
%% order they arrived: `{ok, nil}' for an ack, `returned' for an ack after a
%% `basic.return', `nacked' for a nack, and `no_answer' when the list ends
%% before any of them. The wait above reads the mailbox the same way, one
%% message at a time; this is it over a list, for the tests.
%%
%% Records by position, as everywhere a file the Gleam compiler builds has
%% to: `{'basic.return', Code, Text, Exchange, RoutingKey}' arrives with the
%% message as `{BasicReturn, AmqpMsg}', `{'basic.ack', Tag, Multiple}',
%% `{'basic.nack', Tag, Multiple, Requeue}'.
%% @end
%%------------------------------------------------------------------------------
-spec confirmed(boolean(), list()) -> {'ok', 'nil'} | {'error', binary()}.
confirmed(Returned, []) ->
    _ = Returned,
    {'error', <<"no_answer">>};
confirmed(Returned, [Message | Messages]) ->
    case confirmation(Returned, Message) of
        {'continue', StillReturned} -> confirmed(StillReturned, Messages);
        {'done', Result} -> Result
    end.

-spec confirmation(boolean(), any()) ->
          {'continue', boolean()} | {'done', {'ok', 'nil'} | {'error', binary()}}.
confirmation(_Returned, {{'basic.return', _Code, _Text, _Exchange, _RoutingKey}, _Msg}) ->
    {'continue', 'true'};
confirmation('true', {'basic.ack', _Tag, _Multiple}) ->
    {'done', {'error', <<"returned">>}};
confirmation('false', {'basic.ack', _Tag, _Multiple}) ->
    {'done', {'ok', 'nil'}};
confirmation(_Returned, {'basic.nack', _Tag, _Multiple, _Requeue}) ->
    {'done', {'error', <<"nacked">>}};
confirmation(Returned, _Other) ->
    {'continue', Returned}.

%% A channel of this process's own, without waiting for one for ever.
-spec own_channel(pos_integer()) -> boolean().
own_channel(Timeout) ->
    case code:ensure_loaded('kz_amqp_assignments') of
        {'error', _Reason} -> 'false';
        {'module', 'kz_amqp_assignments'} ->
            try kz_amqp_assignments:get_channel(Timeout) of
                {'error', _Reason} -> 'false';
                _Assignment -> 'true'
            catch
                _E:_R -> 'false'
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Publish one message straight at a queue, through the default
%% exchange, and do not wait.
%%
%% A queue is bound to the default exchange under its own name, so this is
%% how a plain work queue is fed: no exchange, no binding, no `kapi' module
%% and no routing key but the queue's name. It is what a listener with a
%% queue and no bindings consumes.
%%
%% Persistent (`delivery_mode' 2), because the queue this feeds is durable
%% and the work on it is meant to survive the broker; the pair is what makes
%% a message outlast a restart.
%%
%% The JSON goes out exactly as it was given rather than through
%% `kz_amqp_worker''s proplist round trip: nothing here validates it, so
%% nothing here should reshape it either.
%% @end
%%------------------------------------------------------------------------------
-spec publish_to_queue(binary(), binary()) -> {'ok', 'nil'} | {'error', binary()}.
publish_to_queue(Queue, Json) ->
    case worker_loaded() of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            Publish = fun(_Prop) ->
                              kz_amqp_util:basic_publish(<<>>
                                                        ,Queue
                                                        ,Json
                                                        ,<<"application/json">>
                                                        ,[{'delivery_mode', 2}]
                                                        )
                      end,
            try kz_amqp_worker:cast([], Publish) of
                'ok' -> {'ok', 'nil'};
                {'error', Reason} -> {'error', reason(Reason)}
            catch
                _E:R -> {'error', reason(R)}
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Publish the same way and wait for one answer.
%%
%% Every answer is taken, which is what a request with one answer wants; a
%% request many nodes answer is a `call_collect/6'.
%% @end
%%------------------------------------------------------------------------------
-spec call(binary(), binary(), binary(), integer()) -> {'ok', map()} | {'error', binary()}.
call(Module, Function, Json, Timeout) ->
    case publisher(Module, Function) of
        {'error', _Reason} = Error -> Error;
        {'ok', PublishFun} ->
            try kz_amqp_worker:call(payload(Json)
                                   ,PublishFun
                                   ,fun kz_term:always_true/1
                                   ,Timeout
                                   )
            of
                {'ok', JObj} -> {'ok', kz_json:to_map(JObj)};
                {'timeout', _Partial} -> {'error', <<"no_answer">>};
                {'returned', _JObj, _Basic} -> {'error', <<"returned">>};
                {'error', Reason} -> {'error', reason(Reason)}
            catch
                _E:R -> {'error', reason(R)}
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Publish the same way and collect the answers.
%%
%% `Kind' is how the collection ends: `&lt;&lt;"whapp"&gt;&gt;' when every node running
%% `Whapp' has answered (federated zones included), `&lt;&lt;"count"&gt;&gt;' when
%% `Count' answers are in, `&lt;&lt;"deadline"&gt;&gt;' when the timeout is up.
%%
%% The answer says which of the two happened: `{'true', Answers}' is a
%% collection that finished, `{'false', Answers}' one the timeout ended, with
%% whatever had arrived. `kz_amqp_worker' keeps them apart and so does this;
%% what a collection the timeout ended with nothing in it means is decided in
%% Gleam, where it can be tested.
%% @end
%%------------------------------------------------------------------------------
-spec call_collect(binary(), binary(), binary(), binary(), binary(), integer()) ->
          {'ok', {boolean(), [map()]}} | {'error', binary()}.
call_collect(Module, Function, Json, Kind, Whapp, Timeout) ->
    case publisher(Module, Function) of
        {'error', _Reason} = Error -> Error;
        {'ok', PublishFun} ->
            try kz_amqp_worker:call_collect(payload(Json)
                                           ,PublishFun
                                           ,until(Kind, Whapp)
                                           ,Timeout
                                           )
            of
                {'ok', JObjs} -> {'ok', {'true', [kz_json:to_map(JObj) || JObj <- JObjs]}};
                {'timeout', JObjs} -> {'ok', {'false', [kz_json:to_map(JObj) || JObj <- JObjs]}};
                {'error', Reason} -> {'error', reason(Reason)}
            catch
                _E:R -> {'error', reason(R)}
            end
    end.

%% `Count' arrives as the whapp field because that is the only argument a
%% collection takes; it is a decimal string there and an integer here.
-spec until(binary(), binary()) -> any().
until(<<"whapp">>, Whapp) -> {Whapp, 'true'};
until(<<"count">>, Count) ->
    Wanted = binary_to_integer(Count),
    fun(Responses) -> length(Responses) >= Wanted end;
until(<<"deadline">>, _Whapp) -> kz_amqp_worker:collect_until_timeout().

%%------------------------------------------------------------------------------
%% @doc The headers every message on the bus carries: who sent it, which
%% version, from which node, and what the message is.
%%
%% `Server-ID' and `Msg-ID' are not here: `kz_amqp_worker' sets them to its
%% own queue and a fresh id for a request it is going to wait on, and a
%% publish that is not waiting for anything has no use for them.
%% @end
%%------------------------------------------------------------------------------
-spec default_headers(binary(), binary(), binary()) -> map().
default_headers(App, Category, Name) ->
    case code:ensure_loaded('kz_api') of
        {'error', _Reason} -> #{};
        {'module', 'kz_api'} ->
            try maps:from_list(kz_api:default_headers(Category
                                                     ,Name
                                                     ,App
                                                     ,kazoo_gleam_ffi:app_version(App)
                                                     )
                              )
            catch _E:_R -> #{}
            end
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% @doc `fun kapi_&lt;Module&gt;:publish_&lt;Function&gt;/1', when there is one.
-spec publisher(binary(), binary()) -> {'ok', fun()} | {'error', binary()}.
publisher(Module, Function) -> publisher(Module, Function, 1).

-spec publisher(binary(), binary(), 1 | 2) -> {'ok', fun()} | {'error', binary()}.
publisher(Module, Function, Arity) ->
    case worker_loaded() of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            kapi_publisher(<<"kapi_", Module/binary>>
                          ,<<"publish_", Function/binary>>
                          ,Arity
                          )
    end.

-spec kapi_publisher(binary(), binary(), 1 | 2) -> {'ok', fun()} | {'error', binary()}.
kapi_publisher(Module, Function, Arity) ->
    Kapi = binary_to_atom(Module, 'utf8'),
    case code:ensure_loaded(Kapi) of
        {'error', _Reason} -> {'error', <<"unavailable">>};
        {'module', Kapi} -> exported_publisher(Kapi, Function, Arity)
    end.

-spec exported_publisher(atom(), binary(), 1 | 2) -> {'ok', fun()} | {'error', binary()}.
exported_publisher(Kapi, Function, Arity) ->
    try binary_to_existing_atom(Function, 'utf8') of
        Publish -> exported_publisher(Kapi, Publish, Arity, erlang:function_exported(Kapi, Publish, Arity))
    catch
        _E:_R -> {'error', <<"no_such_publisher">>}
    end.

-spec exported_publisher(atom(), atom(), 1 | 2, boolean()) -> {'ok', fun()} | {'error', binary()}.
exported_publisher(_Kapi, _Publish, _Arity, 'false') -> {'error', <<"no_such_publisher">>};
exported_publisher(Kapi, Publish, 1, 'true') -> {'ok', fun Kapi:Publish/1};
exported_publisher(Kapi, Publish, 2, 'true') -> {'ok', fun Kapi:Publish/2}.

-spec worker_loaded() -> boolean().
worker_loaded() ->
    case code:ensure_loaded('kz_amqp_worker') of
        {'module', 'kz_amqp_worker'} -> 'true';
        {'error', _Reason} -> 'false'
    end.

-spec payload(binary()) -> any().
payload(Json) ->
    case json:decode(Json) of
        Map when is_map(Map) -> kz_json:from_map(Map);
        Other -> kz_json:from_map(#{<<"value">> => Other})
    end.

-spec reason(any()) -> binary().
reason('timeout') -> <<"no_answer">>;
reason('pool_full') -> <<"unavailable">>;
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, 'utf8');
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
