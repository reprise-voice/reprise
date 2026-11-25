%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% Process-local, virtual-clock driver for the actual callflow loop.
-module(queue_runtime_ffi).
-export([init/2, now_ms/0, next/1, publish/3, publications/0,
         destroyed/1, fail_publication/0, hangup_on_publication/0,
         continue_branch/2, continued_with/0, replied/1, replies/0]).

init(Script, Now) ->
    put(?MODULE, #{script => Script, now => Now, publications => [],
                   destroyed => false, fail => false, hangup => false,
                   replies => []}),
    nil.

state() -> get(?MODULE).
set(Key, Value) -> put(?MODULE, (state())#{Key => Value}), nil.
now_ms() -> maps:get(now, state()).
destroyed(_) -> maps:get(destroyed, state()).
fail_publication() -> set(fail, true).
hangup_on_publication() -> set(hangup, true).
publications() -> lists:reverse(maps:get(publications, state())).
replied(Payload) -> set(replies, [Payload | maps:get(replies, state())]).
replies() -> lists:reverse(maps:get(replies, state())).

next(Timeout) when Timeout > 0 ->
    case maps:get(script, state()) of
        [{check, Check} | Rest] ->
            set(script, Rest),
            Check(),
            next(Timeout);
        [{event_after, Delay, Event} | Rest] when Delay =< Timeout ->
            set(script, Rest),
            set(now, now_ms() + Delay),
            {ok, Event};
        [{event_after, Delay, Event} | Rest] ->
            set(script, [{event_after, Delay - Timeout, Event} | Rest]),
            set(now, now_ms() + Timeout),
            {error, timeout};
        [{disappear_after, Delay} | Rest] when Delay =< Timeout ->
            set(script, Rest),
            set(now, now_ms() + Delay),
            set(destroyed, true),
            {error, timeout};
        [{disappear_after, Delay} | Rest] ->
            set(script, [{disappear_after, Delay - Timeout} | Rest]),
            set(now, now_ms() + Timeout),
            {error, timeout};
        [] ->
            set(now, now_ms() + Timeout),
            {error, timeout}
    end.

publish(_Shard, Name, Payload) ->
    kazoo_gleam_call_ffi:note(Name, <<>>),
    set(publications, [{Name, Payload} | maps:get(publications, state())]),
    case {Name, maps:get(fail, state())} of
        {<<"member_call">>, true} -> {error, nil};
        _ ->
            case maps:get(hangup, state()) of
                true -> set(destroyed, true);
                false -> nil
            end,
            {ok, nil}
    end.

continue_branch(Call, Branch) ->
    set(continued, Call),
    kazoo_gleam_call_ffi:note(<<"continue_branch">>, Branch), nil.

%% The call record the action handed on to the rest of its callflow.
continued_with() ->
    case maps:find(continued, state()) of
        {ok, Call} -> {ok, Call};
        error -> {error, nil}
    end.
