//// The outbound entry point over the fake: a key imported and activated
//// through `keys`, a signer started the way `signer_test` starts one, and
//// every answer `stepswitch` can get -- signed, carried through, left
//// alone -- with the reasons. Then the Erlang face of it: `headers` over
//// a map of binaries, and over what is not a map at all.
////
//// Like `signer_test`, one test: the signer is a named process and the
//// application's own is stopped first and started again at the end.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake
import stir/key
import stir/keys
import stir/keys_test
import stir/numbers
import stir/outbound.{Facts, Passthrough, Signed, Unsigned}
import stir/passport
import stir/secret
import stir/signer
import stir/system
import stir/vault

const base = "https://api.example/v2/stir/certs"

const account = "00000000000000000000000000000003"

fn views() -> List(fake.View) {
  [
    keys_test.key_view(),
    fake.View(
      name: numbers.external_numbers_view,
      doc_type: numbers.external_number_type,
      key: fn(document) {
        doc.get_string(document, ["number"])
        |> result.map(fn(number) {
          doc.List([
            doc.String(numbers.external_number_type),
            doc.String(number),
          ])
        })
      },
    ),
  ]
}

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

/// A leg with nothing going for it: an onnet call from a number nobody
/// owns, which the defaults sign at B.
fn plain() -> outbound.Facts {
  Facts(
    account_id: account,
    orig_number: "+1 (404) 555-0199",
    dest_number: "+14045550100",
    resource_id: Some("carrier-1"),
    inception_offnet: False,
    call_forward: False,
    retain_cid: False,
    privacy_hide_number: False,
    emergency: False,
    inbound_carrier: False,
    inbound_caller: None,
    inbound_verstat: None,
    inbound_attest: None,
    inbound_identity: None,
    resource_sign: None,
  )
}

/// A leg that forwards an inbound carrier call whose caller is the
/// number this leg will sign, and which verified: everything §3.5's
/// rule 2 asks for.
fn forwarded() -> outbound.Facts {
  Facts(
    ..plain(),
    call_forward: True,
    retain_cid: True,
    inbound_carrier: True,
    inbound_caller: Some("+14045550199"),
    inbound_verstat: Some("TN-Validation-Passed"),
    inbound_attest: Some("A"),
  )
}

/// Every check runs fresh: nothing cached from the last decision.
fn fresh() -> Nil {
  keys.forget_selection()
  numbers.forget()
  outbound.forget_failures()
}

pub fn outbound_test() {
  let _ = application_stop(atom.create("stir"))
  unregistered()

  let f = fake.new_with_views(views())
  let kz = fake.kazoo(f)
  fake.put_account(f, account, "account.example", [])
  fresh()

  // --- nothing to sign with, nothing to sign --------------------------

  // Off by default: no key is looked for, no failure is counted.
  assert outbound.decide(kz, plain()) == Unsigned("signing disabled")
  assert outbound.failures(kz, "no key for scope") == 0

  fake.put_config(f, "sign_enabled", doc.String("true"))
  // On, with no key for the scope: unsigned, counted, and logged.
  assert outbound.decide(kz, plain()) == Unsigned("no key for scope")
  assert outbound.failures(kz, "no key for scope") == 1
  assert outbound.decide(kz, plain()) == Unsigned("no key for scope")
  assert outbound.failures(kz, "no key for scope") == 2

  // A resource that opted out, and a request with no number, are left
  // alone without being counted as failures.
  assert outbound.decide(kz, Facts(..plain(), resource_sign: Some(False)))
    == Unsigned("resource opted out")
  assert outbound.decide(kz, Facts(..plain(), orig_number: ""))
    == Unsigned("no orig number")
  assert outbound.decide(kz, Facts(..plain(), orig_number: "anonymous"))
    == Unsigned("no orig number")
  assert outbound.decide(kz, Facts(..plain(), dest_number: ""))
    == Unsigned("no dest number")
  // One with no account is a wiring fault and is counted.
  assert outbound.decide(kz, Facts(..plain(), account_id: ""))
    == Unsigned("no account id")
  assert outbound.failures(kz, "no account id") == 1
  assert outbound.failures(kz, "no key for scope") == 2

  // --- a key, and no signer ---------------------------------------------

  let kek = random_bytes(32)
  let assert Ok(sealer) = vault.from_bytes(kek)
  let assert Ok(imported) =
    keys.import_key(
      kz,
      sealer,
      key.System,
      secret.new("test key", bit_array.from_string(fixture("test-key.pem"))),
      fixture("test-cert.pem"),
      "TEST",
      base,
      "sup",
    )
  let assert Ok(_) = keys.activate(kz, imported.kid, "m/u")
  fresh()

  // Fail open: the signer is not running on this node, and the leg is
  // built unsigned. Past ten of these in five minutes an alert is raised
  // (off the call path; on this node with no master account it is a log
  // line), and the count goes on.
  let not_running = "signer: the signer is not running on this node"
  assert outbound.decide(kz, plain()) == Unsigned(not_running)
  assert outbound.failures(kz, not_running) == 1
  list.each(list.repeat(Nil, 11), fn(_) {
    let before = outbound.failures(kz, not_running)
    assert outbound.decide(kz, plain()) == Unsigned(not_running)
    assert outbound.failures(kz, not_running) == before + 1
  })
  assert outbound.failures(kz, not_running) == 12
  // The window closes after five minutes.
  fake.set_now(f, kz.now() + 301)
  assert outbound.failures(kz, not_running) == 0
  assert outbound.decide(kz, plain()) == Unsigned(not_running)
  assert outbound.failures(kz, not_running) == 1

  // --- signed --------------------------------------------------------------

  putenv(system.kek_variable, bit_array.base64_encode(kek, True))
  let assert Ok(started) = signer.start(kz)
  unsetenv(system.kek_variable)
  fresh()

  let assert Signed(identity, kid, attest, origid, exclude) =
    outbound.decide(kz, plain())
  assert kid == imported.kid
  assert attest == "B"
  assert exclude == "^sip_h_[Ii]dentity$"
  assert string.length(origid) == 36
  let assert Ok(parsed) = passport.parse_identity(identity)
  assert parsed.x5u == imported.x5u
  assert parsed.alg == Some("ES256")
  assert parsed.ppt == Some("shaken")
  let assert Ok(claims) =
    passport.verify(parsed, fixture("test-cert.pem"), kz.now(), 60)
  assert claims
    == passport.Claims(
      attest: "B",
      dest: ["14045550100"],
      iat: kz.now(),
      orig: "14045550199",
      origid:,
    )
  // The wrong certificate does not verify it.
  assert passport.verify(
      parsed,
      fixture("example-999Y-chain.pem"),
      kz.now(),
      60,
    )
    |> result.is_error

  // A fresh origid per call.
  let assert Signed(_, _, _, again, _) = outbound.decide(kz, plain())
  assert again != origid

  // The policy, through the real ownership questions: in from a carrier
  // and back out is C ...
  let assert Signed(_, _, "C", _, _) =
    outbound.decide(kz, Facts(..plain(), inception_offnet: True))
  // ... a forward of a verified inbound carrier call, with that call's
  // caller kept, is B by default, and A only where an operator asked for
  // it and the inbound call was itself A ...
  let forwarded = forwarded()
  let assert Signed(_, _, "B", _, _) = outbound.decide(kz, forwarded)
  fake.put_config(f, "attest_forwarded", doc.String("A"))
  let assert Signed(_, _, "A", _, _) = outbound.decide(kz, forwarded)
  // ... a carrier's suffixed pass is a pass, at the suffix's level: a C
  // call forwarded is C under our certificate, not A ...
  let assert Signed(_, _, "C", _, _) =
    outbound.decide(
      kz,
      Facts(
        ..forwarded,
        inbound_verstat: Some("TN-Validation-Passed-C"),
        inbound_attest: None,
      ),
    )
  let assert Signed(_, _, "B", _, _) =
    outbound.decide(
      kz,
      Facts(..forwarded, inbound_verstat: Some("TN-Validation-Passed-B")),
    )
  // ... the lower of the suffix and the recorded attestation ...
  let assert Signed(_, _, "C", _, _) =
    outbound.decide(
      kz,
      Facts(
        ..forwarded,
        inbound_verstat: Some("TN-Validation-Passed-B"),
        inbound_attest: Some("C"),
      ),
    )
  // ... and C when nothing says what the inbound call carried.
  let assert Signed(_, _, "C", _, _) =
    outbound.decide(kz, Facts(..forwarded, inbound_attest: None))
  // ... C when that call failed verification or nothing validated it:
  // it carried no level, and a forward is capped at what it carried.
  let assert Signed(_, _, "C", _, _) =
    outbound.decide(
      kz,
      Facts(..forwarded, inbound_verstat: Some("TN-Validation-Failed")),
    )
  let assert Signed(_, _, "C", _, _) =
    outbound.decide(
      kz,
      Facts(..forwarded, inbound_verstat: Some("No-TN-Validation")),
    )
  let assert Signed(_, _, "C", _, _) =
    outbound.decide(kz, Facts(..forwarded, inbound_verstat: None))
  // A forward that does not keep the caller id is not a forward here.
  let assert Signed(_, _, "B", _, _) =
    outbound.decide(kz, Facts(..plain(), call_forward: True))
  // Nor is one the inbound hook did not corroborate: the markers alone,
  // the markers with no inbound caller, and the markers with another
  // account's caller are all B and never A.
  let assert Signed(_, _, "B", _, _) =
    outbound.decide(kz, Facts(..forwarded, inbound_carrier: False))
  let assert Signed(_, _, "B", _, _) =
    outbound.decide(kz, Facts(..forwarded, inbound_caller: None))
  let assert Signed(_, _, "B", _, _) =
    outbound.decide(
      kz,
      Facts(..forwarded, inbound_caller: Some("+12125550111")),
    )
  // ... a verified external number of the account is A.
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String("ext-1")),
      #("pvt_type", doc.String(numbers.external_number_type)),
      #("number", doc.String("+14045550199")),
      #("pvt_verified", doc.Bool(True)),
    ]),
  )
  numbers.forget()
  // B by default; A where an operator trusts the platform's verification.
  let assert Signed(_, _, "B", _, _) = outbound.decide(kz, plain())
  fake.put_config(f, "attest_verified_external_number", doc.String("A"))
  let assert Signed(_, _, "A", _, _) = outbound.decide(kz, plain())
  // Not for another account's number.
  let assert Signed(_, _, "B", _, _) =
    outbound.decide(kz, Facts(..plain(), orig_number: "+14045550198"))
  // Not for an adopted one: `gather_external_numbers` marks every caller id
  // it finds verified and adopted.
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String("ext-2")),
      #("pvt_type", doc.String(numbers.external_number_type)),
      #("number", doc.String("+14045550197")),
      #("pvt_verified", doc.Bool(True)),
      #("pvt_adopted", doc.Bool(True)),
    ]),
  )
  numbers.forget()
  let assert Signed(_, _, "B", _, _) =
    outbound.decide(kz, Facts(..plain(), orig_number: "+14045550197"))

  // --- passthrough -----------------------------------------------------------

  fake.put_config(f, "attest_forwarded", doc.String("passthru"))
  let header = "eyJ.eyJ.sig;info=<x>"
  let carried = Facts(..forwarded, inbound_identity: Some(header))
  assert outbound.decide(kz, carried)
    == Passthrough(identity: header, exclude: "^sip_h_[Ii]dentity$")
  // With nothing to carry through, signed as transit.
  let assert Signed(_, _, "C", _, _) = outbound.decide(kz, forwarded)
  // And a failed inbound leg is signed, at C: passthru governs the other
  // case, and the cap holds a failed call's forward to C.
  let assert Signed(_, _, "C", _, _) =
    outbound.decide(
      kz,
      Facts(..carried, inbound_verstat: Some("TN-Validation-Failed")),
    )
  fake.put_config(f, "attest_forwarded", doc.String("A"))

  // --- skipped by policy ---------------------------------------------------

  assert outbound.decide(kz, Facts(..plain(), emergency: True))
    == Unsigned("emergency")
  assert outbound.decide(
      kz,
      Facts(..plain(), emergency: True, inception_offnet: True),
    )
    == Unsigned("emergency")
  assert outbound.decide(kz, Facts(..plain(), orig_number: "+442071234567"))
    == Unsigned("orig tn outside NANP")
  fake.put_config(f, "sign_non_nanp_origin", doc.String("true"))
  let assert Signed(_, _, "B", _, _) =
    outbound.decide(kz, Facts(..plain(), orig_number: "+442071234567"))
  // Privacy does not change the number that is signed: the verified
  // external number seeded above is still A with the caller id hidden.
  let assert Signed(_, _, "A", _, _) =
    outbound.decide(kz, Facts(..plain(), privacy_hide_number: True))
  let assert Signed(_, _, "B", _, _) =
    outbound.decide(
      kz,
      Facts(..plain(), orig_number: "+14045550198", privacy_hide_number: True),
    )
  fake.put_config(f, "sign_anonymous", doc.String("false"))
  assert outbound.decide(kz, Facts(..plain(), privacy_hide_number: True))
    == Unsigned("anonymous")
  assert outbound.decide(
      kz,
      Facts(..plain(), orig_number: "+14045550198", privacy_hide_number: True),
    )
    == Unsigned("anonymous")
  // None of those is a failure.
  assert outbound.failures(kz, "emergency") == 0
  assert outbound.failures(kz, "anonymous") == 0
  assert outbound.failures(kz, "orig tn outside NANP") == 0

  // --- the Erlang face ------------------------------------------------------

  let facts =
    to_map(
      doc.to_string(
        doc.object([
          #("account_id", doc.String(account)),
          #("orig_number", doc.String("+14045550198")),
          #("dest_number", doc.String("+14045550100")),
          #("resource_id", doc.String("carrier-1")),
          #("inception", doc.String("offnet")),
          #("call_forward", doc.String("false")),
          #("retain_cid", doc.String("false")),
          #("privacy_hide_number", doc.String("false")),
          #("emergency", doc.String("false")),
          #("budget_ms", doc.String("500")),
        ]),
      ),
    )
  // What the map decodes to.
  assert outbound.facts_from(facts)
    == Facts(
      ..plain(),
      orig_number: "+14045550198",
      inception_offnet: True,
      resource_id: Some("carrier-1"),
    )
  assert outbound.facts_from(
      to_map(
        doc.to_string(
          doc.object([
            #("account_id", doc.String(account)),
            #("orig_number", doc.String("14045550199")),
            #("dest_number", doc.String("14045550100")),
            #("call_forward", doc.String("TRUE")),
            #("retain_cid", doc.String("true")),
            #("emergency", doc.String("yes")),
            #("inbound_carrier", doc.String("true")),
            #("inbound_caller", doc.String("14045550199")),
            #("inbound_verstat", doc.String("TN-Validation-Failed")),
            #("inbound_attest", doc.String("B")),
            #("inbound_identity", doc.String("")),
            #("resource_sign", doc.String("false")),
          ]),
        ),
      ),
    )
    == Facts(
      account_id: account,
      orig_number: "14045550199",
      dest_number: "14045550100",
      resource_id: None,
      inception_offnet: False,
      call_forward: True,
      retain_cid: True,
      privacy_hide_number: False,
      emergency: False,
      inbound_carrier: True,
      inbound_caller: Some("14045550199"),
      inbound_verstat: Some("TN-Validation-Failed"),
      inbound_attest: Some("B"),
      inbound_identity: None,
      resource_sign: Some(False),
    )

  // `inception` is the token the Erlang side maps Kazoo's route string
  // to; a route string that reached this unmapped is a call that came in
  // from somewhere all the same.
  let inception = fn(value) {
    outbound.facts_from(
      to_map(
        doc.to_string(
          doc.object([
            #("account_id", doc.String(account)),
            #("inception", doc.String(value)),
          ]),
        ),
      ),
    ).inception_offnet
  }
  assert inception("offnet")
  assert inception("OFFNET")
  assert inception("4045550199@account.example")
  assert !inception("onnet")
  assert !inception("")

  // A signed answer, in the shape `stepswitch` reads: a transit call from
  // a number nobody owns, C.
  let assert Ok(answer) = outbound.headers_with(kz, facts)
  let signed = doc.from_dynamic(answer)
  let assert Ok(header) = doc.get_string(signed, ["Identity"])
  let assert Ok(parsed) = passport.parse_identity(header)
  let assert Ok(claims) =
    passport.verify(parsed, fixture("test-cert.pem"), kz.now(), 60)
  assert claims.attest == "C"
  assert doc.get_string(signed, ["Exclude-Outgoing-Extra-Header"])
    == Ok("^sip_h_[Ii]dentity$")
  assert doc.get_string(signed, ["Custom-Channel-Vars", "STIR-Attest"])
    == Ok("C")
  assert doc.get_string(signed, ["Custom-Channel-Vars", "STIR-Key-ID"])
    == Ok(imported.kid)
  assert doc.get_string(signed, ["Custom-Channel-Vars", "STIR-Orig-ID"])
    == Ok(claims.origid)
  assert doc.members(signed) |> list.length == 3

  // A passthrough answer carries the inbound call's own header: nothing
  // in FreeSWITCH 1.11.4 is behind `sip_identity_passthru`, so the value
  // is answered here for `stepswitch` to place as the Identity header.
  fake.put_config(f, "attest_forwarded", doc.String("passthru"))
  let inbound_header = "eyJ.eyJ.sig;info=<x>"
  let passthru_facts = fn(carrier: String) {
    to_map(
      doc.to_string(
        doc.object([
          #("account_id", doc.String(account)),
          // A number the account neither holds nor has verified, so what
          // decides this leg is the forward rule and nothing else.
          #("orig_number", doc.String("+14045550198")),
          #("dest_number", doc.String("+14045550100")),
          #("call_forward", doc.String("true")),
          #("retain_cid", doc.String("true")),
          #("inbound_carrier", doc.String(carrier)),
          #("inbound_caller", doc.String("+14045550198")),
          #("inbound_verstat", doc.String("TN-Validation-Passed")),
          #("inbound_identity", doc.String(inbound_header)),
        ]),
      ),
    )
  }
  let assert Ok(carried) = outbound.headers_with(kz, passthru_facts("true"))
  let carried = doc.from_dynamic(carried)
  assert doc.get_string(carried, ["Identity"]) == Ok(inbound_header)
  assert doc.get_string(carried, ["Exclude-Outgoing-Extra-Header"])
    == Ok("^sip_h_[Ii]dentity$")
  assert doc.get_string(carried, ["Custom-Channel-Vars", "STIR-Attest"])
    == Ok("passthru")
  assert doc.members(carried) |> list.length == 3
  // The same call without the inbound hook's corroboration is signed,
  // not carried: the leg is not a forward as far as the policy goes.
  let assert Ok(signed_instead) =
    outbound.headers_with(kz, passthru_facts("false"))
  let signed_instead = doc.from_dynamic(signed_instead)
  assert doc.get_string(signed_instead, ["Custom-Channel-Vars", "STIR-Attest"])
    == Ok("B")
  fake.put_config(f, "attest_forwarded", doc.String("A"))

  // Left alone, with the reason.
  assert outbound.headers_with(
      kz,
      to_map(
        doc.to_string(
          doc.object([
            #("account_id", doc.String(account)),
            #("orig_number", doc.String("+14045550199")),
            #("dest_number", doc.String("+14045550100")),
            #("emergency", doc.String("true")),
          ]),
        ),
      ),
    )
    == Error("emergency")

  // Garbage in: an answer, never a raise.
  assert outbound.headers_with(kz, dynamic.nil()) == Error("no account id")
  assert outbound.headers_with(kz, dynamic.int(3)) == Error("no account id")
  assert outbound.headers_with(kz, dynamic.string("facts"))
    == Error("no account id")
  assert outbound.headers_with(kz, dynamic.list([dynamic.string("a")]))
    == Error("no account id")
  assert outbound.headers_with(kz, to_map("{}")) == Error("no account id")
  assert outbound.headers_with(kz, to_map("not json")) == Error("no account id")
  assert outbound.headers_with(
      kz,
      to_map("{\"account_id\": 3, \"orig_number\": [1], \"dest_number\": {}}"),
    )
    == Error("no account id")
  assert outbound.headers_with(
      kz,
      to_map(
        "{\"account_id\": \""
        <> account
        <> "\", \"orig_number\": 14045550199, \"dest_number\": true}",
      ),
    )
    == Error("no orig number")

  // And something that crashes inside the decision is a crash to
  // `stepswitch`, not an exit: a record whose datastore raises.
  let raising =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(..kz.datamgr, get_results: fn(_db, _view, _opts) {
        panic as "the datastore blew up"
      }),
    )
  fresh()
  assert outbound.headers_with(raising, facts) == Error("crash")
  assert outbound.failures(kz, "crash") == 1

  // The live entry point over this node: no datastore, signing off, and
  // an answer for anything at all.
  assert outbound.headers(facts) == Error("signing disabled")
  assert outbound.headers(dynamic.nil()) == Error("signing disabled")

  // Leave the node as it was found.
  process.unlink(started.pid)
  process.kill(started.pid)
  let _ = application_ensure_all_started(atom.create("stir"))
  Nil
}

/// The name is free again: a registered name goes with the process that
/// held it, which takes a moment after the kill.
fn unregistered() -> Nil {
  case process.named(signer.name()) {
    Error(Nil) -> Nil
    Ok(_) -> {
      process.sleep(5)
      unregistered()
    }
  }
}

fn putenv(name: String, value: String) -> Nil {
  let _ = os_putenv(charlist.from_string(name), charlist.from_string(value))
  Nil
}

fn unsetenv(name: String) -> Nil {
  let _ = os_unsetenv(charlist.from_string(name))
  Nil
}

@external(erlang, "application", "stop")
fn application_stop(app: Atom) -> Dynamic

@external(erlang, "application", "ensure_all_started")
fn application_ensure_all_started(app: Atom) -> Dynamic

@external(erlang, "os", "putenv")
fn os_putenv(name: Charlist, value: Charlist) -> Bool

@external(erlang, "os", "unsetenv")
fn os_unsetenv(name: Charlist) -> Bool

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "stir_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray

/// The map `stepswitch` would send, from JSON.
@external(erlang, "stir_ffi", "to_map")
fn to_map(json: String) -> Dynamic
