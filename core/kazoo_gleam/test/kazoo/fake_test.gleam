//// What the fake models, which is what a suite written against it is
//// allowed to rely on: document revisions, conflicts, CouchDB's key
//// ordering, and a view that emits only for its own document type.

import gleam/list
import gleam/option.{None}
import gleam/string
import kazoo/accounts
import kazoo/doc.{type Value}
import kazoo/kazoo
import kazoo/testing/fake

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const other_account = "1a2b3c4d5e6f708192a3b4c5d6e7f809"

/// The application's own design document, the way a consumer declares one.
fn widgets() -> List(fake.View) {
  [
    fake.View(name: "app/by_owner", doc_type: "widget", key: fn(document) {
      case
        doc.get_string(document, ["owner"]),
        doc.get_int(document, ["rank"])
      {
        Ok(owner), Ok(rank) -> Ok(doc.List([doc.String(owner), doc.Int(rank)]))
        _, _ -> Error(Nil)
      }
    }),
  ]
}

fn widget(id: String, owner: String, rank: Int) -> Value {
  doc.object([
    #("_id", doc.String(id)),
    #("pvt_type", doc.String("widget")),
    #("owner", doc.String(owner)),
    #("rank", doc.Int(rank)),
  ])
}

/// A first save gets `1-`, and every save after it bumps the revision.
pub fn revisions_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)

  let assert Ok(saved) = kz.datamgr.save_doc("app", widget("w1", "a", 1))
  assert doc.get_string(saved, ["_rev"]) == Ok("1-fake")

  let assert Ok(again) = kz.datamgr.save_doc("app", saved)
  assert doc.get_string(again, ["_rev"]) == Ok("2-fake")
}

/// A save with a stale revision is a conflict, and so is a save with none
/// over a document that has one.
pub fn conflict_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)

  let assert Ok(saved) = kz.datamgr.save_doc("app", widget("w1", "a", 1))
  let assert Ok(_) = kz.datamgr.save_doc("app", saved)

  assert kz.datamgr.save_doc("app", saved) == Error(kazoo.Conflict)
  assert kz.datamgr.save_doc("app", widget("w1", "a", 1))
    == Error(kazoo.Conflict)
  // A document with no id cannot be saved at all.
  assert kz.datamgr.save_doc("app", doc.object([]))
    == Error(kazoo.Invalid("no_id"))
}

/// Kazoo drops a top-level `id` from every document it saves
/// (`kzs_doc:prepare_doc_for_save`), so a decoder that requires one fails on
/// a cluster and has to fail here too.
pub fn top_level_id_is_dropped_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)

  let assert Ok(saved) =
    kz.datamgr.save_doc(
      "app",
      doc.object([
        #("_id", doc.String("w1")),
        #("id", doc.String("w1")),
      ]),
    )
  assert doc.get(saved, ["id"]) == Error(Nil)
  assert doc.get_string(saved, ["_id"]) == Ok("w1")
}

pub fn delete_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)

  let assert Ok(_) = kz.datamgr.save_doc("app", widget("w1", "a", 1))
  let assert Ok(_) = kz.datamgr.del_doc("app", "w1")
  assert kz.datamgr.open_doc("app", "w1") == Error(kazoo.NotFound)
  assert kz.datamgr.del_doc("app", "w1") == Error(kazoo.NotFound)
}

/// A delete leaves a tombstone, and the body before it is read back through
/// the tombstone's history until compaction discards it.
pub fn last_body_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)

  let assert Ok(first) = kz.datamgr.save_doc("app", widget("w1", "a", 1))
  let assert Ok(second) =
    kz.datamgr.save_doc("app", doc.set(first, ["rank"], doc.Int(2)))
  let assert Ok(tombstone) = kz.datamgr.del_doc("app", "w1")
  assert doc.get_string(tombstone, ["_rev"]) == Ok("3-fake")
  assert doc.get_bool(tombstone, ["_deleted"]) == Ok(True)

  let assert Ok(at) = kz.datamgr.open_revision("app", "w1", "3-fake")
  assert doc.get_int(at, ["_revisions", "start"]) == Ok(3)
  assert doc.strings(at, ["_revisions", "ids"]) == ["fake", "fake", "fake"]

  assert kazoo.last_body(kz, "app", "w1", "3-fake") == Ok(second)
  // A revision that still holds a body, as a soft delete's does, is its
  // own answer.
  assert kazoo.last_body(kz, "app", "w1", "1-fake") == Ok(first)
  assert kazoo.last_body(kz, "app", "w1", "9-fake") == Error(kazoo.NotFound)

  fake.compact(f, "app")
  assert kazoo.last_body(kz, "app", "w1", "3-fake") == Error(kazoo.NotFound)
  let assert Ok(_) = kz.datamgr.open_revision("app", "w1", "3-fake")
}

/// A database exists once something has been written to it, and creating one
/// is remembered.
pub fn databases_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)

  assert !kz.datamgr.db_exists("app")
  assert kz.datamgr.db_create("app")
  assert kz.datamgr.db_exists("app")
}

/// Rows come back in the view's key order, not in the order they were
/// written, and `limit` cuts the sorted list.
pub fn view_ordering_test() {
  let f = fake.new_with_views(widgets())
  let kz = fake.kazoo(f)

  fake.put_doc(f, "app", widget("w3", "b", 1))
  fake.put_doc(f, "app", widget("w1", "a", 2))
  fake.put_doc(f, "app", widget("w2", "a", 1))

  let assert Ok(rows) =
    kz.datamgr.get_results("app", "app/by_owner", kazoo.view_options())
  assert ids(rows) == ["w2", "w1", "w3"]

  let assert Ok(limited) =
    kz.datamgr.get_results(
      "app",
      "app/by_owner",
      kazoo.view_options() |> kazoo.with_limit(2),
    )
  assert ids(limited) == ["w2", "w1"]
}

/// A range is closed with an object, because CouchDB's collation puts every
/// object after every array, string, number, boolean and null.
pub fn view_range_test() {
  let f = fake.new_with_views(widgets())
  let kz = fake.kazoo(f)

  fake.put_doc(f, "app", widget("w1", "a", 1))
  fake.put_doc(f, "app", widget("w2", "a", 2))
  fake.put_doc(f, "app", widget("w3", "b", 1))

  let options =
    kazoo.view_options()
    |> kazoo.with_range(
      doc.List([doc.String("a")]),
      doc.List([doc.String("a"), doc.object([])]),
    )
  let assert Ok(rows) = kz.datamgr.get_results("app", "app/by_owner", options)
  assert ids(rows) == ["w1", "w2"]

  // An exact key matches only itself.
  let exact =
    kazoo.view_options()
    |> kazoo.with_key(doc.List([doc.String("b"), doc.Int(1)]))
  let assert Ok(one) = kz.datamgr.get_results("app", "app/by_owner", exact)
  assert ids(one) == ["w3"]
}

/// A row carries the id, the key and a null value; the document itself only
/// when the reader asked for it.
pub fn view_row_shape_test() {
  let f = fake.new_with_views(widgets())
  let kz = fake.kazoo(f)
  fake.put_doc(f, "app", widget("w1", "a", 1))

  let assert Ok([row]) =
    kz.datamgr.get_results("app", "app/by_owner", kazoo.view_options())
  assert doc.get_string(row, ["id"]) == Ok("w1")
  assert doc.get(row, ["key"]) == Ok(doc.List([doc.String("a"), doc.Int(1)]))
  assert doc.get(row, ["value"]) == Ok(doc.Null)
  assert doc.get(row, ["doc"]) == Error(Nil)

  let assert Ok([with_doc]) =
    kz.datamgr.get_results(
      "app",
      "app/by_owner",
      kazoo.view_options() |> kazoo.with_docs,
    )
  assert doc.get_string(with_doc, ["doc", "owner"]) == Ok("a")
}

/// A view emits only for its own document type, a deleted document is in no
/// view, and a view nothing declared is empty rather than an error.
pub fn view_filters_test() {
  let f = fake.new_with_views(widgets())
  let kz = fake.kazoo(f)

  fake.put_doc(f, "app", widget("w1", "a", 1))
  fake.put_doc(
    f,
    "app",
    doc.object([
      #("_id", doc.String("other")),
      #("pvt_type", doc.String("gadget")),
      #("owner", doc.String("a")),
      #("rank", doc.Int(1)),
    ]),
  )
  fake.put_doc(
    f,
    "app",
    doc.set(widget("w2", "a", 2), ["pvt_deleted"], doc.Bool(True)),
  )

  let assert Ok(rows) =
    kz.datamgr.get_results("app", "app/by_owner", kazoo.view_options())
  assert ids(rows) == ["w1"]

  let assert Ok(none) =
    kz.datamgr.get_results("app", "app/nothing", kazoo.view_options())
  assert none == []
}

/// The realm listing of the aggregate `accounts` database is built in, so an
/// application that resolves a realm needs no views of its own.
pub fn account_views_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  fake.put_account(f, account, "ACME.example.com", [])
  fake.put_account(f, other_account, "other.example.com", [account])

  assert accounts.id_for_realm(kz, "acme.example.com") == Ok(account)
  // The view emits the realm in lower case, and the lookup lowercases too.
  assert accounts.id_for_realm(kz, "ACME.EXAMPLE.COM") == Ok(account)
  assert accounts.id_for_realm(kz, "nobody.example.com")
    == Error(kazoo.NotFound)
  assert accounts.chain(kz, other_account) == Ok([account, other_account])
}

/// Time stands still until a test moves it, and the generated passwords are
/// a counter rather than random bytes.
pub fn clock_and_random_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)

  let at = kz.now()
  assert kz.now() == at
  fake.set_now(f, at + 60)
  assert kz.now() == at + 60

  assert kz.random(8) != kz.random(8)
}

/// Alerts and check-sync notifies are recorded rather than sent, in the
/// order they happened.
pub fn recorded_calls_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  fake.put_account(f, account, "acme.example.com", [])

  let assert Ok(Nil) =
    kz.alerts.create(kazoo.Alert(
      title: "Trouble",
      message: "something",
      account_id: account,
      owner_id: None,
      reseller_id: None,
      metadata: doc.object([]),
    ))
  let assert Ok(Nil) = kz.switch.check_sync("check-sync", "acme", "1001")

  let assert [alert] = fake.alerts(f)
  assert alert.title == "Trouble"
  assert fake.notifies(f)
    == [fake.Notify(event: "check-sync", realm: "acme", username: "1001")]
}

/// Only the tokens a test put there validate.
pub fn tokens_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  fake.token_for(f, "good", account)

  let assert Ok(claims) = kz.auth.validate_token("good")
  assert doc.get_string(claims, ["account_id"]) == Ok(account)
  assert kz.auth.validate_token("bad") == Error(kazoo.Invalid("invalid_token"))
}

/// A configuration value a test set is read back; anything else is the
/// caller's default.
pub fn config_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  fake.put_config(f, "port", doc.Int(9000))

  assert kz.config.get_int("port", 8100) == 9000
  assert kz.config.get_int("missing", 8100) == 8100
  assert kz.config.get_string("port", "x") == "x"

  let assert Ok(Nil) = kz.config.set_default("mode", doc.String("amqp"))
  assert kz.config.get_string("mode", "poll") == "amqp"
}

pub fn account_ids_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  assert kz.cluster.account_ids() == Ok([])

  fake.put_account(f, account, "acme.example.com", [])
  fake.put_account(f, other_account, "other.example.com", [])
  let assert Ok(found) = kz.cluster.account_ids()
  assert list.sort(found, string.compare)
    == list.sort([account, other_account], string.compare)
}

fn ids(rows: List(Value)) -> List(String) {
  list.map(rows, fn(row) {
    case doc.get_string(row, ["id"]) {
      Ok(id) -> id
      Error(_) -> ""
    }
  })
}

/// The descendants listing fans out: one row per ancestor, so a range from
/// `[root]` to `[root, {}]` is the whole subtree and a range under the
/// reseller is only what sits below it.
pub fn descendants_fan_out_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  let root = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
  fake.put_account(f, root, "root.example", [])
  fake.put_account(f, account, "reseller.example", [root])
  fake.put_account(f, other_account, "sub.example", [root, account])

  let under = fn(id: String) {
    let assert Ok(rows) =
      kz.datamgr.get_results(
        accounts.aggregate_db,
        accounts.listing_by_descendants,
        kazoo.view_options()
          |> kazoo.with_range(
            doc.List([doc.String(id)]),
            doc.List([doc.String(id), doc.object([])]),
          ),
      )
    ids(rows)
  }
  // Rows sort by `[ancestor, name]`, and the fake names an account after
  // its id.
  assert under(root) == [other_account, account]
  assert under(account) == [other_account]
  assert under(other_account) == []
}

/// A minted token validates to the claims it was minted from.
pub fn minted_tokens_validate_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  let claims = [
    #("account_id", doc.String(account)),
    #("owner_id", doc.String("00000000000000000000000000000001")),
    #("method", doc.String("cb_example_auth")),
    #("exp", doc.Int(1_757_403_600)),
  ]
  let assert Ok(token) = kz.auth.create_token(claims)
  assert kz.auth.validate_token(token) == Ok(doc.object(claims))
  assert fake.minted(f) == [#(token, doc.object(claims))]
  assert kz.auth.validate_token("not-minted")
    == Error(kazoo.Invalid("invalid_token"))
}
