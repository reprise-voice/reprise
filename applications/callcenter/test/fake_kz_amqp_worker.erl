%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `kz_amqp_worker' for `platform_fakes': a cast runs the publisher it was
%% given, there and then, so that what `kazoo/amqp.publish' sends is what
%% `kz_amqp_util' records. Every cast is recorded as `cast' with the message,
%% which is how a test says a message did not go through the worker pool --
%% on a node, a worker's channel and not the caller's. A publisher that
%% raises -- which is what a `kapi' publisher does with a message its
%% definition refuses -- is recorded as `rejected' with the message and the
%% reason as well, where the platform would have logged it and gone on.
-module(fake_kz_amqp_worker).

-export([cast/2]).

cast(Req, PublishFun) ->
    platform_fakes:record('kz_amqp_worker', 'cast', [Req]),
    try PublishFun(Req) of
        _ -> 'ok'
    catch
        Class:Reason ->
            platform_fakes:record('kz_amqp_worker', 'rejected', [Req, {Class, Reason}]),
            {'error', Reason}
    end.
