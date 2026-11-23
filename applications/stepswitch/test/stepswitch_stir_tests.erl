%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc `stepswitch_stir' against a stand-in `stir@outbound' compiled here:
%%% the module absent, an answer merged, an error, a crash, and an answer
%%% later than the budget, none of which may change the endpoints or leave
%%% anything in the caller's mailbox.
%%% @end
%%%-----------------------------------------------------------------------------
-module(stepswitch_stir_tests).

-include_lib("eunit/include/eunit.hrl").

-define(OUTBOUND, 'stir@outbound').
-define(FAKE_FILE, "stir@outbound.erl").
-define(NUMBER, <<"+14155551212">>).
%% where `stepswitch_stir' keeps the signer's header until the leg is formatted
-define(OWN_IDENTITY, <<"Stir-Identity">>).
-define(IDENTITY, <<"eyJhbGciOiJFUzI1NiJ9.e30.sig;info=<https://api.example/v2/stir/certs/k1.pem>;alg=ES256;ppt=shaken">>).

%% The stand-in dispatches on the caller id number, which the facts carry.
-define(FAKE_SOURCE,
        "-module('stir@outbound').\n"
        "-export([headers/1]).\n"
        "headers(#{<<\"orig_number\">> := <<\"+15550000001\">>}) ->\n"
        "    {ok, #{<<\"Identity\">> => <<\"" ++ binary_to_list(?IDENTITY) ++ "\">>,\n"
        "           <<\"Exclude-Outgoing-Extra-Header\">> => <<\"^sip_h_[Ii]dentity$\">>,\n"
        "           <<\"Custom-Channel-Vars\">> => #{<<\"STIR-Attest\">> => <<\"A\">>,\n"
        "                                            <<\"STIR-Orig-ID\">> => <<\"orig-1\">>}}};\n"
        "headers(#{<<\"orig_number\">> := <<\"+15550000002\">>}) -> {error, <<\"disabled\">>};\n"
        "headers(#{<<\"orig_number\">> := <<\"+15550000003\">>}) -> erlang:error(boom);\n"
        "headers(#{<<\"orig_number\">> := <<\"+15550000004\">>}) -> timer:sleep(1500), {ok, #{<<\"Identity\">> => <<\"late\">>}};\n"
        "headers(#{<<\"orig_number\">> := <<\"+15550000005\">>}) ->\n"
        "    {ok, #{<<\"Identity\">> => <<\"inbound-jws\">>,\n"
        "           <<\"Exclude-Outgoing-Extra-Header\">> => <<\"^sip_h_[Ii]dentity$\">>,\n"
        "           <<\"Custom-Channel-Vars\">> => #{<<\"STIR-Verdict-Source\">> => <<\"passthrough\">>}}};\n"
        "headers(#{<<\"orig_number\">> := <<\"+15550000006\">>}) -> not_a_result;\n"
        "headers(#{<<\"orig_number\">> := <<\"+15550000007\">>}) ->\n"
        "    {ok, #{<<\"Identity\">> => <<>>, <<\"Exclude-Outgoing-Extra-Header\">> => <<>>,\n"
        "           <<\"Custom-Channel-Vars\">> => #{<<\"STIR-Attest\">> => <<\"A\">>}}};\n"
        "headers(Facts) -> {ok, #{<<\"Custom-Channel-Vars\">> => Facts}}.\n"
       ).

%%------------------------------------------------------------------------------
%% Without the stir application
%%------------------------------------------------------------------------------

absent_test_() ->
    {'setup'
    ,fun hide_stir/0
    ,fun restore_stir/1
    ,fun(_) ->
             [{"no stir module: endpoints unchanged but for the opt-out flag"
              ,?_assertEqual(stripped(), stepswitch_stir:maybe_sign(?NUMBER, offnet(<<"+15550000001">>), endpoints()))
              }
             ,{"no stir module: nothing left in the mailbox"
              ,?_assertEqual({'message_queue_len', 0}, process_info(self(), 'message_queue_len'))
              }
             ,{"no endpoints: nothing to do"
              ,?_assertEqual([], stepswitch_stir:maybe_sign(?NUMBER, offnet(<<"+15550000001">>), []))
              }
             ]
     end
    }.

%%------------------------------------------------------------------------------
%% With the stand-in
%%------------------------------------------------------------------------------

present_test_() ->
    {'setup'
    ,fun load_fake/0
    ,fun unload_fake/1
    ,fun(_) ->
             [{"signed: header, switch and CCVs on every leg that did not opt out", fun signed/0}
             ,{"error answer: endpoints unchanged", fun error_answer/0}
             ,{"crash: endpoints unchanged", fun crash/0}
             ,{"late answer: endpoints unchanged, mailbox empty", {'timeout', 10, fun late/0}}
             ,{"passthrough answer carries the inbound header", fun passthrough/0}
             ,{"answer of the wrong shape: endpoints unchanged", fun wrong_shape/0}
             ,{"an empty header or exclusion is left off the endpoint", fun empty_answer/0}
             ,{"a request with no call id is not a call to sign", fun no_call_id/0}
             ,{"facts", fun facts/0}
             ,{"inception is the presence of a route, not its text", fun inception/0}
             ,{"privacy comes off the endpoints as well as the request", fun privacy/0}
             ,{"the carrier the call came in from is a fact", fun inbound_carrier/0}
             ,{"unsigned leg: the request's Identity is dropped", fun foreign_identity_unsigned/0}
             ,{"signed leg: the request's identity is dropped, ours kept", fun foreign_identity_signed/0}
             ,{"a resource's own Identity is dropped", fun foreign_identity_resource/0}
             ,{"passthrough: the signer's inbound header is kept", fun foreign_identity_passthrough/0}
             ,{"a formatter cannot rewrite our Identity, nor strip it", fun foreign_identity_formatter/0}
             ,{"only Identity headers are dropped", fun foreign_identity_others/0}
             ,{"a leg that never went through maybe_sign goes out bare", fun foreign_identity_never_signed/0}
             ,{"the signer's private key never survives formatting", fun own_identity_key_taken_off/0}
             ]
     end
    }.

%% An empty exclusion would fail the bridge endpoint's type and drop the
%% endpoint from the bridge; an empty header would reach FreeSWITCH as no
%% variable at all. Neither is worth carrying.
empty_answer() ->
    [Endpoint | _] = stepswitch_stir:maybe_sign(?NUMBER, offnet(<<"+15550000007">>), endpoints()),
    ?assertEqual('undefined', kz_json:get_value(?OWN_IDENTITY, Endpoint)),
    ?assertEqual('undefined', kz_json:get_value([<<"Custom-SIP-Headers">>, <<"Identity">>], Endpoint)),
    ?assertEqual('undefined', kz_json:get_value(<<"Exclude-Outgoing-Extra-Header">>, Endpoint)),
    ?assertEqual(<<"A">>, kz_json:get_value([<<"Custom-Channel-Vars">>, <<"STIR-Attest">>], Endpoint)).

signed() ->
    [Signed, OptedOut, Bare] = stepswitch_stir:maybe_sign(?NUMBER, offnet(<<"+15550000001">>), endpoints()),
    %% the header waits under the private key; formatting the leg writes it
    ?assertEqual(?IDENTITY, kz_json:get_value(?OWN_IDENTITY, Signed)),
    ?assertEqual('undefined', kz_json:get_value([<<"Custom-SIP-Headers">>, <<"Identity">>], Signed)),
    ?assertEqual(<<"X-Existing">>, kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-Keep">>], Signed)),
    ?assertEqual(<<"^sip_h_[Ii]dentity$">>, kz_json:get_value(<<"Exclude-Outgoing-Extra-Header">>, Signed)),
    ?assertEqual(<<"A">>, kz_json:get_value([<<"Custom-Channel-Vars">>, <<"STIR-Attest">>], Signed)),
    ?assertEqual(<<"orig-1">>, kz_json:get_value([<<"Custom-Channel-Vars">>, <<"STIR-Orig-ID">>], Signed)),
    ?assertEqual(<<"res1">>, kz_json:get_value([<<"Custom-Channel-Vars">>, <<"Resource-ID">>], Signed)),
    ?assertEqual(<<"sip:+14155551212@gw1">>, kz_json:get_value(<<"Route">>, Signed)),

    %% the routing flag is gone from every leg, signed or not
    ?assertEqual('undefined', kz_json:get_value([<<"Custom-Channel-Vars">>, <<"Stir-Sign">>], Signed)),
    ?assertEqual(lists:nth(2, stripped()), OptedOut),
    ?assertEqual('undefined', kz_json:get_value([<<"Custom-Channel-Vars">>, <<"Stir-Sign">>], OptedOut)),

    ?assertEqual(?IDENTITY, kz_json:get_value(?OWN_IDENTITY, Bare)),
    ?assertEqual(<<"A">>, kz_json:get_value([<<"Custom-Channel-Vars">>, <<"STIR-Attest">>], Bare)),
    ?assertEqual({'message_queue_len', 0}, process_info(self(), 'message_queue_len')).

error_answer() ->
    unchanged(<<"+15550000002">>).

crash() ->
    unchanged(<<"+15550000003">>).

late() ->
    Started = erlang:monotonic_time('millisecond'),
    unchanged(<<"+15550000004">>),
    Elapsed = erlang:monotonic_time('millisecond') - Started,
    ?assert(Elapsed >= 600),
    ?assert(Elapsed < 1400),
    %% the stand-in would have answered at 1500 ms; the proxy is gone by now
    timer:sleep(1200),
    ?assertEqual({'message_queue_len', 0}, process_info(self(), 'message_queue_len')).

%% A passthrough answer has the shape of a signed one: the inbound header
%% is what goes out, and this module cannot tell the two apart.
passthrough() ->
    [Passthru, OptedOut, _] = stepswitch_stir:maybe_sign(?NUMBER, offnet(<<"+15550000005">>), endpoints()),
    ?assertEqual(<<"inbound-jws">>, kz_json:get_value(?OWN_IDENTITY, Passthru)),
    ?assertEqual(<<"^sip_h_[Ii]dentity$">>, kz_json:get_value(<<"Exclude-Outgoing-Extra-Header">>, Passthru)),
    ?assertEqual(<<"passthrough">>, kz_json:get_value([<<"Custom-Channel-Vars">>, <<"STIR-Verdict-Source">>], Passthru)),
    ?assertEqual(lists:nth(2, stripped()), OptedOut).

wrong_shape() ->
    unchanged(<<"+15550000006">>).

%% `stepswitch_maintenance:process_number/1,2' builds an offnet request out
%% of a number alone; nothing about it is a call.
no_call_id() ->
    Offnet = kz_json:delete_key(<<"Call-ID">>, offnet(<<"+15550000001">>)),
    Endpoints = endpoints(),
    ?assertEqual(stripped(), stepswitch_stir:maybe_sign(?NUMBER, Offnet, Endpoints)),
    ?assertEqual({'message_queue_len', 0}, process_info(self(), 'message_queue_len')).

unchanged(CallerId) ->
    ?assertEqual(stripped(), stepswitch_stir:maybe_sign(?NUMBER, offnet(CallerId), endpoints())),
    ?assertEqual({'message_queue_len', 0}, process_info(self(), 'message_queue_len')).

facts() ->
    [Endpoint | _] = stepswitch_stir:maybe_sign(?NUMBER, forwarded_offnet(<<"+15550000099">>), endpoints()),
    Facts = kz_json:get_json_value(<<"Custom-Channel-Vars">>, Endpoint),
    Expected = [{<<"account_id">>, <<"account0000000000000000000000001">>}
               ,{<<"orig_number">>, <<"+15550000099">>}
               ,{<<"dest_number">>, ?NUMBER}
               ,{<<"inception">>, <<"offnet">>}
               ,{<<"call_forward">>, <<"true">>}
               ,{<<"retain_cid">>, <<"true">>}
               ,{<<"privacy_hide_number">>, <<"true">>}
               ,{<<"inbound_verstat">>, <<"TN-Validation-Passed">>}
               ,{<<"inbound_attest">>, <<"C">>}
               ,{<<"inbound_carrier">>, <<"true">>}
               ,{<<"inbound_caller">>, <<"+15551234567">>}
               ,{<<"inbound_identity">>, <<"inbound-jws">>}
               ,{<<"budget_ms">>, <<"500">>}
               ],
    [?assertEqual({Key, Value}, {Key, kz_json:get_value(Key, Facts)}) || {Key, Value} <- Expected],
    %% not emergency, so the key is left out; two resources, so no resource facts
    ?assertEqual('undefined', kz_json:get_value(<<"emergency">>, Facts)),
    ?assertEqual('undefined', kz_json:get_value(<<"resource_id">>, Facts)),
    ?assertEqual('undefined', kz_json:get_value(<<"resource_sign">>, Facts)),

    %% every leg of one resource that opted out: the signer's answer touches none
    OptedOut = [kz_json:set_values([{[<<"Custom-Channel-Vars">>, <<"Resource-ID">>], <<"res2">>}
                                   ,{[<<"Custom-Channel-Vars">>, <<"Stir-Sign">>], 'false'}
                                   ]
                                  ,Endpoint1
                                  )
                || Endpoint1 <- endpoints()
               ],
    ?assertEqual([strip(E) || E <- OptedOut]
                ,stepswitch_stir:maybe_sign(?NUMBER, forwarded_offnet(<<"+15550000099">>), OptedOut)
                ),

    %% one resource, one emergency leg among its legs
    Emergency = [kz_json:set_values([{[<<"Custom-Channel-Vars">>, <<"Resource-ID">>], <<"res1">>}
                                    ,{[<<"Custom-Channel-Vars">>, <<"Stir-Sign">>], 'true'}
                                    ]
                                   ,Endpoint1
                                   )
                 || Endpoint1 <- endpoints()
                ],
    [_, Second | _] = Emergency,
    Emergency2 = [hd(Emergency)
                 ,kz_json:set_value([<<"Custom-Channel-Vars">>, <<"Emergency-Resource">>], <<"true">>, Second)
                  | tl(tl(Emergency))
                 ],
    [Signed | _] = stepswitch_stir:maybe_sign(?NUMBER, forwarded_offnet(<<"+15550000099">>), Emergency2),
    Facts2 = kz_json:get_json_value(<<"Custom-Channel-Vars">>, Signed),
    ?assertEqual(<<"true">>, kz_json:get_value(<<"emergency">>, Facts2)),
    ?assertEqual(<<"res1">>, kz_json:get_value(<<"resource_id">>, Facts2)),
    ?assertEqual('undefined', kz_json:get_value(<<"resource_sign">>, Facts2)).

%% Kazoo's `Inception' is a route, `<number>@<realm>'; what the signer is
%% told is that the call came in from offnet, not the route itself.
inception() ->
    ?assertEqual(<<"offnet">>, fact(<<"inception">>, forwarded_offnet(<<"+15550000099">>))),

    OnOffnet = kz_json:set_value(<<"Inception">>
                               ,<<"+15551234567@4a6863.sip.2600hz.local">>
                               ,offnet(<<"+15550000099">>)
                               ),
    ?assertEqual(<<"offnet">>, fact(<<"inception">>, OnOffnet)),

    %% a call that started here has no inception at all
    ?assertEqual('undefined', fact(<<"inception">>, offnet(<<"+15550000099">>))).

privacy() ->
    ?assertEqual(<<"false">>, fact(<<"privacy_hide_number">>, offnet(<<"+15550000099">>))),

    %% the gateway's own flag is on the endpoint, not on the request
    Hidden = [kz_json:set_value(<<"Privacy-Hide-Number">>, 'true', hd(endpoints()))
             ,lists:nth(3, endpoints())
             ],
    [Endpoint | _] = stepswitch_stir:maybe_sign(?NUMBER, offnet(<<"+15550000099">>), Hidden),
    ?assertEqual(<<"true">>
                ,kz_json:get_value(<<"privacy_hide_number">>, kz_json:get_json_value(<<"Custom-Channel-Vars">>, Endpoint))
                ).

inbound_carrier() ->
    ?assertEqual('undefined', fact(<<"inbound_carrier">>, offnet(<<"+15550000099">>))),
    ?assertEqual('undefined', fact(<<"inbound_caller">>, offnet(<<"+15550000099">>))),
    ?assertEqual(<<"true">>, fact(<<"inbound_carrier">>, forwarded_offnet(<<"+15550000099">>))),
    ?assertEqual(<<"+15551234567">>, fact(<<"inbound_caller">>, forwarded_offnet(<<"+15550000099">>))),
    %% the level the inbound call carried, which a forward is never signed above
    ?assertEqual('undefined', fact(<<"inbound_attest">>, offnet(<<"+15550000099">>))),
    ?assertEqual(<<"C">>, fact(<<"inbound_attest">>, forwarded_offnet(<<"+15550000099">>))).

%%------------------------------------------------------------------------------
%% Foreign `Identity' headers: Kazoo alone decides the one on a carrier leg
%%------------------------------------------------------------------------------

%% A trunk's own header, as `Custom-SIP-Headers' carries it into the
%% offnet request.
-define(FOREIGN, <<"eyJmb3JlaWduIjp0cnVlfQ.e30.pbx;info=<https://pbx.example/cert.pem>">>).

%% The signer said no: nothing may carry an `Identity', whatever the request
%% or the resource asked for, and whatever the case of the name.
foreign_identity_unsigned() ->
    Configured = with_resource_identity(<<"identity">>, endpoints()),
    Refused = with_request_headers([{<<"Identity">>, ?FOREIGN}], offnet(<<"+15550000002">>)),
    [?assertEqual([], identities(Leg)) || Leg <- carrier_legs(Refused, Configured)],
    %% the resource opted out of a signed request: same
    Signing = with_request_headers([{<<"Identity">>, ?FOREIGN}], offnet(<<"+15550000001">>)),
    [_, OptedOut, _] = carrier_legs(Signing, Configured),
    ?assertEqual([], identities(OptedOut)),
    ?assertEqual(<<"v">>, kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-Other">>], OptedOut)).

foreign_identity_signed() ->
    Offnet = with_request_headers([{<<"identity">>, ?FOREIGN}], offnet(<<"+15550000001">>)),
    [Signed, OptedOut, Bare] = carrier_legs(Offnet, endpoints()),
    ?assertEqual([{<<"Identity">>, ?IDENTITY}], identities(Signed)),
    ?assertEqual([{<<"Identity">>, ?IDENTITY}], identities(Bare)),
    ?assertEqual([], identities(OptedOut)),
    %% the exclusion rides with the header it was written for, and only there
    ?assertEqual(<<"^sip_h_[Ii]dentity$">>, kz_json:get_value(<<"Exclude-Outgoing-Extra-Header">>, Signed)),
    ?assertEqual('undefined', kz_json:get_value(<<"Exclude-Outgoing-Extra-Header">>, OptedOut)),

    %% the request's `Identity' in the case ours is spelled in: still theirs
    Same = with_request_headers([{<<"Identity">>, ?FOREIGN}], offnet(<<"+15550000001">>)),
    ?assertEqual([{<<"Identity">>, ?IDENTITY}], identities(hd(carrier_legs(Same, endpoints())))).

foreign_identity_resource() ->
    Configured = with_resource_identity(<<"IDENTITY">>, endpoints()),
    [Signed, OptedOut, _] = carrier_legs(offnet(<<"+15550000001">>), Configured),
    ?assertEqual([{<<"Identity">>, ?IDENTITY}], identities(Signed)),
    ?assertEqual(<<"X-Existing">>, kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-Keep">>], Signed)),
    ?assertEqual([], identities(OptedOut)),

    %% the signer answers an error: the legs go out unsigned, and bare
    Refused = carrier_legs(offnet(<<"+15550000002">>), Configured),
    [?assertEqual([], identities(Leg)) || Leg <- Refused],
    %% a resource whose only header was the Identity has none left
    ?assertEqual('undefined', kz_json:get_value(<<"Custom-SIP-Headers">>, lists:nth(2, Refused))).

foreign_identity_passthrough() ->
    Offnet = with_request_headers([{<<"identity">>, ?FOREIGN}], forwarded_offnet(<<"+15550000005">>)),
    Configured = with_resource_identity(<<"Identity">>, endpoints()),
    [Passthru, OptedOut, _] = carrier_legs(Offnet, Configured),
    ?assertEqual([{<<"Identity">>, <<"inbound-jws">>}], identities(Passthru)),
    ?assertEqual([], identities(OptedOut)).

%% A resource's formatters run after the merge and can rewrite or strip a
%% header that is there, the headers as a whole, or a top-level key; ours
%% is out of their reach until after them.
foreign_identity_formatter() ->
    Rewrite = kz_json:from_list([{<<"identity">>, [kz_json:from_list([{<<"value">>, ?FOREIGN}])]}
                                ,{<<"stir_identity">>, [kz_json:from_list([{<<"value">>, ?FOREIGN}])]}
                                ,{<<"x_other">>, [kz_json:from_list([{<<"value">>, <<"formatted">>}])]}
                                ]),
    Offnet = with_request_headers([{<<"Identity">>, ?FOREIGN}], offnet(<<"+15550000001">>)),
    [Signed, OptedOut, _] = carrier_legs(Offnet, endpoints(), Rewrite),
    ?assertEqual([{<<"Identity">>, ?IDENTITY}], identities(Signed)),
    ?assertEqual([], identities(OptedOut)),
    %% the formatter still applies to everything else
    ?assertEqual(<<"formatted">>, kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-Other">>], Signed)),

    %% stripping no longer keeps a signed Identity off: `stir.sign' does
    Strip = kz_json:from_list([{<<"custom_sip_headers">>, [kz_json:from_list([{<<"strip">>, 'true'}])]}]),
    [Stripped, StrippedOut, _] = carrier_legs(Offnet, endpoints(), Strip),
    ?assertEqual([{<<"Identity">>, ?IDENTITY}], identities(Stripped)),
    ?assertEqual('undefined', kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-Keep">>], Stripped)),
    ?assertEqual('undefined', kz_json:get_value(<<"Custom-SIP-Headers">>, StrippedOut)).

foreign_identity_others() ->
    Headers = kz_json:from_list([{<<"Identity">>, ?FOREIGN}
                                ,{<<"identity">>, ?FOREIGN}
                                ,{<<"X-Other">>, <<"v">>}
                                ,{<<"Identity-Info">>, <<"kept">>}
                                ,{<<"P-Identity">>, <<"kept">>}
                                ]),
    ?assertEqual(kz_json:from_list([{<<"X-Other">>, <<"v">>}
                                   ,{<<"Identity-Info">>, <<"kept">>}
                                   ,{<<"P-Identity">>, <<"kept">>}
                                   ])
                ,stepswitch_stir:drop_foreign_identity(Headers, <<"a test">>)
                ),
    ?assertEqual('undefined', stepswitch_stir:drop_foreign_identity('undefined', <<"a test">>)),
    NoIdentity = kz_json:from_list([{<<"X-Other">>, <<"v">>}]),
    ?assertEqual(NoIdentity, stepswitch_stir:drop_foreign_identity(NoIdentity, <<"a test">>)),

    Offnet = with_request_headers([{<<"identity">>, ?FOREIGN}
                                  ,{<<"Identity-Info">>, <<"kept">>}
                                  ,{<<"P-Identity">>, <<"kept">>}
                                  ]
                                 ,offnet(<<"+15550000001">>)
                                 ),
    [Signed, _, Bare] = carrier_legs(Offnet, endpoints()),
    [?assertEqual(<<"kept">>, kz_json:get_value([<<"Custom-SIP-Headers">>, Key], Leg))
     || Leg <- [Signed, Bare],
        Key <- [<<"Identity-Info">>, <<"P-Identity">>]
    ],
    ?assertEqual(<<"v">>, kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-Other">>], Signed)),
    ?assertEqual(<<"X-Existing">>, kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-Keep">>], Signed)),
    ?assertEqual(<<"v">>, kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-Other">>], Bare)).

%% `stepswitch_outbound:local_originate/2', or any other builder, can hand
%% the formatting an endpoint `maybe_sign/3' never saw. Whatever `Identity'
%% it carries is not the signer's, so the leg goes out with none.
foreign_identity_never_signed() ->
    Endpoint = kz_json:from_list_recursive([{<<"Route">>, <<"sip:+14155551212@gw9">>}
                                           ,{<<"Custom-SIP-Headers">>, [{<<"Identity">>, ?FOREIGN}
                                                                       ,{<<"X-Keep">>, <<"X-Existing">>}
                                                                       ]}
                                           ]),
    Formatted = stepswitch_util:format_sip_headers(Endpoint, kz_json:new(), kz_json:new()),
    ?assertEqual([], identities(Formatted)),
    ?assertEqual(<<"X-Existing">>, kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-Keep">>], Formatted)),
    %% with the request's own on top: still none
    Request = stepswitch_util:get_sip_headers(with_request_headers([{<<"identity">>, ?FOREIGN}], offnet(<<"+15550000001">>))),
    ?assertEqual([], identities(stepswitch_util:format_sip_headers(Endpoint, Request, kz_json:new()))).

%% Signed, passthrough, refused, opted out, with and without formatters: no
%% leg leaves the formatting with the private key, and a leg carries an
%% `Identity' exactly when it carries the exclusion that goes with it.
own_identity_key_taken_off() ->
    Offnets = [with_request_headers([{<<"identity">>, ?FOREIGN}], offnet(<<"+15550000001">>))
              ,with_request_headers([{<<"identity">>, ?FOREIGN}], forwarded_offnet(<<"+15550000005">>))
              ,offnet(<<"+15550000002">>)
              ],
    Formatters = [kz_json:new()
                 ,kz_json:from_list([{<<"stir_identity">>, [kz_json:from_list([{<<"strip">>, 'true'}])]}])
                 ,kz_json:from_list([{<<"custom_sip_headers">>, [kz_json:from_list([{<<"strip">>, 'true'}])]}])
                 ],
    Configured = with_resource_identity(<<"Identity">>, endpoints()),
    %% the signed and passthrough legs did carry it into the formatting
    ?assertEqual(4, length([Leg || Offnet <- Offnets,
                                   Leg <- stepswitch_stir:maybe_sign(?NUMBER, Offnet, Configured),
                                   kz_json:get_value(?OWN_IDENTITY, Leg) =/= 'undefined'
                           ])),
    Legs = [Leg || Offnet <- Offnets,
                   Formatter <- Formatters,
                   Leg <- carrier_legs(Offnet, Configured, Formatter)
           ],
    ?assertEqual(27, length(Legs)),
    [?assertEqual('undefined', kz_json:get_value(?OWN_IDENTITY, Leg)) || Leg <- Legs],
    [?assertEqual(identities(Leg) =/= []
                 ,kz_json:get_value(<<"Exclude-Outgoing-Extra-Header">>, Leg) =/= 'undefined'
                 )
     || Leg <- Legs
    ].

%% The carrier legs of one request as `stepswitch_util:format_endpoints/4'
%% builds their headers, but for the resource's formatters, which are given
%% here instead of read from the resource: the request's headers as
%% `get_sip_headers/1' reads them, each leg `maybe_sign/3' answers, and the
%% real `format_sip_headers/3' over both.
carrier_legs(Offnet, Endpoints) ->
    carrier_legs(Offnet, Endpoints, kz_json:new()).

carrier_legs(Offnet, Endpoints, Formatters) ->
    SIPHeaders = stepswitch_util:get_sip_headers(Offnet),
    [stepswitch_util:format_sip_headers(Leg, SIPHeaders, Formatters)
     || Leg <- stepswitch_stir:maybe_sign(?NUMBER, Offnet, Endpoints)
    ].

%% The offnet request's own `Custom-SIP-Headers', where a trunk's `Identity'
%% arrives.
with_request_headers(Extra, Offnet) ->
    kz_json:set_value(<<"Custom-SIP-Headers">>
                     ,kz_json:from_list([{<<"X-Other">>, <<"v">>} | Extra])
                     ,Offnet
                     ).

%% The signing resource's and the opted-out resource's own headers carry an
%% `Identity' under `Name'.
with_resource_identity(Name, [Signing, OptedOut, Bare]) ->
    [kz_json:set_value([<<"Custom-SIP-Headers">>, Name], <<"from-resource">>, Signing)
    ,kz_json:set_value([<<"Custom-SIP-Headers">>, Name], <<"from-resource">>, OptedOut)
    ,Bare
    ].

%% Every `Identity' header on a leg, whatever the case of its name.
identities(Leg) ->
    [{K, V} || {K, V} <- kz_json:to_proplist(kz_json:get_json_value(<<"Custom-SIP-Headers">>, Leg, kz_json:new())),
               kz_term:to_lower_binary(K) =:= <<"identity">>
    ].

%% The catch-all clause of the stand-in answers the facts back as channel
%% variables, so this reads one of them off the first endpoint.
fact(Key, Offnet) ->
    [Endpoint | _] = stepswitch_stir:maybe_sign(?NUMBER, Offnet, endpoints()),
    kz_json:get_value(Key, kz_json:get_json_value(<<"Custom-Channel-Vars">>, Endpoint)).

%%------------------------------------------------------------------------------
%% Fixtures
%%------------------------------------------------------------------------------

offnet(CallerId) ->
    kz_json:from_list_recursive(
      [{<<"Account-ID">>, <<"account0000000000000000000000001">>}
      ,{<<"Application-Name">>, <<"bridge">>}
      ,{<<"Call-ID">>, <<"call-1">>}
      ,{<<"Event-Category">>, <<"resource">>}
      ,{<<"Event-Name">>, <<"offnet_req">>}
      ,{<<"Outbound-Caller-ID-Number">>, CallerId}
      ,{<<"Resource-Type">>, <<"audio">>}
      ,{<<"To-DID">>, ?NUMBER}
      ,{<<"Requestor-Custom-Channel-Vars">>, [{<<"Caller-Screen-Bit">>, 'true'}]}
      ]).

%% The same request as a forward of a carrier call `cf_stir' has already
%% put a verdict on: `Inception' is the route the call came in on, and the
%% `STIR-*' channel variables are the ones `cf_stir' exports.
forwarded_offnet(CallerId) ->
    kz_json:set_values([{[<<"Requestor-Custom-Channel-Vars">>, <<"Inception">>], <<"+15551234567@4a6863.sip.2600hz.local">>}
                       ,{[<<"Requestor-Custom-Channel-Vars">>, <<"Call-Forward">>], 'true'}
                       ,{[<<"Requestor-Custom-Channel-Vars">>, <<"Retain-CID">>], <<"true">>}
                       ,{[<<"Requestor-Custom-Channel-Vars">>, <<"STIR-Verstat">>], <<"TN-Validation-Passed">>}
                       ,{[<<"Requestor-Custom-Channel-Vars">>, <<"STIR-Attest">>], <<"C">>}
                       ,{[<<"Requestor-Custom-Channel-Vars">>, <<"STIR-Inbound-Carrier">>], <<"true">>}
                       ,{[<<"Requestor-Custom-Channel-Vars">>, <<"STIR-Inbound-Caller">>], <<"+15551234567">>}
                       ,{[<<"Requestor-Custom-SIP-Headers">>, <<"identity">>], <<"inbound-jws">>}
                       ,{[<<"Custom-Channel-Vars">>, <<"Caller-Privacy-Hide-Number">>], 'true'}
                       ]
                      ,offnet(CallerId)
                      ).

%% Three legs: one of a resource that signs, one of a resource that opted
%% out, one with no CCVs and no SIP headers at all.
endpoints() ->
    [kz_json:from_list_recursive(
       [{<<"Route">>, <<"sip:+14155551212@gw1">>}
       ,{<<"Invite-Format">>, <<"route">>}
       ,{<<"Custom-SIP-Headers">>, [{<<"X-Keep">>, <<"X-Existing">>}]}
       ,{<<"Custom-Channel-Vars">>, [{<<"Resource-ID">>, <<"res1">>}
                                    ,{<<"Emergency-Resource">>, 'false'}
                                    ]}
       ])
    ,kz_json:from_list_recursive(
       [{<<"Route">>, <<"sip:+14155551212@gw2">>}
       ,{<<"Invite-Format">>, <<"route">>}
       ,{<<"Custom-Channel-Vars">>, [{<<"Resource-ID">>, <<"res2">>}
                                    ,{<<"Stir-Sign">>, 'false'}
                                    ]}
       ])
    ,kz_json:from_list(
       [{<<"Route">>, <<"sip:+14155551212@gw3">>}
       ,{<<"Invite-Format">>, <<"route">>}
       ])
    ].

%% The endpoints as they come back when nothing was signed: `Stir-Sign' is
%% read here and taken off again.
stripped() -> [strip(Endpoint) || Endpoint <- endpoints()].

strip(Endpoint) ->
    case kz_json:get_json_value(<<"Custom-Channel-Vars">>, Endpoint) of
        'undefined' -> Endpoint;
        CCVs -> kz_json:set_value(<<"Custom-Channel-Vars">>, kz_json:delete_key(<<"Stir-Sign">>, CCVs), Endpoint)
    end.

%% The stand-in is loaded with the real application off the code path
%% (hide_stir/0). Should a real `stir@outbound' still be found, loading over
%% it and purging it afterwards would break every later test in the run, so
%% the run stops here instead.
load_fake() ->
    Hidden = hide_stir(),
    ?assertEqual('non_existing', code:where_is_file("stir@outbound.beam")),
    Forms = forms(?FAKE_SOURCE),
    {'ok', ?OUTBOUND, Binary} = compile:forms(Forms, ['return_errors']),
    {'module', ?OUTBOUND} = code:load_binary(?OUTBOUND, ?FAKE_FILE, Binary),
    Hidden.

unload_fake(Hidden) ->
    unload_fake(),
    restore_stir(Hidden).

%% applications/stir is built wherever the gleam binary is (CI's build job
%% installs it), and its ebin is then on the code path through ERL_LIBS. For
%% the length of a group that ebin is taken off the path and a copy of the
%% module loaded from it is unloaded, so that `absent' means absent and the
%% stand-in replaces nothing; restore_stir/1 puts the path back.
hide_stir() ->
    unload_fake(),
    case code:where_is_file("stir@outbound.beam") of
        'non_existing' -> 'undefined';
        Beam ->
            Ebin = filename:dirname(Beam),
            'true' = code:del_path(Ebin),
            _ = code:purge(?OUTBOUND),
            _ = code:delete(?OUTBOUND),
            _ = code:purge(?OUTBOUND),
            Ebin
    end.

restore_stir('undefined') -> 'ok';
restore_stir(Ebin) ->
    'true' = code:add_pathz(Ebin),
    'ok'.

%% Only ever the stand-in: `code:which/1' answers the filename it was
%% loaded under, which nothing on the code path can be.
unload_fake() ->
    case code:which(?OUTBOUND) of
        ?FAKE_FILE ->
            _ = code:purge(?OUTBOUND),
            _ = code:delete(?OUTBOUND),
            _ = code:purge(?OUTBOUND),
            'ok';
        _NotOurs -> 'ok'
    end.

forms(Source) ->
    {'ok', Tokens, _} = erl_scan:string(Source),
    [begin {'ok', Form} = erl_parse:parse_form(FormTokens), Form end
     || FormTokens <- split_forms(Tokens, [], [])
    ].

split_forms([], [], Forms) -> lists:reverse(Forms);
split_forms([{'dot', _}=Dot | Rest], Acc, Forms) ->
    split_forms(Rest, [], [lists:reverse([Dot | Acc]) | Forms]);
split_forms([Token | Rest], Acc, Forms) ->
    split_forms(Rest, [Token | Acc], Forms).
