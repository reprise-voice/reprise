%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_auth_client_tests).

-include_lib("eunit/include/eunit.hrl").
-include("kazoo_auth.hrl").

-define(APP_ID, <<"gce-app">>).
-define(METADATA_URL, "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token").
-define(STUB_URL, <<"http://127.0.0.1:8181/token">>).

-define(APP_DOC, kz_json:from_list([{<<"_id">>, ?APP_ID}
                                   ,{<<"name">>, ?APP_ID}
                                   ,{<<"pvt_type">>, <<"app">>}
                                   ,{<<"pvt_auth_provider">>, <<"gce_metadata">>}
                                   ])).

-define(TOKEN_BODY, <<"{\"access_token\":\"ya29.test-token\",\"expires_in\":3599,\"token_type\":\"Bearer\"}">>).

gce_metadata_test_() ->
    {'setup'
    ,fun setup/0
    ,fun kz_auth_test_util:cleanup/1
    ,fun(_) ->
             [{"a 200 from the metadata server becomes the app's token"
              ,?_test(token_from_metadata_server())
              }
             ,{"the caller's scopes do not change the request"
              ,?_test(scopes_are_ignored())
              }
             ,{"the metadata URL comes from system_config/auth"
              ,?_test(url_from_config())
              }
             ,{"a 503 from the metadata server is an error"
              ,?_test(metadata_server_unavailable())
              }
             ,{"an unreachable metadata server is an error"
              ,?_test(metadata_server_unreachable())
              }
             ]
     end
    }.

setup() ->
    kz_auth_test_util:setup(),
    meck:expect('kz_datamgr', 'open_cache_doc'
               ,fun(?KZ_AUTH_DB, ?APP_ID) -> {'ok', ?APP_DOC};
                   (_, _) -> {'error', 'not_found'}
                end
               ).

token_from_metadata_server() ->
    meck:expect('kz_http', 'get', fun(_Url, _Headers) -> {'ok', 200, [], ?TOKEN_BODY} end),

    {'ok', #{token := Token}} = kz_auth_client:token_for_app(?APP_ID),

    ?assertMatch(#{access_token := <<"ya29.test-token">>
                  ,token_type := <<"Bearer">>
                  ,expires_in := 3599
                  ,authorization := <<"Bearer ya29.test-token">>
                  }
                ,Token
                ),
    ?assert(meck:called('kz_http', 'get', [?METADATA_URL, '_'])),
    Headers = meck:capture('last', 'kz_http', 'get', '_', 2),
    ?assert(lists:member({"Metadata-Flavor", "Google"}, Headers)).

scopes_are_ignored() ->
    meck:reset('kz_http'),
    meck:expect('kz_http', 'get', fun(_Url, _Headers) -> {'ok', 200, [], ?TOKEN_BODY} end),
    Options = #{'scopes' => [<<"https://www.googleapis.com/auth/devstorage.read_write">>]},

    {'ok', #{token := Token}} = kz_auth_client:token_for_app(?APP_ID, Options),

    ?assertMatch(#{authorization := <<"Bearer ya29.test-token">>}, Token),
    ?assert(meck:called('kz_http', 'get', [?METADATA_URL, '_'])),
    ?assertEqual(0, meck:num_calls('kz_http', 'post', '_')).

url_from_config() ->
    kz_auth_test_util:set_config([{<<"gce_metadata_url">>, ?STUB_URL}]),
    meck:reset('kz_http'),
    meck:expect('kz_http', 'get', fun(_Url, _Headers) -> {'ok', 200, [], ?TOKEN_BODY} end),

    {'ok', _} = kz_auth_client:token_for_app(?APP_ID),

    ?assert(meck:called('kz_http', 'get', [kz_term:to_list(?STUB_URL), '_'])),
    kz_auth_test_util:set_config([]).

metadata_server_unavailable() ->
    meck:expect('kz_http', 'get', fun(_Url, _Headers) -> {'ok', 503, [], <<"unavailable">>} end),

    ?assertMatch({'error', #{error := _}}, kz_auth_client:token_for_app(?APP_ID)).

metadata_server_unreachable() ->
    meck:expect('kz_http', 'get', fun(_Url, _Headers) -> {'error', 'econnrefused'} end),

    ?assertMatch({'error', #{error := _}}, kz_auth_client:token_for_app(?APP_ID)).
