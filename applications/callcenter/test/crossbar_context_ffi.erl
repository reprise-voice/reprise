%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% A Crossbar context for a test, in the shape `kazoo_gleam_crossbar_ffi'
%% keeps outside a release, with the fields Gleam has no setter for: whose
%% account the request is against, who is asking, the verb, and the path as
%% Crossbar parsed it. And the error a phase left on it, which Gleam only
%% sees as a status.
-module(crossbar_context_ffi).
-export([context/3, with_verb/2, with_nouns/2, with_auth_user_id/2
        ,system_error/1, error_code/1, validation_errors/1
        ]).

context(AccountId, IsAccountAdmin, IsSuperduperAdmin) ->
    {'kazoo_gleam_context', #{<<"account_id">> => AccountId
                             ,<<"is_account_admin">> => IsAccountAdmin
                             ,<<"is_superduper_admin">> => IsSuperduperAdmin
                             }}.

with_verb({'kazoo_gleam_context', Map}, Verb) ->
    {'kazoo_gleam_context', Map#{<<"req_verb">> => Verb}}.

%% Deepest noun first, as `req_nouns' answers them.
with_nouns({'kazoo_gleam_context', Map}, Nouns) ->
    {'kazoo_gleam_context', Map#{<<"req_nouns">> => Nouns}}.

with_auth_user_id({'kazoo_gleam_context', Map}, UserId) ->
    {'kazoo_gleam_context', Map#{<<"auth_user_id">> => UserId}}.

system_error({'kazoo_gleam_context', Map}) ->
    case maps:find(<<"system_error">>, Map) of
        {'ok', Kind} -> {'ok', Kind};
        'error' -> {'error', 'nil'}
    end.

%% The status code an error of the handler's own carries (`crossbar.add_error').
error_code({'kazoo_gleam_context', Map}) ->
    case maps:find(<<"error_code">>, Map) of
        {'ok', Code} -> {'ok', Code};
        'error' -> {'error', 'nil'}
    end.

validation_errors({'kazoo_gleam_context', Map}) ->
    [{Property, Code} || {Property, Code, _Message} <- maps:get(<<"validation_errors">>, Map, [])].
