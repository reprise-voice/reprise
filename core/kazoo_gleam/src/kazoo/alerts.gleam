//// Kazoo alerts.
////
//// An alert is addressed to the account's admins and to the reseller's,
//// which is where `provisioner_v5:create_alert/4` sends the one it raises
//// when a push fails. The category is the application's own name, set by
//// `kazoo.live/1`; the title is the application's to choose.
////
//// Alerts are best effort: a node with no datastore records nothing and the
//// caller carries on.

import gleam/option.{type Option, None}
import kazoo/accounts
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo, Alert}

/// Raise an alert about one account. The reseller is looked up so the
/// reseller's admins see it too.
pub fn about_account(
  kz: Kazoo,
  account_id: String,
  title: String,
  message: String,
  metadata: Value,
) -> Nil {
  create(kz, account_id, None, title, message, metadata)
}

pub fn create(
  kz: Kazoo,
  account_id: String,
  owner_id: Option(String),
  title: String,
  message: String,
  metadata: Value,
) -> Nil {
  let _ =
    kz.alerts.create(Alert(
      title: title,
      message: message,
      account_id: account_id,
      owner_id: owner_id,
      reseller_id: accounts.reseller_id(kz, account_id),
      metadata: metadata,
    ))
  Nil
}
