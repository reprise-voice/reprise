%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc Call events, without a listener of your own.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% `kz_events' is Kazoo's pool of call-event listeners: one set of AMQP
%%% bindings for the whole node, with the events handed to whoever asked for
%%% them. An application that wants an account's events asks here instead of
%%% binding a queue of its own, which is what `blackhole' and `jonny5' do.
%%%
%%% The pool is started on the first subscription. `kz_events' starts it in
%%% `bind_call_id/2' but not in `add_async_call_event_handler/3', so an
%%% application that only ever registers a handler -- which is every
%%% application here -- has to start it, the way `blackhole_app' and
%%% `jonny5_app' do.
%%%
%%% == What the bus can be asked for ==
%%%
%%% The pool binds `call.#' on the call event exchange, federated, and that
%%% is the whole of what reaches a node: every call event of the cluster.
%%% That is `kz_event_listener''s and not narrowed here. What a subscriber
%%% can narrow is what is handed to it:
%%%
%%% <ul>
%%% <li>an async handler is bound under `kz_events.call_events.Account.Name',
%%% and `kazoo_bindings' matches that key before spawning anything for the
%%% handler. Either part can be `*'. So an interest in four event names is
%%% four bindings, and every other name never reaches the handler;</li>
%%% <li>`bind_call_id/2' sends the events of one call id to the calling
%%% process, by `gproc'. It cannot follow an event whose own call id is
%%% another leg's and whose other leg is the call, which is how an offer
%%% sees the agent's leg; so nothing here uses it.</li>
%%% </ul>
%%%
%%% Everything else is decided here, on the event as `kz_json' has it --
%%% before anything is turned into a map, let alone a Gleam value. An
%%% interest names the event names, what the event has to carry (a call id,
%%% an other leg, a call id prefix, a channel variable) and, optionally, a
%%% gate: a set of accounts the subscriber opens and shuts as it goes. An
%%% event that is not wanted costs a handful of `lists:keyfind/3's.
%%%
%%% == How long a subscription lives ==
%%%
%%% As long as the process that made it, at most. A handler left bound by a
%%% subscriber that crashed would run for every event on the node for ever,
%%% so every subscription has a guard: a process that monitors the
%%% subscriber (and the process relayed to) and unbinds the handler when
%%% either goes. `off/1' unbinds it at once and dismisses the guard.
%%%
%%% The handler runs in a process `kazoo_bindings' spawns for it, not in the
%%% subscriber: the same rule as a listener closure holds, be quick and hand
%%% the work to a named actor.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_events_ffi).

-export([on_call_events/3
        ,subscribe/2
        ,relay/2
        ,off/1
        ,new_gate/0
        ,open/2
        ,shut/2
        ]).

%% The filter and the handler it wraps, for the tests and the benchmark.
-export([handler/2
        ,wanted/2
        ,from_json/1
        ,apply_all/2
        ,monotonic_us/0
        ]).

%% What a subscription is: everything `kz_events' needs to be told to forget
%% it again -- one binding per event name, the wrapped closure included,
%% since unbinding matches on the function itself -- and the guard that does
%% it if the subscriber never does.
-type binding() :: {binary(), binary(), fun()}.
-type subscription() :: {'kazoo_gleam_subscription', [binding()], pid()}.

%% `kazoo/events.Interest', by position.
-type mark() :: {'call_id', binary()}
              | {'other_leg', binary()}
              | {'call_id_prefix', binary()}
              | {'channel_var', binary()}.
-type interest() :: {'interest', binary(), [binary()], [mark()], 'none' | {'some', ets:tid()}}.

-export_type([subscription/0]).

-define(ANY, <<"*">>).

%%------------------------------------------------------------------------------
%% @doc Call `Handler' with every `EventName' event on `AccountId'.
%%
%% Both take `&lt;&lt;"*"&gt;&gt;'. Every event is turned into a map for the handler;
%% `subscribe/2' is the same with a filter in front.
%% @end
%%------------------------------------------------------------------------------
-spec on_call_events(binary(), binary(), fun((map()) -> any())) ->
          {'ok', subscription()} | {'error', binary()}.
on_call_events(AccountId, EventName, Handler) ->
    Names = case EventName of
                ?ANY -> [];
                Name -> [Name]
            end,
    subscribe({'interest', AccountId, Names, [], 'none'}, Handler).

%%------------------------------------------------------------------------------
%% @doc Call `Handler' with every event `Interest' wants, as a map.
%% @end
%%------------------------------------------------------------------------------
-spec subscribe(interest(), fun((map()) -> any())) ->
          {'ok', subscription()} | {'error', binary()}.
subscribe(Interest, Handler) ->
    bind(handler(Interest, Handler), Interest, [self()]).

%%------------------------------------------------------------------------------
%% @doc Send every event `Interest' wants to `Pid', as it arrived: the
%% `{amqp_msg, JObj}' that `kapps_call_command:relay_event/2' sends and
%% `kapps_call_command:receive_event/1' reads. Nothing is converted at all.
%% @end
%%------------------------------------------------------------------------------
-spec relay(interest(), pid()) -> {'ok', subscription()} | {'error', binary()}.
relay(Interest, Pid) ->
    Relay = filtered(Interest, fun(JObj) -> Pid ! {'amqp_msg', JObj} end),
    bind(Relay, Interest, lists:usort([self(), Pid])).

-spec bind(fun(), interest(), [pid()]) ->
          {'ok', subscription()} | {'error', binary()}.
bind(Wrapped, Interest, Watched) ->
    case code:ensure_loaded('kz_events') of
        {'error', _Reason} -> {'error', <<"unavailable">>};
        {'module', 'kz_events'} -> bind_handler(Interest, Wrapped, Watched)
    end.

-spec bind_handler(interest(), fun(), [pid()]) -> {'ok', subscription()} | {'error', binary()}.
bind_handler({'interest', AccountId, Names, _Marks, _Gate}, Wrapped, Watched) ->
    try
        'ok' = kz_events:start_call_events(),
        bind_names(AccountId, names(Names), Wrapped, [], Watched)
    catch
        _E:R -> {'error', reason(R)}
    end.

-spec names([binary()]) -> [binary()].
names([]) -> [?ANY];
names(Names) -> lists:usort(Names).

-spec bind_names(binary(), [binary()], fun(), [binding()], [pid()]) ->
          {'ok', subscription()} | {'error', binary()}.
bind_names(_AccountId, [], _Wrapped, Bound, Watched) ->
    {'ok', {'kazoo_gleam_subscription', Bound, guard(Watched, Bound)}};
bind_names(AccountId, [Name | Names], Wrapped, Bound, Watched) ->
    case kz_events:add_async_call_event_handler(AccountId, Name, Wrapped) of
        'ok' -> bind_names(AccountId, Names, Wrapped, [{AccountId, Name, Wrapped} | Bound], Watched);
        {'error', Reason} ->
            unbind(Bound),
            {'error', reason(Reason)}
    end.

%% A process of its own, linked to nobody, that unbinds the handler when any
%% of `Watched' goes. It ends when it has, or when `off/1' dismisses it.
-spec guard([pid()], [binding()]) -> pid().
guard(Watched, Bound) ->
    spawn(fun() ->
                  _ = [erlang:monitor('process', Pid) || Pid <- Watched],
                  receive
                      {'DOWN', _Ref, 'process', _Pid, _Reason} -> unbind(Bound);
                      'dismissed' -> 'ok'
                  end
          end).

%%------------------------------------------------------------------------------
%% @doc Stop calling that handler.
%% @end
%%------------------------------------------------------------------------------
-spec off(subscription()) -> 'nil'.
off({'kazoo_gleam_subscription', Bound, Guard}) ->
    unbind(Bound),
    Guard ! 'dismissed',
    'nil'.

-spec unbind([binding()]) -> 'ok'.
unbind(Bound) ->
    lists:foreach(fun({AccountId, Name, Wrapped}) ->
                          try kz_events:delete_async_call_event_handler(AccountId, Name, Wrapped)
                          catch _E:_R -> 'ok'
                          end
                  end
                 ,Bound
                 ).

%%%=============================================================================
%%% Gates
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc A set of accounts an interest can be limited to, which the
%% subscriber changes while it is subscribed. Owned by the calling process
%% and gone with it; read, without asking it, by every handler.
%% @end
%%------------------------------------------------------------------------------
-spec new_gate() -> ets:tid().
new_gate() ->
    ets:new('kazoo_gleam_events_gate', ['set', 'public', {'read_concurrency', 'true'}]).

-spec open(ets:tid(), binary()) -> 'nil'.
open(Gate, Key) ->
    _ = ets:insert(Gate, {Key}),
    'nil'.

-spec shut(ets:tid(), binary()) -> 'nil'.
shut(Gate, Key) ->
    _ = ets:delete(Gate, Key),
    'nil'.

%%%=============================================================================
%%% The filter
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc The closure `subscribe/2' binds on the bus: `Handler' called with
%% every event `Interest' wants, as a map, and nothing done at all with the
%% rest.
%% @end
%%------------------------------------------------------------------------------
-spec handler(interest(), fun((map()) -> any())) -> fun((any()) -> any()).
handler(Interest, Handler) ->
    filtered(Interest, fun(JObj) -> Handler(to_map(JObj)) end).

%%------------------------------------------------------------------------------
%% @doc `Deliver' called with every event `Interest' wants, on the event as
%% it arrived.
%%
%% `kazoo_bindings:pmap/2' wraps a payload that is not already a list in one
%% before it applies a responder, so a handler of one argument is handed
%% `[JObj]' rather than the event. `j5_channels:handle_call_event/1' takes
%% both shapes for the same reason.
%% @end
%%------------------------------------------------------------------------------
-spec filtered(interest(), fun((any()) -> any())) -> fun((any()) -> any()).
filtered(Interest, Deliver) ->
    fun(Payload) ->
            JObj = unwrap(Payload),
            _ = case wanted(Interest, JObj) of
                    'true' -> Deliver(JObj);
                    'false' -> 'ok'
                end,
            Payload
    end.

-spec unwrap(any()) -> any().
unwrap([JObj]) -> JObj;
unwrap(JObj) -> JObj.

%%------------------------------------------------------------------------------
%% @doc Whether `Interest' wants the event: its name is one of the names (or
%% there are none), its account is open in the gate (or there is no gate),
%% and it carries one of the marks (or there are none).
%%
%% The names are bound on the bus one by one, so an event of another name
%% does not get here; they are checked again because it costs nothing and a
%% handler bound under `*' is not told the name it was matched on.
%% @end
%%------------------------------------------------------------------------------
-spec wanted(interest(), any()) -> boolean().
wanted({'interest', _AccountId, Names, Marks, Gate}, JObj) ->
    named(Names, JObj)
        andalso admitted(Gate, JObj)
        andalso carrying(Marks, JObj).

-spec named([binary()], any()) -> boolean().
named([], _JObj) -> 'true';
named(Names, JObj) -> lists:member(get(<<"Event-Name">>, JObj), Names).

-spec admitted('none' | {'some', ets:tid()}, any()) -> boolean().
admitted('none', _JObj) -> 'true';
admitted({'some', Gate}, JObj) ->
    case ccv(<<"Account-ID">>, JObj) of
        AccountId when is_binary(AccountId) ->
            try ets:member(Gate, AccountId)
            catch 'error':'badarg' -> 'false'
            end;
        _Otherwise -> 'false'
    end.

-spec carrying([mark()], any()) -> boolean().
carrying([], _JObj) -> 'true';
carrying(Marks, JObj) -> lists:any(fun(Mark) -> marked(Mark, JObj) end, Marks).

-spec marked(mark(), any()) -> boolean().
marked({'call_id', CallId}, JObj) -> get(<<"Call-ID">>, JObj) =:= CallId;
marked({'other_leg', CallId}, JObj) -> get(<<"Other-Leg-Call-ID">>, JObj) =:= CallId;
marked({'call_id_prefix', Prefix}, JObj) ->
    Size = byte_size(Prefix),
    case get(<<"Call-ID">>, JObj) of
        <<Prefix:Size/binary, _/binary>> -> 'true';
        _Otherwise -> 'false'
    end;
marked({'channel_var', Name}, JObj) -> is_binary(ccv(Name, JObj)).

%% `kz_json' objects are `{Proplist}'; `kz_json:get_value/2' on a top-level
%% key is this, without the path handling nobody here needs.
-spec get(binary(), any()) -> any().
get(Key, {Props}) when is_list(Props) ->
    case lists:keyfind(Key, 1, Props) of
        {Key, Value} -> Value;
        'false' -> 'undefined'
    end;
get(_Key, _NotAnObject) -> 'undefined'.

-spec ccv(binary(), any()) -> any().
ccv(Name, JObj) -> get(Name, get(<<"Custom-Channel-Vars">>, JObj)).

%%------------------------------------------------------------------------------
%% @doc An event as a map: `kz_json:to_map/1' on an object, without needing
%% `kz_json' to be there.
%% @end
%%------------------------------------------------------------------------------
-spec to_map(any()) -> any().
to_map({Props}) when is_list(Props) -> maps:from_list([{K, to_map(V)} || {K, V} <- Props]);
to_map(List) when is_list(List) -> [to_map(Item) || Item <- List];
to_map(Else) -> Else.

%%%=============================================================================
%%% Test support
%%%=============================================================================

%% @doc JSON text as `kz_json' decodes it: objects as `{Proplist}'.
-spec from_json(binary()) -> any().
from_json(Json) ->
    Push = fun(Key, Value, Acc) -> [{Key, Value} | Acc] end,
    Finish = fun(Acc, Old) -> {{lists:reverse(Acc)}, Old} end,
    {Decoded, 'ok', <<>>} =
        json:decode(Json, 'ok', #{'object_push' => Push
                                 ,'object_finish' => Finish
                                 ,'null' => 'null'
                                 }),
    Decoded.

%% @doc Hand every event to the closure, as the bus would: each wrapped in a
%% list, the way `kazoo_bindings:pmap/2' does.
-spec apply_all(fun((any()) -> any()), [any()]) -> 'nil'.
apply_all(Handler, Events) ->
    lists:foreach(fun(Event) -> Handler([Event]) end, Events),
    'nil'.

-spec monotonic_us() -> integer().
monotonic_us() -> erlang:monotonic_time('microsecond').

-spec reason(any()) -> binary().
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, 'utf8');
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
