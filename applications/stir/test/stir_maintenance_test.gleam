//// The `sup` surface itself.
////
//// `sup` calls a module by name with binary arguments and no types at
//// all, so every exported function of `stir_maintenance` is something an
//// operator can call with four binaries. What the commands print lives in
//// `stir/report` (and is tested there) precisely so that `sup` cannot
//// reach it: this test is the guard on that, and on the arity of the two
//// commands that now need a word of confirmation.
////
//// Everything else the commands do needs a node: a datastore, an
//// environment with a key-encryption key, and the network.

import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/string

/// Every command the README lists, with the arity `sup` calls it at.
const commands = [
  #("status", 0),
  #("keys", 0),
  #("new_key", 2),
  #("csr", 1),
  #("certificate", 2),
  #("import_key", 4),
  #("activate", 1),
  #("retire", 2),
  #("delete", 2),
  #("rekey", 0),
  #("trust_refresh", 0),
  #("trust_upload", 2),
  #("monitor_now", 0),
  #("check_x5u", 1),
  #("sign", 4),
  #("verify", 1),
]

/// The module exports the commands and nothing else. A helper exported
/// here is a helper `sup` can call with a binary where it wants a `Key`,
/// a `List(Key)` or an `Int`, which is a crash in a shell an operator
/// reached for because something was already wrong.
pub fn only_commands_are_exported_test() {
  let exported =
    exports(atom.create("stir_maintenance"))
    |> list.map(fn(pair) { #(atom.to_string(pair.0), pair.1) })
    // Erlang gives every module these two.
    |> list.filter(fn(pair) { pair.0 != "module_info" })
    |> sorted
  assert exported == sorted(commands)
}

/// The two commands that can leave a scope unable to sign take a second
/// word, so that neither is one keystroke away from an outage.
pub fn retire_and_delete_need_confirming_test() {
  let arity = fn(name) {
    exports(atom.create("stir_maintenance"))
    |> list.filter_map(fn(pair) {
      case atom.to_string(pair.0) == name {
        True -> Ok(pair.1)
        False -> Error(Nil)
      }
    })
  }
  assert arity("retire") == [2]
  assert arity("delete") == [2]
  // Activating cannot take signing away, and stays one word.
  assert arity("activate") == [1]
}

fn sorted(pairs: List(#(String, Int))) -> List(#(String, Int)) {
  list.sort(pairs, fn(a, b) {
    string.compare(
      a.0 <> "/" <> int.to_string(a.1),
      b.0 <> "/" <> int.to_string(b.1),
    )
  })
}

/// The name and arity of every function a module exports. Through
/// `apply`, so that the module is loaded if this is the first call into
/// it in the test VM.
fn exports(module: Atom) -> List(#(Atom, Int)) {
  apply(module, atom.create("module_info"), [atom.create("exports")])
}

@external(erlang, "erlang", "apply")
fn apply(
  module: Atom,
  function: Atom,
  arguments: List(Atom),
) -> List(#(Atom, Int))
