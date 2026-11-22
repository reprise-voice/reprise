%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc What the webhooks listener keeps in memory when a hook is created.
%%%
%%% A hook created with enabled false must stay out of memory, as the
%%% start-up load leaves it out: before, the created path added it whatever
%%% its flag, and it was delivered until it was edited or the application
%%% restarted.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(webhooks_listener_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kazoo_amqp/include/kapi_conf.hrl").
-include("webhooks.hrl").

-define(ACCOUNT_ID, <<"account0000000000000000000000001">>).
-define(HOOK_ID, <<"hook00000000000000000000000000001">>).

created_hook_test_() ->
    [{"a hook created enabled is added", ?_assertMatch([{'add_hook', _}], created(hook([{<<"enabled">>, 'true'}])))}
    ,{"a hook created without the flag is added", ?_assertMatch([{'add_hook', _}], created(hook([])))}
    ,{"a hook created disabled is not added", ?_assertEqual([], created(hook([{<<"enabled">>, 'false'}])))}
    ,{"a hook created soft-deleted is not added", ?_assertEqual([], created(hook([{<<"pvt_deleted">>, 'true'}])))}
    ].

hook(Props) ->
    kz_json:from_list(
      [{<<"_id">>, ?HOOK_ID}
      ,{<<"pvt_account_id">>, ?ACCOUNT_ID}
      ,{<<"pvt_type">>, <<"webhook">>}
      ,{<<"hook">>, <<"all">>}
      ,{<<"uri">>, <<"http://receiver.invalid/hook">>}
      ,{<<"http_verb">>, <<"post">>}
       | Props
      ]).

%% Runs the created-document event through the listener with this process
%% as the server, and returns the casts it made.
created(Hook) ->
    Event = kz_json:from_list(
              [{<<"ID">>, ?HOOK_ID}
              ,{<<"Database">>, ?KZ_WEBHOOKS_DB}
              ,{<<"Account-ID">>, ?ACCOUNT_ID}
              ,{<<"Type">>, <<"webhook">>}
              ,{<<"Doc">>, Hook}
              ,{<<"Event-Category">>, <<"configuration">>}
              ,{<<"Event-Name">>, ?DOC_CREATED}
              ,{<<"Msg-ID">>, kz_binary:rand_hex(8)}
               | kz_api:default_headers(<<"webhooks_listener_tests">>, <<"1">>)
              ]),
    'ok' = webhooks_listener:handle_config(Event, [{'server', self()}]),
    casts().

casts() ->
    receive
        {'$gen_cast', {'$client_cast', Msg}} -> [Msg | casts()]
    after 0 -> []
    end.
