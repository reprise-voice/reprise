%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The Erlang behind `stir': what Gleam cannot say and Kazoo's own
%%% modules answer.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% Compiled by the Gleam compiler beside the Gleam sources, so: no parse
%%% transform (`lager:log/4' by hand, never `lager:debug/2'), no Kazoo header
%%% (literal atoms and binaries), and every call into a Kazoo module guarded
%%% with `code:ensure_loaded/1', so that `gleam test' runs with no release
%%% around it.
%%%
%%% Nothing in this module logs, prints or returns private key bytes.
%%% @end
%%%-----------------------------------------------------------------------------
-module(stir_ffi).

-export([register_views/0
        ,register_views_now/0
        ,no_return/0
        ,broker_available/0
        ,ensure_http_client/0
        ,getenv/1
        ,master_account_id/0
        ]).

%% Cryptography (worker A). Private key PEMs cross as binaries, are never
%% logged, and are answered only to `stir/keys' and `stir/signer'.
-export([generate_ec_key/0
        ,public_key_pem/1
        ,ecdsa_sign/2
        ,ecdsa_verify/3
        ,csr/4
        ,certificate_info/1
        ,certificates_pem/1
        ,certificate_matches_key/2
        ,validate_chain/5
        ,validate_chain_info/5
        ,validate_chain_with_anchors/6
        ,aes_gcm_seal/3
        ,aes_gcm_open/3
        ,sha256_hex/1
        ,random_bytes/1
        ,uuid/0
        ]).

%% A CRL `stir/trust' is about to store, authenticated before it is.
-export([authenticate_crl/4]).

%% HTTP (worker A implements; `httpc' needs `ssl' options `gleam_httpc'
%% does not expose).
-export([http_get/2
        ,receive_response/2
        ]).

%% The call path (worker W1): the number manager's answer for a number, a
%% call that cannot raise, and a JSON text as the plain map `stepswitch'
%% pattern-matches.
-export([lookup_number/1
        ,call_safely/1
        ,to_map/1
        ]).

%%------------------------------------------------------------------------------
%% @doc Register the application's CouchDB views and its JSON schemas, and
%% bind so that they are re-registered whenever the platform refreshes.
%% @end
%%------------------------------------------------------------------------------
-spec register_views() -> 'nil'.
register_views() ->
    _ = case code:ensure_loaded('kapps_maintenance') of
            {'error', _Reason} -> 'ok';
            {'module', 'kapps_maintenance'} ->
                catch kapps_maintenance:bind_and_register_views('stir'
                                                               ,'stir_ffi'
                                                               ,'register_views_now'
                                                               )
        end,
    'nil'.

%% @doc The callback `bind_and_register_views/3' binds and then calls. The
%% schemas under `priv/couchdb/schemas' go along: Crossbar validates from
%% the `system_schemas' database and loads only its own priv into it, so
%% the `stir_shaken' callflow action's schema is this application's to
%% register, and a cluster without `stir' has no such action.
-spec register_views_now() -> 'ok'.
register_views_now() ->
    _ = kz_datamgr:revise_docs_from_folder(<<"system_schemas">>, 'stir', <<"schemas">>),
    kz_datamgr:register_views_from_folder('stir').

%% @doc What `sup' reads as "printed already".
-spec no_return() -> 'no_return'.
no_return() -> 'no_return'.

%% @doc Whether there is a `gen_listener' in this VM at all: false under
%% `gleam run' and the test suite.
-spec broker_available() -> boolean().
broker_available() ->
    case code:ensure_loaded('gen_listener') of
        {'module', 'gen_listener'} -> 'true';
        {'error', _Reason} -> 'false'
    end.

%% @doc `inets' and `ssl' are extra applications of `gleam_httpc', so a
%% release start brings them up; this makes a bare test node work too.
-spec ensure_http_client() -> 'nil'.
ensure_http_client() ->
    _ = application:ensure_all_started('inets'),
    _ = application:ensure_all_started('ssl'),
    'nil'.

%% @doc An environment variable, if set and non-empty. This is how the
%% key-encryption key reaches the application; the value is never logged.
-spec getenv(binary()) -> {'ok', binary()} | {'error', 'nil'}.
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        'false' -> {'error', 'nil'};
        "" -> {'error', 'nil'};
        Value -> {'ok', unicode:characters_to_binary(Value)}
    end.

%% @doc The master account id, which platform-wide alerts are raised against.
-spec master_account_id() -> {'ok', binary()} | {'error', 'nil'}.
master_account_id() ->
    case code:ensure_loaded('kapps_util') of
        {'error', _} -> {'error', 'nil'};
        {'module', 'kapps_util'} ->
            try kapps_util:get_master_account_id() of
                {'ok', Id} -> {'ok', Id};
                _ -> {'error', 'nil'}
            catch
                _:_ -> {'error', 'nil'}
            end
    end.

%%%=============================================================================
%%% The call path
%%%=============================================================================

%% @doc The account a number is assigned to, in service and not pending a
%% port, from the number manager (`knm_numbers:lookup_account/1', which
%% caches). Every other answer is a reason: `unassigned', `not_in_service',
%% `account_disabled', `not_reconcilable', `pending_port'; and `no number
%% manager' on a node with no release around it, which is what a test node
%% is. Nothing raises: a number manager that crashes is a number nobody
%% owns for this call.
-spec lookup_number(binary()) -> {'ok', binary()} | {'error', binary()}.
lookup_number(Number) ->
    case code:ensure_loaded('knm_numbers') of
        {'error', _} -> {'error', <<"no number manager">>};
        {'module', 'knm_numbers'} ->
            try knm_numbers:lookup_account(Number) of
                {'ok', AccountId, Props} when is_binary(AccountId) ->
                    case knm_options:has_pending_port(Props) of
                        'true' -> {'error', <<"pending_port">>};
                        _ -> {'ok', AccountId}
                    end;
                {'error', {Why, _AccountId}} when is_atom(Why) ->
                    {'error', atom_to_binary(Why)};
                {'error', Why} when is_atom(Why) ->
                    {'error', atom_to_binary(Why)};
                _Other ->
                    {'error', <<"lookup failed">>}
            catch
                _:_ -> {'error', <<"lookup failed">>}
            end
    end.

%% @doc `Fun()', or `{error, <<"crash">>}' when it raised. Gleam has no
%% catch, and the outbound entry point is on the call path: whatever goes
%% wrong in it leaves the leg unsigned and the call proceeds.
-spec call_safely(fun(() -> Answer)) -> {'ok', Answer} | {'error', binary()}.
call_safely(Fun) ->
    try {'ok', Fun()}
    catch
        _Class:_Reason -> {'error', <<"crash">>}
    end.

%% @doc A JSON text as the plain map of binaries `stepswitch' reads: what
%% `kazoo/doc.to_string' wrote, decoded with `json:decode/1'. A text that
%% is not an object, or not JSON, is the empty map.
-spec to_map(binary()) -> map().
to_map(Json) ->
    try json:decode(Json) of
        Map when is_map(Map) -> Map;
        _Other -> #{}
    catch
        _:_ -> #{}
    end.

%%%=============================================================================
%%% Cryptography
%%%
%%% Everything below is OTP `public_key' and `crypto': no Kazoo module, so it
%%% runs the same under `gleam test' and in a release. OTP's own records are
%%% the only include, and it is OTP's, not Kazoo's.
%%%=============================================================================

-include_lib("public_key/include/public_key.hrl").

%% TNAuthList (RFC 8226 §3): id-pe-TNAuthList.
-define(TN_AUTH_LIST, {1,3,6,1,5,5,7,1,26}).

%% Seconds between year 0 and 1970-01-01T00:00:00Z: Gregorian to unix.
-define(UNIX_EPOCH, 62167219200).

%% @doc A fresh P-256 private key as a PKCS#8 `PRIVATE KEY' PEM.
%%
%% The key is in hand for the whole body, so nothing may escape uncaught: a
%% `badmatch' or a `crypto' error carries its arguments into the crash
%% report. The answer is a bare binary and has no error shape, so a failure
%% is one atom with no arguments beside it.
-spec generate_ec_key() -> binary().
generate_ec_key() ->
    try
        Key = public_key:generate_key({'namedCurve', ?'secp256r1'}),
        pem([public_key:pem_entry_encode('PrivateKeyInfo', Key)])
    catch
        _:_ -> erlang:error('generate_ec_key_failed')
    end.

%% @doc The `PUBLIC KEY' PEM of a private key PEM.
-spec public_key_pem(binary()) -> {'ok', binary()} | {'error', binary()}.
public_key_pem(PrivateKeyPem) ->
    try
        case private_key(PrivateKeyPem) of
            {'ok', Key} -> {'ok', spki_pem(public_of(Key))};
            {'error', _} = Error -> Error
        end
    catch
        _:Reason -> {'error', key_reason(Reason)}
    end.

%% @doc ECDSA over SHA-256 with the private key, answered as the raw 64-byte
%% `R||S' JWS wants, not DER.
-spec ecdsa_sign(binary(), binary()) -> {'ok', binary()} | {'error', binary()}.
ecdsa_sign(PrivateKeyPem, Message) ->
    try
        case private_key(PrivateKeyPem) of
            {'ok', Key} ->
                Der = public_key:sign(Message, 'sha256', Key),
                #'ECDSA-Sig-Value'{r = R, s = S} = public_key:der_decode('ECDSA-Sig-Value', Der),
                {'ok', <<R:256, S:256>>};
            {'error', _} = Error -> Error
        end
    catch
        _:Reason -> {'error', key_reason(Reason)}
    end.

%% @doc Verify a raw `R||S' signature against a `PUBLIC KEY' PEM or a
%% `CERTIFICATE' PEM (the first certificate of a chain).
-spec ecdsa_verify(binary(), binary(), binary()) -> boolean().
ecdsa_verify(PublicOrCertificatePem, Message, <<R:256, S:256>>) ->
    try
        {'ok', Public} = public_key_of(PublicOrCertificatePem),
        Der = public_key:der_encode('ECDSA-Sig-Value', #'ECDSA-Sig-Value'{r = R, s = S}),
        public_key:verify(Message, 'sha256', Der, Public)
    catch
        _:_ -> 'false'
    end;
ecdsa_verify(_Pem, _Message, _NotSixtyFourBytes) -> 'false'.

%% @doc A PKCS#10 CSR PEM for the key: subject `C=US, O=Org, CN=Cn', with the
%% TNAuthList extension (1.3.6.1.5.5.7.1.26) for the SPC requested, carried
%% in a PKCS#9 `extensionRequest' attribute and signed ecdsa-with-SHA256.
%% `Org' is the service provider's name and is required: ATIS-1000080 wants
%% C, O and CN in a SHAKEN certificate's subject.
-spec csr(binary(), binary(), binary(), binary()) -> {'ok', binary()} | {'error', binary()}.
csr(PrivateKeyPem, Org, Cn, Spc) ->
    try
        {'ok', Key} = private_key(PrivateKeyPem),
        'true' = is_ia5(Spc) orelse throw({'error', <<"spc must be ASCII">>}),
        'true' = Spc =/= <<>> orelse throw({'error', <<"spc is empty">>}),
        'true' = Org =/= <<>> orelse throw({'error', <<"organization is empty">>}),
        #'ECPrivateKey'{publicKey = Point, parameters = Params} = Key,
        Subject = {'rdnSequence'
                  ,[[#'SingleAttribute'{type = ?'id-at-countryName', value = "US"}]
                   ,[#'SingleAttribute'{type = ?'id-at-organizationName', value = {'utf8String', Org}}]
                   ,[#'SingleAttribute'{type = ?'id-at-commonName', value = {'utf8String', Cn}}]
                   ]},
        Extensions = [#'Extension'{extnID = ?TN_AUTH_LIST
                                  ,critical = 'false'
                                  ,extnValue = tn_auth_list(Spc)
                                  }],
        Info = #'CertificationRequestInfo'{
                  version = 0
                 ,subject = Subject
                 ,subjectPKInfo =
                      #'CertificationRequestInfo_subjectPKInfo'{
                         algorithm =
                             #'CertificationRequestInfo_subjectPKInfo_algorithm'{
                                algorithm = ?'id-ecPublicKey'
                               ,parameters = {'asn1_OPENTYPE', public_key:der_encode('EcpkParameters', Params)}
                               }
                        ,subjectPublicKey = Point
                        }
                 ,attributes =
                      [#'CertificationRequestInfo_attributes_SETOF'{
                          type = ?'pkcs-9-at-extensionRequest'
                         ,values = [{'asn1_OPENTYPE', public_key:der_encode('Extensions', Extensions)}]
                         }]
                 },
        Signature = public_key:sign(public_key:der_encode('CertificationRequestInfo', Info), 'sha256', Key),
        Request = #'CertificationRequest'{
                     certificationRequestInfo = Info
                    ,signatureAlgorithm =
                         #'CertificationRequest_signatureAlgorithm'{algorithm = ?'ecdsa-with-SHA256'}
                    ,signature = Signature
                    },
        Der = public_key:der_encode('CertificationRequest', Request),
        {'ok', pem([{'CertificationRequest', Der, 'not_encrypted'}])}
    catch
        'throw':{'error', _} = Error -> Error;
        'error':{'badmatch', {'error', _} = Error} -> Error;
        %% The private key is in hand here: `key_reason/1', not `reason/1'.
        _:Reason -> {'error', <<"csr failed: ", (key_reason(Reason))/binary>>}
    end.

%% @doc What a certificate chain PEM says, as JSON text: an object with
%% `subject' (string), `issuer', `serial' (hex), `not_before' and
%% `not_after' (unix seconds), `spcs' (the TNAuthList SPCs, strings),
%% `fingerprint' (`sha256:<hex>' of the leaf DER), `public_key_pem',
%% `chain_length', `is_ca'. The leaf is the first certificate.
-spec certificate_info(binary()) -> {'ok', binary()} | {'error', binary()}.
certificate_info(ChainPem) ->
    try
        Chain = [Leaf | _] = certificates(ChainPem),
        #'OTPCertificate'{tbsCertificate = TBS} = public_key:pkix_decode_cert(Leaf, 'otp'),
        #'OTPTBSCertificate'{serialNumber = Serial
                            ,issuer = Issuer
                            ,subject = Subject
                            ,validity = #'Validity'{notBefore = NotBefore, notAfter = NotAfter}
                            ,subjectPublicKeyInfo = Spki
                            ,extensions = Extensions
                            } = TBS,
        Info = #{'subject' => dn_to_binary(Subject)
                ,'issuer' => dn_to_binary(Issuer)
                ,'serial' => serial_hex(Serial)
                ,'not_before' => to_unix(NotBefore)
                ,'not_after' => to_unix(NotAfter)
                ,'spcs' => spcs(Extensions)
                ,'fingerprint' => <<"sha256:", (sha256_hex(Leaf))/binary>>
                ,'public_key_pem' => spki_pem(spki_key(Spki))
                ,'chain_length' => length(Chain)
                ,'is_ca' => is_ca(Extensions)
                },
        {'ok', iolist_to_binary(json:encode(Info))}
    catch
        'throw':{'error', _} = Error -> Error;
        _:Reason -> {'error', reason({'certificate', Reason})}
    end.

%% @doc Whether the chain's leaf carries the public key of the private key.
-spec certificate_matches_key(binary(), binary()) -> boolean().
certificate_matches_key(ChainPem, PrivateKeyPem) ->
    try
        [Leaf | _] = certificates(ChainPem),
        {'ok', Key} = private_key(PrivateKeyPem),
        {#'ECPoint'{point = KeyPoint}, _} = public_of(Key),
        {#'ECPoint'{point = CertPoint}, _} = spki_key(leaf_spki(Leaf)),
        KeyPoint =:= CertPoint
    catch
        _:_ -> 'false'
    end.

%% @doc `public_key:pkix_path_validation/3' of the chain against the trust
%% bundle (PEM, roots and intermediates), with the indirect CRL (PEM, may be
%% empty) and its signer's certificate (PEM, may be empty), at `Now' (unix).
%%
%% The anchor is the first certificate, walking the chain from its top, that
%% is in the bundle or was issued by a bundle certificate, so a bundle of
%% intermediates completes a chain that carries only its leaf. OTP checks
%% validity periods against the wall clock and offers no way to inject a
%% time, so every certificate is also checked against `Now' here, before
%% the call; the CRL's own window is checked against `Now' as well.
%%
%% The CRL check is done here rather than through `pkix_crls_validate/3':
%% that function judges the CRL's freshness by the wall clock alone, which
%% cannot be tested against a fixture. This does what it would for an
%% indirect CRL: the signer named separately must be the CRL's issuer,
%% carry `cRLSign', verify the CRL's signature, and chain to an anchor in
%% the trust bundle, which is therefore expected to hold the STI-PA's own
%% root beside the STI-CAs' roots; every certificate of the path is
%% then looked up by serial and issuer, following the `certificateIssuer'
%% entry extension an indirect CRL uses to name each entry's CA.
%%
%% The anchor is checked against the CRL beside the path below it, unless
%% it is self-signed. `pkix_path_validation/3' takes the anchor on trust
%% and never looks at it again, so an STI-CA certificate that the STI-PA
%% has revoked but that is still sitting in the stored bundle would go on
%% anchoring chains: a revocation only reaches a certificate the check
%% actually walks. A self-signed root is excluded because a root that
%% revokes itself says nothing the bundle does not already decide.
%%
%% This arity is the loose form, and the one the STI-PA's own signer
%% chains go through (`stir/trust.check_signer', `stir/stipa'): a list
%% signer is not a SHAKEN end-entity certificate and carries no
%% TNAuthList. The verify-time forms are `validate_chain_with_anchors/6'
%% and `validate_chain_info/5', which hold the leaf to RFC 8226 as well.
-spec validate_chain(binary(), binary(), binary(), binary(), integer()) -> {'ok', 'nil'} | {'error', binary()}.
validate_chain(ChainPem, TrustPem, CrlPem, CrlSignerPem, Now) ->
    case validate(ChainPem, TrustPem, CrlPem, CrlSignerPem, TrustPem, Now, 'any_leaf') of
        {'ok', _Spcs} -> {'ok', 'nil'};
        {'error', _} = Error -> Error
    end.

%% @doc `validate_chain/5' with the CRL signer held to its own anchors.
%%
%% The certificate that signs the STI-PA's CRL and the certificates that
%% sign calls are not the same population: the first chains to the
%% pinned STI-PA roots, the second to the STI-CAs the STI-PA publishes.
%% Holding both to one bundle means any STI-CA in the list can mint a
%% certificate that signs a revocation list, and an empty list signed
%% that way is how a revoked signer comes back. `CrlAnchorsPem' is the
%% pinned set; `validate_chain/5' passes `TrustPem' for it, which is the
%% old behaviour.
%%
%% Verify-time: the leaf is held to RFC 8226 (see `check_leaf/1').
-spec validate_chain_with_anchors(binary(), binary(), binary(), binary(), binary(), integer()) ->
          {'ok', 'nil'} | {'error', binary()}.
validate_chain_with_anchors(ChainPem, TrustPem, CrlPem, CrlSignerPem, CrlAnchorsPem, Now) ->
    case validate(ChainPem, TrustPem, CrlPem, CrlSignerPem, CrlAnchorsPem, Now, 'shaken_leaf') of
        {'ok', _Spcs} -> {'ok', 'nil'};
        {'error', _} = Error -> Error
    end.

%% @doc What `validate_chain/5' decided, and what the leaf is for: JSON
%% text, an object with `spcs' (the leaf's TNAuthList entries, strings).
%%
%% The same checks and the same errors, verify-time leaf constraints
%% included; the answer carries the SPCs so that a caller can hold an
%% inbound call's `orig' to the service provider codes the certificate
%% was actually issued for, which is the whole point of the extension
%% and which no caller could do while the answer was `nil'.
-spec validate_chain_info(binary(), binary(), binary(), binary(), integer()) ->
          {'ok', binary()} | {'error', binary()}.
validate_chain_info(ChainPem, TrustPem, CrlPem, CrlSignerPem, Now) ->
    case validate(ChainPem, TrustPem, CrlPem, CrlSignerPem, TrustPem, Now, 'shaken_leaf') of
        {'ok', Spcs} -> {'ok', iolist_to_binary(json:encode(#{'spcs' => Spcs}))};
        {'error', _} = Error -> Error
    end.

-spec validate(binary(), binary(), binary(), binary(), binary(), integer(), 'any_leaf' | 'shaken_leaf') ->
          {'ok', [binary()]} | {'error', binary()}.
validate(ChainPem, TrustPem, CrlPem, CrlSignerPem, CrlAnchorsPem, Now, LeafPolicy) ->
    try
        Chain = [Leaf | _] = certificates(ChainPem),
        Bundle = case certificates_or_empty(TrustPem) of
                     [] -> throw({'error', <<"empty trust bundle">>});
                     Certs -> Certs
                 end,
        'ok' = check_validity(Chain, Now),
        {Anchor, Path} = anchor_and_path(lists:reverse(Chain), Bundle),
        'ok' = path_validation(Anchor, Path),
        Spcs = check_leaf(LeafPolicy, Leaf),
        CrlAnchors = certificates_or_empty(CrlAnchorsPem),
        'ok' = check_crl(crl_path(Anchor, Path), trim_bytes(CrlPem), CrlSignerPem, CrlAnchors, Now),
        {'ok', Spcs}
    catch
        'throw':{'error', _} = Error -> Error;
        _:Reason -> {'error', reason({'validate_chain', Reason})}
    end.

%% @doc AES-256-GCM: `Nonce(12) || Tag(16) || Ciphertext', fresh nonce.
%%
%% The plaintext is a private key, so no failure may carry it: a
%% `function_clause' would put the key in the crash report's argument
%% list. Every failure is one atom with nothing beside it.
-spec aes_gcm_seal(binary(), binary(), binary()) -> binary().
aes_gcm_seal(Key32, Aad, Plain) when byte_size(Key32) =:= 32 ->
    try
        Nonce = crypto:strong_rand_bytes(12),
        {Cipher, Tag} = crypto:crypto_one_time_aead('aes_256_gcm', Key32, Nonce, Plain, Aad, 16, 'true'),
        <<Nonce/binary, Tag/binary, Cipher/binary>>
    catch
        _:_ -> erlang:error('aes_gcm_seal_failed')
    end;
aes_gcm_seal(_Key, _Aad, _Plain) ->
    erlang:error('aes_gcm_seal_failed').

-spec aes_gcm_open(binary(), binary(), binary()) -> {'ok', binary()} | {'error', 'nil'}.
aes_gcm_open(Key32, Aad, <<Nonce:12/binary, Tag:16/binary, Cipher/binary>>)
  when byte_size(Key32) =:= 32 ->
    try crypto:crypto_one_time_aead('aes_256_gcm', Key32, Nonce, Cipher, Aad, Tag, 'false') of
        Plain when is_binary(Plain) -> {'ok', Plain};
        _ -> {'error', 'nil'}
    catch
        _:_ -> {'error', 'nil'}
    end;
aes_gcm_open(_Key, _Aad, _Blob) -> {'error', 'nil'}.

-spec sha256_hex(binary()) -> binary().
sha256_hex(Bin) -> binary:encode_hex(crypto:hash('sha256', Bin), 'lowercase').

-spec random_bytes(non_neg_integer()) -> binary().
random_bytes(N) -> crypto:strong_rand_bytes(N).

%% @doc A random UUID (version 4), lowercase, hyphenated: the `origid'.
-spec uuid() -> binary().
uuid() ->
    <<A:32, B:16, _:4, C:12, _:2, D:14, E:48>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
                                  ,[A, B, (4 bsl 12) bor C, (2 bsl 14) bor D, E]
                                  )).

%%%=============================================================================
%%% Cryptography: helpers
%%%=============================================================================

%% @doc The EC private key in a `PRIVATE KEY' (PKCS#8) or `EC PRIVATE KEY'
%% PEM, with its public point filled in when the PEM left it out.
-spec private_key(binary()) -> {'ok', #'ECPrivateKey'{}} | {'error', binary()}.
private_key(Pem) ->
    Entries = [Entry || {Type, _, _} = Entry <- pem_entries(Pem)
                       ,Type =:= 'PrivateKeyInfo' orelse Type =:= 'ECPrivateKey'
              ],
    case Entries of
        [] -> {'error', <<"no private key in PEM">>};
        [{_, _, 'not_encrypted'} = Entry | _] ->
            %% Every step that has the key in hand is inside the `try', the
            %% derivation of the public point included: an `of' body is not
            %% protected, and a failure there would put the key in a crash
            %% report. The text of a failure is fixed, never the term.
            try
                case public_key:pem_entry_decode(Entry) of
                    #'ECPrivateKey'{parameters = {'namedCurve', ?'secp256r1'}} = Key ->
                        {'ok', with_public_point(Key)};
                    #'ECPrivateKey'{} -> {'error', <<"not a P-256 key">>};
                    _ -> {'error', <<"not an EC key">>}
                end
            catch
                _:_ -> {'error', <<"unreadable private key">>}
            end;
        [_Encrypted | _] -> {'error', <<"encrypted private key">>}
    end.

-spec with_public_point(#'ECPrivateKey'{}) -> #'ECPrivateKey'{}.
with_public_point(#'ECPrivateKey'{publicKey = Point} = Key) when is_binary(Point), Point =/= <<>> ->
    Key;
with_public_point(#'ECPrivateKey'{privateKey = Private} = Key) ->
    {Point, _} = crypto:generate_key('ecdh', 'secp256r1', Private),
    Key#'ECPrivateKey'{publicKey = Point}.

-spec public_of(#'ECPrivateKey'{}) -> {#'ECPoint'{}, {'namedCurve', tuple()}}.
public_of(#'ECPrivateKey'{publicKey = Point, parameters = Params}) ->
    {#'ECPoint'{point = Point}, Params}.

%% @doc The EC public key of a PEM: the first `CERTIFICATE' if the PEM
%% holds one at all, and only otherwise a `PUBLIC KEY'.
%%
%% A certificate always wins, wherever in the PEM it sits. The verifier
%% fetches this PEM from a signer's `x5u' and validates the chain in it
%% separately, and chain validation reads only the certificates: were a
%% bare `SubjectPublicKeyInfo' in front of a genuine chain enough to
%% choose the key, anyone could serve their own public key ahead of
%% somebody else's chain and have a PASSporT they signed themselves
%% verified against a chain that validates. A `PUBLIC KEY' is honoured
%% only when there is no certificate to prefer, which is how a key's own
%% public PEM is checked in the tests and in `check_x5u'.
-spec public_key_of(binary()) -> {'ok', {#'ECPoint'{}, term()}} | {'error', binary()}.
public_key_of(Pem) ->
    Entries = pem_entries(Pem),
    case certificates_of(Entries) of
        [Der | _] ->
            case spki_key(leaf_spki(Der)) of
                {#'ECPoint'{}, _} = Public -> {'ok', Public};
                _ -> {'error', <<"certificate key is not EC">>}
            end;
        [] ->
            case [E || {'SubjectPublicKeyInfo', _, _} = E <- Entries] of
                [Entry | _] ->
                    case public_key:pem_entry_decode(Entry) of
                        {#'ECPoint'{}, _} = Public -> {'ok', Public};
                        _ -> {'error', <<"not an EC public key">>}
                    end;
                [] -> {'error', <<"no public key in PEM">>}
            end
    end.

-spec leaf_spki(binary()) -> #'OTPSubjectPublicKeyInfo'{}.
leaf_spki(Der) ->
    #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{subjectPublicKeyInfo = Spki}} =
        public_key:pkix_decode_cert(Der, 'otp'),
    Spki.

-spec spki_key(#'OTPSubjectPublicKeyInfo'{}) -> {term(), term()}.
spki_key(#'OTPSubjectPublicKeyInfo'{algorithm = #'PublicKeyAlgorithm'{parameters = Params}
                                   ,subjectPublicKey = Key
                                   }) ->
    {Key, Params}.

-spec spki_pem({term(), term()}) -> binary().
spki_pem(Public) ->
    pem([public_key:pem_entry_encode('SubjectPublicKeyInfo', Public)]).

%% @doc PEM text ending in exactly one newline, as `openssl' writes it;
%% `public_key:pem_encode/1' leaves a blank line after each entry.
-spec pem([public_key:pem_entry()]) -> binary().
pem(Entries) ->
    <<(string:trim(public_key:pem_encode(Entries), 'trailing'))/binary, "\n">>.

%% @doc The `CERTIFICATE' entries of a PEM, and nothing else, as PEM text.
%% A chain is stored and served at a public URL, so whatever else an
%% operator's file held (a `PRIVATE KEY' block, a key file concatenated with
%% its chain) must not travel with it.
-spec certificates_pem(binary()) -> {'ok', binary()} | {'error', binary()}.
certificates_pem(Pem) ->
    case certificates_or_empty(Pem) of
        [] -> {'error', <<"no certificate in PEM">>};
        Ders -> {'ok', pem([{'Certificate', Der, 'not_encrypted'} || Der <- Ders])}
    end.

%% @doc Every PEM entry, or none for text that is not PEM at all.
-spec pem_entries(binary()) -> [public_key:pem_entry()].
pem_entries(Pem) when is_binary(Pem) ->
    try public_key:pem_decode(Pem)
    catch _:_ -> []
    end.

%% @doc The DER of every `CERTIFICATE' in a PEM; at least one, or a throw.
-spec certificates(binary()) -> [binary()].
certificates(Pem) ->
    case certificates_or_empty(Pem) of
        [] -> throw({'error', <<"no certificate in PEM">>});
        Certs -> Certs
    end.

-spec certificates_or_empty(binary()) -> [binary()].
certificates_or_empty(Pem) ->
    certificates_of(pem_entries(Pem)).

-spec certificates_of([public_key:pem_entry()]) -> [binary()].
certificates_of(Entries) ->
    [Der || {'Certificate', Der, 'not_encrypted'} <- Entries].

-spec is_ia5(binary()) -> boolean().
is_ia5(Bin) -> lists:all(fun(C) -> C < 128 end, binary_to_list(Bin)).

%% @doc The TNAuthList DER for one SPC: `SEQUENCE { [0] IA5String spc }',
%% explicit tags (RFC 8226 §3).
-spec tn_auth_list(binary()) -> binary().
tn_auth_list(Spc) ->
    Ia5 = der_tlv(16#16, Spc),
    der_tlv(16#30, der_tlv(16#A0, Ia5)).

-spec der_tlv(byte(), binary()) -> binary().
der_tlv(Tag, Value) ->
    <<Tag, (der_length(byte_size(Value)))/binary, Value/binary>>.

-spec der_length(non_neg_integer()) -> binary().
der_length(L) when L < 128 -> <<L>>;
der_length(L) when L < 256 -> <<16#81, L>>;
der_length(L) when L < 65536 -> <<16#82, L:16>>.

%% @doc One DER element: its tag, its contents, and what follows it.
-spec der_element(binary()) -> {byte(), binary(), binary()}.
der_element(<<Tag, L, Rest/binary>>) when L < 128 ->
    <<Value:L/binary, More/binary>> = Rest,
    {Tag, Value, More};
der_element(<<Tag, 1:1, N:7, Rest/binary>>) ->
    <<LenBytes:N/binary, More0/binary>> = Rest,
    L = binary:decode_unsigned(LenBytes),
    <<Value:L/binary, More/binary>> = More0,
    {Tag, Value, More}.

-spec der_elements(binary()) -> [{byte(), binary()}].
der_elements(<<>>) -> [];
der_elements(Der) ->
    {Tag, Value, More} = der_element(Der),
    [{Tag, Value} | der_elements(More)].

%% @doc The SPCs and numbers of a certificate's TNAuthList (RFC 8226 §3):
%% `TNEntry ::= CHOICE { spc [0] IA5String, range [1] SEQUENCE { start
%% IA5String, count INTEGER }, one [2] IA5String }', explicit tags. A range
%% is reported as `<start>+<count>'.
-spec spcs([#'Extension'{}] | 'asn1_NOVALUE') -> [binary()].
spcs('asn1_NOVALUE') -> [];
spcs(Extensions) ->
    case [V || #'Extension'{extnID = ?TN_AUTH_LIST, extnValue = V} <- Extensions] of
        [Der | _] when is_binary(Der) ->
            try
                {16#30, Entries, <<>>} = der_element(Der),
                [tn_entry(Tag, Value) || {Tag, Value} <- der_elements(Entries)]
            catch
                _:_ -> []
            end;
        _ -> []
    end.

-spec tn_entry(byte(), binary()) -> binary().
tn_entry(16#A0, Inner) ->
    {16#16, Spc, <<>>} = der_element(Inner),
    Spc;
tn_entry(16#A2, Inner) ->
    {16#16, Number, <<>>} = der_element(Inner),
    Number;
tn_entry(16#A1, Inner) ->
    {16#30, Range, <<>>} = der_element(Inner),
    [{16#16, Start}, {16#02, Count}] = der_elements(Range),
    <<Start/binary, "+", (integer_to_binary(binary:decode_unsigned(Count)))/binary>>.

-spec is_ca([#'Extension'{}] | 'asn1_NOVALUE') -> boolean().
is_ca('asn1_NOVALUE') -> 'false';
is_ca(Extensions) ->
    lists:any(fun(#'Extension'{extnID = ?'id-ce-basicConstraints'
                              ,extnValue = #'BasicConstraints'{cA = 'true'}
                              }) -> 'true';
                 (_) -> 'false'
              end
             ,Extensions
             ).

-spec key_usage([#'Extension'{}] | 'asn1_NOVALUE') -> [atom()] | 'undefined'.
key_usage('asn1_NOVALUE') -> 'undefined';
key_usage(Extensions) ->
    case [U || #'Extension'{extnID = ?'id-ce-keyUsage', extnValue = U} <- Extensions] of
        [Usage | _] when is_list(Usage) -> Usage;
        _ -> 'undefined'
    end.

-spec serial_hex(integer()) -> binary().
serial_hex(Serial) when Serial >= 0 ->
    Hex = integer_to_binary(Serial, 16),
    case byte_size(Hex) rem 2 of
        0 -> Hex;
        1 -> <<"0", Hex/binary>>
    end.

%% @doc An X.509 time as unix seconds. Two-digit years follow RFC 5280
%% §4.1.2.5.1: 50 to 99 are 1950 to 1999, 00 to 49 are 2000 to 2049.
%%
%% The trailing `Z' is required and is the whole of what may follow the
%% seconds. RFC 5280 §4.1.2.5 allows nothing else -- both time types
%% must be UTC and must end in `Z' -- and reading `20260912154044+0500'
%% as if it said `Z' moves a `notAfter' five hours later than the
%% certificate says, which for a revoked or expiring certificate is five
%% more hours of being accepted. A time this cannot read is a refusal,
%% not a guess.
-spec to_unix({'utcTime' | 'generalTime', string() | binary()}) -> integer().
to_unix({Type, Time}) when is_binary(Time) ->
    to_unix({Type, binary_to_list(Time)});
to_unix({'utcTime', [Y1, Y2 | Rest]}) ->
    YY = list_to_integer([Y1, Y2]),
    Century = case YY < 50 of 'true' -> "20"; 'false' -> "19" end,
    to_unix({'generalTime', Century ++ [Y1, Y2 | Rest]});
to_unix({'generalTime', [Y1, Y2, Y3, Y4, M1, M2, D1, D2, H1, H2, Mi1, Mi2, S1, S2 | Zone]}) ->
    Zone =:= "Z"
        orelse throw({'error', <<"certificate time is not UTC">>}),
    DateTime = {{list_to_integer([Y1, Y2, Y3, Y4])
                ,list_to_integer([M1, M2])
                ,list_to_integer([D1, D2])
                }
               ,{list_to_integer([H1, H2])
                ,list_to_integer([Mi1, Mi2])
                ,list_to_integer([S1, S2])
                }
               },
    calendar:datetime_to_gregorian_seconds(DateTime) - ?UNIX_EPOCH.

%% @doc A distinguished name as one line, in the order the certificate
%% carries it: `C=US, O=Example Telecom, CN=SHAKEN 1234'. The characters RFC
%% 4514 reserves are escaped with a backslash.
-spec dn_to_binary({'rdnSequence', list()}) -> binary().
dn_to_binary({'rdnSequence', Rdns}) ->
    iolist_to_binary(lists:join(<<", ">>, [rdn_to_binary(Rdn) || Rdn <- Rdns])).

-spec rdn_to_binary(list()) -> iolist().
rdn_to_binary(Attributes) ->
    lists:join(<<"+">>, [[attribute_name(Type), <<"=">>, escape_dn(attribute_value(Value))]
                         || Attribute <- Attributes, {Type, Value} <- [attribute(Attribute)]
                        ]).

-spec attribute(#'AttributeTypeAndValue'{} | #'SingleAttribute'{}) -> {tuple(), term()}.
attribute(#'AttributeTypeAndValue'{type = Type, value = Value}) -> {Type, Value};
attribute(#'SingleAttribute'{type = Type, value = Value}) -> {Type, Value}.

-spec attribute_name(tuple()) -> binary().
attribute_name(?'id-at-commonName') -> <<"CN">>;
attribute_name(?'id-at-countryName') -> <<"C">>;
attribute_name(?'id-at-organizationName') -> <<"O">>;
attribute_name(?'id-at-organizationalUnitName') -> <<"OU">>;
attribute_name(?'id-at-stateOrProvinceName') -> <<"ST">>;
attribute_name(?'id-at-localityName') -> <<"L">>;
attribute_name(?'id-at-serialNumber') -> <<"serialNumber">>;
attribute_name(?'id-emailAddress') -> <<"emailAddress">>;
attribute_name({0,9,2342,19200300,100,1,25}) -> <<"DC">>;
attribute_name(Oid) ->
    iolist_to_binary(lists:join(".", [integer_to_list(N) || N <- tuple_to_list(Oid)])).

%% @doc The text of an attribute value in any of the shapes OTP decodes:
%% a typed string, a plain string, the country-name choice, or DER left
%% undecoded.
%%
%% The guards are written with `orelse' rather than `;': a comma binds
%% tighter than a semicolon, so `is_list(Chars), A; B; C' asks for a list
%% under `A' alone and lets a `B' of any shape through. Every string type
%% carried as a list wants `is_list'; the two wide types carried as a
%% binary are UTF-16BE and UTF-32BE and are decoded as such, since reading
%% those bytes as UTF-8 yields nonsense.
-spec attribute_value(term()) -> binary().
attribute_value({'utf8String', Bin}) when is_binary(Bin) -> Bin;
attribute_value({'bmpString', Bin}) when is_binary(Bin) -> wide_to_binary(Bin, {'utf16', 'big'});
attribute_value({'universalString', Bin}) when is_binary(Bin) -> wide_to_binary(Bin, {'utf32', 'big'});
attribute_value({'correct', Value}) -> attribute_value(Value);
attribute_value({'wrong', Value}) -> attribute_value(Value);
attribute_value({Type, Chars}) when is_list(Chars)
                                    ,(Type =:= 'printableString'
                                      orelse Type =:= 'ia5String'
                                      orelse Type =:= 'teletexString'
                                      orelse Type =:= 'visibleString'
                                      orelse Type =:= 'generalString'
                                      orelse Type =:= 'universalString'
                                      orelse Type =:= 'bmpString'
                                      orelse Type =:= 'utf8String'
                                     ) ->
    chars_to_binary(Chars);
attribute_value({Type, Bin}) when is_atom(Type), is_binary(Bin) -> Bin;
attribute_value(Chars) when is_list(Chars) -> chars_to_binary(Chars);
attribute_value(<<Tag, _/binary>> = Der) when Tag =:= 16#0C; Tag =:= 16#13; Tag =:= 16#16;
                                              Tag =:= 16#14; Tag =:= 16#1C; Tag =:= 16#1E ->
    try der_element(Der) of
        {_, Value, <<>>} -> Value
    catch
        _:_ -> Der
    end;
attribute_value(Bin) when is_binary(Bin) -> Bin;
attribute_value(Other) -> reason(Other).

%% @doc A list of characters as UTF-8, or, for a list no encoding accepts,
%% its bytes: a name is rendered for a log line and an error text, and an
%% unreadable one must not take the validation down with it.
-spec chars_to_binary(list()) -> binary().
chars_to_binary(Chars) ->
    case unicode:characters_to_binary(Chars) of
        Bin when is_binary(Bin) -> Bin;
        _ -> iolist_to_binary([<<C:8>> || C <- Chars, is_integer(C), C >= 0, C < 256])
    end.

%% @doc A `bmpString' (UTF-16BE) or `universalString' (UTF-32BE) as UTF-8,
%% or the bytes as they came when they do not decode.
-spec wide_to_binary(binary(), {atom(), atom()}) -> binary().
wide_to_binary(Bin, Encoding) ->
    case unicode:characters_to_binary(Bin, Encoding, 'utf8') of
        Utf8 when is_binary(Utf8) -> Utf8;
        _ -> Bin
    end.

-spec escape_dn(binary()) -> binary().
escape_dn(Value) ->
    << <<(escape_dn_char(C))/binary>> || <<C>> <= Value >>.

%% @doc RFC 4514 §2.4 escaping, and the control characters besides: a
%% name is rendered into log lines and error texts, and a `CN' holding a
%% carriage return or an escape sequence writes whatever the attacker
%% who requested the certificate liked into them. Anything below a space
%% and the delete character become `\XX'.
-spec escape_dn_char(byte()) -> binary().
escape_dn_char(C) when C < 16#20; C =:= 16#7f ->
    <<$\\, (binary:encode_hex(<<C>>, 'uppercase'))/binary>>;
escape_dn_char(C) ->
    case lists:member(C, ",+\"\\<>;") of
        'true' -> <<$\\, C>>;
        'false' -> <<C>>
    end.

%% @doc Whether two names are one name.
%%
%% Not the rendered text: `dn_to_binary/1' is for a human, it joins the
%% attributes with punctuation it also escapes into the values, and it
%% says nothing about which string type carried which value. Comparing
%% it is wrong twice over. A CRL entry that fails to match the
%% certificate it names is a revoked certificate accepted -- and the
%% STI-PA's own staging CRL carries its issuer as `UTF8String' where the
%% signer's certificate carries the same name as `PrintableString', so
%% this is not a hypothetical.
%%
%% So: attribute by attribute, in the order the name carries them (the
%% sequence is ordered; the set inside one RDN is not, and is sorted),
%% comparing the attribute type as an OID and the value as text with its
%% case folded and its whitespace collapsed, which is what RFC 4518 §2.6
%% asks of `caseIgnoreMatch'. `attribute_value/1' answers the text of
%% every shape OTP decodes a value into, DER left undecoded included, so
%% the two sides of a comparison need not have come from the same
%% decoder -- a CRL's issuer comes from `der_decode/2' and a
%% certificate's subject from `pkix_decode_cert/2', and they never do.
%%
%% Anything that does not decode at all is `false': two names that
%% cannot be read are not thereby the same name.
-spec same_dn(term(), term()) -> boolean().
same_dn(A, B) ->
    try dn_key(A) =:= dn_key(B)
    catch _:_ -> 'false'
    end.

-spec dn_key({'rdnSequence', list()}) -> [[{tuple(), binary()}]].
dn_key({'rdnSequence', Rdns}) ->
    [lists:sort([{Type, fold_value(Value)}
                 || Attribute <- Rdn, {Type, Value} <- [attribute(Attribute)]
                ])
     || Rdn <- Rdns
    ].

%% @doc One attribute value as the text it compares by. Bytes that are
%% not text fold to themselves rather than raising, so two names that
%% carry the same unreadable bytes are still the same name.
-spec fold_value(term()) -> binary().
fold_value(Value) ->
    Text = attribute_value(Value),
    try string:casefold(collapse_spaces(Text))
    catch _:_ -> Text
    end.

-spec collapse_spaces(binary()) -> binary().
collapse_spaces(Text) ->
    iolist_to_binary(lists:join(<<" ">>, string:lexemes(Text, " \t\r\n"))).

%% @doc ASCII whitespace off both ends, byte by byte. `string:trim/1'
%% raises on bytes that are not UTF-8, and what is trimmed here is a PEM
%% a server answered.
-spec trim_bytes(binary()) -> binary().
trim_bytes(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    trim_bytes(Rest);
trim_bytes(Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        0 -> <<>>;
        Size ->
            case binary:at(Bin, Size - 1) of
                C when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
                    trim_bytes(binary_part(Bin, 0, Size - 1));
                _ -> Bin
            end
    end.

%%%-----------------------------------------------------------------------------
%%% Path validation
%%%-----------------------------------------------------------------------------

-spec check_validity([binary()], integer()) -> 'ok'.
check_validity(Chain, Now) ->
    lists:foreach(fun(Der) -> check_validity_of(Der, Now) end, Chain).

-spec check_validity_of(binary(), integer()) -> 'ok'.
check_validity_of(Der, Now) ->
    #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{subject = Subject, validity = Validity}} =
        public_key:pkix_decode_cert(Der, 'otp'),
    #'Validity'{notBefore = NotBefore, notAfter = NotAfter} = Validity,
    case {to_unix(NotBefore) =< Now, Now =< to_unix(NotAfter)} of
        {'true', 'true'} -> 'ok';
        {'false', _} -> throw({'error', <<"certificate not yet valid: ", (dn_to_binary(Subject))/binary>>});
        {_, 'false'} -> throw({'error', <<"certificate expired: ", (dn_to_binary(Subject))/binary>>})
    end.

%% @doc The trust anchor and the path below it, anchor first, from a chain
%% given top first. The first certificate from the top that the bundle
%% holds is the anchor; else the first the bundle issued gets a bundle
%% anchor; else there is none.
-spec anchor_and_path([binary()], [binary()]) -> {binary(), [binary()]}.
anchor_and_path([], _Bundle) ->
    throw({'error', <<"no trust anchor for the chain">>});
anchor_and_path([Cert | Below] = TopDown, Bundle) ->
    case lists:member(Cert, Bundle) of
        'true' -> {Cert, Below};
        'false' ->
            case issuer_in(Cert, Bundle) of
                {'ok', Anchor} -> {Anchor, TopDown};
                'error' -> anchor_and_path(Below, Bundle)
            end
    end.

%% @doc A bundle certificate that issued `Der': same name, and its key
%% verifies the signature.
%%
%% `is_issuer/2', not `catch public_key:pkix_is_issuer(...) =:= true': a
%% `catch' binds looser than the comparison, so the comparison happens
%% first and a throw from inside the filter is a `bad_filter' crash. One
%% certificate in the bundle that does not decode would then take down
%% every validation, and a trust bundle is text an operator uploaded.
-spec issuer_in(binary(), [binary()]) -> {'ok', binary()} | 'error'.
issuer_in(Der, Bundle) ->
    Candidates = [C || C <- Bundle, C =/= Der, is_issuer(Der, C)],
    case [C || C <- Candidates, verifies_with(Der, C)] of
        [Issuer | _] -> {'ok', Issuer};
        [] -> 'error'
    end.

%% @doc Whether `IssuerDer' names itself as `Der''s issuer; false for
%% anything that does not decode.
-spec is_issuer(binary(), binary()) -> boolean().
is_issuer(Der, IssuerDer) ->
    try public_key:pkix_is_issuer(Der, IssuerDer)
    catch _:_ -> 'false'
    end.

-spec verifies_with(binary(), binary()) -> boolean().
verifies_with(Der, IssuerDer) ->
    try
        public_key:pkix_verify(Der, spki_key(leaf_spki(IssuerDer)))
    catch
        _:_ -> 'false'
    end.

%% @doc What the leaf must be for a SHAKEN signature, checked after the
%% path is good (RFC 8226 §5, ATIS-1000080): not a CA, allowed to sign
%% when it says what it is allowed to do, and carrying the TNAuthList
%% that says which service provider codes it speaks for. Answers the
%% SPCs.
%%
%% Path validation alone does not say any of this. `pkix_path_validation'
%% checks basic constraints going *down* a chain, so an intermediate
%% presented as a leaf is a valid path of its own; without this an
%% STI-CA's own certificate, or any certificate a trusted CA issued for
%% another purpose, would verify a PASSporT.
-spec check_leaf('any_leaf' | 'shaken_leaf', binary()) -> [binary()].
check_leaf('any_leaf', _Der) -> [];
check_leaf('shaken_leaf', Der) ->
    #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{subject = Subject
                                                           ,extensions = Extensions
                                                           }} =
        public_key:pkix_decode_cert(Der, 'otp'),
    Name = dn_to_binary(Subject),
    is_ca(Extensions)
        andalso throw({'error', <<"the leaf is a CA certificate: ", Name/binary>>}),
    case key_usage(Extensions) of
        'undefined' -> 'ok';
        Usage ->
            lists:member('digitalSignature', Usage)
                orelse throw({'error', <<"the leaf has no digitalSignature key usage: ", Name/binary>>})
    end,
    has_tn_auth_list(Extensions)
        orelse throw({'error', <<"the leaf has no TNAuthList extension: ", Name/binary>>}),
    spcs(Extensions).

-spec has_tn_auth_list([#'Extension'{}] | 'asn1_NOVALUE') -> boolean().
has_tn_auth_list('asn1_NOVALUE') -> 'false';
has_tn_auth_list(Extensions) ->
    lists:any(fun(#'Extension'{extnID = ?TN_AUTH_LIST}) -> 'true';
                 (_) -> 'false'
              end
             ,Extensions
             ).

%% @doc The certificates a CRL is asked about: the path, and the anchor
%% above it unless the anchor signed itself.
-spec crl_path(binary(), [binary()]) -> [binary()].
crl_path(Anchor, Path) ->
    case is_self_signed(Anchor) of
        'true' -> Path;
        'false' -> [Anchor | Path]
    end.

-spec is_self_signed(binary()) -> boolean().
is_self_signed(Der) ->
    try
        #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{issuer = Issuer
                                                               ,subject = Subject
                                                               }} =
            public_key:pkix_decode_cert(Der, 'otp'),
        same_dn(Issuer, Subject)
            andalso verifies_with(Der, Der)
    catch
        _:_ -> 'false'
    end.

-spec path_validation(binary(), [binary()]) -> 'ok'.
path_validation(Anchor, Path) ->
    Verify = fun(_Cert, {'bad_cert', Reason}, _State) -> {'fail', Reason};
                (_Cert, {'extension', _}, State) -> {'unknown', State};
                (_Cert, 'valid', State) -> {'valid', State};
                (_Cert, 'valid_peer', State) -> {'valid', State}
             end,
    case public_key:pkix_path_validation(Anchor, Path, [{'verify_fun', {Verify, []}}]) of
        {'ok', _} -> 'ok';
        {'error', {'bad_cert', Reason}} ->
            throw({'error', <<"path validation failed: ", (reason(Reason))/binary>>});
        {'error', Reason} ->
            throw({'error', <<"path validation failed: ", (reason(Reason))/binary>>})
    end.

%%%-----------------------------------------------------------------------------
%%% CRL
%%%-----------------------------------------------------------------------------

-spec check_crl([binary()], binary(), binary(), [binary()], integer()) -> 'ok'.
check_crl(_Path, <<>>, _SignerPem, _CrlAnchors, _Now) -> 'ok';
check_crl(Path, CrlPem, SignerPem, CrlAnchors, Now) ->
    Crl = case [Der || {'CertificateList', Der, 'not_encrypted'} <- pem_entries(CrlPem)] of
              [CrlDer | _] -> CrlDer;
              [] -> throw({'error', <<"no CRL in PEM">>})
          end,
    SignerChain = case certificates_or_empty(SignerPem) of
                      [] -> throw({'error', <<"CRL signer certificate missing">>});
                      Certs -> Certs
                  end,
    [Signer | _] = SignerChain,
    #'CertificateList'{tbsCertList = TBS} = public_key:der_decode('CertificateList', Crl),
    #'TBSCertList'{issuer = CrlIssuer
                  ,thisUpdate = ThisUpdate
                  ,nextUpdate = NextUpdate
                  ,revokedCertificates = Revoked
                  } = TBS,
    #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{subject = SignerSubject
                                                           ,extensions = SignerExtensions
                                                           }} =
        public_key:pkix_decode_cert(Signer, 'otp'),
    same_dn(CrlIssuer, SignerSubject)
        orelse throw({'error', <<"CRL issuer is not the signer given">>}),
    %% No key usage at all, or one that did not decode, is a failure and
    %% not a pass: `cRLSign' is what says this certificate may sign a
    %% revocation list, and a certificate that does not say so has not
    %% been given the right (RFC 5280 §6.3.3 (f)).
    case key_usage(SignerExtensions) of
        'undefined' -> throw({'error', <<"CRL signer has no cRLSign key usage">>});
        Usage ->
            lists:member('cRLSign', Usage)
                orelse throw({'error', <<"CRL signer has no cRLSign key usage">>})
    end,
    'ok' = check_validity([Signer], Now),
    'ok' = check_signer_chain(SignerChain, CrlAnchors),
    public_key:pkix_crl_verify(Crl, Signer)
        orelse throw({'error', <<"CRL signature does not verify">>}),
    to_unix(ThisUpdate) =< Now
        orelse throw({'error', <<"CRL not yet valid">>}),
    case NextUpdate of
        'asn1_NOVALUE' -> 'ok';
        _ -> Now =< to_unix(NextUpdate) orelse throw({'error', <<"CRL stale">>})
    end,
    Entries = revoked_entries(Revoked, CrlIssuer),
    lists:foreach(fun(Der) -> check_revoked(Der, Entries) end, Path).

%% @doc Whether a CRL may be stored: `check_crl/5' with no path to look
%% up, so the checks verification makes of the CRL itself -- the signer
%% is the CRL's issuer, carries `cRLSign', is inside its validity at
%% `Now' and chains to `AnchorsPem'; the signature verifies; `thisUpdate'
%% is not after `Now' and `nextUpdate' not before it -- and, when they
%% pass, what the caller needs to refuse an older CRL than the one it
%% holds: `{ThisUpdate, NextUpdate, CrlNumber}', the times in unix
%% seconds and the two optional ones `none' or `{some, N}'.
%%
%% An empty CRL, which `check_crl/5' takes as "no CRL" and passes, is a
%% refusal here. Whatever the bytes are, the answer is `{error, Reason}'
%% and never an exception: the CRL came off the network.
-spec authenticate_crl(binary(), binary(), binary(), integer()) ->
          {'ok', {integer(), 'none' | {'some', integer()}, 'none' | {'some', integer()}}} |
          {'error', binary()}.
authenticate_crl(CrlPem, SignerPem, AnchorsPem, Now) ->
    try
        Pem = trim_bytes(CrlPem),
        Pem =/= <<>> orelse throw({'error', <<"no CRL in PEM">>}),
        'ok' = check_crl([], Pem, SignerPem, certificates_or_empty(AnchorsPem), Now),
        [Der | _] = [D || {'CertificateList', D, 'not_encrypted'} <- pem_entries(Pem)],
        #'CertificateList'{tbsCertList = #'TBSCertList'{thisUpdate = ThisUpdate
                                                       ,nextUpdate = NextUpdate
                                                       ,crlExtensions = Extensions
                                                       }} =
            public_key:der_decode('CertificateList', Der),
        {'ok', {to_unix(ThisUpdate), optional_unix(NextUpdate), crl_number(Extensions)}}
    catch
        'throw':{'error', _} = Error -> Error;
        _:Reason -> {'error', reason({'authenticate_crl', Reason})}
    end.

-spec optional_unix(term()) -> 'none' | {'some', integer()}.
optional_unix('asn1_NOVALUE') -> 'none';
optional_unix(Time) -> {'some', to_unix(Time)}.

-spec crl_number(list() | 'asn1_NOVALUE') -> 'none' | {'some', integer()}.
crl_number('asn1_NOVALUE') -> 'none';
crl_number(Extensions) ->
    case [V || #'Extension'{extnID = ?'id-ce-cRLNumber', extnValue = V} <- Extensions] of
        [Der | _] -> {'some', public_key:der_decode('CRLNumber', Der)};
        [] -> 'none'
    end.

%% @doc The CRL signer, the first certificate of the signer PEM, chains to
%% an anchor in the CRL anchor set, through the rest of the signer PEM as
%% intermediates where it needs them.
%%
%% The anchor comes from that set and from nowhere else. Anchoring on a
%% self-signed certificate found in the signer PEM, and treating a signer
%% that reaches no anchor at all as trusted, made this check unable to
%% fail: whoever supplies the CRL supplies the signer PEM beside it, so a
%% root of their own in that PEM was a root the check accepted. A CRL is
%% what says a certificate has been revoked, and a CRL signed by anybody
%% is a revocation list anybody can write.
-spec check_signer_chain([binary()], [binary()]) -> 'ok'.
check_signer_chain(SignerChain, CrlAnchors) ->
    {Anchor, Path} =
        try anchor_and_path(lists:reverse(SignerChain), CrlAnchors)
        catch
            'throw':{'error', <<"no trust anchor", _/binary>>} ->
                throw({'error', <<"CRL signer does not chain to the trust bundle">>})
        end,
    path_validation(Anchor, Path).

%% @doc Every entry as `{Serial, IssuerName}', with the issuer an indirect
%% CRL's `certificateIssuer' extension names carried forward to the entries
%% after it (RFC 5280 §5.3.3); before any, the CRL's own issuer.
-spec revoked_entries(list() | 'asn1_NOVALUE', term()) -> [{integer(), term()}].
revoked_entries('asn1_NOVALUE', _Issuer) -> [];
revoked_entries(Revoked, Issuer0) ->
    {Entries, _} =
        lists:mapfoldl(fun(#'TBSCertList_revokedCertificates_SEQOF'{userCertificate = Serial
                                                                    ,crlEntryExtensions = Extensions
                                                                    }
                          ,Issuer) ->
                               Current = entry_issuer(Extensions, Issuer),
                               {{Serial, Current, entry_reason(Extensions)}, Current}
                       end
                      ,Issuer0
                      ,Revoked
                      ),
    Entries.

-spec entry_issuer(list() | 'asn1_NOVALUE', term()) -> term().
entry_issuer('asn1_NOVALUE', Default) -> Default;
entry_issuer(Extensions, Default) ->
    case [V || #'Extension'{extnID = ?'id-ce-certificateIssuer', extnValue = V} <- Extensions] of
        [Der | _] ->
            case [Name || {'directoryName', Name} <- public_key:der_decode('GeneralNames', Der)] of
                [Name | _] -> Name;
                [] -> Default
            end;
        [] -> Default
    end.

-spec entry_reason(list() | 'asn1_NOVALUE') -> atom().
entry_reason('asn1_NOVALUE') -> 'unspecified';
entry_reason(Extensions) ->
    case [V || #'Extension'{extnID = ?'id-ce-cRLReasons', extnValue = V} <- Extensions] of
        [Der | _] -> public_key:der_decode('CRLReason', Der);
        [] -> 'unspecified'
    end.

-spec check_revoked(binary(), [{integer(), term(), atom()}]) -> 'ok'.
check_revoked(Der, Entries) ->
    #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{serialNumber = Serial
                                                           ,issuer = Issuer
                                                           ,subject = Subject
                                                           }} =
        public_key:pkix_decode_cert(Der, 'otp'),
    case [Reason || {S, I, Reason} <- Entries, S =:= Serial, same_dn(I, Issuer)] of
        [] -> 'ok';
        [Reason | _] ->
            throw({'error', <<"revoked (", (atom_to_binary(Reason))/binary, "): "
                             ,(dn_to_binary(Subject))/binary>>})
    end.

%%%=============================================================================
%%% HTTP
%%%=============================================================================

%% The most a fetched body may be. A certificate chain is a few kilobytes
%% and the STI-PA's CA list and CRL tens of them; a megabyte is generous.
%% Everything this module fetches comes from a URL somebody else chose
%% (an inbound call's `x5u'), so the body is not read without a bound.
-define(MAX_BODY_BYTES, 1048576).

%% @doc `GET' over `httpc' with `verify_peer' against the OS trust store, no
%% redirects, `Timeout' milliseconds: `{Status, Headers, Body}'.
%%
%% `https' only. A certificate served over `http' would be fetched from
%% whoever answers at that address, which is the whole of what
%% verification rests on; `http' is a refusal rather than a downgrade.
%%
%% The body is capped at a megabyte, two ways. `httpc''s own
%% `max_body_size' refuses a `content-length' above the cap before any of
%% the body is read and stops a chunked body at it. That leaves the case
%% it does not cover, a response with no length that ends when the server
%% closes the connection, so the body is streamed here as well and the
%% bytes counted as they arrive. The status line does not reach a
%% streaming reader: `httpc' streams a body only for 200 and 206, and
%% every other status arrives whole, with its code. Nothing here ever
%% sends a `Range' header, but a server answers what it likes, and a 206
%% nobody asked for would arrive as a stream and be reported as a 200
%% holding part of a document. So a streamed response that carries a
%% `content-range' header is refused rather than answered: a fragment of
%% a certificate, a CA list or a CRL is not one.
-spec http_get(binary(), pos_integer()) -> {'ok', {integer(), [{binary(), binary()}], binary()}} | {'error', binary()}.
http_get(Url, TimeoutMs) ->
    ensure_http_client(),
    %% The URL came out of an `Identity' header a carrier peer wrote, so
    %% it is a binary and not promised to be text: `characters_to_list/1'
    %% answers a tuple for bytes that are not UTF-8, and handing that to
    %% `uri_string:parse/1' is a crash rather than a refusal.
    case unicode:characters_to_list(Url) of
        UrlString when is_list(UrlString) ->
            try uri_string:parse(UrlString) of
                #{'scheme' := Scheme, 'host' := Host} ->
                    case string:lowercase(Scheme) of
                        "https" -> https_get(UrlString, Host, TimeoutMs);
                        _ -> {'error', <<"https only">>}
                    end;
                _ -> {'error', <<"https only">>}
            catch
                _:_ -> {'error', <<"https only">>}
            end;
        _ -> {'error', <<"https only">>}
    end.

%% @doc The request runs in a process of its own, which answers one
%% message and dies.
%%
%% A streamed body arrives as `{http, _}' messages, and the reader is
%% whichever process called: the signer, the monitor, a Crossbar request.
%% `httpc:cancel_request/1' does not promise that nothing more is
%% delivered, and a body abandoned at the cap leaves parts already in
%% flight, so draining the mailbox is a race that was observed to lose.
%% A process that exists for the one request cannot lose it: whatever is
%% still coming is addressed to it, and dies with it.
-spec https_get(string(), string(), pos_integer()) ->
          {'ok', {integer(), [{binary(), binary()}], binary()}} | {'error', binary()}.
https_get(UrlString, Host, TimeoutMs) ->
    Parent = self(),
    Tag = make_ref(),
    {Pid, Monitor} =
        erlang:spawn_monitor(fun() -> Parent ! {Tag, request(UrlString, Host, TimeoutMs)} end),
    receive
        {Tag, Result} ->
            _ = erlang:demonitor(Monitor, ['flush']),
            Result;
        {'DOWN', Monitor, 'process', Pid, Reason} ->
            {'error', reason(Reason)}
    after TimeoutMs + 2000 ->
            _ = erlang:demonitor(Monitor, ['flush']),
            'true' = exit(Pid, 'kill'),
            {'error', <<"timeout">>}
    end.

-spec request(string(), string(), pos_integer()) ->
          {'ok', {integer(), [{binary(), binary()}], binary()}} | {'error', binary()}.
request(UrlString, Host, TimeoutMs) ->
    HttpOptions = [{'timeout', TimeoutMs}
                  ,{'connect_timeout', TimeoutMs}
                  ,{'autoredirect', 'false'}
                   | ssl_options(Host)
                  ],
    Options = [{'sync', 'false'}
              ,{'receiver', self()}
              ,{'stream', 'self'}
              ,{'max_body_size', ?MAX_BODY_BYTES}
              ],
    Request = {UrlString, [{"user-agent", "reprise-stir"}]},
    try httpc:request('get', Request, HttpOptions, Options) of
        {'ok', RequestId} -> receive_response(RequestId, TimeoutMs);
        {'error', Reason} -> {'error', reason(Reason)}
    catch
        _:Reason -> {'error', reason(Reason)}
    end.

%% @doc The answer to one asynchronous request, counting the streamed body
%% against the cap.
%%
%% Exported so that the cap can be tested: `httpc' will not be made to
%% answer a megabyte over TLS from a test, but the loop reads its
%% mailbox, and a test that sends itself the `{http, _}' messages
%% `httpc' would send is the same loop reading the same messages.
-spec receive_response(reference(), pos_integer()) ->
          {'ok', {integer(), [{binary(), binary()}], binary()}} | {'error', binary()}.
receive_response(RequestId, TimeoutMs) ->
    receive_response(RequestId, TimeoutMs, [], [], 0).

-spec receive_response(reference(), pos_integer(), [tuple()], [binary()], non_neg_integer()) ->
          {'ok', {integer(), [{binary(), binary()}], binary()}} | {'error', binary()}.
receive_response(RequestId, TimeoutMs, Headers, Parts, Size) ->
    receive
        {'http', {RequestId, 'stream_start', StreamHeaders}} ->
            case is_partial(StreamHeaders) of
                'true' ->
                    abort_request(RequestId),
                    {'error', <<"partial response">>};
                'false' ->
                    receive_response(RequestId, TimeoutMs, StreamHeaders, Parts, Size)
            end;
        {'http', {RequestId, 'stream', Part}} ->
            case Size + byte_size(Part) of
                Grown when Grown > ?MAX_BODY_BYTES ->
                    abort_request(RequestId),
                    {'error', <<"response too large">>};
                Grown ->
                    receive_response(RequestId, TimeoutMs, Headers, [Part | Parts], Grown)
            end;
        {'http', {RequestId, 'stream_end', EndHeaders}} ->
            %% A chunked body's trailers arrive here, so these are the
            %% headers to answer; before any of them, what started the
            %% stream.
            Final = case EndHeaders of
                        [] -> Headers;
                        _ -> EndHeaders
                    end,
            case is_partial(Final) of
                'true' -> {'error', <<"partial response">>};
                'false' ->
                    {'ok', {200, [header(H) || H <- Final], iolist_to_binary(lists:reverse(Parts))}}
            end;
        {'http', {RequestId, {{_Version, Status, _Phrase}, WholeHeaders, Body}}} ->
            {'ok', {Status, [header(H) || H <- WholeHeaders], Body}};
        {'http', {RequestId, {'error', Reason}}} ->
            {'error', http_reason(Reason)}
    after TimeoutMs + 1000 ->
            abort_request(RequestId),
            {'error', <<"timeout">>}
    end.

%% @doc Whether the headers say this is part of a document rather than
%% the document: a `content-range', which only a 206 carries.
-spec is_partial([{string(), string()}]) -> boolean().
is_partial(Headers) ->
    lists:any(fun({Name, _Value}) ->
                      <<"content-range">> =:= lowercase_name(Name);
                 (_) -> 'false'
              end
             ,Headers
             ).

-spec lowercase_name(term()) -> binary().
lowercase_name(Name) ->
    try unicode:characters_to_binary(string:lowercase(Name)) of
        Lowered when is_binary(Lowered) -> Lowered;
        _ -> <<>>
    catch
        _:_ -> <<>>
    end.

%% @doc Stop the transfer. What it has already sent, or sends before it
%% notices, stays in this process's mailbox and dies with it.
-spec abort_request(reference()) -> 'ok'.
abort_request(RequestId) ->
    _ = (catch httpc:cancel_request(RequestId)),
    'ok'.

%% @doc `httpc' names the cap two ways: `body_too_big' for a
%% `content-length' above it, `body_too_long' from the chunk decoder.
-spec http_reason(term()) -> binary().
http_reason('body_too_big') -> <<"response too large">>;
http_reason({'body_too_long', _}) -> <<"response too large">>;
http_reason(Reason) -> reason(Reason).

-spec ssl_options(string()) -> [{'ssl', list()}].
ssl_options(Host) ->
    [{'ssl', [{'verify', 'verify_peer'}
             ,{'cacerts', cacerts()}
             ,{'depth', 10}
             ,{'server_name_indication', Host}
             ,{'customize_hostname_check'
              ,[{'match_fun', public_key:pkix_verify_hostname_match_fun('https')}]
              }
             ]}].

%% @doc The OS trust store. Without one every TLS connection fails, which
%% is the right failure for `verify_peer'.
-spec cacerts() -> [binary()].
cacerts() ->
    try public_key:cacerts_get()
    catch _:_ -> []
    end.

%% @doc One response header as two binaries. The bytes are the server's,
%% so neither half may be assumed to be text: `characters_to_binary/1'
%% answers a tuple for bytes that are not, and matching that against a
%% binary is a crash in the middle of a fetch.
-spec header({term(), term()}) -> {binary(), binary()}.
header({Name, Value}) ->
    {lowercase_name(Name), text(Value)}.

-spec text(term()) -> binary().
text(Value) when is_binary(Value) -> Value;
text(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> Binary;
        _ -> iolist_to_binary([B band 16#ff || B <- Value, is_integer(B)])
    catch
        _:_ -> <<>>
    end.

%% @doc Any term as an error text.
-spec reason(term()) -> binary().
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
reason(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

%% @doc The error text for a failure caught with a private key in hand.
%%
%% `reason/1' will not do there: it formats any term with `~0p', and the
%% terms these failures carry hold the argument that failed. A `badmatch'
%% of an `ECPrivateKey' record prints the private scalar; `crypto' raises
%% `{badarg, {File, Line}, Description}' with a description written by the
%% NIF, and `public_key' raises plain `badarg' and `function_clause' whose
%% arguments are the key. Only a bare atom and a binary the module wrote
%% itself are safe to pass on; everything else becomes one fixed text.
-spec key_reason(term()) -> binary().
key_reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
key_reason(Reason) when is_binary(Reason) -> Reason;
key_reason(_Reason) -> <<"private key operation failed">>.
