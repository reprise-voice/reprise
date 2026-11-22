%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_parallel_dial_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("xmerl/include/xmerl.hrl").

parallel_wire_contract_test_() ->
    Endpoints = [kz_json:new(), kz_json:new()],
    [{"parallel endpoints retain the simultaneous contract",
      ?_assertEqual(<<",">>, ecallmgr_util:get_dial_separator(<<"simultaneous">>, Endpoints))}
    ,{"single strategy remains ordered",
      ?_assertEqual(<<"|">>, ecallmgr_util:get_dial_separator(<<"single">>, Endpoints))}
    ,{"one endpoint does not create a spurious enterprise leg",
      ?_assertEqual(<<"|">>, ecallmgr_util:get_dial_separator(<<"simultaneous">>, [kz_json:new()]))}
    ,{"channel variables retain the producer contract",
      ?_assertMatch(<<"<", _/binary>>, iolist_to_binary(ecallmgr_fs_xml:get_channel_vars(
         kz_json:from_list([{<<"Custom-Channel-Vars">>, kz_json:from_list([{<<"Account-ID">>, <<"account">>}])}]))))}
    ].

directory_append_separator_test() ->
    Endpoint = kz_json:from_list([{<<"Endpoint-Type">>, <<"user">>}
                                ,{<<"Domain-Name">>, <<"account">>}
                                ,{<<"User-ID">>, <<"user">>}
                                ,{<<"Endpoint-Dial-String">>, <<"kz/a@account,kz/b@account">>}
                                ]),
    meck:new(kapps_config, [non_strict, no_link]),
    meck:expect(kapps_config, get_ne_binary, fun(_, _, Default) -> Default end),
    try
        {ok, XML} = ecallmgr_fs_xml:directory_resp_endpoint_xml(node(), Endpoint, kz_json:new()),
        {Doc, _} = xmerl_scan:string(lists:flatten(XML)),
        Values = xmerl_xpath:string("//param[@name='endpoint-separator']/@value", Doc),
        ?assertEqual([","], [Value || #xmlAttribute{value=Value} <- Values])
    after meck:unload(kapps_config) end.
