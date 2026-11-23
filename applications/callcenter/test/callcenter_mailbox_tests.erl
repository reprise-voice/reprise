%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% The look an offer takes at its own mailbox before it sends its bridge.
%%
%% The dispatcher calls a ring off by relaying an event to the offer's
%% process, in the `{amqp_msg, JObj}' shape `kapps_call_command:relay_event/2'
%% sends. Before its bridge the offer asks whether that event is there
%% without taking it out -- its loop reads the same event again if the bridge
%% went out after all -- and without taking anything else out either: the
%% call's own events that arrived meanwhile are the loop's to read.
-module(callcenter_mailbox_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CALLED_OFF, <<"callcenter_offer_called_off">>).

event(Name) ->
    {'amqp_msg', {[{<<"Event-Category">>, <<"callcenter">>}
                  ,{<<"Event-Name">>, Name}
                  ,{<<"Unbridged">>, 'true'}
                  ]}}.

drain() ->
    receive _ -> drain() after 0 -> 'ok' end.

a_call_off_is_seen_and_left_in_place_test() ->
    drain(),
    Create = {'amqp_msg', {[{<<"Event-Name">>, <<"CHANNEL_CREATE">>}]}},
    self() ! Create,
    ?assertNot(callcenter_ffi:mailbox_has_event(?CALLED_OFF)),
    self() ! 'something_else',
    self() ! event(?CALLED_OFF),
    ?assert(callcenter_ffi:mailbox_has_event(?CALLED_OFF)),
    ?assert(callcenter_ffi:mailbox_has_event(?CALLED_OFF)),
    %% Everything is still there, in the order it came.
    {'messages', Messages} = erlang:process_info(self(), 'messages'),
    ?assertEqual([Create, 'something_else', event(?CALLED_OFF)], Messages),
    drain().

another_event_is_not_a_call_off_test() ->
    drain(),
    self() ! event(<<"callcenter_dispatcher_gone">>),
    self() ! {'amqp_msg', 'not_an_object'},
    ?assertNot(callcenter_ffi:mailbox_has_event(?CALLED_OFF)),
    drain().
