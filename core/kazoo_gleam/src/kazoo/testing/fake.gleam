//// A `Kazoo` record over an in-memory store.
////
//// A test runs against this instead of a node: documents live in a
//// dictionary, views are the same map functions the design documents carry,
//// `now` stands still until a test moves it, and generated passwords are a
//// counter rather than random bytes. What it deliberately does model is
//// document revisions -- a save with a stale `_rev` is a conflict, a
//// delete leaves a tombstone, and a superseded revision can be read back
//// until `compact` discards its body -- and CouchDB's key ordering, because
//// a test that reads a range of a view has to see the order the cluster
//// would give it.
////
//// This lives in `src` rather than in `test` because Gleam has no test-only
//// exports and every application's suite wants it. It is test support: no
//// production code should import it.
////
//// The views of Kazoo's own databases are built in. An application adds the
//// views of its own design documents with `new_with_views`.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/otp/actor
import gleam/result
import gleam/string
import kazoo/accounts
import kazoo/devices
import kazoo/doc.{type Value}
import kazoo/kazoo.{
  type Alert, type Error, type Kazoo, type ViewOptions, Alerts, Auth, Cluster,
  Config, Datamgr, Kazoo, Switch,
}

pub opaque type Fake {
  Fake(subject: Subject(Message))
}

/// One view of one design document: the documents it emits for, and the key
/// it emits them under. A document whose `pvt_type` is not `doc_type`, or
/// whose `key` returns `Error`, is not in the view. `pvt_deleted` documents
/// are in no view at all. A `Fanout` view emits one row per key, which is
/// what `accounts/listing_by_descendants` does for every ancestor.
pub type View {
  View(name: String, doc_type: String, key: fn(Value) -> Result(Value, Nil))
  Fanout(name: String, doc_type: String, keys: fn(Value) -> List(Value))
  /// A view whose rows carry a value beside the key, as a map function
  /// that emits one does; `value` is what it emits for a document.
  Valued(
    name: String,
    doc_type: String,
    key: fn(Value) -> Result(Value, Nil),
    value: fn(Value) -> Value,
  )
}

pub type Notify {
  Notify(event: String, realm: String, username: String)
}

type State {
  State(
    views: List(View),
    docs: Dict(String, Dict(String, Value)),
    /// Every revision each document has had, newest first, keyed by
    /// database and id: the revision and its body, `None` once compacted
    /// away. A delete's tombstone is the newest entry of a deleted document.
    history: Dict(#(String, String), List(#(String, Option(Value)))),
    databases: List(String),
    config: Dict(String, Value),
    tokens: Dict(String, Value),
    minted: List(#(String, Value)),
    account_ids: List(String),
    alerts: List(Alert),
    notifies: List(Notify),
    now: Int,
    seq: Int,
  )
}

type Message {
  Open(String, String, Subject(Result(Value, Error)))
  OpenRevision(String, String, String, Subject(Result(Value, Error)))
  Compact(String, Subject(Nil))
  Save(String, Value, Subject(Result(Value, Error)))
  Delete(String, String, Subject(Result(Value, Error)))
  Rows(String, String, ViewOptions, Subject(Result(List(Value), Error)))
  DbExists(String, Subject(Bool))
  DbCreate(String, Subject(Bool))
  ConfigGet(String, Subject(Result(Value, Error)))
  ConfigSet(String, Value, Subject(Result(Nil, Error)))
  ValidateToken(String, Subject(Result(Value, Error)))
  CreateToken(Value, Subject(Result(String, Error)))
  Alerted(Alert, Subject(Result(Nil, Error)))
  CheckSync(Notify, Subject(Result(Nil, Error)))
  AccountIds(Subject(Result(List(String), Error)))
  Now(Subject(Int))
  Random(Int, Subject(String))
  PutDoc(String, Value, Subject(Nil))
  PutToken(String, Value, Subject(Nil))
  PutConfig(String, Value, Subject(Nil))
  SetAccountIds(List(String), Subject(Nil))
  SetNow(Int, Subject(Nil))
  AlertLog(Subject(List(Alert)))
  Minted(Subject(List(#(String, Value))))
  Notifies(Subject(List(Notify)))
  AllDocs(String, Subject(List(Value)))
}

const timeout = 5000

/// A fake with the views of Kazoo's own databases and nothing else.
pub fn new() -> Fake {
  new_with_views([])
}

/// A fake that also knows the application's own views.
pub fn new_with_views(views: List(View)) -> Fake {
  let assert Ok(started) =
    actor.new(State(
      views: list.append(kazoo_views(), views),
      docs: dict.new(),
      history: dict.new(),
      databases: [],
      config: dict.new(),
      tokens: dict.new(),
      minted: [],
      account_ids: [],
      alerts: [],
      notifies: [],
      now: 1_757_400_000,
      seq: 0,
    ))
    |> actor.on_message(handle)
    |> actor.start
  Fake(subject: started.data)
}

pub fn kazoo(fake: Fake) -> Kazoo {
  let subject = fake.subject
  Kazoo(
    datamgr: Datamgr(
      open_cache_doc: fn(db, id) {
        actor.call(subject, timeout, Open(db, id, _))
      },
      open_doc: fn(db, id) { actor.call(subject, timeout, Open(db, id, _)) },
      open_revision: fn(db, id, rev) {
        actor.call(subject, timeout, OpenRevision(db, id, rev, _))
      },
      // The fake has no cache: every read is the document as it is now.
      flush_cache_doc: fn(_db, _id) { Nil },
      save_doc: fn(db, document) {
        actor.call(subject, timeout, Save(db, document, _))
      },
      del_doc: fn(db, id) { actor.call(subject, timeout, Delete(db, id, _)) },
      get_results: fn(db, view, options) {
        actor.call(subject, timeout, Rows(db, view, options, _))
      },
      db_exists: fn(db) { actor.call(subject, timeout, DbExists(db, _)) },
      db_create: fn(db) { actor.call(subject, timeout, DbCreate(db, _)) },
    ),
    config: Config(
      get_int: fn(key, default) {
        case actor.call(subject, timeout, ConfigGet(key, _)) {
          Ok(doc.Int(value)) -> value
          _ -> default
        }
      },
      get_string: fn(key, default) {
        case actor.call(subject, timeout, ConfigGet(key, _)) {
          Ok(doc.String(value)) -> value
          _ -> default
        }
      },
      get_string_in: fn(category, key, default) {
        case
          actor.call(subject, timeout, ConfigGet(category <> "." <> key, _))
        {
          Ok(doc.String(value)) -> value
          _ -> default
        }
      },
      get_json: fn(key) { actor.call(subject, timeout, ConfigGet(key, _)) },
      set_default: fn(key, value) {
        actor.call(subject, timeout, ConfigSet(key, value, _))
      },
    ),
    auth: Auth(
      validate_token: fn(token) {
        actor.call(subject, timeout, ValidateToken(token, _))
      },
      create_token: fn(claims) {
        actor.call(subject, timeout, CreateToken(doc.object(claims), _))
      },
    ),
    alerts: Alerts(create: fn(alert) {
      actor.call(subject, timeout, Alerted(alert, _))
    }),
    switch: Switch(check_sync: fn(event, realm, username) {
      actor.call(subject, timeout, CheckSync(
        Notify(event: event, realm: realm, username: username),
        _,
      ))
    }),
    cluster: Cluster(account_ids: fn() {
      actor.call(subject, timeout, AccountIds)
    }),
    now: fn() { actor.call(subject, timeout, Now) },
    random: fn(length) { actor.call(subject, timeout, Random(length, _)) },
  )
}

//
// Arranging a test.
//

/// Put a document in a database, as if it had always been there.
pub fn put_doc(fake: Fake, db: String, document: Value) -> Nil {
  actor.call(fake.subject, timeout, PutDoc(db, document, _))
}

/// An account document, in the account's own database and in the aggregate
/// `accounts` database, which is where the realm listing is read from.
pub fn put_account(
  fake: Fake,
  account_id: String,
  realm: String,
  tree: List(String),
) -> Nil {
  let document =
    doc.object([
      #("_id", doc.String(account_id)),
      #("pvt_type", doc.String("account")),
      #("name", doc.String("Account " <> account_id)),
      #("realm", doc.String(realm)),
      #("pvt_tree", doc.List(list.map(tree, doc.String))),
      #("pvt_enabled", doc.Bool(True)),
    ])
  put_doc(fake, kazoo.account_db(account_id), document)
  put_doc(fake, accounts.aggregate_db, document)
  set_account_ids(fake, [account_id])
}

pub fn make_superduper(fake: Fake, account_id: String) -> Nil {
  let assert Ok(account) =
    lookup(fake, kazoo.account_db(account_id), account_id)
  put_doc(
    fake,
    kazoo.account_db(account_id),
    doc.set(account, ["pvt_superduper_admin"], doc.Bool(True)),
  )
}

/// A device document, in the account's own database.
pub fn put_device(
  fake: Fake,
  account_id: String,
  device_id: String,
  mac: String,
  members: List(#(String, Value)),
) -> Nil {
  put_doc(
    fake,
    kazoo.account_db(account_id),
    doc.object(list.append(
      [
        #("_id", doc.String(device_id)),
        #("pvt_type", doc.String("device")),
        #("mac_address", doc.String(mac)),
      ],
      members,
    )),
  )
}

/// A token the fake will accept, with the claims it stands for.
pub fn put_token(fake: Fake, token: String, claims: Value) -> Nil {
  actor.call(fake.subject, timeout, PutToken(token, claims, _))
}

/// A token for an account, with the claims `kz_auth` returns.
pub fn token_for(fake: Fake, token: String, account_id: String) -> Nil {
  put_token(
    fake,
    token,
    doc.object([
      #("account_id", doc.String(account_id)),
      #("owner_id", doc.String("00000000000000000000000000000001")),
    ]),
  )
}

pub fn put_config(fake: Fake, key: String, value: Value) -> Nil {
  actor.call(fake.subject, timeout, PutConfig(key, value, _))
}

pub fn set_account_ids(fake: Fake, account_ids: List(String)) -> Nil {
  actor.call(fake.subject, timeout, SetAccountIds(account_ids, _))
}

pub fn set_now(fake: Fake, now: Int) -> Nil {
  actor.call(fake.subject, timeout, SetNow(now, _))
}

//
// Looking at what happened.
//

pub fn lookup(fake: Fake, db: String, id: String) -> Result(Value, Error) {
  actor.call(fake.subject, timeout, Open(db, id, _))
}

/// What compacting a database does to it: every superseded revision loses
/// its body, so only the newest revision of each document -- a deleted
/// one's tombstone -- can still be read.
pub fn compact(fake: Fake, db: String) -> Nil {
  actor.call(fake.subject, timeout, Compact(db, _))
}

pub fn all_docs(fake: Fake, db: String) -> List(Value) {
  actor.call(fake.subject, timeout, AllDocs(db, _))
}

pub fn alerts(fake: Fake) -> List(Alert) {
  actor.call(fake.subject, timeout, AlertLog)
}

/// Every token minted through `auth.create_token`, oldest first, with the
/// claims it was minted from. A minted token validates to those claims.
pub fn minted(fake: Fake) -> List(#(String, Value)) {
  actor.call(fake.subject, timeout, Minted)
}

pub fn notifies(fake: Fake) -> List(Notify) {
  actor.call(fake.subject, timeout, Notifies)
}

//
// The store itself.
//

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Open(db, id, reply) -> {
      process.send(reply, open(state, db, id))
      actor.continue(state)
    }
    OpenRevision(db, id, rev, reply) -> {
      process.send(reply, open_revision(state, db, id, rev))
      actor.continue(state)
    }
    Compact(db, reply) -> {
      process.send(reply, Nil)
      actor.continue(compact_db(state, db))
    }
    Save(db, document, reply) -> {
      let #(state, result) = save(state, db, document)
      process.send(reply, result)
      actor.continue(state)
    }
    Delete(db, id, reply) -> {
      let #(state, result) = delete(state, db, id)
      process.send(reply, result)
      actor.continue(state)
    }
    Rows(db, view, options, reply) -> {
      process.send(reply, view_rows(state, db, view, options))
      actor.continue(state)
    }
    DbExists(db, reply) -> {
      process.send(reply, list.contains(state.databases, db))
      actor.continue(state)
    }
    DbCreate(db, reply) -> {
      process.send(reply, True)
      actor.continue(State(..state, databases: [db, ..state.databases]))
    }
    ConfigGet(key, reply) -> {
      process.send(
        reply,
        dict.get(state.config, key) |> result.replace_error(kazoo.NotFound),
      )
      actor.continue(state)
    }
    ConfigSet(key, value, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(..state, config: dict.insert(state.config, key, value)),
      )
    }
    ValidateToken(token, reply) -> {
      process.send(
        reply,
        dict.get(state.tokens, token)
          |> result.replace_error(kazoo.Invalid("invalid_token")),
      )
      actor.continue(state)
    }
    CreateToken(claims, reply) -> {
      let token = "fake-token-" <> int.to_string(state.seq)
      process.send(reply, Ok(token))
      actor.continue(
        State(
          ..state,
          tokens: dict.insert(state.tokens, token, claims),
          minted: [#(token, claims), ..state.minted],
          seq: state.seq + 1,
        ),
      )
    }
    Alerted(alert, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(State(..state, alerts: [alert, ..state.alerts]))
    }
    CheckSync(notify, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(State(..state, notifies: [notify, ..state.notifies]))
    }
    AccountIds(reply) -> {
      process.send(reply, Ok(state.account_ids))
      actor.continue(state)
    }
    Now(reply) -> {
      process.send(reply, state.now)
      actor.continue(state)
    }
    Random(length, reply) -> {
      process.send(reply, pseudo_random(state.seq, length))
      actor.continue(State(..state, seq: state.seq + 1))
    }
    PutDoc(db, document, reply) -> {
      let id = doc.get_string(document, ["_id"]) |> result.unwrap("")
      process.send(reply, Nil)
      actor.continue(put(state, db, id, document))
    }
    PutToken(token, claims, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        State(..state, tokens: dict.insert(state.tokens, token, claims)),
      )
    }
    PutConfig(key, value, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        State(..state, config: dict.insert(state.config, key, value)),
      )
    }
    SetAccountIds(account_ids, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          account_ids: list.unique(list.append(state.account_ids, account_ids)),
        ),
      )
    }
    SetNow(now, reply) -> {
      process.send(reply, Nil)
      actor.continue(State(..state, now: now))
    }
    AlertLog(reply) -> {
      process.send(reply, list.reverse(state.alerts))
      actor.continue(state)
    }
    Minted(reply) -> {
      process.send(reply, list.reverse(state.minted))
      actor.continue(state)
    }
    Notifies(reply) -> {
      process.send(reply, list.reverse(state.notifies))
      actor.continue(state)
    }
    AllDocs(db, reply) -> {
      process.send(reply, documents(state, db))
      actor.continue(state)
    }
  }
}

fn documents(state: State, db: String) -> List(Value) {
  case dict.get(state.docs, db) {
    Ok(documents) -> dict.values(documents)
    Error(_) -> []
  }
}

fn open(state: State, db: String, id: String) -> Result(Value, Error) {
  dict.get(state.docs, db)
  |> result.try(fn(documents) { dict.get(documents, id) })
  |> result.replace_error(kazoo.NotFound)
}

fn put(state: State, db: String, id: String, document: Value) -> State {
  let documents = dict.get(state.docs, db) |> result.unwrap(dict.new())
  State(
    ..remember(state, db, id, document),
    docs: dict.insert(state.docs, db, dict.insert(documents, id, document)),
    databases: list.unique([db, ..state.databases]),
  )
}

/// Record a revision in the document's history. A document put without a
/// `_rev` has no revision to read back by, so it is not recorded.
fn remember(state: State, db: String, id: String, document: Value) -> State {
  case doc.get_string(document, ["_rev"]) {
    Error(Nil) -> state
    Ok(rev) -> {
      let key = #(db, id)
      let earlier = dict.get(state.history, key) |> result.unwrap([])
      State(
        ..state,
        history: dict.insert(state.history, key, [
          #(rev, Some(document)),
          ..earlier
        ]),
      )
    }
  }
}

/// `?rev=<rev>&revs=true`: the revision's body, with `_revisions` holding
/// its generation and the hashes of it and every ancestor, newest first.
fn open_revision(
  state: State,
  db: String,
  id: String,
  rev: String,
) -> Result(Value, Error) {
  let revisions =
    dict.get(state.history, #(db, id))
    |> result.unwrap([])
    |> list.drop_while(fn(entry) { entry.0 != rev })
  case revisions {
    [#(_, Some(body)), ..] ->
      Ok(doc.set(
        body,
        ["_revisions"],
        doc.object([
          #("start", doc.Int(generation(rev))),
          #(
            "ids",
            doc.List(
              list.map(revisions, fn(entry) { doc.String(hash(entry.0)) }),
            ),
          ),
        ]),
      ))
    _ -> Error(kazoo.NotFound)
  }
}

fn compact_db(state: State, db: String) -> State {
  State(
    ..state,
    history: dict.map_values(state.history, fn(key, revisions) {
      case key.0 == db, revisions {
        True, [newest, ..older] -> [
          newest,
          ..list.map(older, fn(entry) { #(entry.0, None) })
        ]
        _, _ -> revisions
      }
    }),
  )
}

fn generation(rev: String) -> Int {
  case string.split_once(rev, "-") {
    Ok(#(number, _)) -> int.parse(number) |> result.unwrap(0)
    Error(Nil) -> 0
  }
}

fn hash(rev: String) -> String {
  case string.split_once(rev, "-") {
    Ok(#(_, hash)) -> hash
    Error(Nil) -> rev
  }
}

fn save(
  state: State,
  db: String,
  document: Value,
) -> #(State, Result(Value, Error)) {
  let id = doc.get_string(document, ["_id"]) |> result.unwrap("")
  // Kazoo drops a top-level `id` from every document it saves
  // (`kzs_doc:prepare_doc_for_save`), so a document that carries one gets it
  // back only in `_id`. Modelling that here is what stops a decoder that
  // requires `id` passing the suite and failing on a cluster.
  let document = doc.delete(document, ["id"])
  case id {
    "" -> #(state, Error(kazoo.Invalid("no_id")))
    _ -> {
      let stored = open(state, db, id)
      let stored_rev = case stored {
        Ok(existing) -> doc.get_string(existing, ["_rev"]) |> option.from_result
        Error(_) -> None
      }
      let sent_rev = doc.get_string(document, ["_rev"]) |> option.from_result
      case stored_rev == sent_rev {
        False -> #(state, Error(kazoo.Conflict))
        True -> {
          let saved =
            doc.set(document, ["_rev"], doc.String(next_rev(stored_rev)))
          #(put(state, db, id, saved), Ok(saved))
        }
      }
    }
  }
}

fn next_rev(current: Option(String)) -> String {
  let number = case current {
    Some(rev) ->
      case string.split(rev, "-") {
        [number, ..] -> int.parse(number) |> result.unwrap(0)
        _ -> 0
      }
    None -> 0
  }
  int.to_string(number + 1) <> "-fake"
}

fn delete(
  state: State,
  db: String,
  id: String,
) -> #(State, Result(Value, Error)) {
  case open(state, db, id) {
    Error(error) -> #(state, Error(error))
    Ok(document) -> {
      let documents = dict.get(state.docs, db) |> result.unwrap(dict.new())
      // CouchDB keeps a bare tombstone as the deleted document's newest
      // revision, and answers the delete with that revision.
      let tombstone =
        doc.object([
          #("_id", doc.String(id)),
          #(
            "_rev",
            doc.String(next_rev(
              doc.get_string(document, ["_rev"]) |> option.from_result,
            )),
          ),
          #("_deleted", doc.Bool(True)),
        ])
      #(
        State(
          ..remember(state, db, id, tombstone),
          docs: dict.insert(state.docs, db, dict.delete(documents, id)),
        ),
        Ok(tombstone),
      )
    }
  }
}

//
// Views. The same map functions the design documents carry.
//

/// The views of the Kazoo databases every application sees.
fn kazoo_views() -> List(View) {
  [
    View(
      name: accounts.listing_by_realm,
      doc_type: "account",
      key: fn(document) {
        doc.get_string(document, ["realm"])
        |> result.map(fn(realm) { doc.String(string.lowercase(realm)) })
      },
    ),
    View(
      name: devices.listing_by_macaddress,
      doc_type: "device",
      key: fn(document) {
        doc.get_string(document, ["mac_address"]) |> result.map(doc.String)
      },
    ),
    View(name: "devices/sip_credentials", doc_type: "device", key: fn(document) {
      doc.get_string(document, ["sip", "username"])
      |> result.map(fn(username) { doc.String(string.lowercase(username)) })
    }),
    View(name: "devices/crossbar_listing", doc_type: "device", key: by_id),
    View(name: "users/crossbar_listing", doc_type: "user", key: by_id),
    View(name: "users/list_by_username", doc_type: "user", key: fn(document) {
      doc.get_string(document, ["username"]) |> result.map(doc.String)
    }),
    // `[ancestor, name]` once per ancestor in `pvt_tree`, as the aggregate
    // `accounts` database's design document emits it.
    Fanout(
      name: accounts.listing_by_descendants,
      doc_type: "account",
      keys: fn(document) {
        let name = doc.get_string(document, ["name"]) |> result.unwrap("")
        doc.strings(document, ["pvt_tree"])
        |> list.map(fn(ancestor) {
          doc.List([doc.String(ancestor), doc.String(name)])
        })
      },
    ),
  ]
}

fn view_rows(
  state: State,
  db: String,
  view: String,
  options: ViewOptions,
) -> Result(List(Value), Error) {
  let emitted =
    documents(state, db)
    |> list.flat_map(fn(document) { emit(state.views, view, document) })
    |> list.sort(fn(a, b) { compare(a.0, b.0) })
    |> list.filter(fn(row) { in_range(row.0, options) })
  let limited = case options.limit {
    Some(limit) -> list.take(emitted, limit)
    None -> emitted
  }
  Ok(
    list.map(limited, fn(row) {
      let #(key, value, document) = row
      let id = doc.get_string(document, ["_id"]) |> result.unwrap("")
      doc.object(
        list.append(
          [
            #("id", doc.String(id)),
            #("key", key),
            #("value", value),
          ],
          case options.include_docs {
            True -> [#("doc", document)]
            False -> []
          },
        ),
      )
    }),
  )
}

fn emit(
  views: List(View),
  view: String,
  document: Value,
) -> List(#(Value, Value, Value)) {
  case doc.get_bool(document, ["pvt_deleted"]) |> result.unwrap(False) {
    True -> []
    False -> {
      let doc_type = doc.get_string(document, ["pvt_type"]) |> result.unwrap("")
      let emitted =
        views
        |> list.filter(fn(v) { v.name == view && v.doc_type == doc_type })
        |> list.first
        |> result.map(fn(definition) {
          case definition {
            View(key: key, ..) ->
              case key(document) {
                Ok(key) -> [#(key, doc.Null)]
                Error(Nil) -> []
              }
            Valued(key: key, value: value, ..) ->
              case key(document) {
                Ok(key) -> [#(key, value(document))]
                Error(Nil) -> []
              }
            Fanout(keys: keys, ..) ->
              list.map(keys(document), fn(key) { #(key, doc.Null) })
          }
        })
        |> result.unwrap([])
      list.map(emitted, fn(pair) { #(pair.0, pair.1, document) })
    }
  }
}

fn by_id(document: Value) -> Result(Value, Nil) {
  doc.get_string(document, ["_id"]) |> result.map(doc.String)
}

fn in_range(key: Value, options: ViewOptions) -> Bool {
  let after_start = case options.start_key {
    Some(start) -> compare(key, start) != Lt
    None ->
      case options.key {
        Some(exact) -> compare(key, exact) == Eq
        None -> True
      }
  }
  let before_end = case options.end_key {
    Some(end) -> compare(key, end) != Gt
    None ->
      case options.key {
        Some(exact) -> compare(key, exact) == Eq
        None -> True
      }
  }
  after_start && before_end
}

/// CouchDB's collation, as far as document keys go: null, then
/// booleans, then numbers, then strings, then arrays, then objects.
fn compare(one: Value, other: Value) -> Order {
  case one, other {
    doc.String(a), doc.String(b) -> string.compare(a, b)
    doc.Int(a), doc.Int(b) -> int.compare(a, b)
    doc.List(a), doc.List(b) -> compare_lists(a, b)
    _, _ -> int.compare(rank(one), rank(other))
  }
}

fn compare_lists(one: List(Value), other: List(Value)) -> Order {
  case one, other {
    [], [] -> Eq
    [], _ -> Lt
    _, [] -> Gt
    [a, ..rest_a], [b, ..rest_b] ->
      case compare(a, b) {
        Eq -> compare_lists(rest_a, rest_b)
        order -> order
      }
  }
}

fn rank(value: Value) -> Int {
  case value {
    doc.Null -> 0
    doc.Bool(_) -> 1
    doc.Int(_) -> 2
    doc.Float(_) -> 2
    doc.String(_) -> 3
    doc.List(_) -> 4
    doc.Object(_) -> 5
  }
}

const alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"

fn pseudo_random(seq: Int, length: Int) -> String {
  case length {
    0 -> ""
    _ ->
      string.slice(
        alphabet,
        { seq * 7 + length * 3 } % string.length(alphabet),
        1,
      )
      <> pseudo_random(seq, length - 1)
  }
}
