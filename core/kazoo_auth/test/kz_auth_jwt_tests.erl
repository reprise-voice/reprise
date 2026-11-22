%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_auth_jwt_tests).

-include_lib("eunit/include/eunit.hrl").
-include("kazoo_auth.hrl").

-define(ACCOUNT_ID, <<"account0000000000000000000000001">>).

%% The signature is checked against a key handed in with the token, and the
%% provider is a bare registered one, so only the expiry check decides.
expiration_test_() ->
    {'setup'
    ,fun setup/0
    ,fun kz_auth_test_util:cleanup/1
    ,fun(Key) ->
             [{"a token without exp is rejected"
              ,?_assertEqual({'error', 'no_expiration'}, validate(Key, []))
              }
             ,{"a token without exp is accepted when the deployment allows it"
              ,?_test(begin
                          kz_auth_test_util:set_config([{<<"allow_tokens_without_expiry">>, 'true'}]),
                          ?assertMatch({'ok', _}, validate(Key, [])),
                          kz_auth_test_util:set_config([])
                      end)
              }
             ,{"an elapsed exp is rejected"
              ,?_assertEqual({'error', 'token_expired'}, validate(Key, [{<<"exp">>, unix_now() - 1}]))
              }
             ,{"an exp that is not a timestamp is rejected"
              ,?_assertEqual({'error', 'invalid_expiration'}, validate(Key, [{<<"exp">>, 'null'}]))
              }
             ,{"a future exp is accepted"
              ,?_assertMatch({'ok', _}, validate(Key, [{<<"exp">>, unix_now() + 60}]))
              }
             ]
     end
    }.

setup() ->
    kz_auth_test_util:setup(),
    kz_auth_test_util:rsa_key().

unix_now() ->
    kz_auth_test_util:unix_now().

validate(Key, Claims) ->
    Header = [{<<"alg">>, <<"RS256">>}
             ,{<<"typ">>, <<"JWT">>}
             ,{<<"kid">>, <<"idp-key">>}
             ],
    Payload = [{<<"iss">>, <<"idp">>}
              ,{<<"account_id">>, ?ACCOUNT_ID}
               | Claims
              ],
    {'ok', Parsed} = kz_auth_jwt:parse(kz_auth_test_util:sign_jwt(Key, Header, Payload)),
    Token = Parsed#{auth_provider => #{name => <<"idp">>}
                   ,jwt_public_key => kz_auth_keys:get_public_key_from_private_key(Key)
                   },
    kz_auth:validate_token(Token).
