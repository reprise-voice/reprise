%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The calls the call center makes that `kazoo_gleam' does not cover.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% The hash that puts an account in a shard, the queue declaration that also
%%% reports what is on the queue, where a callflow action can be reached,
%%% the exit signal a listener has to act on,
%%% the ways a supervised process ends, and the atom `sup' reads as a
%%% command that has already printed what it had to say.
%%%
%%% Like every FFI module in the release's Gleam applications this is
%%% compiled by the Gleam compiler, so: no parse transform (`lager:log/4' by
%%% hand, never `lager:debug/2'), no Kazoo header (literal atoms and
%%% proplists, never a record from an `.hrl'), and every call guarded with
%%% `code:ensure_loaded/1' so the test suite runs with no release around it.
%%% @end
%%%-----------------------------------------------------------------------------
-module(callcenter_ffi).

-export([shard_for/2
        ,rendezvous_weight/2
        ,presence_call_id/1
        ,status_change_id/3
        ,unsettled_delivery/0
        ,redelivered_delivery/0
        ,declare_queue/1
        ,declare_marker/2
        ,is_precondition_failed/1
        ,node_term/1
        ,put_node_term/2
        ,register_views/0
        ,register_views_now/0
        ,is_exit_from/2
        ,monotonic_ms/0
        ,leg_prefix/1
        ,no_return/0
        ,broker_available/0
        ,stop_normally/0
        ,stop_shutdown/0
        ,terminate/2
        ,log_debug/1
        ,callflow_executor/1
        ,callflow_queue/0
        ]).

%% The call actor's reach: see `callcenter/call/actor'.
-export([bind_call/1
        ,unbind_call/1
        ,kapi_payload/1
        ,reply_address/0
        ,send_command/2
        ,ensure_channel/0
        ,callflow_branches/2
        ]).

%%------------------------------------------------------------------------------
%% @doc The shard an account belongs to: `erlang:phash2(AccountId, Shards)'.
%%
%% The only place it is computed, through `callcenter/shards': the callflow
%% action that publishes a member and the node holding the shard have to
%% agree on it, or the message goes to a queue nobody is consuming.
%% @end
%%------------------------------------------------------------------------------
-spec shard_for(binary(), pos_integer()) -> non_neg_integer().
shard_for(AccountId, Shards) when Shards > 0 ->
    erlang:phash2(AccountId, Shards).

%%------------------------------------------------------------------------------
%% @doc How much a member wants a shard, for `callcenter/shards:assign/2'.
%%
%% `erlang:phash2/2' is the same on every node and every release of the
%% runtime, which is what lets every node rank the members the same way
%% without asking each other.
%% @end
%%------------------------------------------------------------------------------
-spec rendezvous_weight(binary(), non_neg_integer()) -> non_neg_integer().
rendezvous_weight(Member, Shard) ->
    erlang:phash2({Member, Shard}, 1 bsl 32).

%%------------------------------------------------------------------------------
%% @doc The call id a presence update for a presence id carries.
%%
%% `kapps_call_command:presence/2' makes one up from the presence id when
%% there is no call, so that every update for the same key carries the same
%% identifier and omnipresence treats them as one dialogue. This is that
%% function's `?FAKE_CALLID': the MD5 of the presence id, in hexadecimal.
%% @end
%%------------------------------------------------------------------------------
-spec presence_call_id(binary()) -> binary().
presence_call_id(PresenceId) ->
    Digest = crypto:hash('md5', PresenceId),
    <<<<(integer_to_binary(Nibble, 16))/binary>> || <<Nibble:4>> <= Digest>>.

%%------------------------------------------------------------------------------
%% @doc The document id of one availability change.
%%
%% Agent, new value and second. Requirement 0.6 says two nodes acting on one
%% event must give the same result as one, and this is where that is made
%% true for the status log: the same change written twice is one document,
%% not two lines in a supervisor's report.
%% @end
%%------------------------------------------------------------------------------
-spec status_change_id(binary(), binary(), integer()) -> binary().
status_change_id(AgentId, To, At) ->
    <<"agent_status_change-"
     ,AgentId/binary, "-"
     ,(integer_to_binary(At))/binary, "-"
     ,To/binary
    >>.

%%------------------------------------------------------------------------------
%% @doc A delivery that never came off a broker.
%%
%% `kazoo/listener' hands a delivery over as an opaque term and settles it
%% through `gen_listener', so a test that has no broker still needs one of
%% the right shape to hand to a dispatcher. Acking or nacking this one
%% reaches a `gen_listener' that is not there, which the library already
%% catches.
%% @end
%%------------------------------------------------------------------------------
-spec unsettled_delivery() -> {'kazoo_gleam_delivery', 'undefined', 'undefined'}.
unsettled_delivery() ->
    {'kazoo_gleam_delivery', 'undefined', 'undefined'}.

%%------------------------------------------------------------------------------
%% @doc The same, flagged as a message the broker has handed out before.
%%
%% Here beside `unsettled_delivery/0' and for the same reason: both are for
%% the suite and neither can live under `test'. `gleam export
%% erlang-shipment' copies every native module it finds, `test' included,
%% into the shipment's `ebin', so a module moved there would ship under a
%% name that says it should not have. Two functions that build a term cost
%% the release nothing.
%%
%% The flag lives in the `#'basic.deliver'{}' a delivery carries, which is
%% built by hand -- `{'basic.deliver', ConsumerTag, DeliveryTag, Redelivered,
%% Exchange, RoutingKey}' -- because this file, like every FFI module the
%% Gleam compiler builds, has no include path to name the record with.
%% `kazoo_gleam_listener:redelivered/1' reads it back the same way.
%% @end
%%------------------------------------------------------------------------------
-spec redelivered_delivery() -> {'kazoo_gleam_delivery', 'undefined', tuple()}.
redelivered_delivery() ->
    {'kazoo_gleam_delivery'
    ,'undefined'
    ,{'basic.deliver', 'undefined', 1, 'true', <<>>, <<>>}
    }.

%%------------------------------------------------------------------------------
%% @doc Register the application's CouchDB views, and bind so that they are
%% re-registered whenever the platform refreshes.
%%
%% `applications/callcenter/priv/couchdb/views' holds one file per
%% classification; `kapps_maintenance' calls `register_views/0' back on every
%% refresh, which is how skel does it and how a fresh database gets the views
%% without an operator step.
%% @end
%%------------------------------------------------------------------------------
-spec register_views() -> 'nil'.
register_views() ->
    _ = case code:ensure_loaded('kapps_maintenance') of
            {'error', _Reason} -> 'ok';
            {'module', 'kapps_maintenance'} ->
                catch kapps_maintenance:bind_and_register_views('callcenter'
                                                               ,'callcenter_ffi'
                                                               ,'register_views_now'
                                                               )
        end,
    'nil'.

%%------------------------------------------------------------------------------
%% @doc The callback `bind_and_register_views/3' binds and then calls.
%% @end
%%------------------------------------------------------------------------------
-spec register_views_now() -> 'ok'.
register_views_now() ->
    kz_datamgr:register_views_from_folder('callcenter').

%%------------------------------------------------------------------------------
%% @doc Declare one of the application's durable queues and answer what is on
%% it: `{MessageCount, ConsumerCount}'.
%%
%% `Spec' is the queue half of a `kazoo/listener' spec, the one
%% `callcenter/shards' gives the listener that consumes the queue, and it is
%% turned into options exactly as `kazoo_gleam_listener' turns it, so a queue
%% declared here and then consumed by a listener does not fail on mismatched
%% arguments.
%%
%% The counts are what the broker answers a `queue.declare' with, and there
%% is one thing they do not say: a message that has been delivered to a
%% consumer and not yet acked is on neither count. So a message count of zero
%% means "nothing is waiting", not "nothing exists" -- unless the consumer
%% count is zero as well, and then it means both. The consumer count is the
%% one the placement (`callcenter/placement') reads: a member queue with a
%% consumer is a shard some node holds, and a node's own queue with one is a
%% member (`callcenter/members').
%%
%% A channel is asked for with a timeout rather than taken with
%% `kz_amqp_channel:consumer_channel/0', which waits for one for ever: this
%% is reached from `sup' and from application start-up, and neither should
%% hang on a node whose broker is not there.
%% @end
%%------------------------------------------------------------------------------
-spec declare_queue(map()) -> {'ok', {non_neg_integer(), non_neg_integer()}} | {'error', binary()}.
declare_queue(Spec) ->
    case channel(5000) of
        'false' -> {'error', <<"unavailable">>};
        'true' -> declare_on_channel(Spec)
    end.

-spec declare_on_channel(map()) -> {'ok', {non_neg_integer(), non_neg_integer()}} | {'error', binary()}.
declare_on_channel(#{<<"name">> := Queue}=Spec) ->
    try kz_amqp_util:new_queue(Queue, queue_options(Spec)) of
        {_Q, MessageCount, ConsumerCount} -> {'ok', {MessageCount, ConsumerCount}};
        {'error', Reason} -> {'error', reason(Reason)};
        _Other -> {'error', <<"unexpected_declare">>}
    catch
        _E:R -> {'error', reason(R)}
    end.

%% `kazoo_gleam_listener:queue_options/1', and the counts back.
-spec queue_options(map()) -> list().
queue_options(Spec) ->
    [{'durable', maps:get(<<"durable">>, Spec, 'false')}
    ,{'exclusive', maps:get(<<"exclusive">>, Spec, 'false')}
    ,{'auto_delete', maps:get(<<"auto_delete">>, Spec, 'true')}
    ,{'arguments', [{<<"x-message-ttl">>, limit(maps:get(<<"ttl">>, Spec, 'undefined'))}
                   ,{<<"x-max-length">>, limit(maps:get(<<"max_length">>, Spec, 'undefined'))}
                   ]}
    ,{'return_field', 'all'}
    ].

-spec limit(any()) -> any().
limit(<<"infinity">>) -> 'infinity';
limit(Limit) -> Limit.

%%------------------------------------------------------------------------------
%% @doc Declare the queue that carries the cluster's shard count, in a process
%% of its own, and say whether the broker agreed.
%%
%% `callcenter.shards' is durable, never consumed and never published to,
%% and declared with `x-max-length' set to the count. A second declaration
%% with other arguments is refused by the broker with `PRECONDITION_FAILED',
%% which is how a node whose count differs from the one the queue was
%% declared with finds out: `{error, {mismatch, Reason}}'. Anything else
%% going wrong -- no broker, no channel -- is `{error, {unreachable,
%% Reason}}', which says nothing about the count.
%%
%% A process of its own because a refused declaration closes the channel it
%% was made on, and the channel is the calling process's: an owner's, or the
%% callflow's. This one's goes with it, and the caller's is never touched.
%% @end
%%------------------------------------------------------------------------------
-spec declare_marker(binary(), pos_integer()) ->
          {'ok', 'nil'} | {'error', {'mismatch' | 'unreachable', binary()}}.
declare_marker(Queue, Count) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} =
        spawn_monitor(fun() ->
                              Parent ! {Ref, declare_marker_here(Queue, Count)},
                              exit('shutdown')
                      end),
    receive
        {Ref, Result} ->
            erlang:demonitor(Monitor, ['flush']),
            Result;
        {'DOWN', Monitor, 'process', Pid, Reason} ->
            {'error', {'unreachable', reason(Reason)}}
    after 15000 ->
            erlang:demonitor(Monitor, ['flush']),
            exit(Pid, 'kill'),
            {'error', {'unreachable', <<"timeout">>}}
    end.

-spec declare_marker_here(binary(), pos_integer()) ->
          {'ok', 'nil'} | {'error', {'mismatch' | 'unreachable', binary()}}.
declare_marker_here(Queue, Count) ->
    case channel(5000) of
        'false' -> {'error', {'unreachable', <<"unavailable">>}};
        'true' ->
            Options = [{'durable', 'true'}
                      ,{'exclusive', 'false'}
                      ,{'auto_delete', 'false'}
                      ,{'arguments', [{<<"x-message-ttl">>, 'infinity'}
                                     ,{<<"x-max-length">>, Count}
                                     ]}
                      ,{'return_field', 'all'}
                      ],
            try kz_amqp_util:new_queue(Queue, Options) of
                {_Q, _Messages, _Consumers} -> {'ok', 'nil'};
                {'error', Reason} -> marker_error(Reason);
                Other -> marker_error(Other)
            catch
                _E:R -> marker_error(R)
            end
    end.

-spec marker_error(any()) -> {'error', {'mismatch' | 'unreachable', binary()}}.
marker_error(Reason) ->
    Text = reason(Reason),
    case is_precondition_failed(Text) of
        'true' -> {'error', {'mismatch', Text}};
        'false' -> {'error', {'unreachable', Text}}
    end.

%%------------------------------------------------------------------------------
%% @doc Whether the text of a refusal is the broker's `PRECONDITION_FAILED':
%% the reply text both RabbitMQ and LavinMQ close a channel with when a queue
%% is declared again with other arguments.
%% @end
%%------------------------------------------------------------------------------
-spec is_precondition_failed(binary()) -> boolean().
is_precondition_failed(Text) ->
    binary:match(Text, <<"PRECONDITION_FAILED">>) =/= 'nomatch'.

%%------------------------------------------------------------------------------
%% @doc One of this node's own values, kept for the life of the VM:
%% `persistent_term' under `{callcenter, Name}'. Written once or twice in a
%% node's life, read on every call.
%% @end
%%------------------------------------------------------------------------------
-spec node_term(binary()) -> {'ok', any()} | {'error', 'nil'}.
node_term(Name) ->
    try persistent_term:get({'callcenter', Name}) of
        Value -> {'ok', Value}
    catch
        'error':'badarg' -> {'error', 'nil'}
    end.

-spec put_node_term(binary(), any()) -> 'nil'.
put_node_term(Name, Value) ->
    persistent_term:put({'callcenter', Name}, Value),
    'nil'.

%%------------------------------------------------------------------------------
%% @doc Whether there is a `gen_listener' in this VM to start at all.
%%
%% False under `gleam test' and `gleam run', which have the application but
%% not the release around it. The lease listeners are the whole of the tree,
%% so without this the application cannot start at all off a node.
%% @end
%%------------------------------------------------------------------------------
-spec broker_available() -> boolean().
broker_available() ->
    case code:ensure_loaded('gen_listener') of
        {'module', 'gen_listener'} -> 'true';
        {'error', _Reason} -> 'false'
    end.

%%------------------------------------------------------------------------------
%% @doc The `cf_exe' running a callflow action, spelled as `kapi:encode_pid/2'
%% spells it in a `Controller-Queue': `<0.123.0>'. `none' for anything that
%% is not a call a callflow is running, the test suite's calls included.
%% @end
%%------------------------------------------------------------------------------
-spec callflow_executor(any()) -> {'some', binary()} | 'none'.
callflow_executor(Call) ->
    case code:ensure_loaded('kapps_call') of
        {'module', 'kapps_call'} ->
            try kapps_call:kvs_fetch('cf_exe_pid', Call) of
                Pid when is_pid(Pid) -> {'some', list_to_binary(pid_to_list(Pid))};
                _ -> 'none'
            catch
                _:_ -> 'none'
            end;
        _ -> 'none'
    end.

%%------------------------------------------------------------------------------
%% @doc The queue one of this node's callflow listeners consumes.
%%
%% `cf_listener_sup' runs every `cf_listener' of the node, and they share one
%% queue, `callflow_route_<instance>', which is bound to the `targeted'
%% exchange under its own name and is where a route win arrives. A listener
%% hands a message carrying `Deliver-To-PID' to that pid, so a
%% `pid://<pid>/<queue>' address with this queue reaches any process on this
%% node. `none' when callflow is not running here, or no listener answers.
%% @end
%%------------------------------------------------------------------------------
-spec callflow_queue() -> {'some', binary()} | 'none'.
callflow_queue() ->
    try supervisor:which_children('cf_listener_sup') of
        Children ->
            first_queue([Pid || {_, Pid, _, _} <- Children, is_pid(Pid)])
    catch
        _:_ -> 'none'
    end.

-spec first_queue([pid()]) -> {'some', binary()} | 'none'.
first_queue([]) -> 'none';
first_queue([Pid | Pids]) ->
    try gen_listener:queue_name(Pid) of
        Queue when is_binary(Queue), Queue =/= <<>> -> {'some', Queue};
        _ -> first_queue(Pids)
    catch
        _:_ -> first_queue(Pids)
    end.

%%------------------------------------------------------------------------------
%% @doc Whether a term a listener was sent is an exit signal from that pid.
%%
%% `gen_listener' traps exits, so a link to a dead owner arrives as an
%% ordinary message and the listener carries on consuming a queue nobody owns
%% any more. The member listener watches for this one and stops.
%% @end
%%------------------------------------------------------------------------------
-spec is_exit_from(any(), pid()) -> boolean().
is_exit_from({'EXIT', Pid, _Reason}, Pid) -> 'true';
is_exit_from(_Term, _Pid) -> 'false'.

%%------------------------------------------------------------------------------
%% @doc End the calling process with reason `shutdown', from inside one of
%% its own callbacks: what a supervisor's child answers the supervisor's
%% shutdown with, once it has finished tidying up.
%% @end
%%------------------------------------------------------------------------------
-spec stop_shutdown() -> no_return().
stop_shutdown() -> exit('shutdown').

%%------------------------------------------------------------------------------
%% @doc Shut a supervisor down, from any process, and wait for it to be gone.
%%
%% `sys:terminate/3' is a system message, so unlike an exit signal it does
%% not have to come from the supervisor's parent. It is answered before the
%% supervisor acts on it -- `sys' replies and then calls `system_terminate'
%% -- so the answer says nothing about whether the children have stopped;
%% the monitor does. `true' once the supervisor has exited, `false' when it
%% has not within the time given. A supervisor that is already gone is
%% `true'.
%% @end
%%------------------------------------------------------------------------------
-spec terminate(pid(), pos_integer()) -> boolean().
terminate(Pid, TimeoutMs) ->
    Ref = erlang:monitor('process', Pid),
    _ = (catch sys:terminate(Pid, 'shutdown', TimeoutMs)),
    receive
        {'DOWN', Ref, 'process', Pid, _Reason} -> 'true'
    after TimeoutMs ->
            erlang:demonitor(Ref, ['flush']),
            'false'
    end.

%%------------------------------------------------------------------------------
%% @doc The VM's monotonic clock in milliseconds, for a wait that is bounded
%% by time passing and not by how often it looked.
%% @end
%%------------------------------------------------------------------------------
-spec monotonic_ms() -> integer().
monotonic_ms() ->
    erlang:monotonic_time('millisecond').

%%------------------------------------------------------------------------------
%% @doc Twenty-four lower-case hex characters: the part every call id an offer
%% gives its legs starts with, worked out from the reference the dispatcher
%% made for that offer.
%%
%% A reference is unique to the node and its incarnation, so no two offers
%% anywhere share a prefix; and it is a function of the reference, so the
%% dispatcher can write on the caller's record the prefix the caller's actor
%% rings with, for whoever takes the caller over to read. A callflow action
%% names a passage the same way.
%% @end
%%------------------------------------------------------------------------------
-spec leg_prefix(reference()) -> binary().
leg_prefix(Serial) ->
    <<Part:12/binary, _/binary>> = crypto:hash('sha256', term_to_binary(Serial)),
    string:lowercase(binary:encode_hex(Part)).

%%------------------------------------------------------------------------------
%% @doc End the calling process, from inside one of its own callbacks.
%%
%% A `gen_server' callback that exits with `normal' terminates the server
%% normally: `terminate/2' runs and no crash is reported. It is how a
%% listener stops itself, which it cannot do with `gen_listener:stop/1' --
%% that is a call, and a process cannot call itself.
%% @end
%%------------------------------------------------------------------------------
-spec stop_normally() -> no_return().
stop_normally() -> exit('normal').

%%------------------------------------------------------------------------------
%% @doc The atom `sup' reads as "this command printed what it had to say".
%%
%% Without it `sup' prints the function's return value after the report, and
%% a Gleam function always returns something.
%% @end
%%------------------------------------------------------------------------------
-spec no_return() -> 'no_return'.
no_return() -> 'no_return'.

%%------------------------------------------------------------------------------
%% @doc One line in the Kazoo log at debug level, for what is only worth
%% reading while chasing something: a reply the dispatcher dropped because
%% the offer it names is gone. `kazoo_gleam' logs at info and error only.
%%
%% Guarded the way `kazoo_gleam_ffi:log_info/1' is: no lager in a test suite.
%% @end
%%------------------------------------------------------------------------------
-spec log_debug(binary()) -> 'nil'.
log_debug(Message) ->
    _ = case code:ensure_loaded('lager') of
            {'module', 'lager'} -> lager:log('debug', self(), "~s", [Message]);
            {'error', _Reason} -> logger:debug("~s", [Message])
        end,
    'nil'.

%%%=============================================================================
%%% The call actor
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Hear every event of a call id from now on, in the calling process's
%% mailbox, as `{kapi, Msg}': `kz_events:bind_call_id/1', the node's pooled
%% call events. The caller's own events and each of its offer's legs are
%% bound one by one, by the actor that commands them. Nothing where there
%% are no call events to bind to: the test suite, which hands the actor its
%% events itself.
%% @end
%%------------------------------------------------------------------------------
-spec bind_call(binary()) -> 'nil'.
bind_call(CallId) ->
    try kz_events:bind_call_id(CallId)
    catch _E:_R -> 'ok'
    end,
    'nil'.

%%------------------------------------------------------------------------------
%% @doc Stop hearing a call id. `gproc' refuses to take back what was never
%% registered, and a leg unbound twice is nothing.
%% @end
%%------------------------------------------------------------------------------
-spec unbind_call(binary()) -> 'nil'.
unbind_call(CallId) ->
    try kz_events:unbind_call_id(CallId)
    catch _E:_R -> 'ok'
    end,
    'nil'.

%%------------------------------------------------------------------------------
%% @doc The message a `{kapi, Msg}' carries, as a map for `kazoo/doc': a call
%% event from `kz_events', or a reply `gen_listener' handed straight to the
%% pid its `Deliver-To-PID' named. `nil' for anything else of that shape.
%% @end
%%------------------------------------------------------------------------------
-spec kapi_payload(any()) -> {'ok', map()} | {'error', 'nil'}.
kapi_payload({'kapi', {_Delivery, _Type, Map}}) when is_map(Map) -> {'ok', Map};
kapi_payload({'kapi', {_Delivery, _Type, JObj}}) ->
    try {'ok', kz_json:to_map(JObj)}
    catch _E:_R -> {'error', 'nil'}
    end;
kapi_payload(_Other) -> {'error', 'nil'}.

%%------------------------------------------------------------------------------
%% @doc Where a reply to the calling process goes: `pid://<self>/<queue>',
%% the queue of this node's call reply listener (`callcenter/call/replies'),
%% which hands whatever carries that address straight to this pid. `nil'
%% until the listener has said what its queue is.
%% @end
%%------------------------------------------------------------------------------
-spec reply_address() -> {'ok', binary()} | {'error', 'nil'}.
reply_address() ->
    case node_term(<<"call_replies_queue">>) of
        {'ok', Queue} when is_binary(Queue), Queue =/= <<>> ->
            {'ok', kapi:encode_pid(Queue, self())};
        _ -> {'error', 'nil'}
    end.

%%------------------------------------------------------------------------------
%% @doc Send one command to a call's control queue from the calling process,
%% as `kapps_call_command:send_command/2' sends every command: the call's
%% `Call-ID' and the caller's own headers added. `Json' is the command's
%% fields. Anything `kazoo_gleam' has no function for -- a `noop' with a
%% known `Msg-ID', `connect_leg', a `set' run at once -- goes this way.
%% @end
%%------------------------------------------------------------------------------
-spec send_command(any(), binary()) -> {'ok', 'nil'} | {'error', binary()}.
send_command(Call, Json) ->
    case code:ensure_loaded('kapps_call_command') of
        {'module', 'kapps_call_command'} ->
            try kapps_call_command:send_command(kz_json:to_proplist(kz_json:decode(Json)), Call) of
                _ -> {'ok', 'nil'}
            catch
                _E:R -> {'error', reason(R)}
            end;
        _ -> {'ok', 'nil'}
    end.

%%------------------------------------------------------------------------------
%% @doc Make sure the calling process has an AMQP channel of its own, so that
%% everything it publishes goes out on one channel, in the order it was
%% sent. `False' where there is no broker.
%% @end
%%------------------------------------------------------------------------------
-spec ensure_channel() -> boolean().
ensure_channel() -> channel(5000).

%%------------------------------------------------------------------------------
%% @doc The flows the callflow running a call would go on into on each of
%% `Keys', as its executor says (`cf_exe:next/2': the branch's own child, or
%% the default child when it has none), as a map. A key with neither is left
%% out, and so is everything where there is no executor to ask.
%% @end
%%------------------------------------------------------------------------------
-spec callflow_branches(any(), [binary()]) -> map().
callflow_branches(Call, Keys) ->
    lists:foldl(fun(Key, Acc) ->
                        try cf_exe:next(Key, Call) of
                            'undefined' -> Acc;
                            Flow -> Acc#{Key => kz_json:to_map(Flow)}
                        catch
                            _E:_R -> Acc
                        end
                end
               ,#{}
               ,Keys
               ).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% @doc Make sure the calling process has an AMQP channel, without waiting for
%% one for ever. The assignment is released when the process ends.
-spec channel(pos_integer()) -> boolean().
channel(Timeout) ->
    case code:ensure_loaded('kz_amqp_assignments') of
        {'error', _Reason} -> 'false';
        {'module', 'kz_amqp_assignments'} -> assigned(Timeout)
    end.

-spec assigned(pos_integer()) -> boolean().
assigned(Timeout) ->
    try kz_amqp_assignments:get_channel(Timeout) of
        {'error', _Reason} -> 'false';
        _Assignment -> 'true'
    catch
        _E:_R -> 'false'
    end.

-spec reason(any()) -> binary().
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, 'utf8');
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

