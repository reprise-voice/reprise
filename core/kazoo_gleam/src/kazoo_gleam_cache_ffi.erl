%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc Node-local caches, in ETS.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% One named table per cache, created on first use and owned by a process of
%%% its own so it outlives whichever request happened to touch it first. What
%%% is stored is whatever the caller stored; `kazoo/cache' is what makes that
%%% one type per table.
%%%
%%% Two shapes: entries that never go stale, and entries stamped with a
%%% monotonic clock and read back with a time to live.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_cache_ffi).

-export([get/2
        ,put/3
        ,delete/2
        ,clear/1
        ,get_fresh/3
        ,put_fresh/3
        ,first_in/4
        ,size/1
        ,sweep/3
        ]).

%% @doc What is stored under `Key', if anything is.
-spec get(binary(), binary()) -> {'ok', term()} | {'error', 'nil'}.
get(Table, Key) ->
    Name = ensure(Table),
    case ets:lookup(Name, Key) of
        [{_, Value}] -> {'ok', Value};
        _Other -> {'error', 'nil'}
    end.

-spec put(binary(), binary(), term()) -> 'nil'.
put(Table, Key, Value) ->
    Name = ensure(Table),
    'true' = ets:insert(Name, {Key, Value}),
    'nil'.

-spec delete(binary(), binary()) -> 'nil'.
delete(Table, Key) ->
    Name = ensure(Table),
    'true' = ets:delete(Name, Key),
    'nil'.

%% @doc Forget everything in the table. The table itself stays.
-spec clear(binary()) -> 'nil'.
clear(Table) ->
    Name = ensure(Table),
    'true' = ets:delete_all_objects(Name),
    'nil'.

%% @doc What is stored under `Key', if it was stored less than `TtlMs' ago.
-spec get_fresh(binary(), binary(), integer()) -> {'ok', term()} | {'error', 'nil'}.
get_fresh(Table, Key, TtlMs) ->
    Name = ensure(Table),
    Now = monotonic_ms(),
    case ets:lookup(Name, Key) of
        [{_, Value, At}] when Now - At < TtlMs -> {'ok', Value};
        _Other -> {'error', 'nil'}
    end.

-spec put_fresh(binary(), binary(), term()) -> 'nil'.
put_fresh(Table, Key, Value) ->
    Name = ensure(Table),
    'true' = ets:insert(Name, {Key, Value, monotonic_ms()}),
    'nil'.

%% @doc Whether `Key' has not been seen in the last `IntervalSeconds',
%% remembering that it has been seen at `Now'. A throttle: the first caller in
%% each interval gets `true' and every other one gets `false'.
%%
%% `Now' is the caller's own clock rather than this module's, so a test that
%% holds time still holds this still too.
-spec first_in(binary(), binary(), integer(), integer()) -> boolean().
first_in(Table, Key, Now, IntervalSeconds) ->
    Name = ensure(Table),
    case ets:lookup(Name, Key) of
        [{_, At}] when Now - At < IntervalSeconds -> 'false';
        _Other ->
            'true' = ets:insert(Name, {Key, Now}),
            'true'
    end.

%% @doc How many entries the table holds, fresh or not.
-spec size(binary()) -> non_neg_integer().
size(Table) ->
    Name = ensure(Table),
    case ets:info(Name, 'size') of
        N when is_integer(N) -> N;
        _ -> 0
    end.

%% @doc Drop every `put_fresh' entry older than `TtlMs', then, if more than
%% `Keep' entries remain, the oldest of those too. One atomic pass per
%% predicate over the table (`ets:select_delete'), so it is safe to call from
%% any process while others insert; the trim to `Keep' is a second pass that
%% may over- or under-shoot by the inserts that land during it, which is
%% what a bound on a cache can afford. Answers how many entries went.
-spec sweep(binary(), integer(), non_neg_integer()) -> non_neg_integer().
sweep(Table, TtlMs, Keep) ->
    Name = ensure(Table),
    Cutoff = monotonic_ms() - TtlMs,
    Expired = ets:select_delete(Name, [{{'_', '_', '$1'}, [{'=<', '$1', Cutoff}], ['true']}]),
    Excess = size(Table) - Keep,
    Trimmed = case Excess > 0 of
                  'false' -> 0;
                  'true' ->
                      %% Oldest first; the key breaks ties between entries
                      %% stamped in the same millisecond, so exactly
                      %% `Excess' go.
                      Rows = lists:sort(ets:select(Name, [{{'$1', '_', '$2'}, [], [{{'$2', '$1'}}]}])),
                      Doomed = lists:sublist(Rows, Excess),
                      lists:foldl(fun({_At, Key}, N) -> ets:delete(Name, Key), N + 1 end, 0, Doomed)
              end,
    Expired + Trimmed.

-spec monotonic_ms() -> integer().
monotonic_ms() ->
    erlang:convert_time_unit(erlang:monotonic_time(), 'native', 'millisecond').

%% Table names come from Gleam literals, so the atom table gains one entry per
%% cache in the release and no more.
-spec ensure(binary()) -> atom().
ensure(Table) ->
    Name = erlang:binary_to_atom(Table, 'utf8'),
    case ets:whereis(Name) of
        'undefined' -> _ = create(Name), Name;
        _Tid -> Name
    end.

%% @doc The table outlives the request that first needed it, so it is owned by
%% a process of its own rather than by whichever caller got there first.
-spec create(atom()) -> ets:tid() | atom() | 'undefined'.
create(Name) ->
    Caller = self(),
    Pid = spawn(fun() ->
                        try ets:new(Name, ['set', 'public', 'named_table'
                                          ,{'write_concurrency', 'true'}
                                          ,{'read_concurrency', 'true'}
                                          ]) of
                            Tid ->
                                Caller ! {'table', self(), Tid},
                                receive 'stop' -> 'ok' end
                        catch
                            _E:_R ->
                                Caller ! {'table', self(), ets:whereis(Name)},
                                'ok'
                        end
                end),
    receive
        {'table', Pid, Tid} -> Tid
    after 1000 -> ets:whereis(Name)
    end.
