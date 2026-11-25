//// Which names a node asks the broker about.

import callcenter/members

/// `kz_nodes`'s names, then every member at the last look it has forgotten,
/// each once.
pub fn the_last_members_are_asked_about_again_test() {
  assert members.worth_asking(["a", "b"], []) == ["a", "b"]
  assert members.worth_asking(["a"], ["a", "b"]) == ["a", "b"]
  assert members.worth_asking(["a", "c"], ["b", "a"]) == ["a", "c", "b"]
}
