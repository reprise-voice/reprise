//// Who may run the call center, as opposed to work in it.
////
//// An account administrator or a superduper administrator. The user
//// document has no supervisor role, so `priv_level` is the whole of it.
//// They alone create, change and remove queues, add, move and remove an
//// agent's tier, eavesdrop and pick up, and change another agent's
//// availability. Anybody else with a token for the account may read all of
//// it, and change their own availability.
////
//// The check is made in a noun's `validate` and not in an `Authorize`
//// binding: Crossbar takes a `true` from a noun's binding as permission when
//// its own authorization did not grant the request, so a binding would have
//// to decide every path of the noun. A refusal leaves the context in error,
//// and Crossbar runs no verb after a `validate` that did not succeed, so
//// nothing is saved and nothing is published.

import kazoo/crossbar.{type Context}

/// Whether the request's user is an administrator of the account, or a
/// superduper administrator.
pub fn is_admin(context: Context) -> Bool {
  crossbar.is_account_admin(context) || crossbar.is_superduper_admin(context)
}

/// `next` for an administrator, and a 403 for anybody else. Called first,
/// so that nothing else the request might be wrong about is said before the
/// refusal.
pub fn admin_only(context: Context, next: fn() -> Context) -> Context {
  case is_admin(context) {
    True -> next()
    False -> crossbar.add_system_error(context, "forbidden")
  }
}
