//// The WebSocket subscriptions: what a client asks for, what it is matched
//// against, and what the listener binds. The second and third have to be
//// the same string, from the two ends of `bh_callcenter`.
////
//// `bh_callcenter` is Erlang, so this reaches it through `subscription/2`,
//// which is the module's own mapping with the parts that are not strings
//// taken off.

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

pub fn agent_subscription_test() {
  let #(requested, subscribed, bound) = subscription(account, ["agent", "a1"])
  assert requested == "callcenter.agent.a1"
  assert subscribed == ["callcenter.agent." <> account <> ".a1"]
  assert bound == subscribed
}

pub fn queue_subscription_test() {
  let #(requested, subscribed, bound) = subscription(account, ["queue", "q1"])
  assert requested == "callcenter.queue.q1"
  assert subscribed == ["callcenter.queue." <> account <> ".q1"]
  assert bound == subscribed
}

pub fn call_subscription_test() {
  let #(requested, subscribed, bound) = subscription(account, ["call", "c1"])
  assert requested == "callcenter.call.c1"
  assert subscribed == ["callcenter.call." <> account <> ".c1"]
  assert bound == subscribed
}

/// An id of `*` is every agent in the account, and the account is still in
/// the key: one tenant's wallboard never sees another's.
pub fn wildcard_id_test() {
  let #(requested, subscribed, bound) = subscription(account, ["agent", "*"])
  assert requested == "callcenter.agent.*"
  assert subscribed == ["callcenter.agent." <> account <> ".*"]
  assert bound == subscribed
}

/// A wildcard family is all three, in the order they are advertised, so one
/// subscription covers an account's whole call center.
pub fn wildcard_family_test() {
  let #(requested, subscribed, bound) = subscription(account, ["*", "*"])
  assert requested == "callcenter.*.*"
  assert subscribed
    == [
      "callcenter.agent." <> account <> ".*",
      "callcenter.queue." <> account <> ".*",
      "callcenter.call." <> account <> ".*",
    ]
  assert bound == subscribed
}

/// A superduper admin may subscribe across accounts. The account half of the
/// key is then a wildcard like any other.
pub fn wildcard_account_test() {
  let #(_requested, subscribed, bound) = subscription("*", ["queue", "*"])
  assert subscribed == ["callcenter.queue.*.*"]
  assert bound == subscribed
}

pub fn advertised_families_test() {
  assert families() == ["agent", "queue", "call"]
}

@external(erlang, "bh_callcenter", "subscription")
fn subscription(
  account_id: String,
  keys: List(String),
) -> #(String, List(String), List(String))

@external(erlang, "bh_callcenter", "families")
fn families() -> List(String)
