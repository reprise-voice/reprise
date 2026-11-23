//// Where every caller stands, told to them and to the bus: `member_position`
//// on every change of position and on the announcement interval, and
//// `queue_stats` whenever a queue's shape changes, emptying included.

import callcenter/dispatcher/publish
import callcenter/dispatcher/settings.{type QueueSettings}
import callcenter/dispatcher/state.{type State, State, Wait}
import callcenter/dispatcher/view
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}

/// `member_position` on every change of position and on the announcement
/// interval, and `queue_stats` whenever the queue's shape changes.
///
/// `queued` is the queue's callers in the order they are offered, by call
/// id, and `available` how many of its agents could take one: the pass
/// works both out once for the whole account, rather than sorting the queue
/// and reading its agents again here.
///
/// A count the dispatcher cannot vouch for (`view.vouched_for`) -- the
/// activity unread, the switches not answered yet, the queue's document
/// unreadable or an agent who could be ready unread; `settings` is the
/// queue as the pass read it -- is not said: the positions go out without
/// `Agents-Available`, which a caller's action takes as nothing new rather
/// than as nobody, and no `queue_stats` goes out at all. Said as zero it
/// started every caller's no-agent clock on a question nobody answered.
pub fn announce(
  state: State,
  settings: QueueSettings,
  queued: List(String),
  available: Int,
  now: Int,
) -> State {
  let available = case view.vouched_for(state, settings) {
    True -> Some(available)
    False -> None
  }
  let queue_id = settings.id
  let queued = list.filter_map(queued, dict.get(state.waiting, _))
  let waiting = list.length(queued)
  let longest =
    list.fold(queued, 0, fn(longest, wait) {
      int.max(longest, now - wait.member.joined)
    })

  let state =
    list.index_fold(queued, state, fn(state, wait, index) {
      let position = index + 1
      case
        announcement_due(
          position: position,
          announced: wait.position,
          now: now,
          announced_at: wait.announced_at,
          interval_s: settings.announce_interval_s,
        )
      {
        False -> state
        True -> {
          publish.position(
            state.config.account_id,
            wait.member,
            position,
            waiting,
            available,
            ringing_for(state, wait.member.call_id),
            now,
          )
          State(
            ..state,
            waiting: dict.insert(
              state.waiting,
              wait.member.call_id,
              Wait(..wait, position: position, announced_at: now),
            ),
          )
        }
      }
    })

  // The queue's shape, and not the longest wait, is what a change means: the
  // longest wait goes up by one every second a caller is there, so counting
  // it as a change would put one event per second per busy queue on the bus
  // and say nothing. It still travels on every event, as the number it is.
  case available {
    None -> state
    Some(available) -> {
      let shape = #(waiting, available)
      let stats = #(waiting, longest, available)
      case dict.get(state.stats, queue_id) == Ok(shape) {
        True -> state
        False -> {
          publish.stats(state.config.account_id, queue_id, stats, now)
          State(..state, stats: dict.insert(state.stats, queue_id, shape))
        }
      }
    }
  }
}

/// `queue_stats` for every queue whose last one said somebody was waiting
/// and that has nobody waiting now. `announce` runs only for a queue with
/// somebody in it, so without this the last caller leaving published
/// nothing: a wallboard or webhook went on showing them waiting, and
/// `state.stats` kept the old shape.
///
/// `announced` is every queue the pass announced. Nothing is said while the
/// count is not vouched for, as in `announce`: the queue keeps its last
/// shape and is said empty on the first pass that can. A queue that has
/// been deleted is said empty too, and then forgotten.
pub fn emptied(state: State, announced: List(String), now: Int) -> State {
  case view.vouched(state) {
    False -> state
    True ->
      dict.fold(state.stats, state, fn(state, queue_id, shape) {
        let #(waiting, _available) = shape
        case waiting > 0 && !list.contains(announced, queue_id) {
          False -> state
          True -> {
            let settings = settings.for_queue(state.config, queue_id)
            case view.available_count(state, settings) {
              // The queue or one of its agents could not be read.
              None -> state
              Some(available) -> {
                publish.stats(
                  state.config.account_id,
                  queue_id,
                  #(0, 0, available),
                  now,
                )
                let stats = case settings.deleted {
                  True -> dict.delete(state.stats, queue_id)
                  False -> dict.insert(state.stats, queue_id, #(0, available))
                }
                State(..state, stats: stats)
              }
            }
          }
        }
      })
  }
}

/// Whether an offer for the caller is in flight: asked for or ringing, and
/// neither answered nor called off.
///
/// Asked for counts, although the action hears `member_offer` only once the
/// bridge is out. The two events leave through the broker pool on
/// different channels and can overtake each other; a position made while
/// the offer was being set up that said no ring was out, overtaken by the
/// `member_offer` that followed it, would end the ring the action had just
/// been told of. Saying `True` there costs nothing: it never starts a ring
/// the action was not told of.
fn ringing_for(state: State, call_id: String) -> Bool {
  case dict.get(state.offers, call_id) {
    Ok(offer) -> option.is_none(offer.connected) && !offer.called_off
    Error(Nil) -> False
  }
}

/// Whether a caller is told where they stand.
///
/// On every change of position, because a caller who has moved wants to
/// know, and on the announcement interval, because a caller who has not
/// moved wants to know that somebody is still there. A caller who has just
/// arrived has never been told, which `announced` of zero says.
pub fn announcement_due(
  position position: Int,
  announced announced: Int,
  now now: Int,
  announced_at announced_at: Int,
  interval_s interval_s: Int,
) -> Bool {
  position != announced || now - announced_at >= int.max(interval_s, 1)
}
