%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The Erlang side of `kazoo/callflow': what an action says back to
%%% `cf_exe'.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% `cf_exe' spawns an action and waits. The action has to end by telling it
%%% what to do next; an action that simply returns leaves the caller with a
%%% dead flow and the channel is hung up. Those endings are the first half of
%%% this module.
%%%
%%% The `Data' argument `cf_exe' hands to `handle/2' is a `kz_json' object,
%%% which is the one place a Gleam callflow action meets one. `data/1' is the
%%% conversion, and it is the first thing an action should call.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_callflow_ffi).

-export([data/1
        ,continue/1
        ,continue_branch/2
        ,continue_with_flow/2
        ,branch/2
        ,stop/1
        ,stop_with_cause/2
        ,transfer/1
        ,control_usurped/1
        ,get_call/1
        ,set_call/1
        ,update_call/1
        ,control_queue/1
        ,queue_name/1
        ,call_id/1
        ,add_event_listener/3
        ,add_termination_handler/4
        ,add_call_binding/2
        ,is_channel_destroyed/1
        ,is_action/1
        ]).

%% @doc The action's `Data' as a map. This is the only `kz_json' object a
%% callflow action is handed, and nothing else in Gleam should ever see one.
-spec data(any()) -> map().
data(Data) ->
    case loaded('kz_json')
        andalso kz_json:is_json_object(Data)
    of
        'true' -> kz_json:to_map(Data);
        'false' -> as_map(Data)
    end.

-spec as_map(any()) -> map().
as_map(Data) when is_map(Data) -> Data;
as_map(_Data) -> #{}.

%%%=============================================================================
%%% Endings
%%%
%%% Exactly one of these has to run before the action returns.
%%%=============================================================================

%% @doc Take the flow's `_' child.
-spec continue(any()) -> 'nil'.
continue(Call) -> tell(<<"continue">>, fun() -> cf_exe:continue(Call) end).

%% @doc Take the named child, falling back to `_' when the flow has no such
%% branch.
-spec continue_branch(any(), binary()) -> 'nil'.
continue_branch(Call, Key) ->
    tell(<<"continue_branch">>, fun() -> cf_exe:continue(Key, Call) end).

%% @doc Carry on into a flow built here rather than one of this action's own
%% children.
-spec continue_with_flow(any(), binary()) -> 'nil'.
continue_with_flow(Call, FlowJson) ->
    tell(<<"continue_with_flow">>, fun() -> cf_exe:continue_with_flow(decode(FlowJson), Call) end).

%% @doc Run a flow and come back to this one's children afterwards.
-spec branch(any(), binary()) -> 'nil'.
branch(Call, FlowJson) ->
    tell(<<"branch">>, fun() -> cf_exe:branch(decode(FlowJson), Call) end).

%% @doc End the flow and hang the channel up.
-spec stop(any()) -> 'nil'.
stop(Call) -> tell(<<"stop">>, fun() -> cf_exe:stop(Call) end).

%% @doc End the flow with the hangup cause the CDR should carry, e.g.
%% `USER_BUSY' or `NORMAL_CLEARING'.
-spec stop_with_cause(any(), binary()) -> 'nil'.
stop_with_cause(Call, Cause) ->
    tell(<<"stop_with_cause">>, fun() -> cf_exe:stop(Call, Cause) end).

%% @doc End the flow because the channel is being transferred: the flow stops
%% but the channel is left alone.
-spec transfer(any()) -> 'nil'.
transfer(Call) -> tell(<<"transfer">>, fun() -> cf_exe:transfer(Call) end).

%% @doc End the flow because another process has taken control of the
%% channel.
-spec control_usurped(any()) -> 'nil'.
control_usurped(Call) -> tell(<<"control_usurped">>, fun() -> cf_exe:control_usurped(Call) end).

%%%=============================================================================
%%% The flow's own state
%%%=============================================================================

%% @doc The call as `cf_exe' has it, which is newer than the copy the action
%% was spawned with whenever another action has changed it.
-spec get_call(any()) -> any().
get_call(Call) ->
    case loaded('cf_exe') of
        'false' -> Call;
        'true' ->
            try cf_exe:get_call(Call) of
                {'ok', Updated} -> Updated;
                _Other -> Call
            catch
                _E:_R -> Call
            end
    end.

%% @doc Hand `cf_exe' a call the action has changed, so the actions after it
%% see the change.
-spec set_call(any()) -> 'nil'.
set_call(Call) -> tell(fun() -> cf_exe:set_call(Call) end).

%% @doc Merge this action's changes into `cf_exe''s copy and take the result.
-spec update_call(any()) -> any().
update_call(Call) ->
    case loaded('cf_exe') of
        'false' -> Call;
        'true' ->
            try cf_exe:update_call(Call) of
                Updated -> Updated
            catch
                _E:_R -> Call
            end
    end.

%% @doc The queue commands for this channel go to.
-spec control_queue(any()) -> {'ok', binary()} | {'error', 'nil'}.
control_queue(Call) ->
    from_exe(Call, 'control_queue', <<"control_queue">>).

%% @doc The queue `cf_exe' consumes from, which is what a reply to a command
%% is addressed to.
-spec queue_name(any()) -> {'ok', binary()} | {'error', 'nil'}.
queue_name(Call) ->
    from_exe(Call, 'queue_name', <<"controller_queue">>).

-spec call_id(any()) -> {'ok', binary()} | {'error', 'nil'}.
call_id(Call) ->
    from_exe(Call, 'callid', <<"call_id">>).

%% @doc Start a process, under the callflow's own supervisor, that receives
%% this call's events for as long as the flow runs. `cf_exe' starts it as
%% `Module:start_link(Call, Args...)'.
-spec add_event_listener(any(), binary(), binary()) -> 'nil'.
add_event_listener(Call, Module, ArgsJson) ->
    tell(fun() ->
                 cf_exe:add_event_listener(Call
                                          ,{binary_to_atom(Module, 'utf8')
                                           ,decode_list(ArgsJson)
                                           }
                                          )
         end).

%% @doc Run `Module:Function(Call, HangupEvent, Args...)' when the flow ends,
%% whatever ends it: the extra arguments are spliced, so with none the
%% function has arity two. `Module' is applied by name, so a Gleam module
%% works: its compiled name is the Gleam module path with `/' replaced by
%% `@', which for a module at the top of `src' is just its name.
-spec add_termination_handler(any(), binary(), binary(), binary()) -> 'nil'.
add_termination_handler(Call, Module, Function, ArgsJson) ->
    tell(fun() ->
                 cf_exe:add_termination_handler(Call
                                               ,{binary_to_atom(Module, 'utf8')
                                                ,binary_to_atom(Function, 'utf8')
                                                ,decode_list(ArgsJson)
                                                }
                                               )
         end).

%% @doc Have `cf_exe' consume another call's events as well as this one's,
%% and forward them to the running action. The argument is that call's id,
%% which is how an action follows the leg it just created.
-spec add_call_binding(any(), binary()) -> 'nil'.
add_call_binding(Call, CallId) ->
    tell(fun() -> cf_exe:add_call_binding(Call, CallId) end).

%% @doc Whether the channel is already gone. An action that has been waiting
%% should ask before it sends anything else.
-spec is_channel_destroyed(any()) -> boolean().
is_channel_destroyed(Call) ->
    case loaded('cf_exe') of
        'false' -> 'false';
        'true' ->
            try cf_exe:is_channel_destroyed(Call) of
                Destroyed when is_boolean(Destroyed) -> Destroyed;
                _Other -> 'false'
            catch
                _E:_R -> 'false'
            end
    end.

%% @doc Whether `cf_exe' would resolve a callflow action of this name to a
%% module and run it: the module exists and exports `handle/2'. This is the
%% same test `cf_exe:find_cf_module/2' makes.
-spec is_action(binary()) -> boolean().
is_action(Action) ->
    Module = binary_to_atom(<<"cf_", Action/binary>>, 'utf8'),
    case code:ensure_loaded(Module) of
        {'error', _Reason} -> 'false';
        {'module', Module} -> erlang:function_exported(Module, 'handle', 2)
    end.

%%%=============================================================================
%%% Internal
%%%=============================================================================

%% @doc A read that `cf_exe' answers, falling back to the call record itself
%% when there is no flow running, which is what a test has.
-spec from_exe(any(), atom(), binary()) -> {'ok', binary()} | {'error', 'nil'}.
from_exe(Call, Function, Field) ->
    case loaded('cf_exe') of
        'false' -> kazoo_gleam_call_ffi:get(Call, Field);
        'true' ->
            try cf_exe:Function(Call) of
                Value when is_binary(Value)
                           andalso Value =/= <<>> -> {'ok', Value};
                _Other -> kazoo_gleam_call_ffi:get(Call, Field)
            catch
                _E:_R -> kazoo_gleam_call_ffi:get(Call, Field)
            end
    end.

%% @doc An ending, kept for a test that is recording the channel before it
%% is told to `cf_exe'. See `kazoo/testing/channel'.
-spec tell(binary(), fun(() -> any())) -> 'nil'.
tell(Name, Fun) ->
    kazoo_gleam_call_ffi:note(Name, <<>>),
    tell(Fun).

-spec tell(fun(() -> any())) -> 'nil'.
tell(Fun) ->
    _ = case loaded('cf_exe') of
            'false' -> 'ok';
            'true' ->
                try Fun()
                catch
                    _E:_R -> 'ok'
                end
        end,
    'nil'.

-spec loaded(atom()) -> boolean().
loaded(Module) ->
    case code:ensure_loaded(Module) of
        {'module', Module} -> 'true';
        {'error', _Reason} -> 'false'
    end.

-spec decode(binary()) -> any().
decode(Json) ->
    case loaded('kz_json') of
        'false' -> json:decode(Json);
        'true' -> kz_json:from_map(as_map(json:decode(Json)))
    end.

-spec decode_list(binary()) -> list().
decode_list(Json) ->
    case json:decode(Json) of
        List when is_list(List) -> List;
        _Other -> []
    end.
