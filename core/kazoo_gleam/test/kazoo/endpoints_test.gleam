//// Endpoints. Building one needs the account's documents, so with no
//// datastore every answer is `Unavailable`; what is checked here is that a
//// failure is a value and never a crash, and how Kazoo's own reasons map on
//// to it.

import kazoo/call
import kazoo/doc
import kazoo/endpoints

fn a_call() -> call.Call {
  call.from_value(
    doc.object([
      #("Call-ID", doc.String("4b1f0c2d-7e8a-9b0c")),
      #("Account-ID", doc.String("4b1f0c2d7e8a9b0c1d2e3f4051627384")),
    ]),
  )
}

pub fn unavailable_test() {
  let c = a_call()
  let user = "9ab0c1d2e3f405162738495a6b7c8d9e"
  assert endpoints.build(c, user) == Error(endpoints.Unavailable)
  assert endpoints.build_for_user(c, user) == Error(endpoints.Unavailable)
  assert endpoints.build_for_device(c, user) == Error(endpoints.Unavailable)
  assert endpoints.build_with(
      c,
      user,
      doc.object([#("source", doc.String("cf"))]),
    )
    == Error(endpoints.Unavailable)
  assert endpoints.by_owner(c, user) == Error(endpoints.Unavailable)
}

pub fn owned_by_test() {
  assert endpoints.owned_by(
      "account%2F4b%2F1f%2F0c2d7e8a9b0c1d2e3f4051627384",
      "9ab0c1d2e3f405162738495a6b7c8d9e",
      "device",
    )
    == []
}

/// A user who owns nothing rings nothing, and a datastore that is not there
/// is the same answer: the list is empty and nobody crashed. What the
/// devices themselves decide needs a node, and is checked there.
pub fn build_for_owned_devices_test() {
  assert endpoints.build_for_owned_devices(
      a_call(),
      "account%2F4b%2F1f%2F0c2d7e8a9b0c1d2e3f4051627384",
      "9ab0c1d2e3f405162738495a6b7c8d9e",
      doc.object([#("source", doc.String("callcenter"))]),
    )
    == []
}
