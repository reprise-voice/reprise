//// The ownership questions over the fake: the number manager is a
//// function the test hands in (`owner_with`, `owned_with`), the verified
//// external numbers come from the account database through the
//// `crossbar_listings/by_type_number` view, registered here the way the
//// design document keys it, and both answers are cached for a minute on
//// the node.
////
//// The cache is the node's, so every test forgets it first and picks
//// numbers of its own.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import kazoo/cache
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake
import stir/numbers

const root = "00000000000000000000000000000001"

const parent = "00000000000000000000000000000002"

const account = "00000000000000000000000000000003"

const stranger = "00000000000000000000000000000004"

fn views() -> List(fake.View) {
  [
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

fn store() -> #(fake.Fake, kazoo.Kazoo) {
  numbers.forget()
  let f = fake.new_with_views(views())
  fake.put_account(f, root, "root.example", [])
  fake.put_account(f, parent, "parent.example", [root])
  fake.put_account(f, account, "account.example", [root, parent])
  fake.put_account(f, stranger, "stranger.example", [root])
  #(f, fake.kazoo(f))
}

/// An external number document as `cb_external_numbers` writes one: the
/// number normalised, with its `+`.
fn external_number(number: String, verified: Bool) -> doc.Value {
  doc.object([
    #("_id", doc.String("ext-" <> number)),
    #("pvt_type", doc.String(numbers.external_number_type)),
    #("number", doc.String(number)),
    #("name", doc.String("Main line")),
    #("pvt_verified", doc.Bool(verified)),
  ])
}

const calls_table = "stir_numbers_test_calls"

/// A number manager that answers `answer` and counts how often it was
/// asked.
fn manager(answer: Result(String, String)) -> numbers.Lookup {
  fn(_tn) {
    let so_far = cache.get(calls_table, "calls") |> result.unwrap(0)
    cache.put(calls_table, "calls", so_far + 1)
    answer
  }
}

fn calls() -> Int {
  cache.get(calls_table, "calls") |> result.unwrap(0)
}

pub fn owner_test() {
  let #(_f, kz) = store()
  cache.clear(calls_table)

  assert numbers.owner_with(kz, "14045550101", manager(Ok(account)))
    == numbers.Account(account)
  assert calls() == 1
  // Cached: the manager is not asked again for a minute, whatever it
  // would say now.
  assert numbers.owner_with(kz, "14045550101", manager(Error("unassigned")))
    == numbers.Account(account)
  assert calls() == 1

  // Every reason the manager can give is nobody, and is cached too.
  assert numbers.owner_with(kz, "14045550102", manager(Error("unassigned")))
    == numbers.Nobody
  assert numbers.owner_with(kz, "14045550103", manager(Error("pending_port")))
    == numbers.Nobody
  assert numbers.owner_with(kz, "14045550104", manager(Error("not_in_service")))
    == numbers.Nobody
  assert numbers.owner_with(
      kz,
      "14045550105",
      manager(Error("no number manager")),
    )
    == numbers.Nobody
  assert calls() == 5
  assert numbers.owner_with(kz, "14045550102", manager(Ok(account)))
    == numbers.Nobody
  assert calls() == 5

  // Forgotten, it is asked again.
  numbers.forget()
  assert numbers.owner_with(kz, "14045550102", manager(Ok(account)))
    == numbers.Account(account)
  assert calls() == 6

  // Over the FFI on a node with no number manager: nobody, and no crash.
  assert numbers.owner(kz, "14045550106") == numbers.Nobody
}

pub fn owned_test() {
  let #(_f, kz) = store()

  // The account's own number, under either scope.
  assert numbers.owned_with(
      kz,
      account,
      "14045550201",
      "account",
      manager(Ok(account)),
    )
    == #(True, False)
  assert numbers.owned_with(
      kz,
      account,
      "14045550201",
      "tree",
      manager(Ok(account)),
    )
    == #(True, False)

  // A parent's number counts only under `tree`; so does the root's.
  assert numbers.owned_with(
      kz,
      account,
      "14045550202",
      "account",
      manager(Ok(parent)),
    )
    == #(False, False)
  assert numbers.owned_with(
      kz,
      account,
      "14045550202",
      "tree",
      manager(Ok(parent)),
    )
    == #(False, True)
  assert numbers.owned_with(
      kz,
      account,
      "14045550203",
      "tree",
      manager(Ok(root)),
    )
    == #(False, True)

  // Another account's number is nobody's as far as this account goes,
  // even under `tree`; and so is a number nobody owns.
  assert numbers.owned_with(
      kz,
      account,
      "14045550204",
      "tree",
      manager(Ok(stranger)),
    )
    == #(False, False)
  assert numbers.owned_with(
      kz,
      account,
      "14045550205",
      "tree",
      manager(Error("unassigned")),
    )
    == #(False, False)

  // A parent's number is not the child's the other way round: the
  // parent does not own what the child owns.
  assert numbers.owned_with(
      kz,
      parent,
      "14045550206",
      "tree",
      manager(Ok(account)),
    )
    == #(False, False)

  // An account that cannot be read has no ancestors.
  assert numbers.owned_with(
      kz,
      "00000000000000000000000000000099",
      "14045550207",
      "tree",
      manager(Ok(root)),
    )
    == #(False, False)

  // Over the FFI on a node with no number manager: nothing is owned.
  assert numbers.owned(kz, account, "14045550208", "tree") == #(False, False)
}

pub fn verified_external_test() {
  let #(f, kz) = store()
  let db = kazoo.account_db(account)

  // Nothing stored.
  assert numbers.verified_external(kz, account, "14045550301") == False

  // A verified document, stored as the API stores it, is found under the
  // PASSporT's digits-only spelling.
  fake.put_doc(f, db, external_number("+14045550302", True))
  assert numbers.verified_external(kz, account, "14045550302") == True

  // An unverified one is not.
  fake.put_doc(f, db, external_number("+14045550303", False))
  assert numbers.verified_external(kz, account, "14045550303") == False

  // A document written without the `+` is found too.
  fake.put_doc(f, db, external_number("14045550304", True))
  assert numbers.verified_external(kz, account, "14045550304") == True

  // Another account's document says nothing about this account.
  fake.put_doc(
    f,
    kazoo.account_db(stranger),
    external_number("+14045550305", True),
  )
  assert numbers.verified_external(kz, account, "14045550305") == False
  assert numbers.verified_external(kz, stranger, "14045550305") == True

  // Cached for a minute: a document that appears after the first answer
  // is not seen until the cache is forgotten.
  fake.put_doc(f, db, external_number("+14045550301", True))
  assert numbers.verified_external(kz, account, "14045550301") == False
  numbers.forget()
  assert numbers.verified_external(kz, account, "14045550301") == True

  // A datastore that cannot be read is `False` for that call and is not
  // remembered: the next call, with the store back, sees the document.
  let broken =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(..kz.datamgr, get_results: fn(_db, _view, _opts) {
        Error(kazoo.Unavailable)
      }),
    )
  numbers.forget()
  assert numbers.verified_external(broken, account, "14045550302") == False
  assert numbers.verified_external(kz, account, "14045550302") == True
}

pub fn ancestors_test() {
  let #(_f, kz) = store()
  assert numbers.ancestors(kz, account) == Some([root, parent, account])
  assert numbers.ancestors(kz, parent) == Some([root, parent])
  assert numbers.ancestors(kz, root) == Some([root])
  assert numbers.ancestors(kz, "00000000000000000000000000000099") == None
}

/// The master account is every account's ancestor, so a `tree` scope
/// that counted it would make every number on the platform owned by
/// every account. It is left out of the chain the ancestor check walks.
/// (`ancestors` asks the FFI which account that is; outside a release it
/// cannot say, and the chain is then walked as it stands.)
pub fn the_master_account_is_not_an_ancestor_test() {
  assert numbers.excluding([root, parent, account], Ok(root))
    == [parent, account]
  assert numbers.excluding([root, parent, account], Ok(parent))
    == [root, account]
  assert numbers.excluding([root, parent, account], Error(Nil))
    == [root, parent, account]
  // A master account that is not in the chain changes nothing.
  assert numbers.excluding([root, account], Ok(stranger)) == [root, account]
  assert numbers.excluding([], Ok(root)) == []
}

/// The table is bounded: past `max_entries` the oldest answers go, and
/// the row count says so rather than a bookkeeping list. A sweep of a
/// table inside its bound with nothing stale in it drops nothing, which
/// is what the monitor calls every pass.
pub fn the_cache_is_bounded_test() {
  numbers.forget()
  let #(_f, kz) = store()
  let nobody = manager(Error("unassigned"))
  down_from(numbers.max_entries + 8)
  |> list.each(fn(n) {
    assert numbers.owner_with(kz, "1404555" <> int.to_string(n), nobody)
      == numbers.Nobody
  })
  assert numbers.size() <= numbers.max_entries
  assert numbers.sweep() == 0
  numbers.forget()
  assert numbers.size() == 0
}

/// `n` down to 1; `gleam/list` has no `range`.
fn down_from(n: Int) -> List(Int) {
  case n {
    0 -> []
    _ -> [n, ..down_from(n - 1)]
  }
}
