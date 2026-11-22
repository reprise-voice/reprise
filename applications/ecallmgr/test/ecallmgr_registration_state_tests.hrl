%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% Included after the module's records by the TEST build only.
registration_state_test_() ->
    [fun() ->
         registration_test_setup(),
         try Test() after registration_test_cleanup(ok) end
     end || Test <- [fun invalid_registration_preserves_row/0,
                     fun wildcard_unregister_is_valid/0,
                     fun a_replaced_contacts_unregister_is_ignored/0,
                     fun multiple_aors_do_not_crash/0,
                     fun refresh_repairs_missing_identity/0,
                     fun refresh_auth_failure_stays_unroutable/0,
                     fun refresh_keeps_complete_identity/0,
                     fun password_proxy_preserves_aor/0,
                     fun token_proxy_preserves_aor/0,
                     fun proxy_identity_stays_in_account/0]].

registration_test_setup() ->
    ets:new(?MODULE, [named_table, set, {keypos, #registration.id}]),
    register(?MODULE, self()),
    meck:new(kz_cache, [passthrough]),
    meck:expect(kz_cache, peek_local, fun(_, _) ->
        {ok, kz_json:from_list([{<<"Custom-Channel-Vars">>,
            kz_json:from_list([{<<"Account-ID">>, <<"0123456789abcdef0123456789abcdef">>},
                               {<<"Authorizing-ID">>, <<"device">>}])}])}
    end),
    ok.

registration_test_cleanup(_) ->
    meck:unload(kz_cache),
    unregister(?MODULE),
    ets:delete(?MODULE),
    registration_test_drain().

registration_test_drain() ->
    receive {'$gen_cast', _} -> registration_test_drain() after 0 -> ok end.

registration_test_event() ->
    kz_json:from_list([{<<"Event-Category">>, <<"directory">>},
                      {<<"Event-Name">>, <<"reg_success">>},
                      {<<"Msg-ID">>, <<"registration-test">>}, {<<"App-Name">>, <<"test">>}, {<<"App-Version">>, <<"1">>},
                      {<<"Event-Timestamp">>, 1}, {<<"Expires">>, 900},
                      {<<"Realm">>, <<"realm.invalid">>}, {<<"Username">>, <<"phone">>},
                      {<<"Contact">>, <<"sip:phone@192.0.2.1:5060">>},
                      {<<"Proxy-Path">>, <<"sip:192.0.2.2:5060">>}]).

invalid_registration_preserves_row() ->
    Reg = #registration{id={<<"phone">>, <<"realm.invalid">>}, contact= <<"old">>},
    ets:insert(?MODULE, Reg),
    lists:foreach(fun(Field) ->
        lists:foreach(fun(Value) ->
            Event = kz_json:set_value(Field, Value, registration_test_event()),
            ?assertMatch({error, _}, validate_registration(Event)),
            handle_reg_success(Event, []),
            ?assertEqual([Reg], ets:lookup(?MODULE, Reg#registration.id)),
            receive {'$gen_cast', _} -> ?assert(false) after 0 -> ok end
        end, [<<"<null>">>, <<>>, <<"sip:a@b,sip:c@d">>, 17, <<"tel:1234">>])
    end, [<<"Contact">>, <<"Original-Contact">>, <<"Proxy-Path">>]),
    ?assertEqual(ok, validate_registration(registration_test_event())).

wildcard_unregister_is_valid() ->
    Event = kz_json:set_values([{<<"Contact">>, <<"*">>}, {<<"Expires">>, 0}], registration_test_event()),
    ?assertEqual(ok, validate_registration(Event)),
    ?assertEqual(undefined, bridge_uri(<<"*">>, <<"sip:proxy.invalid">>, <<"phone">>, <<"realm.invalid">>)),
    ?assertMatch({error, _}, validate_registration(kz_json:set_value(<<"Expires">>, 900, Event))).

a_replaced_contacts_unregister_is_ignored() ->
    Reg = #registration{id={<<"phone">>, <<"realm.invalid">>}, username= <<"phone">>, realm= <<"realm.invalid">>,
                        account_id= <<"0123456789abcdef0123456789abcdef">>, authorizing_id= <<"device">>,
                        contact= <<"sip:phone@192.0.2.1:5060">>, expires=900, initial=false},
    ets:insert(?MODULE, Reg),
    Unregister = fun(Contact) ->
        kz_json:set_values([{<<"Contact">>, Contact}, {<<"Expires">>, 0}], registration_test_event())
    end,
    %% the late unregister of the contact this one replaced: the row stays and nothing is cast
    handle_reg_success(Unregister(<<"<sip:phone@192.0.2.1:5062>;expires=0">>), []),
    ?assertEqual([Reg], ets:lookup(?MODULE, Reg#registration.id)),
    receive {'$gen_cast', _} -> ?assert(false) after 0 -> ok end,
    %% the held contact's own unregister, as the SBC sends it, deletes
    handle_reg_success(Unregister(<<"<sip:phone@192.0.2.1:5060>;expires=0">>), []),
    receive {'$gen_cast', {delete_registration, _}} -> ok after 0 -> ?assert(false) end,
    %% so does a wildcard
    handle_reg_success(Unregister(<<"*">>), []),
    receive {'$gen_cast', {delete_registration, _}} -> ok after 0 -> ?assert(false) end,
    %% a user this node does not hold is deleted as before, for the notice
    ets:delete(?MODULE, Reg#registration.id),
    handle_reg_success(Unregister(<<"<sip:phone@192.0.2.1:5062>;expires=0">>), []),
    receive {'$gen_cast', {delete_registration, _}} -> ok after 0 -> ?assert(false) end.

multiple_aors_do_not_crash() ->
    A = #registration{id={<<"old">>, <<"realm.invalid">>}, username= <<"old">>, realm= <<"realm.invalid">>, account_id= <<"0123456789abcdef0123456789abcdef">>,
                      authorizing_id= <<"device">>, proxy= <<"sip:proxy.invalid">>},
    B = A#registration{id={<<"new">>, <<"realm.invalid">>}, username= <<"new">>},
    ets:insert(?MODULE, [A, B]),
    ?assertEqual({error, not_found}, lookup_proxy_path(<<"0123456789abcdef0123456789abcdef">>, <<"device">>)),
    ?assertEqual({error, not_found}, lookup_endpoint(<<"device">>, <<"0123456789abcdef0123456789abcdef">>)),
    ets:delete(?MODULE, B#registration.id),
    ?assertMatch({ok, <<"sip:proxy.invalid">>, _}, lookup_proxy_path(<<"0123456789abcdef0123456789abcdef">>, <<"device">>)),
    ?assertEqual({ok, []}, lookup_endpoint(<<"device">>, <<"0123456789abcdef0123456789abcdef">>)).

refresh_repairs_missing_identity() ->
    Reg = #registration{id={<<"phone">>, <<"realm.invalid">>}, username= <<"phone">>,
                        realm= <<"realm.invalid">>, contact= <<"sip:phone@192.0.2.1">>, expires=900, initial=false},
    insert_registration(Reg),
    ?assert(meck:called(kz_cache, peek_local, ['_', '_'])),
    receive {'$gen_cast', {insert_registration, Reg}} -> ok after 0 -> ?assert(false) end,
    receive {'$gen_cast', {update_registration, _, Props}} ->
        ?assertEqual(<<"0123456789abcdef0123456789abcdef">>, props:get_value(#registration.account_id, Props)),
        ?assertEqual(<<"device">>, props:get_value(#registration.authorizing_id, Props))
    after 0 -> ?assert(false) end.

refresh_keeps_complete_identity() ->
    Reg = #registration{id={<<"phone">>, <<"realm.invalid">>}, username= <<"phone">>, realm= <<"realm.invalid">>,
                        account_id= <<"0123456789abcdef0123456789abcdef">>, authorizing_id= <<"device">>, contact= <<"sip:phone@192.0.2.1">>,
                        expires=900, initial=false},
    insert_registration(Reg),
    ?assertNot(meck:called(kz_cache, peek_local, ['_', '_'])).

refresh_auth_failure_stays_unroutable() ->
    meck:expect(kz_cache, peek_local, fun(_, _) -> {error, not_found} end),
    meck:new(kz_amqp_worker, [passthrough]),
    meck:expect(kz_amqp_worker, call, fun(_, _, _) -> {error, timeout} end),
    Reg = #registration{id={<<"phone">>, <<"realm.invalid">>}, username= <<"phone">>, realm= <<"realm.invalid">>,
                        from_user= <<"phone">>, from_host= <<"realm.invalid">>,
                        to_user= <<"phone">>, to_host= <<"realm.invalid">>,
                        contact= <<"sip:phone@192.0.2.1">>, expires=900, initial=false},
    try
        insert_registration(Reg),
        ?assert(meck:called(kz_amqp_worker, call, ['_', '_', '_'])),
        receive {'$gen_cast', {insert_registration, Reg}} ->
            handle_cast({insert_registration, Reg}, test)
        after 0 -> ?assert(false) end,
        receive {'$gen_cast', {update_registration, _, _}} -> ?assert(false) after 0 -> ok end,
        ?assertEqual({error, not_found}, lookup_proxy_path(<<"0123456789abcdef0123456789abcdef">>, <<"device">>))
    after meck:unload(kz_amqp_worker) end.

password_proxy_preserves_aor() ->
    Props = proxy_vars([{<<"AOR">>, <<"sip:phone@realm.invalid">>}], #{}),
    ?assertEqual(<<"sip:phone@realm.invalid">>, props:get_value(<<"SIP-Invite-To-URI">>, Props)).

token_proxy_preserves_aor() ->
    Props = proxy_vars([{<<"AOR">>, <<"sip:phone@realm.invalid">>}], #{token_registration => true}),
    ?assertEqual(<<"sip:phone@realm.invalid">>, props:get_value(<<"SIP-Invite-To-URI">>, Props)),
    ?assertEqual(<<"sip:phone@realm.invalid">>, props:get_value(<<"KAZOO-AOR">>, Props)).

proxy_identity_stays_in_account() ->
    Reg = #registration{id={<<"phone">>, <<"realm.invalid">>}, username= <<"phone">>,
                        realm= <<"realm.invalid">>, account_id= <<"account-a">>,
                        authorizing_id= <<"device">>, proxy= <<"sip:proxy.invalid">>},
    ets:insert(?MODULE, Reg),
    {ok, <<"sip:proxy.invalid">>, Props} = lookup_proxy_path(<<"account-a">>, <<"device">>),
    ?assertEqual({error, not_found}, lookup_proxy_path(<<"account-b">>, <<"device">>)),
    ?assertEqual(<<"sip:phone@realm.invalid">>, props:get_value(<<"SIP-Invite-To-URI">>, Props)).
