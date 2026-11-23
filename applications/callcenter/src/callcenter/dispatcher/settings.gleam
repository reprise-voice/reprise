//// What a dispatcher reads out of a queue document and out of a user's
//// `call_center` object, with the schema's defaults for everything they
//// leave out.
////
//// The reading is pure; `for_queue` and `for_agent` are the two that go to
//// the datastore for the document first, through the configuration the
//// dispatcher was started with.

import callcenter/agents
import callcenter/availability
import callcenter/dispatcher/config.{type Config}
import callcenter/fields
import callcenter/queue_doc
import callcenter/strategy
import callcenter/tiers
import callcenter/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/cache
import kazoo/doc.{type Value}
import kazoo/kazoo

// --- The queue document ----------------------------------------------------

/// What the dispatcher reads out of a queue document.
pub type QueueSettings {
  QueueSettings(
    id: String,
    name: String,
    strategy: strategy.Strategy,
    ring_timeout_s: Int,
    wrapup_s: Int,
    cid_prefix: Option(String),
    record: Bool,
    outbound_caller_id_name: Option(String),
    outbound_caller_id_number: Option(String),
    /// `moh`: the queue's hold music, which the offer keeps playing while
    /// the phones ring.
    hold_media: Option(String),
    skip_external_calls: Bool,
    ring_simultaneously: Int,
    announce_interval_s: Int,
    agent_no_answer_status: types.Availability,
    time_base_system: Bool,
    rules: tiers.Rules,
    tiers: List(tiers.Tier),
    /// The queue has been deleted: its document is gone, or Crossbar's soft
    /// delete marked it `pvt_deleted`. Nobody is offered from it, and its
    /// callers are taken out of it (`offers.queue_deleted`).
    deleted: Bool,
    /// Whether these settings are the queue's, as `for_queue` came by them.
    found: Found,
    /// Set by a pass (`view.snapshot`) on the queue it read: an agent of
    /// the queue who could have been ready could not be read. They are
    /// offered nothing, and the count of agents available leaves them out,
    /// so the count is not the queue's either (`vouched`).
    agents_unread: Bool,
  )
}

/// How `for_queue` came by a queue's settings.
pub type Found {
  /// Read, now or -- the database not answering -- the last time it
  /// answered on this node.
  Loaded
  /// The database says the queue is not there: it is deleted.
  NotFound
  /// The document could not be read and this node has no earlier copy:
  /// every setting is the default, the tiers are none, and none of it is
  /// the queue's. Nobody is offered from it, and nothing the dispatcher
  /// counts or keeps for it -- the agents available, `queue_stats`, the
  /// strategy's memo -- is said or changed on it (`vouched`).
  Unreadable
}

/// Whether the count of agents available the dispatcher works out from
/// these settings is the queue's own: not so for an unreadable queue, whose
/// tiers are none because nothing was read, and not for one an agent of
/// which could not be read, who is counted neither way.
pub fn vouched(settings: QueueSettings) -> Bool {
  settings.found != Unreadable && !settings.agents_unread
}

/// The last queue document each node read, by database and queue id: what
/// stands for the queue while the database does not answer.
const kept = "callcenter_queue_kept"

/// When each queue's document was last kept, by the same key: it is kept
/// at most once every `queue_refresh_s`, not copied on every pass.
const kept_at = "callcenter_queue_kept_at"

/// The queue's settings as they stand, read through `queue_doc`. A queue
/// the database says is not there is deleted.
///
/// One whose document could not be read is not assumed to be anything.
/// `queue_doc` already falls back to the data layer's cached copy, but that
/// copy is gone once the cache lets it go or a refresh that read the
/// database dropped it, and a node that takes the account over in an outage
/// never had one. So the last document read here is kept (`kept`) and
/// stands in; with none, the queue is `Unreadable`. It used to be read as a
/// queue with every default and no agents, which the dispatcher then
/// reported as nobody available.
pub fn for_queue(config: Config, queue_id: String) -> QueueSettings {
  let db = kazoo.account_db(config.account_id)
  let key = db <> "/" <> queue_id
  let read =
    queue_doc.read(
      config.kz,
      db,
      queue_id,
      config.now(),
      config.queue_refresh_s,
    )
  let settings = fn(document, found) {
    QueueSettings(
      ..queue(
        queue_id,
        document,
        config.announce_interval_s,
        config.default_no_answer_status,
      ),
      found: found,
    )
  }
  case read {
    Ok(document) -> {
      case cache.first_in(kept_at, key, config.now(), config.queue_refresh_s) {
        True -> cache.put(kept, key, document)
        False -> Nil
      }
      settings(document, Loaded)
    }
    Error(kazoo.NotFound) -> {
      cache.delete(kept, key)
      QueueSettings(..settings(doc.object([]), NotFound), deleted: True)
    }
    Error(_unreachable) ->
      case cache.get(kept, key) {
        Ok(document) -> settings(document, Loaded)
        Error(Nil) -> settings(doc.object([]), Unreadable)
      }
  }
}

/// Forget every queue document kept. For a test suite whose queues are
/// written again by every test.
pub fn forget_kept() -> Nil {
  cache.clear(kept)
  cache.clear(kept_at)
}

/// A queue document as the dispatcher reads it, with the schema's defaults
/// for everything it leaves out.
pub fn queue(
  queue_id: String,
  document: Value,
  default_announce_interval_s: Int,
  default_no_answer_status: String,
) -> QueueSettings {
  QueueSettings(
    id: queue_id,
    name: fields.string_at(document, ["name"], queue_id),
    strategy: strategy.resolve(fields.string_at(
      document,
      ["strategy"],
      "longest_idle",
    )),
    ring_timeout_s: fields.int_at(document, ["agent_ring_timeout"], 15),
    wrapup_s: fields.int_at(document, ["agent_wrapup_time"], 0),
    cid_prefix: fields.some_string(document, ["cid_prefix"]),
    record: fields.bool_at(document, ["record"], False),
    outbound_caller_id_name: fields.some_string(document, [
      "outbound_caller_id",
      "name",
    ]),
    outbound_caller_id_number: fields.some_string(document, [
      "outbound_caller_id",
      "number",
    ]),
    hold_media: fields.some_string(document, ["moh"]),
    skip_external_calls: fields.bool_at(
      document,
      ["skip_agents_with_external_calls"],
      True,
    ),
    ring_simultaneously: fields.int_at(document, ["ring_simultaneously"], 1),
    announce_interval_s: fields.int_at(
      document,
      ["announce", "interval"],
      default_announce_interval_s,
    ),
    agent_no_answer_status: availability.from_string(fields.string_at(
      document,
      ["agent_no_answer_status"],
      default_no_answer_status,
    )),
    time_base_system: fields.string_at(document, ["time_base_score"], "system")
      == "system",
    rules: tiers.rules(document),
    tiers: tiers.of(document),
    deleted: fields.bool_at(document, ["pvt_deleted"], False),
    found: Loaded,
    agents_unread: False,
  )
}

// --- The agent -------------------------------------------------------------

/// What the dispatcher reads out of a user's `call_center` object.
pub type AgentSettings {
  AgentSettings(
    ring_timeout_s: Option(Int),
    wrapup_s: Option(Int),
    max_no_answer: Int,
    reject_delay_s: Int,
    busy_delay_s: Int,
    no_answer_delay_s: Int,
    record: Bool,
  )
}

pub fn no_agent() -> AgentSettings {
  AgentSettings(
    ring_timeout_s: None,
    wrapup_s: None,
    max_no_answer: 0,
    reject_delay_s: 0,
    busy_delay_s: 0,
    no_answer_delay_s: 0,
    record: False,
  )
}

/// The agent's settings as they stand, from their user document in the
/// document cache. A user who cannot be read has none.
pub fn for_agent(config: Config, agent_id: String) -> AgentSettings {
  case
    config.kz.datamgr.open_cache_doc(
      kazoo.account_db(config.account_id),
      agent_id,
    )
  {
    Error(_) -> no_agent()
    Ok(user) -> agent(user)
  }
}

/// Whether the user behind a tier can be offered a caller at all: there,
/// not deleted, and enabled (`agents.can_be_offered`). Read from the same
/// cached user document `for_agent` reads.
pub fn can_be_offered(config: Config, agent_id: String) -> Bool {
  config.kz.datamgr.open_cache_doc(
    kazoo.account_db(config.account_id),
    agent_id,
  )
  |> agents.can_be_offered
}

/// A user document's `call_center` object.
pub fn agent(user: Value) -> AgentSettings {
  AgentSettings(
    ring_timeout_s: fields.some_int(user, ["call_center", "ring_timeout"]),
    wrapup_s: fields.some_int(user, ["call_center", "wrapup_time"]),
    max_no_answer: fields.int_at(user, ["call_center", "max_no_answer"], 0),
    reject_delay_s: fields.int_at(user, ["call_center", "reject_delay"], 0),
    busy_delay_s: fields.int_at(user, ["call_center", "busy_delay"], 0),
    no_answer_delay_s: fields.int_at(
      user,
      ["call_center", "no_answer_delay"],
      0,
    ),
    record: fields.bool_at(user, ["call_center", "record"], False),
  )
}

/// Whom an offer rings now.
///
/// Sequential means the queue's `ring_simultaneously` at a time -- one by
/// default, so that the ring timeout is per agent as requirement 1.6 says.
/// The rest of the list is not held on to: the next pass asks the strategy
/// again, with whatever has happened since.
pub fn ringing(offer: types.Offer, queue: QueueSettings) -> List(String) {
  case offer {
    types.Sequential(agents) ->
      list.take(agents, int.max(1, queue.ring_simultaneously))
    types.Simultaneous(all) -> all
  }
}

/// The shortest ring timeout of the agents being rung, so that no agent's
/// own setting is overrun when several ring together.
pub fn ring_timeout(
  config: Config,
  agents: List(String),
  settings: QueueSettings,
) -> Int {
  list.fold(agents, settings.ring_timeout_s, fn(shortest, agent_id) {
    case for_agent(config, agent_id).ring_timeout_s {
      Some(seconds) if seconds < shortest -> seconds
      _other -> shortest
    }
  })
}

/// Whether any of the agents asks for their calls to be recorded.
pub fn any_agent_records(config: Config, agents: List(String)) -> Bool {
  list.any(agents, fn(agent_id) { for_agent(config, agent_id).record })
}
