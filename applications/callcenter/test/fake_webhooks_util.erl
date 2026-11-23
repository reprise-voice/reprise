%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `webhooks_util' for `platform_fakes'.
%%
%% `find_webhooks/2' answers the hooks a test gave one account for one hook
%% name with `platform_fakes:set({hooks, HookName, AccountId}, Hooks)', and
%% nothing for any other account: which account's hooks are looked for is
%% the call center's decision, and that is what is under test. Firing and
%% the metadata documents are recorded.
-module(fake_webhooks_util).

-export([find_webhooks/2, fire_hooks/3, sanitize_event/1, init_metadata/2]).

find_webhooks(_HookName, 'undefined') -> [];
find_webhooks(HookName, AccountId) ->
    platform_fakes:record('webhooks_util', 'find_webhooks', [HookName, AccountId]),
    platform_fakes:get({'hooks', HookName, AccountId}, []).

fire_hooks(JObj, V2JObj, Hooks) ->
    platform_fakes:record('webhooks_util', 'fire_hooks', [JObj, V2JObj, Hooks]).

%% `webhooks_util''s: public fields only, normalised.
sanitize_event(JObj) ->
    {Props} = JObj,
    Public = [{K, V} || {K, V} <- Props, not is_private(K)],
    kz_json:normalize_jobj({Public}).

init_metadata(Id, JObj) ->
    platform_fakes:record('webhooks_util', 'init_metadata', [Id, JObj]).

is_private(<<"_", _/binary>>) -> 'true';
is_private(<<"pvt_", _/binary>>) -> 'true';
is_private(_) -> 'false'.
