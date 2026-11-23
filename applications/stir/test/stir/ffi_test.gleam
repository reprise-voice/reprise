//// `stir_ffi` called directly: keys, signatures, the CSR, certificate
//// parsing, path validation with the STI-PA's indirect CRL, sealing, and
//// the guards that keep a test node from needing a release.
////
//// Fixtures: `example-999Y-chain.pem` is a SHAKEN certificate for the
//// made-up SPC `999Y` and the intermediate that issued it, shaped like a
//// production STI-CA chain (the same extensions, the STI-PA's CRL
//// distribution point and CRL issuer, validity 2026-02-17T22:24:11Z to
//// 2028-02-17T22:25:11Z) but generated for these tests with throwaway
//// keys under a root that was not kept;
//// `example-shaken-intermediate.pem` is the second of those;
//// `stipa-stg-crl.pem` and `stipa-stg-crl-signer.pem` were fetched from
//// the STI-PA staging API on 2026-09-11 (the CRL, then the AIA URL it
//// names, which answers the signer and its root), and
//// `stipa-stg-root.pem` is that root on its own, which is what a trust
//// bundle holds; `test-key.pem` is a P-256 key generated for these
//// tests, `test-key-pub.pem` its public key, `test-cert.pem` a
//// self-signed certificate over it with a TNAuthList for `TEST`,
//// `test-cert-bmpstring.pem` one whose name is a `BMPString`,
//// `garbage-cert.pem` a `CERTIFICATE` block that decodes to nothing of
//// the sort, `test-message.txt` a signing input and
//// `test-signature.hex` openssl's signature of it as raw `R||S`.
////
//// The `gen-` fixtures are a throwaway hierarchy, made with `openssl`
//// on 2026-09-12 because no staging material can say what they say: a
//// CRL that revokes a certificate a chain anchors on cannot be written
//// without the CA's key. `gen-root.pem` is a self-signed CA with
//// `keyCertSign` and `cRLSign`, `gen-intermediate.pem` a CA under it,
//// `gen-leaf.pem` an end-entity certificate with a TNAuthList for
//// `999Z` and `gen-chain.pem` the two of them; `gen-crl-empty.pem` and
//// `gen-crl-revoking-intermediate.pem` are CRLs the root signed, the
//// second listing the intermediate's serial; `gen-no-tnauth.pem` is a
//// self-signed end-entity certificate with no TNAuthList;
//// `gen-crl-signer-no-keyusage.pem` carries no `keyUsage` at all and
//// signed `gen-crl-no-keyusage.pem`; `gen-spaced-crl-signer.pem` is
//// named `CN=Offhook Spaced CRL` and signed `gen-spaced-crl.pem`,
//// whose issuer is the same name spelled with double spaces;
//// `gen-general-time.pem` carries its validity as `GeneralizedTime`
//// and `gen-offset-time.pem` the same with `+0000` where the `Z`
//// belongs; `gen-control-name.pem` has control characters in its
//// common name. The private keys were not kept: these are fixtures,
//// not a CA.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/io
import gleam/list
import gleam/string
import kazoo/doc

/// 2026-09-12T08:00:00Z: inside the fixture CRL's window
/// (2026-09-11T15:40:44Z to 2026-09-12T15:40:44Z), the chain's validity
/// and the test certificate's.
const during_crl_window = 1_789_200_000

/// One second after the fixture CRL's `nextUpdate`.
const after_crl_window = 1_789_227_645

pub fn generate_and_derive_test() {
  let private_key = generate_ec_key()
  assert string.starts_with(private_key, "-----BEGIN PRIVATE KEY-----\n")
  assert string.ends_with(private_key, "-----END PRIVATE KEY-----\n")
  let assert Ok(public_key) = public_key_pem(private_key)
  assert string.starts_with(public_key, "-----BEGIN PUBLIC KEY-----\n")
  // Two keys differ; a public key derives the same way openssl does it.
  assert generate_ec_key() != private_key
  assert public_key_pem(fixture("test-key.pem"))
    == Ok(fixture("test-key-pub.pem"))
  // Not a key.
  assert public_key_pem("hello") == Error("no private key in PEM")
  assert public_key_pem(fixture("test-cert.pem"))
    == Error("no private key in PEM")
}

pub fn sign_verify_round_trip_test() {
  let private_key = generate_ec_key()
  let assert Ok(public_key) = public_key_pem(private_key)
  let assert Ok(signature) = ecdsa_sign(private_key, "the message")
  assert bit_array.byte_size(signature) == 64
  assert ecdsa_verify(public_key, "the message", signature)
  assert !ecdsa_verify(public_key, "the messagf", signature)
  let assert Ok(other) = ecdsa_sign(private_key, "another message")
  assert !ecdsa_verify(public_key, "the message", other)
  assert !ecdsa_verify(public_key, "the message", <<1, 2, 3>>)
  assert !ecdsa_verify("not a key", "the message", signature)
  // ECDSA is randomised: two signatures of one message differ, both verify.
  let assert Ok(again) = ecdsa_sign(private_key, "the message")
  assert again != signature
  assert ecdsa_verify(public_key, "the message", again)
  assert ecdsa_sign("nope", "m") == Error("no private key in PEM")
}

/// openssl's signature of the fixture message under the fixture key,
/// converted from DER to `R||S`, verifies against the public key and
/// against the certificate over the same key.
pub fn known_answer_test() {
  let message = fixture("test-message.txt")
  let assert Ok(signature) =
    bit_array.base16_decode(string.trim(fixture("test-signature.hex")))
  assert bit_array.byte_size(signature) == 64
  assert ecdsa_verify(fixture("test-key-pub.pem"), message, signature)
  assert ecdsa_verify(fixture("test-cert.pem"), message, signature)
  assert !ecdsa_verify(fixture("example-999Y-chain.pem"), message, signature)
  // What openssl signed is what this signs.
  let assert Ok(ours) = ecdsa_sign(fixture("test-key.pem"), message)
  assert ecdsa_verify(fixture("test-key-pub.pem"), message, ours)
}

/// A `PUBLIC KEY` block in front of a certificate chain does not become
/// the key a signature is checked against.
///
/// The attack this pins: the verifier fetches one PEM from the signer's
/// `x5u` and uses it twice, once to check the PASSporT's signature and
/// once to validate the chain. Chain validation reads only the
/// certificates. So an attacker serves their own `PUBLIC KEY` ahead of
/// somebody else's real, valid chain: the chain validates, and if the
/// bare public key were what checked the signature, a PASSporT they
/// signed themselves would verify under another provider's name.
pub fn certificate_wins_over_public_key_test() {
  let attacker = generate_ec_key()
  let assert Ok(attacker_public) = public_key_pem(attacker)
  let assert Ok(forged) = ecdsa_sign(attacker, "the message")
  // On its own the attacker's key verifies their own signature: this is
  // the `PUBLIC KEY` path, which a key's own public PEM still needs.
  assert ecdsa_verify(attacker_public, "the message", forged)

  // Ahead of a certificate they do not hold the private key for, it is
  // ignored, and the certificate's key is what answers.
  let attack = attacker_public <> fixture("test-cert.pem")
  assert !ecdsa_verify(attack, "the message", forged)
  let assert Ok(honest) = ecdsa_sign(fixture("test-key.pem"), "the message")
  assert ecdsa_verify(attack, "the message", honest)
  // Wherever in the PEM the block sits.
  let trailing = fixture("test-cert.pem") <> attacker_public
  assert !ecdsa_verify(trailing, "the message", forged)
  assert ecdsa_verify(trailing, "the message", honest)

  // And the same for a real chain: the leaf's key is what
  // `certificate_info` reports, not the foreign key in front of it.
  let chain = fixture("example-999Y-chain.pem")
  let assert Ok(clean_text) = certificate_info(chain)
  let assert Ok(clean) = doc.parse(clean_text)
  let assert Ok(leaf_key) = doc.get_string(clean, ["public_key_pem"])
  let assert Ok(text) = certificate_info(attacker_public <> chain)
  let assert Ok(info) = doc.parse(text)
  assert doc.get_string(info, ["public_key_pem"]) == Ok(leaf_key)
  assert leaf_key != attacker_public
  assert !ecdsa_verify(attacker_public <> chain, "the message", forged)
}

pub fn csr_test() {
  let assert Ok(request) =
    csr(fixture("test-key.pem"), "Example Telecom", "SHAKEN 999Y", "999Y")
  assert string.starts_with(request, "-----BEGIN CERTIFICATE REQUEST-----\n")
  assert string.ends_with(request, "-----END CERTIFICATE REQUEST-----\n")
  assert csr("nope", "Example Telecom", "SHAKEN 999Y", "999Y")
    == Error("no private key in PEM")
  assert csr(fixture("test-key.pem"), "Example Telecom", "SHAKEN 999Y", "")
    == Error("spc is empty")
  assert csr(fixture("test-key.pem"), "Example Telecom", "SHAKEN 999Y", "7é1L")
    == Error("spc must be ASCII")
  // No organization, no CSR: ATIS-1000080 wants C, O and CN.
  assert csr(fixture("test-key.pem"), "", "SHAKEN 999Y", "999Y")
    == Error("organization is empty")
}

pub fn certificate_info_test() {
  let assert Ok(text) = certificate_info(fixture("example-999Y-chain.pem"))
  let assert Ok(info) = doc.parse(text)
  assert doc.strings(info, ["spcs"]) == ["999Y"]
  assert doc.get_int(info, ["chain_length"]) == Ok(2)
  // 2028-02-17T22:25:11Z and 2026-02-17T22:24:11Z.
  assert doc.get_int(info, ["not_after"]) == Ok(1_834_439_111)
  assert doc.get_int(info, ["not_before"]) == Ok(1_771_367_051)
  let assert Ok(subject) = doc.get_string(info, ["subject"])
  assert string.contains(subject, "SHAKEN 999Y")
  assert subject
    == "C=US, O=Example Telecom, CN=SHAKEN 999Y, serialNumber=6ABABE3C-8D3C-431D-BCDB-55BD6185EA17"
  assert doc.get_string(info, ["issuer"])
    == Ok("C=US, O=Example SHAKEN CA, CN=Example SHAKEN Intermediate")
  assert doc.get_string(info, ["serial"])
    == Ok("416348A23F98E54F3EFB2F0957DEC07FF086113E")
  let assert Ok(fingerprint) = doc.get_string(info, ["fingerprint"])
  assert string.starts_with(fingerprint, "sha256:")
  assert string.length(fingerprint) == 7 + 64
  assert doc.get_bool(info, ["is_ca"]) == Ok(False)
  let assert Ok(public_key) = doc.get_string(info, ["public_key_pem"])
  assert string.starts_with(public_key, "-----BEGIN PUBLIC KEY-----\n")

  // The intermediate on its own is a CA with no SPC.
  let assert Ok(text) =
    certificate_info(fixture("example-shaken-intermediate.pem"))
  let assert Ok(info) = doc.parse(text)
  assert doc.get_bool(info, ["is_ca"]) == Ok(True)
  assert doc.strings(info, ["spcs"]) == []
  assert doc.get_int(info, ["chain_length"]) == Ok(1)

  let assert Ok(text) = certificate_info(fixture("test-cert.pem"))
  let assert Ok(info) = doc.parse(text)
  assert doc.strings(info, ["spcs"]) == ["TEST"]
  assert doc.get_string(info, ["subject"])
    == Ok("C=US, O=Offhook Test, CN=SHAKEN TEST")

  assert certificate_info("") == Error("no certificate in PEM")
  assert certificate_info(fixture("test-key-pub.pem"))
    == Error("no certificate in PEM")

  // A name in one of the wide string types still reads as text. X.509
  // allows six string types for a name and a distinguished name is
  // rendered into every error text and log line here, so a type the
  // renderer does not know is an exception on the error path.
  let assert Ok(text) = certificate_info(fixture("test-cert-bmpstring.pem"))
  let assert Ok(info) = doc.parse(text)
  assert doc.get_string(info, ["subject"])
    == Ok("C=US, O=Wide Name Ltd, CN=Wide Name Ltd")
}

pub fn certificate_matches_key_test() {
  assert certificate_matches_key(
    fixture("test-cert.pem"),
    fixture("test-key.pem"),
  )
  assert !certificate_matches_key(
    fixture("example-999Y-chain.pem"),
    fixture("test-key.pem"),
  )
  assert !certificate_matches_key(fixture("test-cert.pem"), "nope")
}

pub fn validate_chain_test() {
  let chain = fixture("example-999Y-chain.pem")
  let intermediate = fixture("example-shaken-intermediate.pem")
  assert validate_chain(chain, intermediate, "", "", during_crl_window)
    == Ok(Nil)
  // The bundle completes a chain that carries only its leaf.
  let assert [leaf, ..] = string.split(chain, "-----END CERTIFICATE-----\n")
  assert validate_chain(
      leaf <> "-----END CERTIFICATE-----\n",
      intermediate,
      "",
      "",
      during_crl_window,
    )
    == Ok(Nil)
  // An unrelated anchor, an empty bundle, no chain.
  assert validate_chain(
      chain,
      fixture("test-cert.pem"),
      "",
      "",
      during_crl_window,
    )
    == Error("no trust anchor for the chain")
  assert validate_chain(chain, "", "", "", during_crl_window)
    == Error("empty trust bundle")
  assert validate_chain("", intermediate, "", "", during_crl_window)
    == Error("no certificate in PEM")
  // Outside the leaf's validity, either way.
  let assert Error(expired) =
    validate_chain(chain, intermediate, "", "", 1_834_439_112)
  assert string.starts_with(expired, "certificate expired: ")
  let assert Error(early) =
    validate_chain(chain, intermediate, "", "", 1_771_367_050)
  assert string.starts_with(early, "certificate not yet valid: ")
  // A self-signed certificate is its own anchor.
  let self_signed = fixture("test-cert.pem")
  assert validate_chain(self_signed, self_signed, "", "", during_crl_window)
    == Ok(Nil)
}

/// The STI-PA's CRL is indirect: signed by `CN=STI-PA CRL`, not by the
/// STI-CA, with each entry naming the CA that issued the revoked
/// certificate.
pub fn validate_chain_crl_test() {
  let chain = fixture("example-999Y-chain.pem")
  // The bundle a trust store holds: the STI-CA material the chain needs,
  // and the STI-PA's own root, which is what the CRL's signer chains to.
  let bundle =
    fixture("example-shaken-intermediate.pem") <> fixture("stipa-stg-root.pem")
  let crl = fixture("stipa-stg-crl.pem")
  let signer = fixture("stipa-stg-crl-signer.pem")
  assert validate_chain(chain, bundle, crl, signer, during_crl_window)
    == Ok(Nil)
  // The wrong signer, no signer, a stale CRL, a CRL that is not one.
  assert validate_chain(
      chain,
      bundle,
      crl,
      fixture("test-cert.pem"),
      during_crl_window,
    )
    == Error("CRL issuer is not the signer given")
  assert validate_chain(chain, bundle, crl, "", during_crl_window)
    == Error("CRL signer certificate missing")
  assert validate_chain(chain, bundle, crl, signer, after_crl_window)
    == Error("CRL stale")
  assert validate_chain(chain, bundle, crl, signer, 1_789_141_243)
    == Error("CRL not yet valid")
  assert validate_chain(chain, bundle, "garbage", signer, during_crl_window)
    == Error("no CRL in PEM")
  // The CRL's own bytes changed.
  let tampered = string.replace(crl, "MIIQbzCCEBUCAQEw", "MIIQbzCCEBUCAQIw")
  assert validate_chain(chain, bundle, tampered, signer, during_crl_window)
    == Error("CRL signature does not verify")
}

/// The CRL signer has to reach the trust bundle, and the PEM it arrived in
/// does not get a vote.
///
/// `stipa-stg-crl-signer.pem` is the signer and, below it, the STI-PA root
/// that issued it, exactly as the AIA URL answers them. Whoever supplies a
/// CRL supplies that PEM beside it, so treating a self-signed certificate
/// found there as an anchor, or a signer that reaches no anchor at all as
/// trusted, is the same as accepting a revocation list from anybody. With
/// the root out of the bundle the signer is refused, root in the signer
/// PEM and all.
pub fn validate_chain_crl_signer_anchor_test() {
  let chain = fixture("example-999Y-chain.pem")
  let intermediate = fixture("example-shaken-intermediate.pem")
  let root = fixture("stipa-stg-root.pem")
  let crl = fixture("stipa-stg-crl.pem")
  let signer = fixture("stipa-stg-crl-signer.pem")
  assert validate_chain(chain, intermediate, crl, signer, during_crl_window)
    == Error("CRL signer does not chain to the trust bundle")
  // An unrelated root in the bundle is no better than none.
  assert validate_chain(
      chain,
      intermediate <> fixture("test-cert.pem"),
      crl,
      signer,
      during_crl_window,
    )
    == Error("CRL signer does not chain to the trust bundle")
  // With the STI-PA root in the bundle it passes, and it still passes
  // when the signer PEM carries the signer alone and the bundle supplies
  // the anchor.
  assert validate_chain(
      chain,
      intermediate <> root,
      crl,
      signer,
      during_crl_window,
    )
    == Ok(Nil)
  let assert [signer_only, ..] =
    string.split(signer, "-----END CERTIFICATE-----\n")
  assert validate_chain(
      chain,
      intermediate <> root,
      crl,
      signer_only <> "-----END CERTIFICATE-----\n",
      during_crl_window,
    )
    == Ok(Nil)
}

/// The certificate a chain anchors on is checked against the CRL too.
///
/// `pkix_path_validation/3` takes its anchor on trust and never looks at
/// it again, so a revoked STI-CA certificate still sitting in the stored
/// bundle went on anchoring chains: the CRL was asked about the path
/// below the anchor and never about the anchor. Here the bundle holds
/// the intermediate, so the intermediate is the anchor, and a CRL that
/// lists its serial under the root that issued it must end the
/// validation. Nothing else about the chain changes: with the same
/// bundle and an empty CRL it passes.
pub fn validate_chain_revoked_anchor_test() {
  let chain = fixture("gen-chain.pem")
  let bundle = fixture("gen-intermediate.pem") <> fixture("gen-root.pem")
  let root = fixture("gen-root.pem")
  let revoked = fixture("gen-crl-revoking-intermediate.pem")
  assert validate_chain(
      chain,
      bundle,
      fixture("gen-crl-empty.pem"),
      root,
      during_crl_window,
    )
    == Ok(Nil)
  let assert Error(why) =
    validate_chain(chain, bundle, revoked, root, during_crl_window)
  assert string.starts_with(why, "revoked (")
  assert string.contains(why, "Offhook Generated Intermediate")
  // And when the anchor is the root instead, so that the intermediate is
  // on the path, the same CRL says the same thing.
  assert validate_chain(chain, root, revoked, root, during_crl_window)
    == Error(why)
  // A self-signed anchor is not looked up: it is the bundle that decides
  // whether a root is trusted, and a root cannot revoke itself out of
  // one. The empty CRL above already passes; so does the chain whose
  // anchor is the self-signed root.
  assert validate_chain(
      chain,
      root,
      fixture("gen-crl-empty.pem"),
      root,
      during_crl_window,
    )
    == Ok(Nil)
}

/// What the leaf must be for a signature to count (RFC 8226 §5): not a
/// CA, allowed to sign if it says what it is allowed to do, and naming
/// the service provider codes it speaks for. Path validation says none
/// of this -- an intermediate presented on its own is a valid path --
/// so without it any certificate a trusted CA issued, for any purpose,
/// verified a PASSporT.
///
/// `validate_chain_info/5` answers the SPCs so that a caller can hold
/// the call to them; `validate_chain/5` is the looser arity the STI-PA's
/// own signer chains go through and has no leaf to hold.
pub fn validate_chain_leaf_constraints_test() {
  let chain = fixture("example-999Y-chain.pem")
  let intermediate = fixture("example-shaken-intermediate.pem")
  assert validate_chain_info(chain, intermediate, "", "", during_crl_window)
    == Ok("{\"spcs\":[\"999Y\"]}")
  assert validate_chain_with_anchors(
      chain,
      intermediate,
      "",
      "",
      intermediate,
      during_crl_window,
    )
    == Ok(Nil)

  // A CA certificate is not a leaf, however good its path: the
  // intermediate alone, under the root that issued it.
  let assert Error(ca) =
    validate_chain_info(
      fixture("gen-intermediate.pem"),
      fixture("gen-root.pem"),
      "",
      "",
      during_crl_window,
    )
  assert ca
    == "the leaf is a CA certificate: C=US, O=Offhook Generated, CN=Offhook Generated Intermediate"

  // A certificate with no TNAuthList is not a SHAKEN certificate, even
  // self-signed and trusted as its own anchor.
  let no_tn = fixture("gen-no-tnauth.pem")
  let assert Error(missing) =
    validate_chain_info(no_tn, no_tn, "", "", during_crl_window)
  assert string.starts_with(missing, "the leaf has no TNAuthList extension: ")
  // The loose arity still validates it: that is the path the STI-PA's
  // CA-list and CRL signers take, and neither carries a TNAuthList.
  assert validate_chain(no_tn, no_tn, "", "", during_crl_window) == Ok(Nil)

  // The generated leaf carries its own SPC and passes on its own chain.
  assert validate_chain_info(
      fixture("gen-chain.pem"),
      fixture("gen-root.pem"),
      "",
      "",
      during_crl_window,
    )
    == Ok("{\"spcs\":[\"999Z\"]}")
  // Every error `validate_chain/5` gives, `validate_chain_info/5` gives.
  assert validate_chain_info(chain, "", "", "", during_crl_window)
    == Error("empty trust bundle")
  assert validate_chain_info("", intermediate, "", "", during_crl_window)
    == Error("no certificate in PEM")
}

/// The CRL's signer answers to the pinned STI-PA roots, not to the
/// STI-CA bundle.
///
/// They are not the same population. The bundle is every CA the STI-PA
/// publishes; the CRL is the STI-PA's own word about which certificates
/// are dead. Checking the signer against the bundle means any of those
/// CAs can issue a certificate that signs a revocation list, and an
/// empty list signed that way brings a revoked signer back.
pub fn validate_chain_with_anchors_test() {
  let chain = fixture("example-999Y-chain.pem")
  let intermediate = fixture("example-shaken-intermediate.pem")
  let root = fixture("stipa-stg-root.pem")
  let bundle = intermediate <> root
  let crl = fixture("stipa-stg-crl.pem")
  let signer = fixture("stipa-stg-crl-signer.pem")
  // The STI-PA root alone is enough for the CRL signer, and the bundle
  // need not hold it at all.
  assert validate_chain_with_anchors(
      chain,
      intermediate,
      crl,
      signer,
      root,
      during_crl_window,
    )
    == Ok(Nil)
  // The STI-CA bundle is not: a signer that reaches only it is refused,
  // which is what the five-argument arity could not say.
  assert validate_chain_with_anchors(
      chain,
      bundle,
      crl,
      signer,
      intermediate,
      during_crl_window,
    )
    == Error("CRL signer does not chain to the trust bundle")
  assert validate_chain_with_anchors(
      chain,
      bundle,
      crl,
      signer,
      "",
      during_crl_window,
    )
    == Error("CRL signer does not chain to the trust bundle")
  // With the anchors the same as the bundle it is the old behaviour,
  // which is what `validate_chain/5` passes.
  assert validate_chain_with_anchors(
      chain,
      bundle,
      crl,
      signer,
      bundle,
      during_crl_window,
    )
    == Ok(Nil)
  assert validate_chain(chain, bundle, crl, signer, during_crl_window)
    == Ok(Nil)
}

/// `cRLSign` is what says a certificate may sign a revocation list, and
/// a certificate that says nothing has not been given the right (RFC
/// 5280 §6.3.3). The fixture signer carries no `keyUsage` at all and
/// signed the fixture CRL, so the name matches and the signature
/// verifies: the refusal is the key usage and nothing else.
pub fn validate_chain_crl_signer_key_usage_test() {
  let chain = fixture("gen-chain.pem")
  let bundle = fixture("gen-intermediate.pem") <> fixture("gen-root.pem")
  assert validate_chain(
      chain,
      bundle,
      fixture("gen-crl-no-keyusage.pem"),
      fixture("gen-crl-signer-no-keyusage.pem"),
      during_crl_window,
    )
    == Error("CRL signer has no cRLSign key usage")
  // The signer the CRL names, with `cRLSign`, is accepted.
  assert validate_chain(
      chain,
      bundle,
      fixture("gen-spaced-crl.pem"),
      fixture("gen-spaced-crl-signer.pem"),
      during_crl_window,
    )
    == Ok(Nil)
}

/// A name is compared as a name, not as the line a log prints.
///
/// `gen-spaced-crl.pem` names its issuer `CN=Offhook  Spaced  CRL` and
/// `gen-spaced-crl-signer.pem` carries `CN=Offhook Spaced CRL`: one
/// name, two spellings, and the certificate really did sign the CRL.
/// Comparing the rendered text refused it -- fail closed, a CRL that
/// cannot be checked -- and the same comparison fails open on the other
/// side, where a revoked entry that does not match its certificate is a
/// revoked certificate accepted. The STI-PA's own staging material is
/// the same point in a different key: its CRL carries the issuer as
/// `UTF8String` where the signer's certificate carries it as
/// `PrintableString` (`validate_chain_crl_test`).
pub fn validate_chain_crl_issuer_name_test() {
  let chain = fixture("gen-chain.pem")
  let bundle = fixture("gen-intermediate.pem") <> fixture("gen-root.pem")
  assert validate_chain(
      chain,
      bundle,
      fixture("gen-spaced-crl.pem"),
      fixture("gen-spaced-crl-signer.pem"),
      during_crl_window,
    )
    == Ok(Nil)
  // A different name is still a different name.
  assert validate_chain(
      chain,
      bundle,
      fixture("gen-spaced-crl.pem"),
      fixture("gen-crl-signer-no-keyusage.pem"),
      during_crl_window,
    )
    == Error("CRL issuer is not the signer given")
}

/// Every X.509 time must be UTC and must say so (RFC 5280 §4.1.2.5).
/// Reading `20460101000000+0000` as if the `Z` were there is reading a
/// `notAfter` at an offset the certificate did not give, which for an
/// expiring certificate is more hours of being accepted; a time this
/// cannot read is a refusal.
pub fn certificate_time_must_be_utc_test() {
  let general = fixture("gen-general-time.pem")
  assert validate_chain(general, general, "", "", during_crl_window) == Ok(Nil)
  let assert Ok(text) = certificate_info(general)
  let assert Ok(info) = doc.parse(text)
  // 2026-01-01T00:00:00Z and 2046-01-01T00:00:00Z.
  assert doc.get_int(info, ["not_before"]) == Ok(1_767_225_600)
  assert doc.get_int(info, ["not_after"]) == Ok(2_398_377_600)

  let offset = fixture("gen-offset-time.pem")
  assert validate_chain(offset, offset, "", "", during_crl_window)
    == Error("certificate time is not UTC")
  assert certificate_info(offset) == Error("certificate time is not UTC")
}

/// A name is rendered into log lines and error texts, and whoever asked
/// for the certificate chose it. A carriage return in a common name
/// writes a line of its own into a log; an escape sequence writes
/// whatever a terminal will do. Everything below a space, and the
/// delete character, leave as `\XX`.
pub fn control_characters_in_a_name_test() {
  let assert Ok(text) = certificate_info(fixture("gen-control-name.pem"))
  let assert Ok(info) = doc.parse(text)
  let assert Ok(subject) = doc.get_string(info, ["subject"])
  assert subject
    == "C=US, O=Offhook Generated, CN=Ring\\07 Bell\\0D\\0AInjected\\7F"
  // Not one raw control byte anywhere in it.
  assert !string.contains(subject, "\u{7}")
  assert !string.contains(subject, "\r")
  assert !string.contains(subject, "\n")
  assert !string.contains(subject, "\u{7f}")
}

/// One PEM block in the trust bundle that does not decode must not take
/// every validation with it: a bundle is text an operator uploaded, and a
/// throw inside a comprehension filter is a `bad_filter` crash rather than
/// a false.
pub fn validate_chain_garbage_in_bundle_test() {
  let chain = fixture("example-999Y-chain.pem")
  let intermediate = fixture("example-shaken-intermediate.pem")
  let garbage = fixture("garbage-cert.pem")
  assert validate_chain(
      chain,
      garbage <> intermediate,
      "",
      "",
      during_crl_window,
    )
    == Ok(Nil)
  // The leaf on its own: now the bundle is searched for an issuer, which
  // is the comprehension that used to crash.
  let assert [leaf, ..] = string.split(chain, "-----END CERTIFICATE-----\n")
  assert validate_chain(
      leaf <> "-----END CERTIFICATE-----\n",
      garbage <> intermediate,
      "",
      "",
      during_crl_window,
    )
    == Ok(Nil)
  // And a bundle of nothing but garbage is a refusal, not a crash.
  assert validate_chain(chain, garbage, "", "", during_crl_window)
    == Error("no trust anchor for the chain")
}

pub fn aes_gcm_test() {
  let key = random_bytes(32)
  let blob = aes_gcm_seal(key, <<"kid">>, <<"secret">>)
  assert bit_array.byte_size(blob) == 12 + 16 + 6
  assert aes_gcm_open(key, <<"kid">>, blob) == Ok(<<"secret">>)
  // Wrong key, wrong associated data, tampered, truncated, nonsense.
  assert aes_gcm_open(random_bytes(32), <<"kid">>, blob) == Error(Nil)
  assert aes_gcm_open(key, <<"other">>, blob) == Error(Nil)
  assert aes_gcm_open(key, <<"kid">>, bit_array.append(blob, <<0>>))
    == Error(Nil)
  let assert Ok(short) = bit_array.slice(blob, 0, 20)
  assert aes_gcm_open(key, <<"kid">>, short) == Error(Nil)
  assert aes_gcm_open(key, <<"kid">>, <<>>) == Error(Nil)
  // A fresh nonce each time.
  assert aes_gcm_seal(key, <<"kid">>, <<"secret">>) != blob
  assert aes_gcm_open(key, <<>>, aes_gcm_seal(key, <<>>, <<>>)) == Ok(<<>>)
}

pub fn uuid_test() {
  let id = uuid()
  assert string.length(id) == 36
  let assert [a, b, c, d, e] = string.split(id, "-")
  assert list.map([a, b, c, d, e], string.length) == [8, 4, 4, 4, 12]
  assert string.starts_with(c, "4")
  assert list.contains(["8", "9", "a", "b"], string.slice(d, 0, 1))
  assert string.lowercase(id) == id
  assert uuid() != id
}

pub fn digest_test() {
  assert sha256_hex(<<"">>)
    == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  assert bit_array.byte_size(random_bytes(7)) == 7
}

/// `https` and nothing else. A certificate fetched over `http` is a
/// certificate from whoever answers at that address, and it is the whole
/// of what a verdict rests on.
///
/// The megabyte cap on the body is not exercised here: a listener a test
/// could start would have to speak TLS with a certificate the OS trust
/// store holds, which is not something a test can arrange, and `http` is
/// refused before a socket is opened. The cap is `httpc`'s own
/// `max_body_size`, which refuses a `content-length` above it and stops a
/// chunked body at it, and, for a body with no length that ends when the
/// server closes the connection, the count over the streamed parts in
/// `receive_response/5`.
pub fn http_get_test() {
  assert http_get("nope", 300) == Error("https only")
  assert http_get("ftp://example.test/", 300) == Error("https only")
  assert http_get("http://example.test/cert.pem", 300) == Error("https only")
  assert http_get("", 300) == Error("https only")
  // Nothing listens there, and the answer is still the shape callers read.
  let assert Error(refused) = http_get("https://127.0.0.1:9/", 300)
  assert string.contains(refused, "econnrefused")
    || string.contains(refused, "timeout")
    || string.contains(refused, "failed_connect")
}

/// The megabyte cap on a streamed body, and the refusal of a response
/// that is part of a document.
///
/// A listener a test could talk to would have to speak TLS with a
/// certificate the OS trust store holds, which a test cannot arrange,
/// so `httpc` is not in this loop. What is in it is the loop:
/// `receive_response/2` reads `{http, _}` messages out of its own
/// mailbox, and a test that sends itself the messages `httpc` would
/// send exercises the same counting and the same headers.
pub fn streamed_response_test() {
  // 64 KiB sixteen times is the cap exactly, which is not over it.
  let part = string.repeat("A", 65_536)
  let assert Ok(#(status, headers, body)) =
    stream([#("Content-Type", "application/pkix-cert")], list.repeat(part, 16))
  assert status == 200
  assert headers == [#("content-type", "application/pkix-cert")]
  assert string.byte_size(body) == 1_048_576
  // One byte more is not read.
  assert stream([], list.append(list.repeat(part, 16), ["A"]))
    == Error("response too large")
  // Nor is a body with no length that just keeps coming: the count is
  // over the parts, not over a header.
  assert stream([], list.repeat(part, 64)) == Error("response too large")

  // A streamed response is reported as a 200, since `httpc` streams
  // only 200 and 206 and nothing here asks for a range. A server that
  // answers 206 anyway carries a `content-range`, and a fragment of a
  // certificate is not a certificate.
  assert stream([#("Content-Range", "bytes 0-99/4096")], ["AAAA"])
    == Error("partial response")
  assert stream([#("content-range", "bytes 0-99/4096")], [])
    == Error("partial response")
}

/// The CSR and the key, read by the tool the STI-CA reads them with.
///
/// Every byte of the request is assembled by hand in `stir_ffi:csr/4`:
/// the subject, the TNAuthList, the `extensionRequest` attribute and
/// the signature over the whole `CertificationRequestInfo`. A structure
/// OTP is happy to decode is not evidence that OpenSSL will accept it,
/// and it is OpenSSL, not OTP, on the other end of the STI-CA.
///
/// The key written to `/tmp` is generated for this check and deleted
/// after it: no key that signs anything ever reaches a disk here.
pub fn csr_matches_openssl_test() {
  case shell("command -v openssl >/dev/null 2>&1 && echo yes || echo no") {
    "no" -> io.println("ffi_test: no openssl, skipping the CSR check")
    _ -> {
      let key = generate_ec_key()
      let assert Ok(request) =
        csr(key, "Example Telecom", "SHAKEN 999Y", "999Y")
      let base = "/tmp/stir-ffi-openssl-" <> uuid()
      let key_path = base <> ".key"
      let csr_path = base <> ".csr"
      let _ = write_file(key_path, key)
      let _ = write_file(csr_path, request)

      assert checked("openssl req -noout -verify -in " <> csr_path) == "passed"
      assert checked("openssl pkey -check -noout -in " <> key_path) == "passed"
      // The request really does carry what it was asked for.
      let text = shell("openssl req -noout -text -in " <> csr_path <> " 2>&1")
      assert string.contains(text, "SHAKEN 999Y")
      assert string.contains(text, "1.3.6.1.5.5.7.1.26")
      // A CSR whose signature was tampered with does not verify, so the
      // check above is a check.
      let broken =
        string.replace(request, "REQUEST-----\nMII", "REQUEST-----\nMIJ")
      let broken_path = base <> ".broken.csr"
      let _ = write_file(broken_path, broken)
      assert checked("openssl req -noout -verify -in " <> broken_path)
        == "failed"

      let _ = delete_file(key_path)
      let _ = delete_file(csr_path)
      let _ = delete_file(broken_path)
      Nil
    }
  }
}

/// One `{http, _}` conversation, fed to the reader from its own
/// mailbox: `stream_start`, the parts, `stream_end`.
fn stream(
  headers: List(#(String, String)),
  parts: List(String),
) -> Result(#(Int, List(#(String, String)), String), String) {
  let http = atom("http")
  let reference = make_ref()
  let me = self()
  let _ = send(me, #(http, #(reference, atom("stream_start"), headers)))
  list.each(parts, fn(part) {
    send(me, #(http, #(reference, atom("stream"), part)))
  })
  let _ = send(me, #(http, #(reference, atom("stream_end"), [])))
  receive_response(reference, 1000)
}

/// A shell command's output, with a word for whether it succeeded.
fn checked(command: String) -> String {
  shell(command <> " >/dev/null 2>&1 && echo passed || echo failed")
}

fn shell(command: String) -> String {
  string.trim(charlist_to_string(os_cmd(to_charlist(command))))
}

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

@external(erlang, "stir_ffi", "validate_chain")
fn validate_chain(
  chain: String,
  trust: String,
  crl: String,
  signer: String,
  now: Int,
) -> Result(Nil, String)

@external(erlang, "stir_ffi", "validate_chain_info")
fn validate_chain_info(
  chain: String,
  trust: String,
  crl: String,
  signer: String,
  now: Int,
) -> Result(String, String)

@external(erlang, "stir_ffi", "validate_chain_with_anchors")
fn validate_chain_with_anchors(
  chain: String,
  trust: String,
  crl: String,
  signer: String,
  crl_anchors: String,
  now: Int,
) -> Result(Nil, String)

@external(erlang, "stir_ffi", "receive_response")
fn receive_response(
  request_id: Dynamic,
  timeout_ms: Int,
) -> Result(#(Int, List(#(String, String)), String), String)

/// An Erlang atom, and a character list, as they are: the streaming
/// messages and `os:cmd/1` are Erlang shapes Gleam has no literal for.
type Atom

type Charlist

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Atom

@external(erlang, "erlang", "make_ref")
fn make_ref() -> Dynamic

@external(erlang, "erlang", "self")
fn self() -> Dynamic

@external(erlang, "erlang", "send")
fn send(to: Dynamic, message: message) -> Dynamic

@external(erlang, "unicode", "characters_to_list")
fn to_charlist(text: String) -> Charlist

@external(erlang, "unicode", "characters_to_binary")
fn charlist_to_string(chars: Charlist) -> String

@external(erlang, "os", "cmd")
fn os_cmd(command: Charlist) -> Charlist

@external(erlang, "file", "write_file")
fn write_file(path: String, contents: String) -> Dynamic

@external(erlang, "file", "delete")
fn delete_file(path: String) -> Dynamic

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "stir_ffi", "generate_ec_key")
fn generate_ec_key() -> String

@external(erlang, "stir_ffi", "public_key_pem")
fn public_key_pem(private_key_pem: String) -> Result(String, String)

@external(erlang, "stir_ffi", "ecdsa_sign")
fn ecdsa_sign(
  private_key_pem: String,
  message: String,
) -> Result(BitArray, String)

@external(erlang, "stir_ffi", "ecdsa_verify")
fn ecdsa_verify(pem: String, message: String, signature: BitArray) -> Bool

@external(erlang, "stir_ffi", "csr")
fn csr(
  private_key_pem: String,
  org: String,
  cn: String,
  spc: String,
) -> Result(String, String)

@external(erlang, "stir_ffi", "certificate_info")
fn certificate_info(chain_pem: String) -> Result(String, String)

@external(erlang, "stir_ffi", "certificate_matches_key")
fn certificate_matches_key(chain_pem: String, private_key_pem: String) -> Bool

@external(erlang, "stir_ffi", "aes_gcm_seal")
fn aes_gcm_seal(key: BitArray, aad: BitArray, plain: BitArray) -> BitArray

@external(erlang, "stir_ffi", "aes_gcm_open")
fn aes_gcm_open(
  key: BitArray,
  aad: BitArray,
  blob: BitArray,
) -> Result(BitArray, Nil)

@external(erlang, "stir_ffi", "sha256_hex")
fn sha256_hex(bytes: BitArray) -> String

@external(erlang, "stir_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray

@external(erlang, "stir_ffi", "uuid")
fn uuid() -> String

@external(erlang, "stir_ffi", "http_get")
fn http_get(
  url: String,
  timeout_ms: Int,
) -> Result(#(Int, List(#(String, String)), String), String)
