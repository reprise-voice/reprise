//// Reprise STIR/SHAKEN.
////
//// Signing keys and certificates, PASSporT signing for outbound carrier
//// calls and verification of inbound ones. The application is started by
//// `kapps_controller` on a kazoo_apps node (`KAZOO_APPS=...,stir`, or the
//// `kapps` list in `system_config/kapps_controller`); see `stir/app` for
//// the OTP application callbacks and `doc/engineering/stir-shaken.md` at
//// the repository root for the design.
////
//// Every node runs the same tree: a signer, which is the one process on
//// the node that holds decrypted keys, and a monitor, which renews, alerts
//// and keeps the trust material fresh.

import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import kazoo/kazoo.{type Kazoo}
import stir/http
import stir/monitor
import stir/signer
import stir/system

pub fn main() -> Nil {
  let assert Ok(_) = start(system.live())
  process.sleep_forever()
}

/// Start the supervision tree. One for one: the signer and the monitor are
/// independent, and neither is worth restarting the other for.
pub fn start(
  kz: Kazoo,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  system.log("starting on " <> system.node_name())
  list.fold(
    children(kz),
    supervisor.new(supervisor.OneForOne)
      |> supervisor.restart_tolerance(intensity: 10, period: 60),
    supervisor.add,
  )
  |> supervisor.start
}

fn children(kz: Kazoo) -> List(supervision.ChildSpecification(Nil)) {
  [signer.supervised(kz), monitor.supervised(kz, http.real())]
}
