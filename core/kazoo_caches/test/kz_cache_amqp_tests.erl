%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2025, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_cache_amqp_tests).

-include_lib("eunit/include/eunit.hrl").

-include_lib("kazoo_amqp/include/kz_amqp.hrl").
-include_lib("kazoo_amqp/include/kapi_conf.hrl").
-include("kz_caches.hrl").

-define(CHANGE_TYPE, <<"some_doc_type">>).

%% Two more caches beside ?MODULE, which asks for neither flush: one emptied
%% when the listener gets its first channel, one when it gets a channel back.
-define(FIRST_CHANNEL_CACHE, 'kz_cache_amqp_tests_first_channel').
-define(RECONNECT_CACHE, 'kz_cache_amqp_tests_reconnect').
%% And one whose flush callback reports where it ran and asks for a store
%% while the flush is under way.
-define(SERIAL_CACHE, 'kz_cache_amqp_tests_serial').
-define(RUNNER, 'kz_cache_amqp_tests_runner').
-define(LATE_DB, <<"late-db">>).
-define(LATE_DOC, <<"late-doc">>).

-define(ORIGIN_BINDINGS, [{'origin_bindings', [[{'type', ?CHANGE_TYPE}]]}]).

amqp_test_() ->
    {'timeout'
    ,10
    ,{'spawn'
     ,{'setup'
      ,fun init/0
      ,fun cleanup/1
      ,fun(_Caches) ->
               [{"erase changed doc", fun erase_changed_doc/0}
               ,{"erase docs in db", fun erase_docs_in_db/0}
               ,{"a first channel flushes the cache that asked for it", fun first_channel_flushes/0}
               ,{"a channel coming back flushes the cache that asked for it", fun reconnect_flushes/0}
               ,{"a flush runs in the cache's own process, and a store asked for meanwhile lands whole after it", fun flush_is_serialised_with_stores/0}
               ]
       end
      }
     }
    }.

init() ->
    {'ok', _Started} = application:ensure_all_started('kazoo_bindings'),
    [start_cache(Name, Props)
     || {Name, Props} <- [{?MODULE, ?ORIGIN_BINDINGS}
                         ,{?FIRST_CHANNEL_CACHE, ['new_channel_flush' | ?ORIGIN_BINDINGS]}
                         ,{?RECONNECT_CACHE, ['channel_reconnect_flush' | ?ORIGIN_BINDINGS]}
                         ,{?SERIAL_CACHE, [{'flush_callback', fun store_while_flushing/1} | ?ORIGIN_BINDINGS]}
                         ]
    ].

start_cache(Name, Props) ->
    {'ok', CachePid} = kz_cache_sup:start_link(Name, ?MILLISECONDS_IN_SECOND, Props),
    CachePid.

cleanup(Caches) ->
    lists:foreach(fun kz_cache:stop_local/1, Caches).

%% The process a test runs in is not the one that ran the setup, so a test
%% that expects to be told things takes the runner's name for itself.
be_the_runner() ->
    _ = (catch unregister(?RUNNER)),
    'true' = register(?RUNNER, self()).

%% The serial cache's flush callback: once per table, in whichever process
%% is flushing. A store is asked for asynchronously from here, which lands
%% whole after the flush only if this is the cache's own process -- from
%% any other, the idle cache server would write it into tables being
%% cleared around it.
store_while_flushing(Table) ->
    ?RUNNER ! {'flushing', Table, self()},
    kz_cache:store_local_async(?SERIAL_CACHE, {?LATE_DB, ?LATE_DOC}, <<"late">>, [{'origin', {'db', ?LATE_DB, ?LATE_DOC}}]).

flush_is_serialised_with_stores() ->
    be_the_runner(),
    Db = kz_binary:rand_hex(5),
    DocId = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),
    cache_doc(?SERIAL_CACHE, Db, DocId, Value),

    kz_cache:flush_local(?SERIAL_CACHE),

    Server = whereis(?SERIAL_CACHE),
    ?assertEqual([Server, Server, Server], flushed_in(3)),
    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?SERIAL_CACHE, {Db, DocId})),

    %% A synchronous store is answered after the queued one is done.
    cache_doc(?SERIAL_CACHE, Db, DocId, Value),
    ?assertEqual({'ok', <<"late">>}, kz_cache:peek_local(?SERIAL_CACHE, {?LATE_DB, ?LATE_DOC})),

    %% Its origin pointer survived too: a change notice still finds it.
    send_document_change(?LATE_DB, ?LATE_DOC, ?DOC_EDITED),
    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?SERIAL_CACHE, {?LATE_DB, ?LATE_DOC})).

flushed_in(0) -> [];
flushed_in(N) ->
    receive {'flushing', _Table, Pid} -> [Pid | flushed_in(N - 1)]
    after 1000 -> ['nobody']
    end.

erase_changed_doc() ->
    Value = kz_binary:rand_hex(5),

    Db = kz_binary:rand_hex(5),
    DocId = kz_binary:rand_hex(5),
    DocId2 = kz_binary:rand_hex(5),

    cache_doc(Db, DocId, Value),
    cache_doc(Db, DocId2, Value),

    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db, DocId})),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db, DocId2})),

    send_document_change(Db, DocId, ?DOC_EDITED),

    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, {Db, DocId})),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db, DocId2})),

    cache_doc(Db, DocId, Value),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db, DocId})),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db, DocId2})),

    send_document_change(Db, DocId, ?DOC_DELETED),
    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, {Db, DocId})),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db, DocId2})).

cache_doc(Db, DocId, Value) ->
    cache_doc(?MODULE, Db, DocId, Value).

cache_doc(Cache, Db, DocId, Value) ->
    CacheProps = [{'origin', {'db', Db, DocId}}],
    kz_cache:store_local(Cache, {Db, DocId}, Value, CacheProps).

%% The listener's consumer came up on a channel: what `gen_listener' tells
%% `kz_cache_listener' once `basic.consume' has been answered, a reconnect
%% or not. Called in this process, so the flush has happened when it returns.
channel_up(Reconnected) ->
    {'noreply', _} = kz_cache_listener:handle_cast({'kz_amqp_channel', {'new_channel', Reconnected}}, 'kz_cache_listener'),
    'ok'.

first_channel_flushes() ->
    Db = kz_binary:rand_hex(5),
    DocId = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),
    [cache_doc(Cache, Db, DocId, Value) || Cache <- [?MODULE, ?FIRST_CHANNEL_CACHE, ?RECONNECT_CACHE]],

    channel_up('false'),

    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?FIRST_CHANNEL_CACHE, {Db, DocId})),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?RECONNECT_CACHE, {Db, DocId})),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db, DocId})).

reconnect_flushes() ->
    Db = kz_binary:rand_hex(5),
    DocId = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),
    [cache_doc(Cache, Db, DocId, Value) || Cache <- [?MODULE, ?FIRST_CHANNEL_CACHE, ?RECONNECT_CACHE]],

    channel_up('true'),

    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?RECONNECT_CACHE, {Db, DocId})),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?FIRST_CHANNEL_CACHE, {Db, DocId})),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db, DocId})).

erase_docs_in_db() ->
    Value = kz_binary:rand_hex(5),

    Db = kz_binary:rand_hex(5),
    Db2 = kz_binary:rand_hex(5),

    DocIds = [kz_binary:rand_hex(5) || _ <- lists:seq(1,5)],

    [begin
         cache_doc(Db, DocId, Value),
         cache_doc(Db2, DocId, Value)
     end
     || DocId <- DocIds
    ],

    [begin
         ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db, DocId})),
         ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db2, DocId}))
     end
     || DocId <- DocIds
    ],

    send_db_change(Db, ?DB_DELETED),

    [?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, {Db, DocId}))
     || DocId <- DocIds
    ],
    [?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, {Db2, DocId}))
     || DocId <- DocIds
    ].

send_db_change(Db, ChangeType) ->
    JObj = create_db_payload(Db, ChangeType),
    RK = kz_amqp_util:document_routing_key(ChangeType, Db, ?CHANGE_TYPE, Db),
    kz_cache_listener:handle_change(JObj, [], RK).

create_db_payload(Db, ChangeType) ->
    kz_json:from_list([{<<"Type">>, <<"database">>}
                      ,{<<"ID">>, Db}
                      ,{<<"Database">>, Db}
                      ,{<<"Msg-ID">>, kz_binary:rand_hex(5)}
                      | kz_api:default_headers(?KAPI_CONF_CATEGORY, ChangeType, <<"test">>, <<"1">>)
                      ]).

send_document_change(Db, DocId, ChangeType) ->
    JObj = create_payload_json(Db, DocId, ChangeType),
    RK = kz_amqp_util:document_routing_key(ChangeType, Db, ?CHANGE_TYPE, DocId),
    kz_cache_listener:handle_change(JObj, [], RK).

create_payload_json(Db, DocId, ChangeType) ->
    kz_json:from_list([{<<"ID">>, DocId}
                      ,{<<"Database">>, Db}
                      ,{<<"Type">>, ?CHANGE_TYPE}
                      ,{<<"Msg-ID">>, kz_binary:rand_hex(5)}
                      | kz_api:default_headers(?KAPI_CONF_CATEGORY, ChangeType, <<"test">>, <<"1">>)
                      ]).
