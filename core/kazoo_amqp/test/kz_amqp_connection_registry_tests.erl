%%%-----------------------------------------------------------------------------
%%% @doc A connection whose broker dropped it stays one the node can use.
%%%
%%% The lab of 2026-09-28 froze a node until the broker dropped it. On the
%%% thaw, the first `kz_nodes' heartbeat asked the connection's manager for
%%% `channel_max', and the manager called into the AMQP connection that had
%%% just died, exited with it, and was deleted from `kz_amqp_connections'.
%%% Its supervisor restarted it, and the restart connected, but it was in
%%% nobody's table: `primary_broker/0' answered `undefined' for good and no
%%% consumer of the node was given a channel again.
%%%
%%% The same end waited on the other side: a crash of `kz_amqp_connections'
%%% itself. `kz_amqp_sup' is one_for_one, so the registry restarts alone,
%%% with an empty table, while the managers under `kz_amqp_connection_sup'
%%% live on, connected. The restarted registry asks each of them to register
%%% again (`registry_restart_test_/0').
%%%
%%% No broker: nothing here gets as far as connecting. A manager that is to
%%% be connected is put in the state `connected/1' leaves it in, and says so
%%% to the registry as `connected/1' does (`make_available/1').
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_amqp_connection_registry_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kazoo_amqp/include/kz_amqp.hrl").

-define(BROKER, <<"amqp://guest:guest@127.0.0.1:1">>).

registry_test_() ->
    {'timeout'
    ,10
    ,{'spawn'
     ,{'setup'
      ,fun start/0
      ,fun stop/1
      ,fun(_) ->
               [{"a registry started before the connections' supervisor, as at first boot, runs with an empty table"
                ,fun a_registry_started_first_runs_empty/0
                }
               ,{"a connection is in the table from its start"
                ,fun a_connection_registers_as_it_starts/0
                }
               ,{"a connection restarted after a crash is in the table again, and its broker primary"
                ,fun a_restarted_connection_registers_again/0
                }
               ]
       end
      }
     }
    }.

start() ->
    {'ok', Registry} = kz_amqp_connections:start_link(),
    'true' = unlink(Registry),
    Registry.

stop(Registry) ->
    gen_server:stop(Registry).

connection() ->
    #kz_amqp_connection{broker=?BROKER
                       ,params=#amqp_params_network{host="127.0.0.1", port=1}
                       ,zone='local'
                       }.

%% A connection's manager, started as its supervisor starts it, and not
%% linked to the test.
start_manager() ->
    {'ok', Manager} = kz_amqp_connection:start_link(connection()),
    'true' = unlink(Manager),
    Manager.

in_table() ->
    %% A call after the casts: every registration sent so far is in.
    _ = kz_amqp_connections:broker_connections(?BROKER),
    lists:sort([Pid || #kz_amqp_connections{connection=Pid} <- kz_amqp_connections:connections()]).

%% kz_amqp_sup starts the registry before kz_amqp_connection_sup: its
%% asking finds no supervisor, and must not take it down.
a_registry_started_first_runs_empty() ->
    ?assertEqual('undefined', whereis('kz_amqp_connection_sup')),
    ?assertEqual([], in_table()),
    ?assertEqual('undefined', kz_amqp_connections:primary_broker()).

a_connection_registers_as_it_starts() ->
    Manager = start_manager(),
    ?assertEqual([Manager], in_table()),
    ?assertEqual('local', kz_amqp_connections:broker_zone(?BROKER)),
    kill(Manager).

a_restarted_connection_registers_again() ->
    Crashed = start_manager(),
    kz_amqp_connections:available(Crashed),
    _ = in_table(),
    ?assertEqual(?BROKER, kz_amqp_connections:primary_broker()),

    %% The crash: the table forgets the process.
    kill(Crashed),
    ?assertEqual([], in_table()),
    ?assertEqual('undefined', kz_amqp_connections:primary_broker()),

    %% The supervisor's restart is in the table, and once it has connected
    %% its broker is primary again.
    Restarted = start_manager(),
    ?assertEqual([Restarted], in_table()),
    kz_amqp_connections:available(Restarted),
    _ = in_table(),
    ?assertEqual(?BROKER, kz_amqp_connections:primary_broker()),
    kill(Restarted).

kill(Pid) ->
    Ref = monitor('process', Pid),
    exit(Pid, 'kill'),
    receive {'DOWN', Ref, 'process', Pid, _} -> 'ok' end,
    %% The table heard the same DOWN before this call is answered.
    _ = in_table(),
    'ok'.

%%------------------------------------------------------------------------------
%% The registry restarted on its own, while the connections live on.
%%
%% Each case has a registry and a kz_amqp_connection_sup, and its managers
%% are started by that supervisor, as kz_amqp_connections:add/2 starts
%% them. restart_registry/0 is a crash of the registry and kz_amqp_sup's
%% restart of it: the table goes, the managers stay.
%%------------------------------------------------------------------------------
registry_restart_test_() ->
    {'timeout'
    ,10
    ,{'spawn'
     ,{'foreach'
      ,fun start_with_supervisor/0
      ,fun stop_with_supervisor/1
      ,[{"a registry restarted while a connection is available has it again, available, and its broker primary"
        ,fun a_restarted_registry_relearns_an_available_connection/0
        }
       ,{"a registry restarted while a connection is still connecting has it again, and takes its word when it connects"
        ,fun a_restarted_registry_relearns_a_connecting_connection/0
        }
       ,{"a registry restarted with several connections has each of them again, as each is"
        ,fun a_restarted_registry_relearns_every_connection/0
        }
       ,{"a connection that registers more than once has one record and one monitor"
        ,fun a_connection_registering_again_is_one_record/0
        }
       ]
      }
     }
    }.

start_with_supervisor() ->
    _Registry = start(),
    {'ok', Supervisor} = kz_amqp_connection_sup:start_link(),
    'true' = unlink(Supervisor),
    Supervisor.

stop_with_supervisor(Supervisor) ->
    %% The managers first: as they stop they tell the registry, and read
    %% its table.
    'ok' = gen_server:stop(Supervisor),
    gen_server:stop('kz_amqp_connections').

%% A manager as kz_amqp_connections:add/2 starts one.
add_manager() ->
    {'ok', Manager} = kz_amqp_connection_sup:add(connection()),
    Manager.

%% What connected/1 does once the broker has answered: the manager takes
%% itself to be available, and says so to the registry.
make_available(Manager) ->
    _ = sys:replace_state(Manager
                         ,fun(Connection) ->
                                  kz_amqp_connections:available(self()),
                                  Connection#kz_amqp_connection{available='true'}
                          end
                         ),
    'ok'.

%% A crash of the registry, and kz_amqp_sup's restart of it.
restart_registry() ->
    Crashed = whereis('kz_amqp_connections'),
    Ref = monitor('process', Crashed),
    exit(Crashed, 'kill'),
    receive {'DOWN', Ref, 'process', Crashed, _} -> 'ok' end,
    %% Its table went with it.
    ?assertEqual('undefined', ets:info('kz_amqp_connections')),
    _Restarted = start(),
    'ok'.

%% The table once every manager in Managers has answered whatever it has
%% been asked. The registry asks as it starts, before it handles any
%% message, so by the answer to a first call to it every question is sent;
%% a call to each manager comes after the question in its mailbox, so by its
%% answer the manager's own answer is sent; and in_table/0's call to the
%% registry comes after that.
relearned(Managers) ->
    _ = kz_amqp_connections:broker_connections(?BROKER),
    _ = [kz_amqp_connection:get_connection(Manager) || Manager <- Managers],
    table().

%% Each record as {Manager, Available, Zone}.
table() ->
    _ = in_table(),
    lists:sort([{Manager, Available, Zone}
                || #kz_amqp_connections{connection=Manager
                                       ,available=Available
                                       ,zone=Zone
                                       } <- kz_amqp_connections:connections()
               ]).

a_restarted_registry_relearns_an_available_connection() ->
    Manager = add_manager(),
    make_available(Manager),
    ?assertEqual([{Manager, 'true', 'local'}], table()),
    ?assertEqual(?BROKER, kz_amqp_connections:primary_broker()),

    restart_registry(),

    ?assertEqual([{Manager, 'true', 'local'}], relearned([Manager])),
    ?assertEqual(?BROKER, kz_amqp_connections:primary_broker()),
    ?assertEqual('local', kz_amqp_connections:broker_zone(?BROKER)),
    %% And it is watched again: its going is heard.
    kill(Manager),
    ?assertNot(lists:keymember(Manager, 1, table())).

a_restarted_registry_relearns_a_connecting_connection() ->
    Manager = add_manager(),

    restart_registry(),

    ?assertEqual([{Manager, 'false', 'local'}], relearned([Manager])),
    ?assertEqual('undefined', kz_amqp_connections:primary_broker()),
    %% Its availability, when it connects, lands on the relearned record.
    make_available(Manager),
    ?assertEqual([{Manager, 'true', 'local'}], table()),
    ?assertEqual(?BROKER, kz_amqp_connections:primary_broker()).

a_restarted_registry_relearns_every_connection() ->
    Available = add_manager(),
    Connecting = add_manager(),
    make_available(Available),

    restart_registry(),

    ?assertEqual(lists:sort([{Available, 'true', 'local'}
                            ,{Connecting, 'false', 'local'}
                            ])
                ,relearned([Available, Connecting])
                ),
    ?assertEqual(?BROKER, kz_amqp_connections:primary_broker()).

a_connection_registering_again_is_one_record() ->
    Manager = add_manager(),
    kz_amqp_connection:reregister(Manager),
    kz_amqp_connection:reregister(Manager),
    ?assertEqual([{Manager, 'false', 'local'}], relearned([Manager])),
    {'monitors', Monitors} = erlang:process_info(whereis('kz_amqp_connections'), 'monitors'),
    ?assertEqual([{'process', Manager}], Monitors).

%%------------------------------------------------------------------------------
%% A manager asked about a connection that has died, before it has heard
%% the connection go, says it is not available instead of exiting with it.
%%------------------------------------------------------------------------------
info_on_a_dead_connection_test_() ->
    Dead = spawn(fun() -> 'ok' end),
    Ref = monitor('process', Dead),
    receive {'DOWN', Ref, 'process', Dead, _} -> 'ok' end,
    Connection = (connection())#kz_amqp_connection{available='true'
                                                  ,connection=Dead
                                                  },
    [?_assertEqual({'reply', {'error', 'connection_not_available'}, Connection}
                  ,kz_amqp_connection:handle_call({'info', ['channel_max']}, {self(), make_ref()}, Connection)
                  )
    ,?_assertEqual({'reply', {'error', 'connection_not_available'}, Connection}
                  ,kz_amqp_connection:handle_call('info_keys', {self(), make_ref()}, Connection)
                  )
    ].
