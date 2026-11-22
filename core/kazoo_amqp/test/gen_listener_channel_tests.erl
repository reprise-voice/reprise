%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc What a gen_listener's module hears when the listener gets a channel,
%%% and in what order.
%%%
%%% The module hears `{'kz_amqp_channel', {'new_channel', Reconnected}}' once
%%% its consumer is up -- and only after the bindings it asked for exist,
%%% whether they were delayed until the first channel or restored on one that
%%% replaced a lost one. `kz_cache_listener' flushes a cache on that notice,
%%% and a flush before the binding for change notices exists would let the
%%% cache refill and miss the next edit.
%%%
%%% No broker: the channel and the util calls that would reach it are
%%% mocked, and this module is the listener's own callback module.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(gen_listener_channel_tests).

-include_lib("eunit/include/eunit.hrl").

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-define(RUNNER, 'gen_listener_channel_tests_runner').
-define(QUEUE, <<"gen_listener_channel_tests">>).

new_channel_test_() ->
    {'timeout'
    ,10
    ,{'spawn'
     ,{'setup'
      ,fun start/0
      ,fun stop/1
      ,fun(Listener) ->
               [{"a binding delayed until the first channel exists before the module hears of it"
                ,fun() -> delayed_binding_comes_first(Listener) end
                }
               ,{"a binding restored on a channel that came back exists before the module hears of it"
                ,fun() -> restored_binding_comes_first(Listener) end
                }
               ]
       end
      }
     }
    }.

start() ->
    'ok' = meck:new('kz_amqp_channel', ['passthrough']),
    'ok' = meck:expect('kz_amqp_channel', 'requisition', fun() -> 'true' end),
    'ok' = meck:expect('kz_amqp_channel', 'has_channel', fun() -> 'false' end),
    'ok' = meck:expect('kz_amqp_channel', 'consumer_channel', fun(_Channel) -> 'ok' end),
    'ok' = meck:expect('kz_amqp_channel', 'remove_consumer_channel', fun() -> 'ok' end),
    'ok' = meck:new('kz_amqp_util', ['passthrough']),
    'ok' = meck:expect('kz_amqp_util', 'new_queue', fun(Queue, _Options) -> Queue end),
    'ok' = meck:expect('kz_amqp_util', 'basic_qos', fun(_Prefetch) -> 'ok' end),
    'ok' = meck:expect('kz_amqp_util', 'basic_consume', fun(_Queue, _Options) -> 'ok' end),
    'ok' = meck:expect('kz_amqp_util', 'configuration_exchange', fun() -> 'ok' end),
    'ok' = meck:expect('kz_amqp_util', 'bind_q_to_configuration'
                      ,fun(_Queue, RoutingKey) -> ?RUNNER ! {'bound', RoutingKey}, 'ok' end
                      ),
    {'ok', Listener} =
        gen_listener:start_link(?MODULE
                               ,[{'bindings', []}
                                ,{'queue_name', ?QUEUE}
                                ,{'basic_qos', 1}
                                ,{'kz_monitor', 'false'}
                                ]
                               ,[]
                               ),
    Listener.

%% Killed rather than stopped: terminate would release the consumer to an
%% assignments server that is not running.
stop(Listener) ->
    'true' = erlang:unlink(Listener),
    'true' = exit(Listener, 'kill'),
    'ok' = meck:unload(['kz_amqp_channel', 'kz_amqp_util']).

%% The process a test runs in is not the one that ran the setup, so each
%% test takes the runner's name for itself before anything is sent to it.
be_the_runner() ->
    _ = (catch unregister(?RUNNER)),
    'true' = register(?RUNNER, self()).

delayed_binding_comes_first(Listener) ->
    be_the_runner(),
    'ok' = gen_listener:add_binding(Listener, 'conf', [{'doc_type', <<"queue">>}]),
    %% Answered after the binding request before it was handled, and delayed.
    ?assertNot(gen_listener:is_consuming(Listener)),

    Listener ! {'kz_amqp_assignment', {'new_channel', 'false', self()}},

    ?assertMatch([{'bound', _RoutingKey}, {'notified', 'false'}], heard(2)),
    ?assert(gen_listener:is_consuming(Listener)).

restored_binding_comes_first(Listener) ->
    be_the_runner(),
    Listener ! {'kz_amqp_assignment', 'lost_channel'},
    Listener ! {'kz_amqp_assignment', {'new_channel', 'true', self()}},

    ?assertMatch([{'bound', _RoutingKey}, {'notified', 'true'}], heard(2)).

heard(0) -> [];
heard(N) ->
    receive Message -> [Message | heard(N - 1)]
    after 2000 -> ['nothing']
    end.

%% --- The listener's module ---------------------------------------------------

init([]) -> {'ok', 'nothing'}.

handle_call(_Request, _From, State) -> {'reply', 'ok', State}.

handle_cast({'kz_amqp_channel', {'new_channel', Reconnected}}, State) ->
    ?RUNNER ! {'notified', Reconnected},
    {'noreply', State};
handle_cast(_Message, State) -> {'noreply', State}.

handle_info(_Info, State) -> {'noreply', State}.

handle_event(_JObj, _State) -> {'reply', []}.

terminate(_Reason, _State) -> 'ok'.

code_change(_OldVsn, State, _Extra) -> {'ok', State}.
