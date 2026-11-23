//// Document values: the total decoder, the accessors, and the two merges.

import gleam/dict
import gleam/dynamic
import gleam/erlang/atom
import gleam/option.{None, Some}
import kazoo/doc

const document = "{\"a\":{\"b\":[1,2],\"c\":\"x\"},\"d\":true,\"e\":null}"

pub fn parse_test() {
  let assert Ok(value) = doc.parse(document)
  assert doc.get_int(value, ["a", "b"]) == Error(Nil)
  assert doc.get_list(value, ["a", "b"]) == Ok([doc.Int(1), doc.Int(2)])
  assert doc.get_string(value, ["a", "c"]) == Ok("x")
  assert doc.get_bool(value, ["d"]) == Ok(True)
  // A stored null is a value, not a miss.
  assert doc.get(value, ["e"]) == Ok(doc.Null)
  assert doc.get(value, ["nope"]) == Error(Nil)
  // A path that runs through a scalar is a miss, not a crash.
  assert doc.get(value, ["a", "c", "deeper"]) == Error(Nil)

  assert doc.parse("not json") == Error(Nil)
}

/// Keys are sorted on the way out, so a stored document and a response are
/// byte-stable.
pub fn to_string_is_sorted_test() {
  let value =
    doc.object([
      #("z", doc.Int(1)),
      #("a", doc.Float(1.5)),
      #("m", doc.List([doc.Null, doc.Bool(False)])),
    ])
  assert doc.to_string(value) == "{\"a\":1.5,\"m\":[null,false],\"z\":1}"
}

/// The decoder is total: a document with a shape nothing here knows decodes
/// as far as it can and never fails.
pub fn from_dynamic_test() {
  assert doc.from_dynamic(dynamic.string("x")) == doc.String("x")
  assert doc.from_dynamic(dynamic.int(3)) == doc.Int(3)
  assert doc.from_dynamic(dynamic.float(3.5)) == doc.Float(3.5)
  assert doc.from_dynamic(dynamic.bool(True)) == doc.Bool(True)
  assert doc.from_dynamic(dynamic.nil()) == doc.Null
  assert doc.from_dynamic(dynamic.list([dynamic.int(1)]))
    == doc.List([doc.Int(1)])
  assert doc.from_dynamic(
      dynamic.properties([#(dynamic.string("k"), dynamic.int(1))]),
    )
    == doc.object([#("k", doc.Int(1))])

  // A term that is no JSON value at all -- a reference, a pid, a function --
  // is null rather than an error, so a document written by something else
  // cannot crash a read.
  assert doc.from_dynamic(a_reference()) == doc.Null
}

@external(erlang, "erlang", "make_ref")
fn a_reference() -> dynamic.Dynamic

/// An atom is a string, as a key and as a value.
///
/// `kz_json` holds atoms: every `kapps_call:kvs_store/3` with an atom key
/// puts one in the `Key-Value-Store`, and `cf_route_win` and `cf_exe` put
/// `owner_id`, `context-source` and `cf_last_action` there on every call a
/// callflow runs. `kz_json`'s own encoder writes an atom out as its name, so
/// this reads one as its name too.
pub fn from_dynamic_reads_atoms_test() {
  assert doc.from_dynamic(an_atom("cf_callcenter"))
    == doc.String("cf_callcenter")

  assert doc.from_dynamic(
      dynamic.properties([#(an_atom("owner_id"), dynamic.string("u1"))]),
    )
    == doc.object([#("owner_id", doc.String("u1"))])

  // true, false and undefined keep the meaning they have everywhere else.
  assert doc.from_dynamic(an_atom("true")) == doc.Bool(True)
  assert doc.from_dynamic(an_atom("false")) == doc.Bool(False)
  assert doc.from_dynamic(an_atom("undefined")) == doc.Null
}

/// The whole document survives an atom inside it.
///
/// This is the call a callflow action publishes in a `member_call`: one atom
/// anywhere in it used to make `from_dynamic` answer `Null` for all of it,
/// and the call went out on the bus as `"Call": null`.
pub fn from_dynamic_keeps_a_call_with_a_key_value_store_test() {
  let call =
    dynamic.properties([
      #(dynamic.string("Call-ID"), dynamic.string("call-one")),
      #(
        dynamic.string("Key-Value-Store"),
        dynamic.properties([
          #(an_atom("owner_id"), dynamic.string("u1")),
          #(an_atom("context-source"), an_atom("cf_callcenter")),
        ]),
      ),
    ])

  assert doc.from_dynamic(call)
    == doc.object([
      #("Call-ID", doc.String("call-one")),
      #(
        "Key-Value-Store",
        doc.object([
          #("owner_id", doc.String("u1")),
          #("context-source", doc.String("cf_callcenter")),
        ]),
      ),
    ])
}

fn an_atom(name: String) -> dynamic.Dynamic {
  atom.to_dynamic(atom.create(name))
}

pub fn object_some_test() {
  assert doc.object_some([
      #("kept", Some(doc.Int(1))),
      #("dropped", None),
    ])
    == doc.object([#("kept", doc.Int(1))])
}

pub fn is_object_and_members_test() {
  let value = doc.object([#("b", doc.Int(2)), #("a", doc.Int(1))])
  assert doc.is_object(value)
  assert !doc.is_object(doc.Int(1))
  assert doc.members(value) == [#("a", doc.Int(1)), #("b", doc.Int(2))]
  // Anything that is not an object has no members.
  assert doc.members(doc.Int(1)) == []
}

pub fn strings_test() {
  let value =
    doc.object([
      #(
        "codecs",
        doc.List([doc.String("PCMU"), doc.Int(1), doc.String("G722")]),
      ),
    ])
  // Anything in the list that is not a string is skipped, not fatal.
  assert doc.strings(value, ["codecs"]) == ["PCMU", "G722"]
  assert doc.strings(value, ["nope"]) == []
}

pub fn set_and_delete_test() {
  let value = doc.object([#("a", doc.Int(1))])
  // Objects on the way are created.
  let set = doc.set(value, ["b", "c"], doc.String("x"))
  assert doc.get_string(set, ["b", "c"]) == Ok("x")
  // A non-object on the path is replaced.
  let over = doc.set(set, ["a", "deeper"], doc.Int(2))
  assert doc.get_int(over, ["a", "deeper"]) == Ok(2)

  assert doc.delete(set, ["b", "c"]) |> doc.get(["b", "c"]) == Error(Nil)
  // Deleting what is not there leaves the document alone.
  assert doc.delete(value, ["nope", "deeper"]) == value
  assert doc.delete(value, []) == value
}

/// A merge is what one settings layer sitting on the one below it does:
/// objects merge, everything else replaces.
pub fn merge_test() {
  let base =
    doc.object([
      #("keep", doc.Int(1)),
      #("nested", doc.object([#("a", doc.Int(1)), #("b", doc.Int(2))])),
      #("list", doc.List([doc.Int(1)])),
    ])
  let over =
    doc.object([
      #("nested", doc.object([#("b", doc.Int(3))])),
      #("list", doc.List([doc.Int(9)])),
      #("new", doc.Bool(True)),
    ])
  assert doc.merge(base, over)
    == doc.object([
      #("keep", doc.Int(1)),
      #("nested", doc.object([#("a", doc.Int(1)), #("b", doc.Int(3))])),
      #("list", doc.List([doc.Int(9)])),
      #("new", doc.Bool(True)),
    ])
  // An explicit null is a value in a merge.
  assert doc.merge(base, doc.object([#("keep", doc.Null)]))
    |> doc.get(["keep"])
    == Ok(doc.Null)
}

/// A patch is a merge in which an explicit null removes the key, which is
/// what Crossbar's PATCH does.
pub fn patch_test() {
  let base =
    doc.object([
      #("keep", doc.Int(1)),
      #("nested", doc.object([#("a", doc.Int(1)), #("b", doc.Int(2))])),
    ])
  assert doc.patch(
      base,
      doc.object([
        #("keep", doc.Null),
        #("nested", doc.object([#("a", doc.Null), #("c", doc.Int(3))])),
      ]),
    )
    == doc.object([
      #("nested", doc.object([#("b", doc.Int(2)), #("c", doc.Int(3))])),
    ])
}

/// Every leaf as a dotted path, sorted. A leaf is anything that is not an
/// object: a scalar, a list, or an empty object.
pub fn flatten_test() {
  let value =
    doc.object([
      #("b", doc.Int(2)),
      #("a", doc.object([#("x", doc.String("1")), #("y", doc.List([]))])),
      #("empty", doc.Object(dict.new())),
    ])
  assert doc.flatten(value)
    == [
      #("a.x", doc.String("1")),
      #("a.y", doc.List([])),
      #("b", doc.Int(2)),
      #("empty", doc.Object(dict.new())),
    ]
  assert doc.path("a.x") == ["a", "x"]
  // A scalar at the top has no path, so it has no leaves.
  assert doc.flatten(doc.Int(1)) == []
}

/// The scalar form a template or a vendor file wants. Objects and lists have
/// none and render empty.
pub fn to_text_test() {
  assert doc.to_text(doc.String("x")) == "x"
  assert doc.to_text(doc.Int(3)) == "3"
  assert doc.to_text(doc.Float(3.5)) == "3.5"
  assert doc.to_text(doc.Bool(True)) == "true"
  assert doc.to_text(doc.Bool(False)) == "false"
  assert doc.to_text(doc.Null) == ""
  assert doc.to_text(doc.List([doc.Int(1)])) == ""
  assert doc.to_text(doc.object([])) == ""
}
