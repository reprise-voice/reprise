%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc What lets a Crossbar module be written in Gleam: one Erlang module
%%% Crossbar binds instead of the Gleam one, which dispatches by arity.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% Crossbar binds one routing key per noun and per phase -- there is one
%%% `*.validate.queues' binding, not one per path length -- and applies the
%%% bound function to the whole payload. The payload for `/queues' is one
%%% element long and the payload for `/queues/{id}/agents' is three, so a
%%% Crossbar module has to export `validate/1', `validate/2' and
%%% `validate/3'. Gleam gives a function one arity, so a Gleam module cannot.
%%%
%%% Two mechanisms close the gap, both of them Crossbar's own.
%%%
%%% The phases run through `kazoo_bindings:map/2' and `pmap/2' --
%%% `allowed_methods', `resource_exists', `authenticate', `authorize' --
%%% accept a `fun/1' as the bound responder and hand it the payload as a
%%% list (`apply_map_responder/3'). A closure over the noun is bound for
%%% those, and the arity question never arises.
%%%
%%% The phases that run through `fold/2' -- `validate', `execute.*' and
%%% `content_types_provided' -- have no such clause: `fold_bind_results/5'
%%% applies `{Module, Function}' with `erlang:apply/3', which needs a real
%%% exported function of exactly the payload's length. So this module exports
%%% those names at every arity Crossbar can call, finds the noun in the
%%% context, looks the Gleam handler up by it, and calls the handler with the
%%% path tokens as a list.
%%%
%%% The consequence to know about: the fold-phase bindings of a Gleam
%%% Crossbar module belong to this module, not to the `cb_' one, so
%%% `crossbar_bindings:flush_mod/1' on the Gleam module drops only its
%%% map-phase bindings.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_cb).

-export([bind/4
        ,handlers/0
        ]).

%% The fold phases, at every arity Crossbar reaches them with: the context
%% and up to four path tokens.
-export([content_types_provided/1, content_types_provided/2, content_types_provided/3, content_types_provided/4, content_types_provided/5]).
-export([validate/1, validate/2, validate/3, validate/4, validate/5]).
-export([execute_put/1, execute_put/2, execute_put/3, execute_put/4, execute_put/5]).
-export([execute_post/1, execute_post/2, execute_post/3, execute_post/4, execute_post/5]).
-export([execute_patch/1, execute_patch/2, execute_patch/3, execute_patch/4, execute_patch/5]).
-export([execute_delete/1, execute_delete/2, execute_delete/3, execute_delete/4, execute_delete/5]).

%% Where the handlers live. One table, keyed by noun and phase.
-define(TABLE, <<"kazoo_gleam_cb">>).

%%%=============================================================================
%%% Registration
%%%=============================================================================

%% @doc Remember `Handler' as what answers `Phase' for `Noun', and tell
%% Crossbar to route `Binding' here. `Module' is the Gleam Crossbar module's
%% own name, which is what `crossbar_bindings:modules_loaded/0' reports for
%% the phases that can carry it.
-spec bind(binary(), binary(), binary(), fun()) -> 'nil'.
bind(Noun, Phase, Binding, Handler) ->
    _ = kazoo_gleam_cache_ffi:put(?TABLE, key(Noun, Phase), Handler),
    _ = case loaded('crossbar_bindings') of
            'false' -> 'ok';
            'true' -> bind_phase(Noun, Phase, Binding)
        end,
    'nil'.

-spec bind_phase(binary(), binary(), binary()) -> any().
bind_phase(Noun, <<"allowed_methods">> = Phase, Binding) ->
    crossbar_bindings:bind(Binding
                          ,module(Noun)
                          ,fun(Tokens) -> allowed_methods(Noun, Phase, Tokens) end
                          );
bind_phase(Noun, <<"resource_exists">> = Phase, Binding) ->
    crossbar_bindings:bind(Binding
                          ,module(Noun)
                          ,fun(Tokens) -> resource_exists(Noun, Phase, Tokens) end
                          );
bind_phase(Noun, <<"authenticate">> = Phase, Binding) ->
    crossbar_bindings:bind(Binding, module(Noun), context_predicate(Noun, Phase));
bind_phase(Noun, <<"authorize">> = Phase, Binding) ->
    crossbar_bindings:bind(Binding, module(Noun), authorize_predicate(Noun, Phase));
bind_phase(_Noun, Phase, Binding) ->
    crossbar_bindings:bind(Binding, ?MODULE, fold_function(Phase)).

%% @doc The exported name this module answers a fold phase under.
-spec fold_function(binary()) -> atom().
fold_function(<<"content_types_provided">>) -> 'content_types_provided';
fold_function(<<"validate">>) -> 'validate';
fold_function(<<"put">>) -> 'execute_put';
fold_function(<<"post">>) -> 'execute_post';
fold_function(<<"patch">>) -> 'execute_patch';
fold_function(<<"delete">>) -> 'execute_delete'.

%% @doc The noun's own Crossbar module, by the convention every Crossbar
%% module follows. It owns the map-phase bindings so that Crossbar's own
%% bookkeeping, which only knows modules named `cb_...', still sees them.
-spec module(binary()) -> atom().
module(Noun) -> binary_to_atom(<<"cb_", Noun/binary>>, 'utf8').

%% @doc Every handler registered on this node, as `{Noun, Phase}' pairs. For
%% `sup' and for a test that wants to see what a module bound.
-spec handlers() -> [{binary(), binary()}].
handlers() ->
    Table = binary_to_atom(?TABLE, 'utf8'),
    case ets:whereis(Table) of
        'undefined' -> [];
        _Tid ->
            [split(Key) || {Key, _Handler} <- ets:tab2list(Table)]
    end.

-spec split(binary()) -> {binary(), binary()}.
split(Key) ->
    [Noun, Phase] = binary:split(Key, <<"|">>),
    {Noun, Phase}.

-spec key(binary(), binary()) -> binary().
key(Noun, Phase) -> <<Noun/binary, "|", Phase/binary>>.

%%%=============================================================================
%%% The map phases
%%%=============================================================================

-spec allowed_methods(binary(), binary(), [binary()]) -> [binary()].
allowed_methods(Noun, Phase, Tokens) ->
    case handler(Noun, Phase) of
        {'ok', Handler} -> Handler(Tokens);
        {'error', _} -> []
    end.

-spec resource_exists(binary(), binary(), [binary()]) -> boolean().
resource_exists(Noun, Phase, Tokens) ->
    case handler(Noun, Phase) of
        {'ok', Handler} -> Handler(Tokens);
        {'error', _} -> 'false'
    end.

%% @doc `authenticate' and `authorize' are mapped over a payload of one, the
%% context.
-spec context_predicate(binary(), binary()) -> fun((list()) -> boolean()).
context_predicate(Noun, Phase) ->
    fun([Context | _]) ->
            case handler(Noun, Phase) of
                {'ok', Handler} -> Handler(Context);
                {'error', _} -> 'false'
            end;
       (_Other) -> 'false'
    end.

%% @doc `authorize' is mapped the same way, but a `false' from a Gleam
%% handler has to be binding. Crossbar's own authorization (`cb_simple_authz')
%% has usually already said `true' for an account admin on an account path,
%% and `api_util:is_permitted_verb_on_module/3' then ignores a plain `false'
%% from the noun's binding: only `{stop, Context}' denies. So a `false' here
%% answers a stopped context carrying `forbidden', which is what a Gleam
%% module means by it. `true' allows.
-spec authorize_predicate(binary(), binary()) -> fun((list()) -> boolean() | {'stop', any()}).
authorize_predicate(Noun, Phase) ->
    fun([Context | _]) ->
            case handler(Noun, Phase) of
                {'ok', Handler} ->
                    case Handler(Context) of
                        'true' -> 'true';
                        'false' -> forbidden(Context)
                    end;
                %% No handler is not permission: a module whose authorize
                %% cannot be found denies, the same way a `false' does.
                {'error', _} -> forbidden(Context)
            end;
       (_Other) -> 'false'
    end.

-spec forbidden(any()) -> {'stop', any()} | 'false'.
forbidden(Context) ->
    case loaded('cb_context') of
        'true' -> {'stop', cb_context:add_system_error('forbidden', Context)};
        'false' -> 'false'
    end.

%%%=============================================================================
%%% The fold phases
%%%
%%% Crossbar applies these with the context first and the path tokens after
%%% it, so there is one clause per path length. Each hands the tokens to the
%%% Gleam handler as one list.
%%%=============================================================================

-spec content_types_provided(any()) -> any().
content_types_provided(Context) -> fold(Context, <<"content_types_provided">>, []).

-spec content_types_provided(any(), binary()) -> any().
content_types_provided(Context, A) -> fold(Context, <<"content_types_provided">>, [A]).

-spec content_types_provided(any(), binary(), binary()) -> any().
content_types_provided(Context, A, B) -> fold(Context, <<"content_types_provided">>, [A, B]).

-spec content_types_provided(any(), binary(), binary(), binary()) -> any().
content_types_provided(Context, A, B, C) -> fold(Context, <<"content_types_provided">>, [A, B, C]).

-spec content_types_provided(any(), binary(), binary(), binary(), binary()) -> any().
content_types_provided(Context, A, B, C, D) -> fold(Context, <<"content_types_provided">>, [A, B, C, D]).

-spec validate(any()) -> any().
validate(Context) -> fold(Context, <<"validate">>, []).

-spec validate(any(), binary()) -> any().
validate(Context, A) -> fold(Context, <<"validate">>, [A]).

-spec validate(any(), binary(), binary()) -> any().
validate(Context, A, B) -> fold(Context, <<"validate">>, [A, B]).

-spec validate(any(), binary(), binary(), binary()) -> any().
validate(Context, A, B, C) -> fold(Context, <<"validate">>, [A, B, C]).

-spec validate(any(), binary(), binary(), binary(), binary()) -> any().
validate(Context, A, B, C, D) -> fold(Context, <<"validate">>, [A, B, C, D]).

-spec execute_put(any()) -> any().
execute_put(Context) -> fold(Context, <<"put">>, []).

-spec execute_put(any(), binary()) -> any().
execute_put(Context, A) -> fold(Context, <<"put">>, [A]).

-spec execute_put(any(), binary(), binary()) -> any().
execute_put(Context, A, B) -> fold(Context, <<"put">>, [A, B]).

-spec execute_put(any(), binary(), binary(), binary()) -> any().
execute_put(Context, A, B, C) -> fold(Context, <<"put">>, [A, B, C]).

-spec execute_put(any(), binary(), binary(), binary(), binary()) -> any().
execute_put(Context, A, B, C, D) -> fold(Context, <<"put">>, [A, B, C, D]).

-spec execute_post(any()) -> any().
execute_post(Context) -> fold(Context, <<"post">>, []).

-spec execute_post(any(), binary()) -> any().
execute_post(Context, A) -> fold(Context, <<"post">>, [A]).

-spec execute_post(any(), binary(), binary()) -> any().
execute_post(Context, A, B) -> fold(Context, <<"post">>, [A, B]).

-spec execute_post(any(), binary(), binary(), binary()) -> any().
execute_post(Context, A, B, C) -> fold(Context, <<"post">>, [A, B, C]).

-spec execute_post(any(), binary(), binary(), binary(), binary()) -> any().
execute_post(Context, A, B, C, D) -> fold(Context, <<"post">>, [A, B, C, D]).

-spec execute_patch(any()) -> any().
execute_patch(Context) -> fold(Context, <<"patch">>, []).

-spec execute_patch(any(), binary()) -> any().
execute_patch(Context, A) -> fold(Context, <<"patch">>, [A]).

-spec execute_patch(any(), binary(), binary()) -> any().
execute_patch(Context, A, B) -> fold(Context, <<"patch">>, [A, B]).

-spec execute_patch(any(), binary(), binary(), binary()) -> any().
execute_patch(Context, A, B, C) -> fold(Context, <<"patch">>, [A, B, C]).

-spec execute_patch(any(), binary(), binary(), binary(), binary()) -> any().
execute_patch(Context, A, B, C, D) -> fold(Context, <<"patch">>, [A, B, C, D]).

-spec execute_delete(any()) -> any().
execute_delete(Context) -> fold(Context, <<"delete">>, []).

-spec execute_delete(any(), binary()) -> any().
execute_delete(Context, A) -> fold(Context, <<"delete">>, [A]).

-spec execute_delete(any(), binary(), binary()) -> any().
execute_delete(Context, A, B) -> fold(Context, <<"delete">>, [A, B]).

-spec execute_delete(any(), binary(), binary(), binary()) -> any().
execute_delete(Context, A, B, C) -> fold(Context, <<"delete">>, [A, B, C]).

-spec execute_delete(any(), binary(), binary(), binary(), binary()) -> any().
execute_delete(Context, A, B, C, D) -> fold(Context, <<"delete">>, [A, B, C, D]).

%% @doc Which noun this context is a request for, and therefore whose handler
%% answers. Crossbar folds over the first of `req_nouns', which is the
%% deepest one in the path.
-spec fold(any(), binary(), [binary()]) -> any().
fold(Context, Phase, Tokens) ->
    case handler(noun(Context), Phase) of
        {'ok', Handler} -> Handler(Context, Tokens);
        {'error', _} -> Context
    end.

-spec noun(any()) -> binary().
noun(Context) ->
    case loaded('cb_context') of
        'false' -> <<>>;
        'true' ->
            try cb_context:req_nouns(Context) of
                [{Noun, _Params} | _] -> Noun;
                _Other -> <<>>
            catch
                _E:_R -> <<>>
            end
    end.

-spec handler(binary(), binary()) -> {'ok', fun()} | {'error', 'nil'}.
handler(Noun, Phase) -> kazoo_gleam_cache_ffi:get(?TABLE, key(Noun, Phase)).

-spec loaded(atom()) -> boolean().
loaded(Module) ->
    case code:ensure_loaded(Module) of
        {'module', Module} -> 'true';
        {'error', _Reason} -> 'false'
    end.
