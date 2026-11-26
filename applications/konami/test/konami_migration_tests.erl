%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
-module(konami_migration_tests).

-include_lib("eunit/include/eunit.hrl").

migration_test_() ->
    {setup, fun setup/0, fun(_) -> meck:unload() end, fun(_) -> tests() end}.

setup() ->
    application:ensure_all_started(lager),
    meck:new(kapps_config, [non_strict, no_link]),
    meck:expect(kapps_config, get_is_true, fun(_, _, _) -> false end),
    meck:expect(kapps_config, get_integer, fun(_, _, Default) -> Default end),
    meck:expect(kapps_config, get_ne_binary, fun(_, _, Default) -> Default end),
    meck:expect(kapps_config, get_ne_binary, fun(_, _) -> undefined end),
    meck:new(kzd_accounts, [non_strict, no_link]),
    meck:expect(kzd_accounts, fetch, fun(_) -> {ok, kz_json:new()} end),
    meck:expect(kzd_accounts, realm, fun(_) -> <<"probe.invalid">> end),
    meck:new(konami_event_listener, [non_strict, no_link]),
    meck:expect(konami_event_listener, rm_call_binding, fun(_) -> ok end),
    meck:expect(konami_event_listener, rm_call_binding, fun(_, _) -> ok end),
    meck:expect(konami_event_listener, rm_konami_binding, fun(_) -> ok end),
    meck:expect(konami_event_listener, add_call_binding, fun(_, _) -> ok end),
    meck:expect(konami_event_listener, queue_name, fun() -> <<"probe-q">> end),
    meck:expect(konami_event_listener
               ,originate
               ,fun(Req) ->
                        self() ! {originate_request, Req},
                        ok
                end),
    meck:expect(konami_event_listener, add_call_binding, fun(_) -> ok end),
    meck:expect(konami_event_listener, add_konami_binding, fun(_) -> ok end),
    meck:new(kapi_dialplan, [passthrough, no_link]),
    meck:expect(kapi_dialplan, publish_originate_execute, fun(_, _) -> ok end),
    meck:expect(kapi_dialplan, publish_originate_cancel, fun(_, _) -> ok end),
    ok.

tests() ->
    [{"move adopts current control", fun() -> current_control(konami_move) end}
    ,{"intercept adopts current control", fun() -> current_control(konami_intercept) end}
    ,{"move accepts legacy control", fun() -> legacy_control(konami_move) end}
    ,{"intercept accepts legacy control", fun() -> legacy_control(konami_intercept) end}
    ,{"armed and unarmed handoffs update identity", fun handoff_identity/0}
    ,{"finished timer stops normally", {timeout, 10, fun finished_timeout/0}}
    ,{"takeback timer reconnects without crashing", {timeout, 10, fun takeback_timeout/0}}
    ,{"stale digit timeout is ignored", fun stale_timer/0}
    ,{"current digit timeout disarms", fun current_timer/0}
    ,{"milliseconds converted at originate boundary", fun timeout_units/0}
    ,{"invalid responses never supply control", fun invalid_control/0}
    ,{"originate events route by request identity", fun event_identity/0}
    ,{"transfer waits for control before connecting", fun transfer_control/0}
    ,{"pending takeback cancels rather than executes", fun cancel_before_ready/0}
    ,{"feature code follows a B-leg handoff", fun feature_after_handoff/0}
    ,{"replacement retires old digit collection", fun replacement_handoff/0}
    ,{"independent peer control stays on its own queue", fun peer_control/0}
    ,{"last leg destruction retires the FSM in either order", {timeout, 15, fun last_leg_destroy/0}}
    ,{"account answers cannot adopt an unrelated call", fun unrelated_answer/0}
    ,{"takeback cancellation sends one immediate reconnect", fun takeback_reconnect_once/0}
    ,{"schema capture defaults cannot override an explicit target", fun schema_transfer_target/0}
    ,{"invalid target cannot unbridge an active call", fun invalid_transfer_target/0}].

call() ->
    kapps_call:kvs_store(konami_code_statem
                        ,self()
                        ,kapps_call:set_call_id(<<"original">>, kapps_call:new())).

headers(Name) ->
    [{<<"Event-Category">>, <<"resource">>}
    ,{<<"Event-Name">>, Name}
    ,{<<"App-Name">>, <<"probe">>}
    ,{<<"App-Version">>, <<"1">>}
    ,{<<"Msg-ID">>, <<"probe">>}].

response() ->
    kz_json:from_list([{<<"Call-ID">>, <<"replacement">>}
                      ,{<<"Control-Queue">>, <<"current-control">>}
                      ,{<<"Application-Response">>, <<"SUCCESS">>}
                      | headers(<<"originate_resp">>)]).

legacy() ->
    kz_json:from_list([{<<"Outbound-Call-ID">>, <<"replacement">>}
                      ,{<<"Outbound-Call-Control-Queue">>, <<"legacy-control">>}
                      | headers(<<"originate_uuid">>)]).

current_control(Mod) ->
    Call = call(),
    Resp = response(),
    ?assert(kapi_resource:originate_resp_v(Resp)),
    ?assertEqual({stop, Call}
                ,Mod:maybe_update_metaflow(kz_json:from_list([{<<"dtmf_leg">>, <<"original">>}])
                                          ,Call
                                          ,[Resp])),
    receive
        {'$gen_cast', {transfer_to, NewCall, a}} ->
            ?assertEqual(<<"replacement">>, kapps_call:call_id(NewCall)),
            ?assertEqual(<<"current-control">>, kapps_call:control_queue(NewCall))
    after 0 ->
            error(missing_rebind)
    end.

legacy_control(Mod) ->
    Call = call(),
    ?assert(kapi_resource:originate_uuid_v(legacy())),
    Mod:maybe_update_metaflow(kz_json:from_list([{<<"dtmf_leg">>, <<"original">>}])
                             ,Call
                             ,[kz_json:delete_key(<<"Control-Queue">>, response()), legacy()]),
    receive
        {'$gen_cast', {transfer_to, NewCall, a}} ->
            ?assertEqual(<<"replacement">>, kapps_call:call_id(NewCall)),
            ?assertEqual(<<"legacy-control">>, kapps_call:control_queue(NewCall))
    after 0 ->
            error(missing_legacy_rebind)
    end.

state(Mod, Overrides) ->
    list_to_tuple([state | [props:get_value(Name, Overrides) || Name <- state_fields(Mod)]]).

%% The field names of Mod's #state{}, read from the abstract code the beam
%% carries (every module is compiled with debug_info).
state_fields(Mod) ->
    {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} = beam_lib:chunks(beam(Mod), [abstract_code]),
    [{attribute, _, record, {state, Fields}}] = [F || F = {attribute, _, record, {state, _}} <- Forms],
    [field_name(F) || F <- Fields].

%% Under the CI runner's cover:compile_beam_directory/1, code:which/1 answers
%% 'cover_compiled'; the original beam, abstract code included, is still on disk.
beam(Mod) ->
    case code:which(Mod) of
        cover_compiled ->
            {file, File} = cover:is_compiled(Mod),
            File;
        File ->
            File
    end.

field_name({typed_record_field, F, _}) -> field_name(F);
field_name({record_field, _, {atom, _, Name}}) -> Name;
field_name({record_field, _, {atom, _, Name}, _}) -> Name.

start(Mod, Name, State) ->
    P = proc_lib:spawn(fun() -> gen_statem:enter_loop(Mod, [], Name, State) end),
    {P, monitor(process, P)}.

stop(P, Ref) ->
    gen_statem:stop(P),
    receive
        {'DOWN', Ref, process, P, normal} ->
            ok
    after 1000 ->
            error(stop_timeout)
    end.

reason(P, Ref) ->
    receive
        {'DOWN', Ref, process, P, Why} ->
            Why
    after 7000 ->
            exit(P, kill),
            error(expected_exit_not_seen)
    end.

handoff_identity() ->
    lists:foreach(fun(Name) ->
                          S = state(konami_code_statem
                                   ,[{call, call()}
                                    ,{call_id, <<"original">>}
                                    ,{other_leg, <<"peer">>}
                                    ,{listen_on, a}]),
                          {P, R} = start(konami_code_statem, Name, S),
                          NewCall = kapps_call:set_other_leg_call_id(<<"peer">>
                                                                    ,kapps_call:set_control_queue(<<"new-q">>
                                                                                                 ,kapps_call:set_call_id(<<"replacement">>
                                                                                                                        ,call()))),
                          konami_code_statem:transfer_to(kapps_call:kvs_store(konami_code_statem, P, NewCall)
                                                        ,a),
                          {unarmed, NewState} = sys:get_state(P),
                          ?assertEqual(<<"replacement">>, value(konami_code_statem, call_id, NewState)),
                          ?assertEqual(<<"new-q">>
                                      ,kapps_call:control_queue(value(konami_code_statem, call, NewState))),
                          stop(P, R)
                  end
                 ,[armed, unarmed]).

finished_timeout() ->
    S = state(konami_transfer, [{transferor, <<"original">>}, {transferee, <<"peer">>}]),
    {P, R} = start(konami_transfer, finished, S),
    gen_statem:cast(P, unexpected),
    ?assertEqual(normal, reason(P, R)).

stale_timer() ->
    S = state(konami_code_statem, [{call_id, <<"original">>}, {a_digit_timeout_ref, make_ref()}]),
    {P, R} = start(konami_code_statem, armed, S),
    P ! {timeout, make_ref(), digit_timeout},
    ?assertEqual({armed, S}, sys:get_state(P)),
    stop(P, R).

current_timer() ->
    Ref = make_ref(),
    S = state(konami_code_statem
             ,[{call_id, <<"original">>}
              ,{a_digit_timeout_ref, Ref}
              ,{numbers, kz_json:new()}
              ,{patterns, kz_json:new()}
              ,{a_collected_dtmf, <<>>}]),
    {P, R} = start(konami_code_statem, armed, S),
    P ! {timeout, Ref, digit_timeout},
    {unarmed, _} = sys:get_state(P),
    stop(P, R).

timeout_units() ->
    Call = kapps_call:set_caller_id_number(<<"3103">>, call()),
    konami_transfer:originate_to_extension(<<"3101">>, <<"original">>, Call),
    receive
        {originate_request, Req} ->
            ?assertEqual(20, props:get_value(<<"Timeout">>, Req)),
            ?assertEqual(false, props:get_value(<<"Originate-Immediate">>, Req)),
            ?assertEqual(props:get_value(<<"Outbound-Call-ID">>, Req)
                        ,props:get_value(<<"Msg-ID">>, Req)),
            ?assertEqual([1, 1, 2, 20, 31, 20]
                        ,[konami_originate:timeout_seconds(N) || N <- [1, 1000, 1001, 20000, 30001, 0]])
    after 0 ->
            error(missing_originate_request)
    end.

takeback_timeout() ->
    Parent = self(),
    Call = kapps_call:set_custom_publish_function(fun(_, _) ->
                                                          Parent ! reconnect,
                                                          ok
                                                  end
                                                 ,call()),
    S = state(konami_transfer
             ,[{call, Call}, {target, <<"target">>}, {transferor, <<"original">>}, {transferee, <<"peer">>}]),
    {P, R} = start(konami_transfer, takeback, S),
    gen_statem:cast(P, {event, <<"target">>, <<"CHANNEL_DESTROY">>, kz_json:new()}),
    receive
        reconnect ->
            ok
    after 1000 ->
            error(missing_initial_reconnect)
    end,
    receive
        reconnect ->
            ok;
        {'DOWN', R, process, P, Why} ->
            error({unexpected_exit, Why})
    after 6000 ->
            error(missing_timer_reconnect)
    end,
    {takeback, _} = sys:get_state(P),
    stop(P, R).

value(Mod, Field, State) ->
    props:get_value(Field, lists:zip(state_fields(Mod), tl(tuple_to_list(State)))).

invalid_control() ->
    lists:foreach(fun(Resp) -> ?assertEqual({error, no_control}, konami_originate:control([Resp]))
                  end
                 ,[kz_json:set_value(<<"Application-Response">>, <<"FAILURE">>, response())
                  ,kz_json:delete_key(<<"Control-Queue">>, response())
                  ,kz_json:set_value(<<"Control-Queue">>, <<>>, response())
                  ,kz_json:delete_key(<<"Call-ID">>, response())]),
    ?assertEqual({error, no_control}
                ,konami_originate:control([kz_json:delete_key(<<"Control-Queue">>, response())
                                          ,kz_json:set_value(<<"Outbound-Call-ID">>
                                                            ,<<"unrelated">>
                                                            ,legacy())])).

event_identity() ->
    ?assertEqual(<<"request">>
                ,konami_originate:event_key(kz_json:set_value(<<"Outbound-Call-ID">>
                                                             ,<<"request">>
                                                             ,response()))),
    ?assertEqual(<<"request">>
                ,konami_originate:event_key(kz_json:from_list([{<<"Event-Name">>, <<"originate_ready">>}
                                                              ,{<<"Msg-ID">>, <<"request">>}]))),
    ?assertEqual(<<"channel">>
                ,konami_originate:event_key(kz_json:from_list([{<<"Event-Name">>, <<"CHANNEL_ANSWER">>}
                                                              ,{<<"Call-ID">>, <<"channel">>}]))).

transfer_state(Call) ->
    state(konami_transfer
         ,[{call, call()}
          ,{target_call, Call}
          ,{target_a_leg, <<"request">>}
          ,{originate_complete, false}
          ,{transferor, <<"original">>}
          ,{transferee, <<"peer">>}]).

ready() ->
    kz_json:from_list([{<<"Event-Name">>, <<"originate_ready">>}
                      ,{<<"Event-Category">>, <<"dialplan">>}
                      ,{<<"Msg-ID">>, <<"request">>}
                      ,{<<"Originate-UUID">>, <<"origination">>}
                      ,{<<"Originate-Queue">>, <<"pending-q">>}
                      ,{<<"App-Name">>, <<"probe">>}
                      ,{<<"App-Version">>, <<"1">>}]).

transfer_control() ->
    Parent = self(),
    Call = kapps_call:set_custom_publish_function(fun(Cmd, C) ->
                                                          Parent !
                                                              {command
                                                              ,Cmd
                                                              ,kapps_call:call_id(C)
                                                              ,kapps_call:control_queue(C)},
                                                          ok
                                                  end
                                                 ,kapps_call:new()),
    {P, R} = start(konami_transfer, attended_wait, transfer_state(Call)),
    try
        P ! {amqp_msg, ready()},
        _ = sys:get_state(P),
        ?assertEqual(1, meck:num_calls(kapi_dialplan, publish_originate_execute, [<<"pending-q">>, '_'])),
        P ! {amqp_msg, ready()},
        _ = sys:get_state(P),
        ?assertEqual(1, meck:num_calls(kapi_dialplan, publish_originate_execute, [<<"pending-q">>, '_'])),
        Evt = kz_json:from_list([{<<"Replaced-By">>, <<"replacement">>}]),
        gen_statem:cast(P, {event, <<"request">>, <<"CHANNEL_REPLACED">>, Evt}),
        _ = sys:get_state(P),
        receive
            {command, _, _, _} ->
                error(connected_without_control)
        after 0 ->
                ok
        end,
        Resp = kz_json:set_value(<<"Outbound-Call-ID">>, <<"request">>, response()),
        P ! {amqp_msg, Resp},
        _ = sys:get_state(P),
        receive
            {command, Cmd, <<"replacement">>, <<"current-control">>} ->
                ?assertEqual(<<"connect_leg">>, props:get_value(<<"Application-Name">>, Cmd)),
                ?assertEqual(<<"original">>, props:get_value(<<"Target-Call-ID">>, Cmd))
        after 1000 ->
                error(missing_connection)
        end,
        P ! {amqp_msg, Resp},
        _ = sys:get_state(P),
        receive
            {command, _, _, _} ->
                error(duplicate_connection)
        after 0 ->
                ok
        end
    after
        stop(P, R)
    end.

cancel_before_ready() ->
    meck:reset(kapi_dialplan),
    {P, R} = start(konami_transfer, takeback, transfer_state(kapps_call:new())),
    try
        P ! {amqp_msg, ready()},
        _ = sys:get_state(P),
        ?assertEqual(1, meck:num_calls(kapi_dialplan, publish_originate_cancel, [<<"pending-q">>, '_'])),
        ?assertEqual(0, meck:num_calls(kapi_dialplan, publish_originate_execute, '_'))
    after
        stop(P, R)
    end.

feature_after_handoff() ->
    Parent = self(),
    meck:new(konami_code_exe, [non_strict, no_link]),
    meck:expect(konami_code_exe
               ,handle
               ,fun(M, C) ->
                        Parent ! {metaflow, M, C},
                        ok
                end),
    Call = kapps_call:set_other_leg_call_id(<<"peer">>, call()),
    Numbers = kz_json:from_list([{<<"9">>, kz_json:from_list([{<<"module">>, <<"hangup">>}])}]),
    S = state(konami_code_statem
             ,[{call, Call}
              ,{call_id, <<"original">>}
              ,{other_leg, <<"peer">>}
              ,{listen_on, ab}
              ,{binding_digit, <<"*">>}
              ,{digit_timeout, 20}
              ,{numbers, Numbers}
              ,{patterns, kz_json:new()}]),
    {P, R} = start(konami_code_statem, unarmed, S),
    try
        New = kapps_call:kvs_store(konami_code_statem
                                  ,P
                                  ,kapps_call:set_other_leg_call_id(<<"new-peer">>, Call)),
        konami_code_statem:transfer_to(New, b),
        _ = sys:get_state(P),
        gen_statem:cast(P, {dtmf, <<"peer">>, <<"*">>}),
        {unarmed, _} = sys:get_state(P),
        gen_statem:cast(P, {dtmf, <<"new-peer">>, <<"*">>}),
        gen_statem:cast(P, {dtmf, <<"new-peer">>, <<"9">>}),
        receive
            {metaflow, M, C} ->
                ?assertEqual(<<"new-peer">>, kz_json:get_value([<<"data">>, <<"dtmf_leg">>], M)),
                ?assertEqual(<<"new-peer">>, kapps_call:other_leg_call_id(C))
        after 1000 ->
                error(feature_code_did_not_follow_handoff)
        end
    after
        stop(P, R),
        meck:unload(konami_code_exe)
    end.

replacement_handoff() ->
    Call = kapps_call:set_control_queue(<<"q">>, call()),
    S = state(konami_code_statem
             ,[{call, Call}, {call_id, <<"original">>}, {listen_on, a}, {a_digit_timeout_ref, make_ref()}]),
    {P, R} = start(konami_code_statem, armed, S),
    try
        konami_code_statem:event(P
                                ,<<"original">>
                                ,<<"CHANNEL_REPLACED">>
                                ,kz_json:from_list([{<<"Replaced-By">>, <<"new">>}])),
        {unarmed, New} = sys:get_state(P),
        ?assertEqual(<<"new">>, value(konami_code_statem, call_id, New)),
        ?assertEqual(undefined, value(konami_code_statem, a_digit_timeout_ref, New)),
        ?assertEqual(<<"q">>, kapps_call:control_queue(value(konami_code_statem, call, New)))
    after
        stop(P, R)
    end.

peer_control() ->
    Parent = self(),
    meck:new(kz_amqp_channel, [non_strict, no_link]),
    meck:expect(kz_amqp_channel, check_consumer_pids, fun() -> ok end),
    meck:expect(kapi_dialplan
               ,publish_command
               ,fun(Q, Cmd) ->
                        Parent ! {published, Q, props:get_value(<<"Call-ID">>, Cmd)},
                        ok
                end),
    try
        Base = kapps_call:set_control_queue(<<"a-q">>
                                           ,kapps_call:set_other_leg_call_id(<<"peer">>, call())),
        Call = konami_util:with_leg_control(konami_util:set_leg_control(<<"peer">>, <<"b-q">>, Base)),
        kapps_call_command:send_command([{<<"Application-Name">>, <<"hangup">>}
                                        ,{<<"Call-ID">>, <<"peer">>}]
                                       ,Call),
        receive
            {published, <<"b-q">>, <<"peer">>} ->
                ok
        after 1000 ->
                error(wrong_peer_queue)
        end,
        kapps_call_command:send_command([{<<"Application-Name">>, <<"hangup">>}], Call),
        receive
            {published, <<"a-q">>, <<"original">>} ->
                ok
        after 1000 ->
                error(wrong_original_queue)
        end
    after
        meck:unload(kz_amqp_channel)
    end.

last_leg_destroy() ->
    lists:foreach(fun([First, Last]) ->
                          C = kapps_call:set_other_leg_call_id(<<"peer">>, call()),
                          S = state(konami_code_statem
                                   ,[{call, C}
                                    ,{call_id, <<"original">>}
                                    ,{other_leg, <<"peer">>}
                                    ,{listen_on, ab}]),
                          {P, R} = start(konami_code_statem, unarmed, S),
                          konami_code_statem:event(P, First, <<"CHANNEL_DESTROY">>, kz_json:new()),
                          {unarmed, _} = sys:get_state(P),
                          konami_code_statem:event(P, Last, <<"CHANNEL_DESTROY">>, kz_json:new()),
                          ?assertEqual(normal, reason(P, R))
                  end
                 ,[[<<"original">>, <<"peer">>], [<<"peer">>, <<"original">>]]).

unrelated_answer() ->
    S = state(konami_code_statem, [{call, call()}, {call_id, <<"original">>}, {listen_on, ab}]),
    {P, R} = start(konami_code_statem, unarmed, S),
    try
        Wrong = kz_json:from_list([{<<"Call-ID">>, <<"unrelated">>}
                                  ,{<<"Other-Leg-Call-ID">>, <<"different-call">>}]),
        konami_code_statem:event(P, <<"unrelated">>, <<"CHANNEL_ANSWER">>, Wrong),
        ?assertEqual({unarmed, S}, sys:get_state(P)),
        Right = kz_json:from_list([{<<"Call-ID">>, <<"peer">>}, {<<"Other-Leg-Call-ID">>, <<"original">>}]),
        konami_code_statem:event(P, <<"peer">>, <<"CHANNEL_ANSWER">>, Right),
        {unarmed, Accepted} = sys:get_state(P),
        ?assertEqual(<<"peer">>, value(konami_code_statem, other_leg, Accepted))
    after
        stop(P, R)
    end.

takeback_reconnect_once() ->
    Parent = self(),
    C = kapps_call:set_custom_publish_function(fun(_, _) ->
                                                       Parent ! reconnect,
                                                       ok
                                               end
                                              ,call()),
    S = state(konami_transfer
             ,[{call, C}
              ,{target_call, kapps_call:new()}
              ,{target_a_leg, <<"request">>}
              ,{transferor, <<"original">>}
              ,{transferee, <<"peer">>}
              ,{takeback_dtmf, <<"*1">>}
              ,{transferor_dtmf, <<>>}]),
    {P, R} = start(konami_transfer, attended_wait, S),
    try
        lists:foreach(fun(D) ->
                              gen_statem:cast(P
                                             ,{event
                                              ,<<"original">>
                                              ,<<"DTMF">>
                                              ,kz_json:from_list([{<<"DTMF-Digit">>, D}])})
                      end
                     ,[<<"*">>, <<"1">>]),
        {takeback, _} = sys:get_state(P),
        receive
            reconnect ->
                ok
        after 1000 ->
                error(missing_reconnect)
        end,
        gen_statem:cast(P, {event, <<"request">>, <<"CHANNEL_DESTROY">>, kz_json:new()}),
        gen_statem:cast(P, {event, <<"original">>, <<"CHANNEL_UNBRIDGE">>, kz_json:new()}),
        _ = sys:get_state(P),
        receive
            reconnect ->
                error(duplicate_reconnect)
        after 0 ->
                ok
        end
    after
        stop(P, R)
    end.

schema_transfer_target() ->
    lists:foreach(fun({Props, Expected}) ->
                          C = kapps_call:set_custom_publish_function(fun(_, _) -> ok end
                                                                    ,kapps_call:set_other_leg_call_id(<<"peer">>
                                                                                                     ,call())),
                          Data = kz_json:from_list([{<<"dtmf_leg">>, <<"original">>} | Props]),
                          P = proc_lib:spawn(fun() -> konami_transfer:handle(Data, C) end),
                          R = monitor(process, P),
                          try
                              {pre_originate, S} = sys:get_state(P),
                              ?assertEqual(Expected, value(konami_transfer, extension, S))
                          after
                              stop(P, R)
                          end
                  end
                 ,[{[{<<"target">>, <<"3101">>}, {<<"captures">>, [<<"no_match">>]}], <<"3101">>}
                  ,{[{<<"target">>, <<"3101">>}, {<<"captures">>, [<<"3102">>]}], <<"3101">>}
                  ,{[{<<"captures">>, [<<"3102">>]}], <<"3102">>}]).

invalid_transfer_target() ->
    Parent = self(),
    C = kapps_call:set_custom_publish_function(fun(_, _) ->
                                                       Parent ! unexpected_command,
                                                       ok
                                               end
                                              ,call()),
    Data = kz_json:from_list([{<<"captures">>, [<<"no_match">>]}]),
    {P, R} = spawn_monitor(fun() -> konami_transfer:handle(Data, C) end),
    receive
        {'DOWN', R, process, P, {invalid_transfer_target, _}} ->
            ok
    after 1000 ->
            exit(P, kill),
            error(missing_target_not_rejected)
    end,
    receive
        unexpected_command ->
            error(unbridged_without_target)
    after 0 ->
            ok
    end.
