%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The command queue: what runs, what waits, and what is thrown away.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% A queue call is two applications commanding one channel: the callflow
%%% action holds the caller, and the dispatcher's offer bridges them to an
%%% agent. `hold' is `kz_endless_playback', which never finishes on its own,
%%% so which of the two commands lands first decides everything. These pin
%%% the rules the two rely on: an offer's bridge carries `Insert-At: flush',
%%% and the action's holds carry `tail'.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_call_control_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NODE, 'freeswitch@fs-2.test').
-define(CALL_ID, <<"f693866b-7f00-4c2e-9b2a-3d5e6f708192">>).

command_queue_test_() ->
    {setup
    ,fun setup/0
    ,fun cleanup/1
    ,fun(_) ->
             [a_bridge_that_interrupts_replaces_a_running_hold()
             ,a_hold_queued_behind_a_ringing_bridge_waits_for_it()
             ,a_hold_queued_behind_nothing_is_next()
             ,a_bridge_that_does_not_interrupt_never_runs()
             ,an_announcement_interrupts_a_running_hold()
             ,an_announcement_waits_behind_a_ringing_bridge()
             ,an_announcement_with_nothing_running_is_next()
             ,an_announcement_waits_behind_a_bridge_that_is_about_to_ring()
             ]
     end
    }.

setup() ->
    _ = catch meck:unload('freeswitch'),
    meck:new('freeswitch', ['non_strict', 'no_link']),
    meck:expect('freeswitch', 'api', fun(?NODE, 'uuid_break', _Arg) -> {'ok', <<"+OK">>} end),
    'ok'.

cleanup(_) ->
    flush_advances(),
    meck:unload('freeswitch').

%% Each case inserts one command and reads three things off the process it
%% ran in: what the queue holds, whether the switch was told to break, and
%% whether the process told itself to advance. All three are read here, in
%% this process, before the assertions are handed to eunit to run elsewhere.
-spec inserted(kz_term:api_ne_binary() | tuple(), atom(), kz_json:object()) ->
          {kz_term:ne_binaries(), boolean(), 'advanced' | 'waiting'}.
inserted(State, At, Command) when is_tuple(State) ->
    flush_advances(),
    meck:reset('freeswitch'),
    Queue = ecallmgr_call_control:insert_command(State, At, Command),
    Broke = meck:called('freeswitch', 'api', [?NODE, 'uuid_break', <<?CALL_ID/binary, " all">>]),
    {ecallmgr_call_control:queued_applications(Queue), Broke, advanced()};
inserted(Running, At, Command) ->
    inserted(ecallmgr_call_control:running(?NODE, ?CALL_ID, Running), At, Command).

%% The direction that used to fail: the caller is on hold and the offer's
%% bridge arrives. With `flush' the hold is broken on the switch, the queue
%% is emptied, the bridge is the whole of it, and the process is told to
%% advance -- so the phones ring at once.
a_bridge_that_interrupts_replaces_a_running_hold() ->
    {Queued, Broke, Advance} = inserted(<<"hold">>, 'flush', bridge(<<"flush">>)),
    {"a bridge that interrupts replaces a running hold"
    ,[?_assertEqual([<<"bridge">>], Queued)
     ,?_assert(Broke)
     ,?_assertEqual('advanced', Advance)
     ]
    }.

%% The other direction: the bridge got there first and is ringing, and the
%% caller's hold arrives. A hold carrying `tail' goes behind it and waits,
%% without breaking anything on the switch: it runs only if the ring comes
%% to nothing, which is when the caller needs it back.
a_hold_queued_behind_a_ringing_bridge_waits_for_it() ->
    {Queued, Broke, Advance} = inserted(<<"bridge">>, 'tail', hold(<<"tail">>)),
    {"a hold queued behind a ringing bridge waits for it"
    ,[?_assertEqual([<<"hold">>], Queued)
     ,?_assertNot(Broke)
     ,?_assertEqual('waiting', Advance)
     ]
    }.

%% A queued hold with nothing running is simply the next thing to run.
a_hold_queued_behind_nothing_is_next() ->
    {Queued, Broke, _Advance} = inserted('undefined', 'tail', hold(<<"tail">>)),
    {"a hold queued behind nothing is next"
    ,[?_assertEqual([<<"hold">>], Queued)
     ,?_assertNot(Broke)
     ]
    }.

%% What went wrong: a bridge with no `Insert-At' is queued behind the hold,
%% and the hold never finishes. Nothing rings until something else breaks the
%% hold, and the flush that does when the caller leaves throws the bridge
%% away.
a_bridge_that_does_not_interrupt_never_runs() ->
    {Queued, Broke, Advance} = inserted(<<"hold">>, 'tail', bridge('undefined')),
    {"a bridge that does not interrupt never runs"
    ,[?_assertEqual([<<"bridge">>], Queued)
     ,?_assertNot(Broke)
     ,?_assertEqual('waiting', Advance)
     ]
    }.

%% An announcement to a caller on hold: `interrupt' is a flush, so the hold
%% is broken and the macro is the whole of the queue, its `noop' last so
%% that its completion is the end of the announcement.
an_announcement_interrupts_a_running_hold() ->
    {Queued, Broke, Advance} = inserted(<<"hold">>, 'interrupt', announcement()),
    {"an announcement interrupts a running hold"
    ,[?_assertEqual([<<"play">>, <<"noop">>], Queued)
     ,?_assert(Broke)
     ,?_assertEqual('advanced', Advance)
     ]
    }.

%% The same announcement while the caller's agents are ringing: `interrupt'
%% is `tail', so nothing is broken and the macro waits behind the bridge. A
%% flush here would have run the macro nested inside the ring.
an_announcement_waits_behind_a_ringing_bridge() ->
    {Queued, Broke, Advance} = inserted(<<"bridge">>, 'interrupt', announcement()),
    {"an announcement waits behind a ringing bridge"
    ,[?_assertEqual([<<"play">>, <<"noop">>], Queued)
     ,?_assertNot(Broke)
     ,?_assertEqual('waiting', Advance)
     ]
    }.

%% With nothing running the announcement is simply next, as a flush of an
%% idle channel is.
an_announcement_with_nothing_running_is_next() ->
    {Queued, _Broke, _Advance} = inserted('undefined', 'interrupt', announcement()),
    {"an announcement with nothing running is next"
    ,[?_assertEqual([<<"play">>, <<"noop">>], Queued)]
    }.

%% The bridge's flush puts the bridge in the queue and sends the process an
%% advance; until that is handled the hold is still the current application.
%% An announcement already in the mailbox ahead of the advance sees exactly
%% that, and a flush from it would throw the bridge away: the dispatcher
%% offering, and no phone ringing. It waits behind the bridge instead.
an_announcement_waits_behind_a_bridge_that_is_about_to_ring() ->
    Holding = ecallmgr_call_control:running(?NODE, ?CALL_ID, <<"hold">>),
    AboutToRing = ecallmgr_call_control:with_queue(Holding
                                                  ,ecallmgr_call_control:insert_command(Holding, 'flush', bridge(<<"flush">>))
                                                  ),
    {Queued, Broke, Advance} = inserted(AboutToRing, 'interrupt', announcement()),
    {"an announcement waits behind a bridge that is about to ring"
    ,[?_assertEqual([<<"bridge">>, <<"play">>, <<"noop">>], Queued)
     ,?_assertNot(Broke)
     ,?_assertEqual('waiting', Advance)
     ]
    }.

%% Whether the process was told to move the queue along, which is the
%% `force_queue_advance' it sends itself.
advanced() ->
    receive
        {'force_queue_advance', ?CALL_ID} -> 'advanced'
    after 0 -> 'waiting'
    end.

flush_advances() ->
    receive
        {'force_queue_advance', _} -> flush_advances()
    after 0 -> 'ok'
    end.

bridge(InsertAt) ->
    command([{<<"Application-Name">>, <<"bridge">>}
            ,{<<"Endpoints">>, [kz_json:from_list([{<<"Invite-Format">>, <<"username">>}
                                                  ,{<<"To-User">>, <<"3200">>}
                                                  ,{<<"To-Realm">>, <<"agents.test">>}
                                                  ])]}
            ,{<<"Dial-Endpoint-Method">>, <<"simultaneous">>}
            ,{<<"Timeout">>, 10}
            ,{<<"Insert-At">>, InsertAt}
            ]).

hold(InsertAt) ->
    command([{<<"Application-Name">>, <<"hold">>}
            ,{<<"Insert-At">>, InsertAt}
            ]).

%% An announcement as `kapps_call_command:audio_macro/4' sends it: one
%% `queue' of the `noop' and the prompts, the prompts in reverse, which
%% the queue reverses again on the way in.
announcement() ->
    command([{<<"Application-Name">>, <<"queue">>}
            ,{<<"Insert-At">>, <<"interrupt">>}
            ,{<<"Commands">>, [kz_json:from_list([{<<"Application-Name">>, <<"noop">>}
                                                 ,{<<"Msg-ID">>, kz_binary:rand_hex(8)}
                                                 ,{<<"Call-ID">>, ?CALL_ID}
                                                 ])
                              ,kz_json:from_list([{<<"Application-Name">>, <<"play">>}
                                                 ,{<<"Media-Name">>, <<"/system_media/queue-you_are_at_position">>}
                                                 ,{<<"Call-ID">>, ?CALL_ID}
                                                 ])
                              ]}
            ]).

%% A command as `kapps_call_command:send_command/2' puts it on the wire: the
%% application's own fields, the API's default headers and the message id the
%% publisher stamps on it, all of which the queue validates on the way in.
command(Props) ->
    kz_json:from_list(
      props:filter_undefined(
        [{<<"Call-ID">>, ?CALL_ID}
        ,{<<"Msg-ID">>, kz_binary:rand_hex(8)}
         | Props
        ] ++ kz_api:default_headers(<<"callctl-test">>, <<"call">>, <<"command">>, <<"test">>, <<"1">>)
       )).
