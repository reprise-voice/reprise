//// An agent who never logged in has no availability document, and the
//// dispatcher remembers that for `view.no_document_s` rather than asking
//// the database on every pass. A login is still heard at once, through its
//// `agent_availability` event, and one whose event was lost is found when
//// the finding runs out.

import callcenter/dispatcher/view
import gleam/list
import kazoo/doc
import support/cluster
import support/fake_offer

fn never_logged_in() -> cluster.Cluster {
  let c =
    cluster.new(
      [
        #(
          "support",
          doc.object([
            #("pvt_type", doc.String("queue")),
            #("name", doc.String("Support")),
            #("strategy", doc.String("longest_idle")),
            #(
              "agents",
              doc.List(
                list.map(["ann"], fn(id) {
                  doc.object([
                    #("id", doc.String(id)),
                    #("level", doc.Int(1)),
                    #("position", doc.Int(1)),
                  ])
                }),
              ),
            ),
          ]),
        ),
      ],
      [
        #(
          "ann",
          doc.object([
            #("pvt_type", doc.String("user")),
            #("call_center", doc.object([])),
          ]),
        ),
      ],
    )
  // A caller waits, and a pass has found ann with no document.
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 0
  c
}

/// The event of a first login forgets the finding, and the pass it starts
/// offers the agent.
pub fn a_first_login_is_offered_at_once_test() {
  let c = never_logged_in()
  cluster.agent_logs_in(c, "ann")

  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// Any other change heard about the agent forgets it as well.
pub fn a_change_heard_about_the_agent_reads_them_again_test() {
  let c = never_logged_in()
  cluster.agent_is(c, "ann", "available")
  cluster.agent_changed(c, "ann")

  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// An event naming nobody the dispatcher could read might be anybody's.
pub fn an_event_naming_nobody_reads_everybody_again_test() {
  let c = never_logged_in()
  cluster.agent_is(c, "ann", "available")
  cluster.changed(c)

  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// A login whose event was lost is not seen while the finding stands, and
/// is seen by the first pass after it has run out.
pub fn a_login_whose_event_was_lost_is_found_when_the_finding_runs_out_test() {
  let c = never_logged_in()
  cluster.agent_is(c, "ann", "available")
  cluster.at(c, view.no_document_s - 1)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == []

  cluster.at(c, view.no_document_s)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
}
