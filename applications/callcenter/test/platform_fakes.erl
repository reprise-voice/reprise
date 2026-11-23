%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% Just enough of the platform for the Erlang edges of the application to be
%% tested under `gleam test', which has none of it on the code path.
%%
%% `kapi_callcenter', `webhooks_callcenter' and `bh_callcenter' call
%% `kapi_definition', `kz_api', `kz_json', `props', `kz_amqp_util',
%% `webhooks_util', `bh_context' and a few more by name. Each of those has a
%% stand-in here, `fake_<module>', compiled with the rest of the tests; `start/0'
%% loads every stand-in under the real module's name and `stop/1' unloads them
%% again, so a test that asks for the platform has it for the length of its
%% fixture and every other test in the suite goes on running without it,
%% which is what the Gleam side's "outside a release" paths are written for.
%%
%% The stand-ins are faithful where a test reads the answer -- the header
%% checks `kz_api:validate/4' makes, `kz_json''s object shape and
%% `normalize_jobj' -- and record everything that would have gone to the
%% broker or the datastore, which a test reads back with `calls/1'.
%%
%% Renaming is done on the stand-in's own abstract code, which the Gleam
%% compiler keeps in every beam, so the stand-ins are ordinary modules that
%% compile with the suite and fail to build if they are wrong.
-module(platform_fakes).

-export([start/0, stop/1
        ,record/3, calls/1, all_calls/1, clear/0, clear_calls/0
        ,set/2, get/2
        ,published/0, targeted/0
        ]).

-define(TABLE, ?MODULE).

-define(FAKES, ['bh_context'
               ,'blackhole_bindings'
               ,'kapi_definition'
               ,'kapps_config'
               ,'kz_amqp_util'
               ,'kz_amqp_worker'
               ,'kz_api'
               ,'kz_binary'
               ,'kz_json'
               ,'kz_term'
               ,'lager'
               ,'props'
               ,'webhooks_util'
               ]).

%% Load every stand-in, and the table they record into. The table belongs to
%% a process of its own: eunit may run a fixture's setup, its tests and its
%% cleanup in different processes.
-spec start() -> pid().
start() ->
    Parent = self(),
    Holder = spawn(fun() ->
                           _ = ets:new(?TABLE, ['named_table', 'public', 'ordered_set']),
                           Parent ! {?MODULE, 'ready'},
                           receive {?MODULE, 'stop'} -> 'ok' end
                   end),
    receive {?MODULE, 'ready'} -> 'ok' end,
    lists:foreach(fun load/1, ?FAKES),
    Holder.

-spec stop(pid()) -> 'ok'.
stop(Holder) ->
    lists:foreach(fun unload/1, ?FAKES),
    Ref = erlang:monitor('process', Holder),
    Holder ! {?MODULE, 'stop'},
    receive {'DOWN', Ref, 'process', Holder, _} -> 'ok' end.

-spec record(atom(), atom(), list()) -> 'ok'.
record(Module, Function, Args) ->
    Key = {'call', erlang:unique_integer(['monotonic'])},
    'true' = ets:insert(?TABLE, {Key, self(), Module, Function, Args}),
    'ok'.

%% What this process asked of one stand-in, oldest first, as
%% `{Function, Args}'. A dispatcher an earlier test left running may publish
%% while a fixture is up; what it did is not this test's.
-spec calls(atom()) -> [{atom(), list()}].
calls(Module) ->
    Self = self(),
    [{Function, Args}
     || {{'call', _}, Pid, M, Function, Args} <- ets:tab2list(?TABLE),
        M =:= Module,
        Pid =:= Self
    ].

%% The same, from every process.
-spec all_calls(atom()) -> [{atom(), list()}].
all_calls(Module) ->
    [{Function, Args}
     || {{'call', _}, _Pid, M, Function, Args} <- ets:tab2list(?TABLE),
        M =:= Module
    ].

%% Every publish this process made to an exchange, as `{Exchange, RoutingKey}'.
-spec published() -> [{binary(), binary()}].
published() ->
    [{Exchange, RoutingKey}
     || {'basic_publish', [Exchange, RoutingKey | _]} <- calls('kz_amqp_util')
    ].

%% Every publish this process made straight to one queue, as the queue.
-spec targeted() -> [binary()].
targeted() ->
    [Queue || {'targeted_publish', [Queue | _]} <- calls('kz_amqp_util')].

%% Forget everything recorded and everything set.
-spec clear() -> 'ok'.
clear() ->
    'true' = ets:delete_all_objects(?TABLE),
    'ok'.

%% Forget what was recorded, and keep what was set.
-spec clear_calls() -> 'ok'.
clear_calls() ->
    'true' = ets:match_delete(?TABLE, {{'call', '_'}, '_', '_', '_', '_'}),
    'ok'.

%% What a stand-in answers when it is asked something only a test can
%% know: the hooks an account has, for one.
-spec set(term(), term()) -> 'ok'.
set(Key, Value) ->
    'true' = ets:insert(?TABLE, {{'set', Key}, Value}),
    'ok'.

-spec get(term(), term()) -> term().
get(Key, Default) ->
    case ets:lookup(?TABLE, {'set', Key}) of
        [{_, Value}] -> Value;
        [] -> Default
    end.

load(Module) ->
    Fake = list_to_atom("fake_" ++ atom_to_list(Module)),
    {'ok', {Fake, [{'debug_info', {'debug_info_v1', Backend, Data}}]}} =
        beam_lib:chunks(code:which(Fake), ['debug_info']),
    {'ok', Forms} = Backend:debug_info('erlang_v1', Fake, Data, []),
    Renamed = [rename(Form, Module) || Form <- Forms],
    {'ok', Module, Binary} = compile:forms(Renamed, ['binary', 'return_errors']),
    {'module', Module} = code:load_binary(Module, "platform_fakes", Binary),
    'ok'.

rename({'attribute', Anno, 'module', _Fake}, Module) ->
    {'attribute', Anno, 'module', Module};
rename(Form, _Module) -> Form.

unload(Module) ->
    _ = code:purge(Module),
    _ = code:delete(Module),
    _ = code:purge(Module),
    'ok'.
