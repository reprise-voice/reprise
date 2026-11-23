//// Who a pass offers to whom, decided from what the pass read once.
////
//// Nothing here reads a document, asks an actor or sends anything. The pass
//// reads the account once (`view.snapshot`): each agent's availability and
//// counters, each queue's settings, memo and number of callers, and one
//// view per tier. What an offer made in the same pass changes is small and
//// known -- the agents it rings are offering from then on and free from
//// now, and the queue's strategy has taken its turn -- and `commit` applies
//// exactly that, so the views are built once per queue and not once per
//// caller.
////
//// `decide` is one caller's decision and `commit` what an offer started
//// changes; the pass sends each offer between the two, because an offer
//// that could not be started leaves its agents for the next caller. `plan`
//// is the same fold with every offer taken as started, for a test or a
//// profile to look at on its own.

import callcenter/dispatcher/settings.{type QueueSettings}
import callcenter/dispatcher/state.{type Wait, Wait}
import callcenter/dispatcher/waiting
import callcenter/strategy
import callcenter/tiers
import callcenter/types.{
  type AgentView, AgentView, NoAnswer, Offered, Offering, Sequential,
  Simultaneous,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/set.{type Set}

/// One queue with somebody waiting, as the pass found it.
pub type Queue {
  Queue(
    settings: QueueSettings,
    /// What the strategy is shown, its memo as it stands after the offers
    /// this pass has made so far.
    shown: strategy.QueueState,
    /// One per tier, in the tier order, as the pass began. Empty for a
    /// queue whose agents nobody could offer anything to: no caller of it
    /// is decided, so nothing looks at them.
    views: List(AgentView),
    /// The agent of every tier who could take a caller as the pass began,
    /// once per tier, for `available`.
    ready: List(String),
    /// The same agents, once each.
    selectable: Set(String),
    /// How many of them no offer of this pass has taken yet.
    free: Int,
  )
}

pub type Snapshot {
  Snapshot(
    now: Int,
    /// Queue id to the queue, for every queue with somebody waiting.
    queues: Dict(String, Queue),
    /// Everybody an offer of this pass rings.
    offered: Set(String),
  )
}

/// One offer the pass is to make.
pub type Planned {
  Planned(wait: Wait, settings: QueueSettings, offer: types.Offer)
}

/// Whether anybody at all could be offered a caller in this pass.
pub fn anybody(snapshot: Snapshot) -> Bool {
  dict.values(snapshot.queues) |> list.any(fn(queue) { queue.free > 0 })
}

/// How many of the queue's agents could take a caller now, as `queue_stats`
/// and `member_position` say: once per tier, as `view.available_count`
/// counts.
pub fn available(snapshot: Snapshot, queue_id: String) -> Int {
  case dict.get(snapshot.queues, queue_id) {
    Ok(queue) ->
      list.count(queue.ready, fn(agent_id) {
        !set.contains(snapshot.offered, agent_id)
      })
    Error(Nil) -> 0
  }
}

/// What one caller is offered, if anything.
///
/// Their own queue's tier rules say which of its agents they have waited
/// for, and its strategy chooses among them. When nobody in the queue could
/// take a caller the answer is nothing, straight away: a strategy only ever
/// offers an agent who could, so asking it would change nothing.
pub fn decide(snapshot: Snapshot, wait: Wait) -> Result(Planned, Nil) {
  case dict.get(snapshot.queues, wait.member.queue_id) {
    Error(Nil) -> Error(Nil)
    Ok(Queue(free: 0, ..)) -> Error(Nil)
    Ok(queue) -> {
      let settings = queue.settings
      let waited =
        snapshot.now
        - waiting.score_base(wait.member, settings.time_base_system)
      let eligible =
        tiers.eligible_by(
          settings.rules,
          queue.views,
          fn(view: AgentView) { view.level },
          waited,
          fn(view: AgentView) { answerable(snapshot, queue, view.agent_id) },
        )
        |> list.map(fn(view) { as_now(snapshot, view) })
      let choose = fn(wait: Wait) {
        settings.strategy.candidates(
          queue.shown,
          for_caller(eligible, wait.tried),
          snapshot.now,
        )
      }
      let offer = choose(wait)
      // The caller's list of who has rung for them starts again when
      // everybody who could take them has had them, and it is not consulted
      // at all by a strategy that rings everybody: whether the offer is one
      // of those is only known once the strategy has answered, so an
      // inherited list is found out here and not before.
      let starts_again = case offer, wait.tried {
        _any, [] -> False
        Sequential([]), _everybody -> True
        Sequential(_), _ -> False
        Simultaneous(_), _inherited -> True
      }
      let #(wait, offer) = case starts_again {
        False -> #(wait, offer)
        True -> {
          let wait = Wait(..wait, tried: [])
          #(wait, choose(wait))
        }
      }
      case offer {
        Sequential([]) | Simultaneous([]) -> Error(Nil)
        _somebody -> Ok(Planned(wait: wait, settings: settings, offer: offer))
      }
    }
  }
}

/// An offer of this pass has started, ringing `ringing` for a caller of
/// `queue_id`: they are offering from now on, in every queue they are in,
/// and the queue's strategy has had its turn, as `memo.remember` records it
/// in the dispatcher.
pub fn commit(
  snapshot: Snapshot,
  queue_id: String,
  ringing: List(String),
) -> Snapshot {
  let taken =
    list.filter(ringing, fn(agent_id) {
      !set.contains(snapshot.offered, agent_id)
    })
    |> list.unique
  let queues =
    dict.map_values(snapshot.queues, fn(id, queue) {
      let free =
        queue.free
        - list.count(taken, fn(agent_id) {
          set.contains(queue.selectable, agent_id)
        })
      let shown = case id == queue_id {
        False -> queue.shown
        True ->
          list.fold(ringing, queue.shown, fn(shown, agent_id) {
            queue.settings.strategy.on_result(shown, agent_id, Offered)
          })
      }
      Queue(..queue, free: free, shown: shown)
    })
  Snapshot(
    ..snapshot,
    queues: queues,
    offered: list.fold(taken, snapshot.offered, set.insert),
  )
}

/// Every offer of a pass over these callers, in the account's order, each
/// taken as started: `decide` and `commit` with nothing sent between them.
pub fn plan(snapshot: Snapshot, callers: List(Wait)) -> List(Planned) {
  let #(_snapshot, planned) =
    list.fold(callers, #(snapshot, []), fn(acc, wait) {
      let #(snapshot, planned) = acc
      case decide(snapshot, wait) {
        Error(Nil) -> acc
        Ok(offer) -> #(
          commit(
            snapshot,
            wait.member.queue_id,
            settings.ringing(offer.offer, offer.settings),
          ),
          [offer, ..planned],
        )
      }
    })
  list.reverse(planned)
}

/// Whether an agent could take a caller now, which is what the tier rules'
/// `no_agent_no_wait` asks: they could as the pass began, and no offer of
/// the pass has taken them since.
fn answerable(snapshot: Snapshot, queue: Queue, agent_id: String) -> Bool {
  set.contains(queue.selectable, agent_id)
  && !set.contains(snapshot.offered, agent_id)
}

/// A view as it stands now: an agent an offer of this pass rings is
/// offering, and free from now, as the dispatcher's own record of them
/// (`worked.offered`) has it.
fn as_now(snapshot: Snapshot, view: AgentView) -> AgentView {
  case set.contains(snapshot.offered, view.agent_id) {
    False -> view
    True ->
      AgentView(
        ..view,
        tier_state: Offering,
        free_since: int.max(view.free_since, snapshot.now),
      )
  }
}

/// The views as one caller sees them: an agent who has already had this
/// caller is, for this caller, an agent who did not answer.
fn for_caller(views: List(AgentView), tried: List(String)) -> List(AgentView) {
  case tried {
    [] -> views
    // A set, asked of every view: a caller who has rung round a large
    // queue has a list as long as the queue.
    _some -> {
      let tried = set.from_list(tried)
      list.map(views, fn(view) {
        case set.contains(tried, view.agent_id) {
          True -> AgentView(..view, tier_state: NoAnswer)
          False -> view
        }
      })
    }
  }
}
