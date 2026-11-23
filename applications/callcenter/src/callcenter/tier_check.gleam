//// The rules a queue's tiers are held to, whichever route writes them.
////
//// A queue's tiers are its `agents` list, one entry per agent. Two modules
//// write that list: `cb_queues`, when the queue is created, replaced or
//// patched, and `cb_agents`, one tier at a time at `/queues/{id}/agents`.
//// Both run `check` over the list the write would leave, against the list
//// stored before it, so the rules are the same on every route:
////
//// - an entry names its user in `id`, and no user has two entries;
//// - `level` and `position` are whole numbers from 1, and 1 when left out;
//// - a user the write adds to the queue is a user of the account, and an
////   enabled one. A user already in the queue is not looked up again, so a
////   queue one of whose agents was disabled since can still be renamed.
////
//// The rules hold the entries the write adds or changes, and not the ones it
//// leaves as they were stored. A queue saved before these rules existed
//// may hold a tier they refuse -- a level of 0, or one user twice -- and a
//// write that does not touch it, a rename or another agent's tier, is not
//// refused over it. An entry is left as it was when the stored list has
//// one with the same `id`, `level` and `position`, each stored entry
//// standing for one written one. A user named twice is refused, on the
//// second entry, when the write adds or changes either of their entries:
//// a write that touches that agent has to leave them one. On create
//// nothing is stored, and every entry is held to every rule.
////
//// A user looked up is refused, as a validation error, only when the
//// database says there is no such user. A database that does not answer
//// is not a user missing: the whole write fails with
//// `datastore_unreachable`, Crossbar's 503, and can be tried again.
////
//// The queue schema says the numbers too, but Crossbar only enforces its
//// types when it validates strictly: by default it turns `"2"` into `2`. The
//// checks here run on the body as it was sent. The schema runs after them,
//// and is not shown an entry left as stored with a number it would refuse:
//// see `for_schema`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/set.{type Set}
import kazoo/crossbar.{type Context}
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}

import callcenter/agents

/// One thing wrong with one entry: which entry, the path to the field inside
/// it, the rule it broke, and what to tell the client.
pub type Problem {
  Problem(index: Int, path: List(String), code: String, message: String)
}

/// The code of the problem a database that did not answer is, which
/// `refuse` answers as Crossbar's `datastore_unreachable` rather than as a
/// validation error.
pub const unreachable = "datastore_unreachable"

/// Everything wrong with what `entries`, the `agents` list a write would
/// leave, adds or changes, in the order of the entries. `stored` is the list
/// as it was before the write, empty on create: its entries are neither
/// held to the rules again nor their users looked up again.
pub fn check(
  kz: Kazoo,
  account_id: String,
  entries: List(Value),
  stored: List(Value),
) -> List(Problem) {
  let known = users(stored)
  let touched = list.map(left_as_stored(entries, stored), fn(kept) { !kept })
  let entries = list.zip(entries, touched)
  // The users the write adds or changes an entry of: a second entry of one
  // of them is refused even when that entry itself is as it was.
  let touched_users =
    entries
    |> list.filter_map(fn(pair) {
      case pair.1 {
        True -> doc.get_string(pair.0, ["id"])
        False -> Error(Nil)
      }
    })
    |> set.from_list
  let #(_seen, found) =
    list.index_fold(entries, #(set.new(), []), fn(acc, pair, index) {
      let #(seen, found) = acc
      let #(entry, touched) = pair
      let #(seen, problems) = case touched {
        True -> check_entry(kz, account_id, entry, known, seen)
        False -> as_stored(entry, touched_users, seen)
      }
      let problems =
        list.map(problems, fn(problem) {
          let #(path, code, message) = problem
          Problem(index, path, code, message)
        })
      #(seen, list.append(found, problems))
    })
  found
}

/// For each entry of the list a write would leave, whether it is left as it
/// was stored: the stored list has one with the same `id`, `level` and
/// `position`, each stored entry standing for one written one.
pub fn left_as_stored(entries: List(Value), stored: List(Value)) -> List(Bool) {
  let #(_left, kept) =
    list.map_fold(entries, counted(stored), fn(left, entry) {
      let key = key(entry)
      case dict.get(left, key) {
        Ok(n) if n > 0 -> #(dict.insert(left, key, n - 1), True)
        _ -> #(left, False)
      }
    })
  kept
}

// --- The schema ----------------------------------------------------------------
//
// After these rules both routes validate the whole queue against the queue
// schema, whose `level` and `position` start at 1 as the rules here do. An
// entry the write leaves as stored is not held to these rules, and it must
// not be held to the schema's copy of them either, or a rename of a queue
// storing a `level` of 0 is refused all the same. So the schema is shown
// such an entry with a number it would refuse read as 1, and the entry is
// put back as it was stored once the schema has passed: what the write
// adds or changes gets the schema's defaults and coercion, and what it
// leaves is written back untouched. The list keeps its length and order, so
// the schema's errors still name the entry the client sent.

/// The `agents` list the schema is to validate: `entries` with each one left
/// as stored given a `level` and `position` the schema accepts.
pub fn for_schema(entries: List(Value), stored: List(Value)) -> List(Value) {
  list.zip(entries, left_as_stored(entries, stored))
  |> list.map(fn(pair) {
    case pair {
      #(doc.Object(_) as entry, True) ->
        entry |> acceptable("level") |> acceptable("position")
      #(entry, _) -> entry
    }
  })
}

/// The `agents` list to write, once the schema has passed `validated`, which
/// `for_schema` made from `entries`: the entries left as stored put back as
/// they were, and the schema's own for the rest.
pub fn restore(
  validated: List(Value),
  entries: List(Value),
  stored: List(Value),
) -> List(Value) {
  case list.length(validated) == list.length(entries) {
    // Not the list `for_schema` gave it: nothing to line up.
    False -> validated
    True ->
      list.zip(validated, list.zip(entries, left_as_stored(entries, stored)))
      |> list.map(fn(triple) {
        case triple {
          #(_validated, #(entry, True)) -> entry
          #(validated, #(_entry, False)) -> validated
        }
      })
  }
}

/// A `level` or `position` the schema accepts: the one there when it is a
/// whole number from 1, or left out; 1 otherwise.
fn acceptable(entry: Value, field: String) -> Value {
  case doc.get(entry, [field]) {
    Error(Nil) -> entry
    Ok(doc.Int(n)) if n >= 1 -> entry
    Ok(_refused) -> doc.set(entry, [field], doc.Int(1))
  }
}

/// What an entry is compared to the stored list by: for a tier, its user
/// and numbers as they were sent; anything else, as it is.
fn key(entry: Value) -> Result(List(Result(Value, Nil)), Value) {
  case entry {
    doc.Object(_) ->
      Ok(
        list.map(["id", "level", "position"], fn(field) {
          doc.get(entry, [field])
        }),
      )
    other -> Error(other)
  }
}

/// How many stored entries there are of each key.
fn counted(
  stored: List(Value),
) -> Dict(Result(List(Result(Value, Nil)), Value), Int) {
  list.fold(stored, dict.new(), fn(counts, entry) {
    dict.upsert(counts, key(entry), fn(n) { option.unwrap(n, 0) + 1 })
  })
}

/// An entry left as it was stored has no problem of its own. Its user named
/// twice is one only when the write touches that user.
fn as_stored(
  entry: Value,
  touched_users: Set(String),
  seen: Set(String),
) -> #(Set(String), List(#(List(String), String, String))) {
  case doc.get_string(entry, ["id"]) {
    Ok(user_id) ->
      case set.contains(seen, user_id) {
        True ->
          case set.contains(touched_users, user_id) {
            True -> #(seen, [twice])
            False -> #(seen, [])
          }
        False -> #(set.insert(seen, user_id), [])
      }
    Error(Nil) -> #(seen, [])
  }
}

const twice = #(["id"], "unique", "this user already has a tier in this queue")

fn check_entry(
  kz: Kazoo,
  account_id: String,
  entry: Value,
  known: Set(String),
  seen: Set(String),
) -> #(Set(String), List(#(List(String), String, String))) {
  case entry {
    doc.Object(_) -> {
      let numbers = list.flat_map(["level", "position"], number(entry, _))
      case doc.get(entry, ["id"]) {
        Ok(doc.String(user_id)) if user_id != "" ->
          case set.contains(seen, user_id) {
            True -> #(seen, [twice, ..numbers])
            False -> {
              let seen = set.insert(seen, user_id)
              case set.contains(known, user_id) {
                True -> #(seen, numbers)
                False ->
                  case user(kz, account_id, user_id) {
                    Ok(Nil) -> #(seen, numbers)
                    Error(#(code, message)) -> #(seen, [
                      #(["id"], code, message),
                      ..numbers
                    ])
                  }
              }
            }
          }
        Ok(doc.String(_)) | Ok(doc.Null) | Error(Nil) -> #(seen, [
          #(["id"], "required", "the user who is an agent in this queue"),
          ..numbers
        ])
        Ok(_) -> #(seen, [#(["id"], "type", "a user id"), ..numbers])
      }
    }
    _ -> #(seen, [#([], "type", "a tier is an object")])
  }
}

/// What is wrong with a `level` or a `position`: nothing when it is left
/// out, which is 1.
pub fn number(
  entry: Value,
  field: String,
) -> List(#(List(String), String, String)) {
  case doc.get(entry, [field]) {
    Error(Nil) -> []
    Ok(doc.Int(n)) if n >= 1 -> []
    Ok(doc.Int(_)) -> [#([field], "minimum", field <> " starts at 1")]
    Ok(_) -> [#([field], "type", field <> " is a whole number from 1")]
  }
}

/// Whether the user may be given a tier: a user of the account, not
/// deleted, and enabled.
fn user(
  kz: Kazoo,
  account_id: String,
  user_id: String,
) -> Result(Nil, #(String, String)) {
  case agents.fetch(kz, account_id, user_id) {
    Error(kazoo.NotFound) ->
      Error(#("not_found", "no such user in this account"))
    Error(_unreachable) ->
      Error(#(unreachable, "the user could not be looked up"))
    Ok(user) ->
      case doc.get_bool(user, ["pvt_deleted"]), agents.is_enabled(user) {
        Ok(True), _ -> Error(#("not_found", "no such user in this account"))
        _, False -> Error(#("enabled", "this user is disabled"))
        _, True -> Ok(Nil)
      }
  }
}

/// The users an `agents` list names, which are the ones a later write does
/// not look up again.
fn users(entries: List(Value)) -> Set(String) {
  entries
  |> list.filter_map(doc.get_string(_, ["id"]))
  |> set.from_list
}

/// The entries of a document's `agents` list, or none when it has no list.
/// Anything else there is the schema's to refuse.
pub fn entries(queue: Value) -> List(Value) {
  doc.get_list(queue, ["agents"]) |> result.unwrap([])
}

/// The field a problem is reported on. A tier route names the tier it
/// writes by its path, so that tier's problems are reported on the body's
/// own fields -- `["level"]` -- and any other entry's under the queue's
/// list -- `["agents", "2", "level"]`, which is all a queue write reports.
pub fn property(problem: Problem, written: Option(Int)) -> List(String) {
  case written {
    Some(index) if index == problem.index -> problem.path
    _ -> ["agents", int.to_string(problem.index), ..problem.path]
  }
}

/// The context with every problem added as a validation error, which is a
/// 400 and nothing saved -- unless a user could not be looked up, which is
/// Crossbar's `datastore_unreachable`, a 503, whatever else was wrong.
pub fn refuse(
  context: Context,
  problems: List(Problem),
  written: Option(Int),
) -> Context {
  case list.any(problems, fn(problem) { problem.code == unreachable }) {
    True -> crossbar.add_system_error(context, unreachable)
    False ->
      list.fold(problems, context, fn(context, problem) {
        crossbar.add_validation_error(
          context,
          property(problem, written),
          problem.code,
          problem.message,
        )
      })
  }
}
