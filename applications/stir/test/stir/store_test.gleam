//// The document plumbing: what an `update` carries over from the document
//// it read, what it does when someone else saves that document first, and
//// what a `write` does when the read fails.
////
//// The fake models CouchDB's revisions, so a save with the revision of an
//// earlier read is a conflict here exactly as it is on a cluster.

import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake
import stir/store
import stir/system

fn new() -> #(fake.Fake, kazoo.Kazoo) {
  let f = fake.new()
  #(f, fake.kazoo(f))
}

fn put(f: fake.Fake, members: List(#(String, doc.Value))) -> Nil {
  fake.put_doc(
    f,
    system.category,
    doc.object([
      #("_id", doc.String("d1")),
      #("_rev", doc.String("1-fake")),
      #("pvt_type", doc.String("stir_thing")),
      ..members
    ]),
  )
}

/// The read's revision and private fields survive a change that knows
/// nothing about them.
pub fn update_carries_the_read_test() {
  let #(f, kz) = new()
  put(f, [#("pvt_created", doc.Int(7)), #("name", doc.String("before"))])

  let assert Ok(saved) =
    store.update(kz, "d1", fn(_stored) {
      Ok(
        doc.object([
          #("_id", doc.String("d1")),
          #("name", doc.String("after")),
        ]),
      )
    })
  assert doc.get_string(saved, ["name"]) == Ok("after")
  assert doc.get_int(saved, ["pvt_created"]) == Ok(7)
  assert doc.get_string(saved, ["_rev"]) == Ok("2-fake")
}

/// Someone else saves the document between the read and the save: the
/// save conflicts, the change is applied again to what is stored now, and
/// both changes are there afterwards.
pub fn update_retries_a_conflict_test() {
  let #(f, kz) = new()
  put(f, [#("name", doc.String("before"))])

  let assert Ok(saved) =
    store.update(kz, "d1", fn(stored) {
      // The first time through, and only then, another writer gets there
      // first with a change of its own.
      case doc.get_string(stored, ["theirs"]) {
        Ok(_) -> Nil
        Error(Nil) -> {
          let assert Ok(_) =
            store.write(kz, doc.set(stored, ["theirs"], doc.String("yes")))
          Nil
        }
      }
      Ok(doc.set(stored, ["mine"], doc.String("yes")))
    })

  assert doc.get_string(saved, ["mine"]) == Ok("yes")
  assert doc.get_string(saved, ["theirs"]) == Ok("yes")
  // The read, the other writer's save, and the retry.
  assert doc.get_string(saved, ["_rev"]) == Ok("3-fake")
  let assert Ok(stored) = fake.lookup(f, system.category, "d1")
  assert doc.get_string(stored, ["mine"]) == Ok("yes")
  assert doc.get_string(stored, ["theirs"]) == Ok("yes")
}

/// A writer that always gets there first is a conflict in the end rather
/// than a loop, and nothing of the change is stored.
pub fn update_gives_up_test() {
  let #(f, kz) = new()
  put(f, [#("name", doc.String("before"))])

  let answer =
    store.update(kz, "d1", fn(stored) {
      let assert Ok(_) =
        store.write(kz, doc.set(stored, ["theirs"], doc.String("yes")))
      Ok(doc.set(stored, ["mine"], doc.String("yes")))
    })
  assert answer == Error(store.Datastore(kazoo.Conflict))
  let assert Ok(stored) = fake.lookup(f, system.category, "d1")
  assert doc.get(stored, ["mine"]) == Error(Nil)
}

/// A transform that refuses, and a document that is not there.
pub fn update_refuses_test() {
  let #(f, kz) = new()
  put(f, [#("name", doc.String("before"))])

  assert store.update(kz, "d1", fn(_) { Error("no") })
    == Error(store.Rejected("no"))
  assert store.update(kz, "nope", fn(stored) { Ok(stored) })
    == Error(store.Datastore(kazoo.NotFound))
}

/// A read that fails for anything but `not_found` is that failure: a
/// write over a document the store could not read would take the
/// revision with it.
pub fn write_needs_the_read_test() {
  let #(f, kz) = new()
  put(f, [#("name", doc.String("before"))])
  let unreachable =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(..kz.datamgr, open_doc: fn(_db, _id) {
        Error(kazoo.Unavailable)
      }),
    )

  assert store.write(
      unreachable,
      doc.object([
        #("_id", doc.String("d1")),
        #("name", doc.String("after")),
      ]),
    )
    == Error(kazoo.Unavailable)
  let assert Ok(stored) = fake.lookup(f, system.category, "d1")
  assert doc.get_string(stored, ["name"]) == Ok("before")

  // A document that is not stored yet is created.
  let assert Ok(created) =
    store.write(kz, doc.object([#("_id", doc.String("d2"))]))
  assert doc.get_string(created, ["_rev"]) == Ok("1-fake")
}
