//// `kapps_account_config:get_global/4`, read over the fake: the account's
//// document, then its reseller's, then `system_config`, then the default.

import kazoo/account_config
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const reseller = "9ab0c1d2e3f405162738495a6b7c8d9e"

fn cluster() -> fake.Fake {
  let f = fake.new()
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String(account)),
      #("pvt_type", doc.String("account")),
      #("realm", doc.String("one.example.test")),
      #("pvt_reseller_id", doc.String(reseller)),
    ]),
  )
  f
}

fn configs(
  f: fake.Fake,
  account_id: String,
  fields: List(#(String, doc.Value)),
) {
  fake.put_doc(
    f,
    kazoo.account_db(account_id),
    doc.object([#("_id", doc.String("configs_callcenter")), ..fields]),
  )
}

fn read(f: fake.Fake) -> String {
  account_config.get_string(
    fake.kazoo(f),
    account,
    "callcenter",
    "agent_presence_prefix",
    "*22",
  )
}

pub fn doc_id_test() {
  assert account_config.doc_id("callcenter") == "configs_callcenter"
}

/// Nothing anywhere is the default.
pub fn the_default_test() {
  assert read(cluster()) == "*22"
}

/// `system_config` stands in for an account that says nothing.
pub fn the_system_value_test() {
  let f = cluster()
  fake.put_config(f, "callcenter.agent_presence_prefix", doc.String("*77"))
  assert read(f) == "*77"
}

/// The account's own document wins over the system.
pub fn the_account_value_test() {
  let f = cluster()
  fake.put_config(f, "callcenter.agent_presence_prefix", doc.String("*77"))
  configs(f, account, [#("agent_presence_prefix", doc.String("*88"))])
  assert read(f) == "*88"
}

/// An account with no document of its own reads its reseller's.
pub fn the_reseller_value_test() {
  let f = cluster()
  configs(f, reseller, [#("agent_presence_prefix", doc.String("*55"))])
  assert read(f) == "*55"
}

/// An account document without the key goes to the system, not to the
/// reseller: `get_global` looks at one document.
pub fn a_document_without_the_key_test() {
  let f = cluster()
  fake.put_config(f, "callcenter.agent_presence_prefix", doc.String("*77"))
  configs(f, account, [#("something_else", doc.Bool(True))])
  configs(f, reseller, [#("agent_presence_prefix", doc.String("*55"))])
  assert read(f) == "*77"
}
