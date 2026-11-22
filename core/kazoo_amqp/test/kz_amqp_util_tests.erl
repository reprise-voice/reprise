%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2025, 2600Hz
%%% @doc Utilities to facilitate AMQP interaction
%%% @author James Aimonetti
%%% @author Karl Anderson
%%% @author Edouard Swiac
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_amqp_util_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kazoo_amqp/include/kz_amqp.hrl").

encode_key_test_() ->
    [?_assertEqual(<<"#">>, kz_amqp_util:encode(<<"#">>))
    ,?_assertEqual(<<"*">>, kz_amqp_util:encode(<<"*">>))
    ,?_assertEqual(<<"key">>, kz_amqp_util:encode(<<"key">>))
    ,?_assertEqual(<<"routing%2Ekey">>, kz_amqp_util:encode(<<"routing.key">>))
    ,?_assertEqual(<<"long%2Erouting%2Ekey">>, kz_amqp_util:encode(<<"long.routing.key">>))
    ,?_assertEqual(<<"test%26%2E192%2E+168%2E+5%2E+5%23">>, kz_amqp_util:encode(<<"test&.192. 168. 5. 5#">>))
    ].

%% What `basic_publish/5' would send, built and not sent.
prepare_basic_publish_test_() ->
    Headers = [{<<"X">>, 'longstr', <<"y">>}],
    {BP, AM} = kz_amqp_util:prepare_basic_publish(<<"targeted">>
                                                 ,<<"member.3">>
                                                 ,[<<"{\"a\"">>, <<":1}">>]
                                                 ,<<"application/json">>
                                                 ,[{'mandatory', 'true'}
                                                  ,{'delivery_mode', 2}
                                                  ,{'headers', Headers}
                                                  ,{'timestamp', 42}
                                                  ,{'maybe_publish', 'true'}
                                                  ]
                                                 ),
    {PidBP, #'amqp_msg'{props = #'P_basic'{headers = PidHeaders}}} =
        kz_amqp_util:prepare_basic_publish(<<"targeted">>, <<"pid://<0.1.0>/member.3">>, <<"{}">>, <<"application/json">>, []),
    [?_assertEqual(#'basic.publish'{exchange = <<"targeted">>
                                   ,routing_key = <<"member.3">>
                                   ,mandatory = 'true'
                                   ,immediate = 'false'
                                   }
                  ,BP
                  )
    ,?_assertEqual(#'amqp_msg'{payload = <<"{\"a\":1}">>
                              ,props = #'P_basic'{content_type = <<"application/json">>
                                                 ,headers = Headers
                                                 ,delivery_mode = 2
                                                 ,timestamp = 42
                                                 }
                              }
                  ,AM
                  )
    ,?_assertEqual(<<"member.3">>, PidBP#'basic.publish'.routing_key)
    ,?_assertEqual([{<<"Deliver-To-PID">>, 'binary', <<"<0.1.0>">>}], PidHeaders)
    ,?_assertError('function_clause'
                  ,kz_amqp_util:prepare_basic_publish(<<"targeted">>, <<"q">>, <<>>, <<"application/json">>, [])
                  )
    ].

%% A channel that is gone is an answer at once, not an exit and not a wait.
publish_on_a_gone_channel_test() ->
    {Pid, Ref} = spawn_monitor(fun() -> 'ok' end),
    receive {'DOWN', Ref, 'process', Pid, _} -> 'ok' end,
    {BP, AM} = kz_amqp_util:prepare_basic_publish(<<"targeted">>, <<"q">>, <<"{}">>, <<"application/json">>, []),
    ?assertMatch({'error', {'noproc', _}}, kz_amqp_channel:publish_on(Pid, BP, AM)).
