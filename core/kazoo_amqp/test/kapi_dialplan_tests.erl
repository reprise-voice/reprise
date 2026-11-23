%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kapi_dialplan_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PASSPORT, <<"eyJhbGciOiJFUzI1NiIsInBwdCI6InNoYWtlbiIsInR5cCI6InBhc3Nwb3J0In0"
                    ".eyJhdHRlc3QiOiJBIn0.c2lnbmF0dXJl"
                    ";info=<https://certs.example.invalid/k.pem>;alg=ES256;ppt=shaken"
                  >>).
-define(EXCLUSION, <<"^sip_h_[Ii]dentity$">>).

%% `bridge/1' rebuilds every endpoint from the endpoint definition's
%% headers; a key the definition does not name is dropped on the way to
%% ecallmgr. The signer's exclusion rides on the endpoint, so it has to
%% be one of them.
bridge_endpoint_keeps_the_signers_exclusion_test_() ->
    Endpoint = kz_json:from_list(
                 [{<<"Invite-Format">>, <<"route">>}
                 ,{<<"Route">>, <<"sip:+15552001353@carrier.invalid">>}
                 ,{<<"To-DID">>, <<"+15552001353">>}
                 ,{<<"Custom-SIP-Headers">>, kz_json:from_list([{<<"Identity">>, ?PASSPORT}])}
                 ,{<<"Exclude-Outgoing-Extra-Header">>, ?EXCLUSION}
                 ]),
    Req = [{<<"Application-Name">>, <<"bridge">>}
          ,{<<"Call-ID">>, <<"a-leg-call-id">>}
          ,{<<"Msg-ID">>, kz_binary:rand_hex(16)}
          ,{<<"Endpoints">>, [Endpoint]}
           | kz_api:default_headers(<<"call">>, <<"command">>, <<"stepswitch">>, <<"1.0">>)
          ],
    {'ok', Payload} = kapi_dialplan:bridge(Req),
    [Sent] = kz_json:get_list_value(<<"Endpoints">>, kz_json:decode(iolist_to_binary(Payload))),
    [{"the exclusion survives the bridge command"
     ,?_assertEqual(?EXCLUSION, kz_json:get_value(<<"Exclude-Outgoing-Extra-Header">>, Sent))
     }
    ,{"the Identity header survives with it"
     ,?_assertEqual(?PASSPORT, kz_json:get_value([<<"Custom-SIP-Headers">>, <<"Identity">>], Sent))
     }
    ,{"the exclusion is an optional endpoint header"
     ,?_assert(lists:member(<<"Exclude-Outgoing-Extra-Header">>
                           ,kapi_dialplan:optional_bridge_req_endpoint_headers()
                           ))
     }
    ,{"an exclusion that is not a regex string fails the endpoint"
     ,?_assertNot(kapi_dialplan:bridge_endpoint_v(
                    kz_json:set_value(<<"Exclude-Outgoing-Extra-Header">>, [kz_json:new()], Endpoint)
                   ))
     }
    ,{"and so does an empty one"
     ,?_assertNot(kapi_dialplan:bridge_endpoint_v(
                    kz_json:set_value(<<"Exclude-Outgoing-Extra-Header">>, <<>>, Endpoint)
                   ))
     }
    ].
