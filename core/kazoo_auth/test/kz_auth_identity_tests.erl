%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_auth_identity_tests).

-include_lib("eunit/include/eunit.hrl").
-include("kazoo_auth.hrl").

-define(ACCOUNT_ID, <<"account0000000000000000000000001">>).

identity_signature_test_() ->
    {'setup'
    ,fun setup/0
    ,fun kz_auth_test_util:cleanup/1
    ,fun(_) ->
             [{"a kazoo token without identity_sig fails"
              ,?_assertMatch(#{identify_verified := 'false'
                              ,identity_error := 'missing_identity_signature'
                              }
                            ,kz_auth_identity:token(kazoo_token([]))
                            )
              }
             ,{"a kazoo token without identity_sig passes when the deployment allows it"
              ,?_test(begin
                          kz_auth_test_util:set_config([{<<"require_identity_signature">>, 'false'}]),
                          ?assertMatch(#{identify_verified := 'true'}
                                      ,kz_auth_identity:token(kazoo_token([]))
                                      ),
                          kz_auth_test_util:set_config([])
                      end)
              }
             ,{"a kazoo token with the account's signature passes"
              ,?_assertMatch(#{identify_verified := 'true'}
                            ,kz_auth_identity:token(kazoo_token([{<<"identity_sig">>, signature()}]))
                            )
              }
             ,{"a kazoo token with another signature fails"
              ,?_assertMatch(#{identify_verified := 'false'
                              ,identity_error := 'invalid_identity_signature'
                              }
                            ,kz_auth_identity:token(kazoo_token([{<<"identity_sig">>, kz_base64url:encode(<<"forged">>)}]))
                            )
              }
             ]
     end
    }.

setup() ->
    kz_auth_test_util:setup(),
    AccountDb = kzs_util:format_account_db(?ACCOUNT_ID),
    AccountDoc = kz_json:from_list([{<<"_id">>, ?ACCOUNT_ID}
                                   ,{<<"pvt_signature_secret">>, <<"account-secret">>}
                                   ]),
    meck:expect('kz_datamgr', 'open_cache_doc'
               ,fun(Db, ?ACCOUNT_ID) when Db =:= AccountDb -> {'ok', AccountDoc};
                   (_, _) -> {'error', 'not_found'}
                end
               ).

kazoo_token(Claims) ->
    #{auth_provider => kz_auth_providers:kazoo_auth_provider()
     ,payload => maps:from_list([{<<"account_id">>, ?ACCOUNT_ID} | Claims])
     }.

signature() ->
    {'ok', Signature} = kz_auth_identity:sign(#{<<"account_id">> => ?ACCOUNT_ID}),
    kz_base64url:encode(Signature).
