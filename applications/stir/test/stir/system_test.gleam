import stir/system

pub fn category_test() {
  assert system.category == "stir"
  assert system.kek_variable == "STIR_KEK"
}

import stir/app

/// The module the start path registers with Crossbar is the one at the
/// top of `src`, named as Crossbar expects.
pub fn api_module_test() {
  assert app.api_module == "cb_stir"
}
