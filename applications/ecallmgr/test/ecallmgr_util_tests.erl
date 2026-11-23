%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_util_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/ecallmgr.hrl").

maybe_sanitize_fs_value_test_() ->
    UTF8Bin = <<"Bör1-Goes2$%^ To4 Škofja Loka"/utf8>>,
    Expected = <<"Bör1-Goes2 To4 Škofja Loka"/utf8>>,

    Keys = [<<"Outbound-Caller-ID-Name">>
           ,<<"Outbound-Callee-ID-Name">>
           ,<<"Caller-ID-Name">>
           ,<<"Callee-ID-Name">>
           ],
    TestMsg = fun(KeyStr) ->
                      lists:flatten(["When sanitizing "
                                    ,kz_term:to_list(KeyStr)
                                    ,"'s value it should allow utf8 characters"
                                    ])
              end,
    [{TestMsg(Key)
     ,?_assertEqual(Expected, ecallmgr_util:maybe_sanitize_fs_value(Key, UTF8Bin))
     }
     || Key <- Keys
    ].

build_simple_channels_test_() ->
    SIPHeaders = kz_json:from_list([{<<"X-Account-ID">>, <<"{account_id}">>}
                                   ,{<<"X-Billing-Number">>, <<"1234">>}
                                   ,{<<"X-Caller-Macro">>, <<"{caller_id_number}">>}
                                   ]),

    Endpoint = kz_json:from_list([{<<"Invite-Format">>, <<"username">>}
                                 ,{<<"To-User">>, <<"to_user">>}
                                 ,{<<"To-Realm">>, <<"to_realm">>}
                                 ,{<<"To-DID">>, <<"to_did">>}
                                 ]),
    [{"simple channels"
     ,?_assertEqual([<<"sofia/", ?SIP_INTERFACE, "/to_user@to_realm">>], ecallmgr_util:build_simple_channels([Endpoint]))
     }
    ,{"with custom sip headers"
     ,?_assertEqual([<<"[^^"
                       ?BRIDGE_CHANNEL_VAR_SEPARATOR
                       "sip_h_X-Caller-Macro='${caller_id_number}'"
                       ?BRIDGE_CHANNEL_VAR_SEPARATOR
                       "sip_h_X-Billing-Number='1234'"
                       ?BRIDGE_CHANNEL_VAR_SEPARATOR
                       "sip_h_X-Account-ID='${ecallmgr_Account-ID}']"
                       "sofia/", ?SIP_INTERFACE, "/to_user@to_realm"
                     >>
                    ]
                   ,ecallmgr_util:build_simple_channels(
                      [kz_json:set_value(<<"Custom-SIP-Headers">>, SIPHeaders, Endpoint)]
                     )
                   )
     }
    ].

%%------------------------------------------------------------------------------
%% Sofia places `Identity' from the `sip_h_' variable itself and then sends
%% every `sip_h_*' variable as an extra header, so the signer answers an
%% `Exclude-Outgoing-Extra-Header' with the `Identity' and stepswitch puts
%% both on the endpoint. These pin the wiring from that endpoint to the
%% dial string, with and without the bridge command in between.
%%------------------------------------------------------------------------------

-define(PASSPORT, <<"eyJhbGciOiJFUzI1NiIsInBwdCI6InNoYWtlbiIsInR5cCI6InBhc3Nwb3J0In0"
                    ".eyJhdHRlc3QiOiJBIn0.c2lnbmF0dXJl"
                    ";info=<https://certs.example.invalid/k.pem>;alg=ES256;ppt=shaken"
                  >>).
-define(STIR_EXCLUSION, <<"^sip_h_[Ii]dentity$">>).

signed_leg_carries_identity_once_test_() ->
    DialString = ecallmgr_util:build_bridge_string([signed_endpoint()]),
    [{"the dial string sets sip_h_Identity once"
     ,?_assertEqual(1, occurrences(<<"sip_h_Identity='">>, DialString))
     }
    ,{"and carries the signer's exclusion"
     ,?_assertEqual(1, occurrences(<<"exclude_outgoing_extra_header='", ?STIR_EXCLUSION/binary, "'">>, DialString))
     }
    ].

signed_leg_through_the_bridge_command_test_() ->
    Req = [{<<"Application-Name">>, <<"bridge">>}
          ,{<<"Call-ID">>, <<"a-leg-call-id">>}
          ,{<<"Msg-ID">>, <<"msg-id">>}
          ,{<<"Endpoints">>, [signed_endpoint()]}
           | kz_api:default_headers(<<"call">>, <<"command">>, <<"stepswitch">>, <<"1.0">>)
          ],
    {'ok', Payload} = kapi_dialplan:bridge(Req),
    Endpoints = kz_json:get_list_value(<<"Endpoints">>, kz_json:decode(Payload)),
    DialString = ecallmgr_util:build_bridge_string(Endpoints),
    [{"the leg built from the published command sets sip_h_Identity once"
     ,?_assertEqual(1, occurrences(<<"sip_h_Identity='">>, DialString))
     }
    ,{"and carries the signer's exclusion"
     ,?_assertEqual(1, occurrences(<<"exclude_outgoing_extra_header='", ?STIR_EXCLUSION/binary, "'">>, DialString))
     }
    ].

%% A carrier endpoint as stepswitch_stir leaves it after a signed answer.
-spec signed_endpoint() -> kz_json:object().
signed_endpoint() ->
    kz_json:from_list(
      [{<<"Invite-Format">>, <<"route">>}
      ,{<<"Route">>, <<"sip:+15552001353@carrier.invalid">>}
      ,{<<"To-DID">>, <<"+15552001353">>}
      ,{<<"Custom-SIP-Headers">>, kz_json:from_list([{<<"X-Account-ID">>, <<"e1670784712716304bf982f8ab7c46cf">>}
                                                    ,{<<"Identity">>, ?PASSPORT}
                                                    ])}
      ,{<<"Exclude-Outgoing-Extra-Header">>, ?STIR_EXCLUSION}
      ]).

-spec occurrences(binary(), binary()) -> non_neg_integer().
occurrences(Needle, Haystack) ->
    length(binary:matches(Haystack, Needle)).
