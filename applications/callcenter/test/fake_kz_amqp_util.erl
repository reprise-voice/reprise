%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `kz_amqp_util' for `platform_fakes': nothing reaches a broker, and every
%% publish, binding and declaration is recorded for the test to read back.
-module(fake_kz_amqp_util).

-export([basic_publish/4, basic_publish/5
        ,prepare_basic_publish/5
        ,targeted_publish/3
        ,bind_q_to_exchange/3, unbind_q_from_exchange/3
        ,new_exchange/3
        ]).

basic_publish(Exchange, RoutingKey, Payload, ContentType) ->
    basic_publish(Exchange, RoutingKey, Payload, ContentType, []).

basic_publish(Exchange, RoutingKey, Payload, ContentType, Props) ->
    platform_fakes:record('kz_amqp_util', 'basic_publish', [Exchange, RoutingKey, Payload, ContentType, Props]).

%% Built and not sent: recorded, and the arguments handed back as the pair.
prepare_basic_publish(Exchange, RoutingKey, Payload, ContentType, Props) ->
    platform_fakes:record('kz_amqp_util', 'prepare_basic_publish', [Exchange, RoutingKey, Payload, ContentType, Props]),
    {{'prepared', Exchange, RoutingKey, ContentType, Props}, Payload}.

targeted_publish(Queue, Payload, ContentType) ->
    platform_fakes:record('kz_amqp_util', 'targeted_publish', [Queue, Payload, ContentType]).

bind_q_to_exchange(Queue, RoutingKey, Exchange) ->
    platform_fakes:record('kz_amqp_util', 'bind_q_to_exchange', [Queue, RoutingKey, Exchange]).

unbind_q_from_exchange(Queue, RoutingKey, Exchange) ->
    platform_fakes:record('kz_amqp_util', 'unbind_q_from_exchange', [Queue, RoutingKey, Exchange]).

new_exchange(Exchange, Type, Options) ->
    platform_fakes:record('kz_amqp_util', 'new_exchange', [Exchange, Type, Options]).
