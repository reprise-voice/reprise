%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_auth_keys_tests).

-include_lib("eunit/include/eunit.hrl").
-include("kazoo_auth.hrl").

-define(ISSUER, <<"https://idp.example">>).
-define(DISCOVERY_URL, <<"https://idp.example/.well-known/openid-configuration">>).
-define(JWKS_URL, <<"https://idp.example/jwks">>).
-define(KID, <<"idp-key-1">>).
-define(ACCOUNT_ID, <<"account0000000000000000000000001">>).

-define(DISCOVERY_DOC, kz_json:from_list([{<<"issuer">>, ?ISSUER}
                                         ,{<<"jwks_uri">>, ?JWKS_URL}
                                         ])).

-define(PROVIDER_DOC, kz_json:from_list([{<<"_id">>, <<"idp">>}
                                        ,{<<"pvt_type">>, <<"provider">>}
                                        ,{<<"issuer_domain">>, ?ISSUER}
                                        ,{<<"discovery">>, ?DISCOVERY_URL}
                                        ])).

%% A token an outside issuer signed with its own key, offering that key
%% through OIDC discovery. It is trusted only when the issuer is registered.
issuer_discovery_test_() ->
    {'setup'
    ,fun setup/0
    ,fun kz_auth_test_util:cleanup/1
    ,fun({Key, JWT}) ->
             [{"an issuer with no registered provider gets no discovery and fails"
              ,?_test(unregistered_issuer_rejected(JWT))
              }
             ,{"an unregistered issuer fails the identity check on its own"
              ,?_test(unregistered_issuer_identity())
              }
             ,{"a token with no issuer fails the identity check"
              ,?_test(no_issuer_identity())
              }
             ,{"a registered provider's discovery still verifies the token"
              ,?_test(registered_issuer_verified(Key, JWT))
              }
             ]
     end
    }.

setup() ->
    kz_auth_test_util:setup(),
    Key = kz_auth_test_util:rsa_key(),
    _ = meck:new('kz_auth_util', ['passthrough']),
    meck:expect('kz_auth_util', 'get_json_from_url'
               ,fun(?DISCOVERY_URL) -> {'ok', ?DISCOVERY_DOC};
                   (?JWKS_URL) -> {'ok', kz_auth_test_util:jwks(Key, ?KID)};
                   (_) -> {'error', 'not_found'}
                end
               ),
    {Key, sign(Key)}.

sign(Key) ->
    Header = [{<<"alg">>, <<"RS256">>}
             ,{<<"typ">>, <<"JWT">>}
             ,{<<"kid">>, ?KID}
             ],
    Payload = [{<<"iss">>, ?ISSUER}
              ,{<<"account_id">>, ?ACCOUNT_ID}
              ,{<<"exp">>, kz_auth_test_util:unix_now() + 3600}
              ],
    kz_auth_test_util:sign_jwt(Key, Header, Payload).

unregistered_issuer_rejected(JWT) ->
    meck:reset('kz_auth_util'),
    meck:expect('kz_datamgr', 'get_single_result', fun(_, _, _) -> {'error', 'not_found'} end),

    ?assertMatch({'error', _}, kz_auth:validate_token(JWT)),
    ?assertEqual(0, meck:num_calls('kz_auth_util', 'get_json_from_url', '_')).

unregistered_issuer_identity() ->
    Token = #{auth_provider => {'error', 'not_found'}
             ,payload => #{<<"iss">> => ?ISSUER, <<"account_id">> => ?ACCOUNT_ID}
             },
    ?assertMatch(#{identify_verified := 'false'
                  ,identity_error := 'issuer_not_registered'
                  }
                ,kz_auth_identity:token(Token)
                ).

no_issuer_identity() ->
    Token = #{payload => #{<<"account_id">> => ?ACCOUNT_ID}},
    ?assertMatch(#{identify_verified := 'false'
                  ,identity_error := 'issuer_not_registered'
                  }
                ,kz_auth_identity:token(Token)
                ).

registered_issuer_verified(_Key, JWT) ->
    meck:reset('kz_auth_util'),
    Row = kz_json:from_list([{<<"key">>, ?ISSUER}
                            ,{<<"doc">>, ?PROVIDER_DOC}
                            ]),
    meck:expect('kz_datamgr', 'get_single_result'
               ,fun(?KZ_AUTH_DB, <<"auth/issuer_domain">>, _Options) -> {'ok', Row};
                   (_, _, _) -> {'error', 'not_found'}
                end
               ),

    {'ok', Claims} = kz_auth:validate_token(JWT),

    ?assertEqual(?ACCOUNT_ID, kz_json:get_value(<<"account_id">>, Claims)),
    ?assert(meck:called('kz_auth_util', 'get_json_from_url', [?DISCOVERY_URL])),
    ?assert(meck:called('kz_auth_util', 'get_json_from_url', [?JWKS_URL])).
