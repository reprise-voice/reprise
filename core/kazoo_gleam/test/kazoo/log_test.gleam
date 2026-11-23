//// Logging on a node with no lager around it: both levels reach `logger`
//// instead, and neither raises.

import kazoo/kazoo

pub fn log_info_without_a_release_test() {
  assert kazoo.log_info("callcenter: shard 7 taken up") == Nil
}

pub fn log_error_without_a_release_test() {
  assert kazoo.log_error("callcenter: shard 7 lost") == Nil
}
