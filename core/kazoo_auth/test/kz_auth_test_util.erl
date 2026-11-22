%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc Shared fixtures for the kazoo_auth tests: the data layer, the
%%% caches and the HTTP client are replaced with meck so a test can run
%%% without a database or a network, and set what each lookup answers.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_auth_test_util).

-export([setup/0
        ,cleanup/1
        ,set_config/1
        ,rsa_key/0
        ,sign_jwt/3
        ,jwks/2
        ,unix_now/0
        ]).

-include("kazoo_auth.hrl").

%%------------------------------------------------------------------------------
%% @doc Mock `kz_datamgr', `kz_cache' and `kz_http'. Every lookup answers
%% "not found" until a test says otherwise with `meck:expect/3'; the caches
%% answer "not found" and accept stores so no key or token is remembered
%% between cases.
%% @end
%%------------------------------------------------------------------------------
-spec setup() -> 'ok'.
setup() ->
    _ = meck:new('kz_datamgr', []),
    _ = meck:new('kz_cache', []),
    _ = meck:new('kz_http', []),
    meck:expect('kz_datamgr', 'open_cache_doc', fun(_, _) -> {'error', 'not_found'} end),
    meck:expect('kz_datamgr', 'get_single_result', fun(_, _, _) -> {'error', 'not_found'} end),
    meck:expect('kz_cache', 'fetch_local', fun(_, _) -> {'error', 'not_found'} end),
    meck:expect('kz_cache', 'peek_local', fun(_, _) -> {'error', 'not_found'} end),
    meck:expect('kz_cache', 'store_local', fun(_, _, _) -> 'ok' end),
    meck:expect('kz_cache', 'store_local', fun(_, _, _, _) -> 'ok' end),
    set_config([]),
    'ok'.

-spec cleanup(any()) -> 'ok'.
cleanup(_) ->
    meck:unload().

%%------------------------------------------------------------------------------
%% @doc Make `system_config/auth' answer with the given keys (and a fixed
%% signing secret and system key so signatures are reproducible); every
%% other category is missing, so its defaults apply.
%% @end
%%------------------------------------------------------------------------------
-spec set_config(kz_term:proplist()) -> 'ok'.
set_config(Props) ->
    Defaults = [{?KAZOO_SIGNATURE_ID, <<"test-signature-secret">>}
               ,{<<"system_key">>, <<"test-system-key">>}
               ],
    Node = kz_json:from_list(Props ++ Defaults),
    Doc = kz_json:from_list([{<<"_id">>, ?CONFIG_CAT}
                            ,{<<"default">>, Node}
                            ]),
    meck:expect('kz_datamgr', 'open_doc'
               ,fun(?KZ_CONFIG_DB, ?CONFIG_CAT) -> {'ok', Doc};
                   (_, _) -> {'error', 'not_found'}
                end
               ).

-spec rsa_key() -> public_key:private_key().
rsa_key() ->
    public_key:generate_key({'rsa', 2048, 65537}).

%%------------------------------------------------------------------------------
%% @doc An RS256 JWT over the given header and payload, signed with the key.
%% @end
%%------------------------------------------------------------------------------
-spec sign_jwt(public_key:private_key(), kz_term:proplist(), kz_term:proplist()) -> kz_term:ne_binary().
sign_jwt(Key, Header, Payload) ->
    Header64 = kz_base64url:encode(kz_json:encode(kz_json:from_list(Header))),
    Payload64 = kz_base64url:encode(kz_json:encode(kz_json:from_list(Payload))),
    Signed = <<Header64/binary, ".", Payload64/binary>>,
    Signature = kz_base64url:encode(public_key:sign(Signed, 'sha256', Key)),
    <<Signed/binary, ".", Signature/binary>>.

%%------------------------------------------------------------------------------
%% @doc A JWKS document holding the public half of the key under `Kid'.
%% @end
%%------------------------------------------------------------------------------
-spec jwks(public_key:private_key(), kz_term:ne_binary()) -> kz_json:object().
jwks(#'RSAPrivateKey'{modulus=N, publicExponent=E}, Kid) ->
    Key = kz_json:from_list([{<<"kid">>, Kid}
                            ,{<<"kty">>, <<"RSA">>}
                            ,{<<"alg">>, <<"RS256">>}
                            ,{<<"n">>, kz_base64url:encode(binary:encode_unsigned(N))}
                            ,{<<"e">>, kz_base64url:encode(binary:encode_unsigned(E))}
                            ]),
    kz_json:from_list([{<<"keys">>, [Key]}]).

-spec unix_now() -> pos_integer().
unix_now() ->
    erlang:system_time('seconds').
