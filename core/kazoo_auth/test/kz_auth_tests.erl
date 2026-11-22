%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_auth_tests).

-include_lib("eunit/include/eunit.hrl").
-include("kazoo_auth.hrl").

-define(ACCOUNT_ID, <<"account0000000000000000000000001">>).
-define(MISSING_ACCOUNT_ID, <<"account0000000000000000000000002">>).
-define(TEST_KEY_ID, <<"test-system-key">>).

%% Mint with kazoo's own (test) key and validate the result: the whole
%% path, from the identity signature to the public key lookup.
create_and_validate_test_() ->
    {'setup'
    ,fun setup/0
    ,fun kz_auth_test_util:cleanup/1
    ,fun(Key) ->
             [{"a minted token validates and carries the identity signature"
              ,?_test(round_trip())
              }
             ,{"the same token with the identity signature stripped is rejected"
              ,?_test(stripped_signature_rejected(Key))
              }
             ,{"an identity that cannot be signed is not minted"
              ,?_assertEqual({'error', 'identity_signing_failed'}, kz_auth:create_token(claims(?MISSING_ACCOUNT_ID)))
              }
             ,{"an identity that cannot be signed is minted unsigned when the deployment allows it"
              ,?_test(unsigned_when_allowed())
              }
             ]
     end
    }.

setup() ->
    kz_auth_test_util:setup(),
    Key = kz_auth_test_util:rsa_key(),
    AccountDb = kzs_util:format_account_db(?ACCOUNT_ID),
    AccountDoc = kz_json:from_list([{<<"_id">>, ?ACCOUNT_ID}
                                   ,{<<"pvt_signature_secret">>, <<"account-secret">>}
                                   ]),
    meck:expect('kz_datamgr', 'open_cache_doc'
               ,fun(Db, ?ACCOUNT_ID) when Db =:= AccountDb -> {'ok', AccountDoc};
                   (_, _) -> {'error', 'not_found'}
                end
               ),
    meck:expect('kz_cache', 'fetch_local'
               ,fun(?PK_CACHE, {'private', ?TEST_KEY_ID}) -> {'ok', Key};
                   (_, _) -> {'error', 'not_found'}
                end
               ),
    Key.

claims(AccountId) ->
    [{<<"account_id">>, AccountId}
    ,{<<"exp">>, kz_auth_test_util:unix_now() + 60}
    ].

round_trip() ->
    {'ok', JWT} = kz_auth:create_token(claims(?ACCOUNT_ID)),

    {'ok', Claims} = kz_auth:validate_token(JWT),

    ?assertEqual(?ACCOUNT_ID, kz_json:get_value(<<"account_id">>, Claims)),
    ?assertEqual(<<"kazoo">>, kz_json:get_value(<<"iss">>, Claims)),
    ?assertNotEqual('undefined', kz_json:get_ne_binary_value(<<"identity_sig">>, Claims)).

stripped_signature_rejected(Key) ->
    {'ok', JWT} = kz_auth:create_token(claims(?ACCOUNT_ID)),
    {'ok', Header, Payload} = kz_auth_jwt:decode(JWT, 'false'),
    Stripped = kz_auth_test_util:sign_jwt(Key, Header, props:delete(<<"identity_sig">>, Payload)),

    ?assertEqual({'error', 'missing_identity_signature'}, kz_auth:validate_token(Stripped)).

unsigned_when_allowed() ->
    kz_auth_test_util:set_config([{<<"require_identity_signature">>, 'false'}]),

    {'ok', JWT} = kz_auth:create_token(claims(?MISSING_ACCOUNT_ID)),
    {'ok', _Header, Payload} = kz_auth_jwt:decode(JWT, 'false'),

    ?assertEqual('undefined', props:get_value(<<"identity_sig">>, Payload)),
    ?assertMatch({'ok', _}, kz_auth:validate_token(JWT)),
    kz_auth_test_util:set_config([]).
