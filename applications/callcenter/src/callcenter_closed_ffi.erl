%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The passages this node's dispatchers closed lately: one ETS table the
%%% whole node shares, for `callcenter/closed'.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% Compiled by the Gleam compiler, like every FFI module of the application:
%%% no parse transform and no Kazoo header. Every function but `create/0' is
%%% a no-op, or finds nothing, when the table is not there -- a test that
%%% never made one, or the moment between its owner stopping and starting
%%% again -- because a dispatcher closing a call must not crash over a note.
%%% @end
%%%-----------------------------------------------------------------------------
-module(callcenter_closed_ffi).

-export([create/0
        ,delete/0
        ,put/3
        ,find/1
        ,forget_before/1
        ]).

-define(TABLE, 'callcenter_closed_passages').

%% @doc Make the table, owned by the calling process, unless it is there.
-spec create() -> 'nil'.
create() ->
    case ets:whereis(?TABLE) of
        'undefined' ->
            _ = ets:new(?TABLE, ['named_table'
                                ,'public'
                                ,'set'
                                ,{'read_concurrency', 'true'}
                                ,{'write_concurrency', 'true'}
                                ]),
            'nil';
        _Tid -> 'nil'
    end.

-spec delete() -> 'nil'.
delete() ->
    try ets:delete(?TABLE) of
        _ -> 'nil'
    catch
        'error':'badarg' -> 'nil'
    end.

%% @doc Note one passage: its id, what the close was, and the second noted.
-spec put(binary(), any(), integer()) -> 'nil'.
put(Id, Value, At) ->
    try ets:insert(?TABLE, {Id, Value, At}) of
        _ -> 'nil'
    catch
        'error':'badarg' -> 'nil'
    end.

-spec find(binary()) -> {'ok', any()} | {'error', 'nil'}.
find(Id) ->
    try ets:lookup(?TABLE, Id) of
        [{Id, Value, _At}] -> {'ok', Value};
        [] -> {'error', 'nil'}
    catch
        'error':'badarg' -> {'error', 'nil'}
    end.

%% @doc Forget every passage noted before a second; how many went.
-spec forget_before(integer()) -> non_neg_integer().
forget_before(Second) ->
    Spec = [{{'_', '_', '$1'}, [{'<', '$1', Second}], ['true']}],
    try ets:select_delete(?TABLE, Spec)
    catch
        'error':'badarg' -> 0
    end.
