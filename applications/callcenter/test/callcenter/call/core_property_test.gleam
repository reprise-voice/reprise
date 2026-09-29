//// One queued call's state machine against random scripts.
////
//// Each script is a caller joining -- or, one script in four, a caller
//// handed over whom the actor finds out about, with a random survey of the
//// switch and a probe that may or may not answer, among the first steps --
//// then forty inputs drawn at random from
//// everything that can reach the actor -- rings, answers, legs going, keys,
//// call-offs, a deleted queue, positions, `ecallmgr`'s word on originates,
//// barriers, the callflow's acknowledgement, the next queue, an audit that
//// finds the caller gone, and the clock
//// -- and then the end of the call: every originate over, the caller gone,
//// and the clock long past every deadline. Along the way and at the end the
//// call has to keep what the design promises:
////
//// - it sends the caller only what its phase allows (`core.allowed`), and
////   nothing once it has departed or is done;
//// - one originate per offer, and only for the ring that asked for it;
//// - every offer it rang ends in exactly one reply -- an answer is followed
////   by exactly one end -- or, for a caller who left while it rang, in the
////   shard being told they left in the step that took the call out of the
////   ring: a caller leaving later does not end an offer the dispatcher is
////   still waiting to hear the end of;
//// - the callflow is told to go on only after the passage's barrier, always
////   on the same branch, at most `continue_attempts` times, and resumed
////   elsewhere at most once and only after that;
//// - the shard hears a caller leave at most once a passage;
//// - a caller handed over is told the dispatcher of at most once for each
////   time they were, and an offer found going on for them ends like one the
////   actor rang;
//// - it never sleeps less than a millisecond or more than thirty seconds;
//// - and once the call is over and every deadline has passed, the actor has
////   nothing left to do.
////
//// The scripts come from the seeded generator in `support/rng`, so a failure
//// names a seed and the seed reproduces it.

import callcenter/call/core.{type Call, type Effect, type Input}
import callcenter/call/originate
import callcenter/call/recovery
import callcenter/records
import callcenter/types
import gleam/dict.{type Dict}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kazoo/doc
import kazoo/events
import support/call_script.{
  at_ms, bridged_to, call_id, event, fresh, gone, handoff, joining, key, leg_of,
  noop_done, offer, originate_error, originate_success, ring, settings, t0,
}
import support/rng.{type Rng}

const scripts = 400

const steps = 40

// --- The scripts ---------------------------------------------------------------

/// What the generator knows as it writes a script: the time, and the offers
/// rung so far with how many legs each named.
type World {
  World(ms: Int, offers: List(#(types.OfferId, Int)), rng: Rng)
}

/// One script: the inputs, each with the millisecond it comes at.
fn a_script(seed: Int) -> List(#(Input, Int)) {
  let world = World(ms: 0, offers: [], rng: rng.seeded(seed))
  let #(start, found, world) = case seed % 4 {
    0 -> handed_over(world)
    _ -> #(joining("h1", settings()), [], world)
  }
  let #(inputs, world) =
    rng.upto(steps)
    |> list.fold(#([#(start, 0)], world), fn(acc, _) {
      let #(inputs, world) = acc
      let #(input, world) = an_input(world)
      #([#(input, world.ms), ..inputs], world)
    })
  // What the actor finds out about a caller handed over arrives among the
  // first steps, each at the time of the step it goes before.
  let inputs =
    list.fold(found, list.reverse(inputs), fn(inputs, entry) {
      let #(input, at) = entry
      let at = int.min(at, list.length(inputs) - 1) |> int.max(1)
      let before = list.take(inputs, at)
      let after = list.drop(inputs, at)
      let ms = case after {
        [#(_, ms), ..] -> ms
        [] -> world.ms
      }
      list.flatten([before, [#(input, ms)], after])
    })
    |> list.reverse
  // The end of the call: every originate over, the caller gone, and the
  // clock long past every deadline.
  let end = world.ms + 1000
  let over =
    list.map(world.offers, fn(offer) {
      #(originate_error(offer.0, "ORIGINATOR_CANCEL"), end)
    })
  let ending = [
    #(gone(call_id, "NORMAL_CLEARING"), end),
    #(core.Tick, end + 20_000_000),
    #(core.Tick, end + 40_000_000),
  ]
  list.flatten([list.reverse(inputs), over, ending])
}

/// A caller handed over: the rejoin, and what the survey and the probe
/// bring, each with the step it arrives before. The survey lists a caller
/// row -- bridged to one of the found legs, or to nobody -- and up to three
/// legs of one offer, answered or not, with more or less of their ring left;
/// the probe carries this passage's marks, or none, or never answers; the
/// record says an answer, a close, or nothing.
fn handed_over(world: World) -> #(Input, List(#(Input, Int)), World) {
  let id = types.OfferId(call_id: call_id, serial: reference.new())
  let prefix = originate.leg_prefix(id)
  let #(count, rng) = rng.below(world.rng, 4)
  let #(legs, rng) =
    rng.upto(count)
    |> list.fold(#([], rng), fn(acc, n) {
      let #(legs, rng) = acc
      let #(answered, rng) = rng.chance(rng, 30)
      let #(left, rng) = rng.below(rng, 20)
      let #(agent, rng) = rng.pick(rng, ["ann", "bob", "cat"])
      let leg = prefix <> "-" <> int.to_string(n + 1)
      let row =
        events.channel(
          doc.object([
            #("uuid", doc.String(leg)),
            #("other_leg", doc.String(leg)),
            #("answered", doc.Bool(answered)),
            #(
              "custom_channel_vars",
              doc.object([
                #("Queue-Call-ID", doc.String(call_id)),
                #("Queue-Offer-ID", doc.String(prefix)),
                #("Queue-Offer-Deadline", doc.Int(t0 + left)),
                #("Agent-ID", doc.String(agent)),
              ]),
            ),
          ]),
        )
      #([#(leg, row), ..legs], rng)
    })
  let #(bridged, rng) = rng.chance(rng, 25)
  let through = case bridged, legs {
    True, [#(leg, _), ..] -> Some(leg)
    _, _ -> None
  }
  let rows =
    list.map(legs, fn(entry) {
      let #(leg, row) = entry
      case through == Some(leg) {
        True -> events.Channel(..row, other_leg: Some(call_id), answered: True)
        False -> row
      }
    })
  let caller_row =
    events.channel(
      doc.object_some([
        #("uuid", Some(doc.String(call_id))),
        #("other_leg", option.map(through, doc.String)),
        #("answered", Some(doc.Bool(True))),
      ]),
    )
  let #(listed, rng) = rng.chance(rng, 85)
  let rows = case listed {
    True -> [caller_row, ..rows]
    False -> rows
  }
  let #(recorded, rng) = rng.pick(rng, ["none", "none", "answered", "closed"])
  let record = case recorded {
    "answered" -> Some(passage(Some(t0 - 20), None))
    "closed" -> Some(passage(None, Some(t0 - 5)))
    _ -> None
  }
  let #(marked, rng) =
    rng.pick(rng, ["none", "none", "none", "departing", "departed"])
  let marks = case marked {
    "departing" -> [
      #(recovery.departing_var, doc.String("h1")),
      #(recovery.departing_branch_var, doc.String("exit_key")),
    ]
    "departed" -> [
      #(recovery.departing_var, doc.String("h1")),
      #(recovery.departing_branch_var, doc.String("timeout")),
      #(recovery.departed_var, doc.String("h1")),
    ]
    _ -> []
  }
  let probe =
    event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("noop")),
      #("Application-Response", doc.String(recovery.probe_id("h1", 1))),
      #("Custom-Channel-Vars", doc.object(marks)),
    ])
  let #(surveyed_at, rng) = rng.below(rng, 6)
  let #(probed_at, rng) = rng.below(rng, 6)
  let #(answers, rng) = rng.chance(rng, 80)
  let found =
    [
      #(
        core.Surveyed(recovery.Survey(
          channels: Some(events.Channels(channels: rows, complete: True)),
          record: record,
        )),
        surveyed_at + 1,
      ),
    ]
    |> list.append(case answers {
      True -> [#(probe, probed_at + 1)]
      False -> []
    })
  let world = case legs {
    [] -> World(..world, rng: rng)
    _ -> World(..world, offers: [#(id, count)], rng: rng)
  }
  #(core.Rejoined(joining_of("h1"), id), found, world)
}

fn joining_of(id: String) -> core.Joining {
  core.Joining(
    queue_id: call_script.queue_id,
    joined: t0,
    handoff: handoff(id),
    settings: settings(),
  )
}

fn passage(answered, closed) -> records.Passage {
  records.Passage(
    offer: None,
    answered: answered,
    agent_id: option.map(answered, fn(_) { "ann" }),
    agent_call_id: None,
    picked_up: False,
    ended: closed,
    cancelled: None,
  )
}

fn an_input(world: World) -> #(Input, World) {
  let #(kind, rng) = rng.below(world.rng, 100)
  let world = World(..world, rng: rng)
  case kind {
    k if k < 18 -> {
      let #(by, rng) = rng.below(world.rng, 9000)
      #(core.Tick, World(..world, ms: world.ms + by, rng: rng))
    }
    k if k < 28 -> {
      let #(count, rng) = rng.below(world.rng, 3)
      let agents =
        ["ann", "bob", "cat"]
        |> list.take(count + 1)
      let #(id, endpoints) = offer(agents)
      #(
        ring(id, agents, endpoints, count == 1),
        World(..world, offers: [#(id, count + 1), ..world.offers], rng: rng),
      )
    }
    k if k < 50 -> a_leg_event(world)
    k if k < 58 -> {
      let #(digit, rng) = rng.pick(world.rng, ["#", "5"])
      #(key(digit), World(..world, rng: rng))
    }
    k if k < 64 -> a_caller_bridge(world)
    k if k < 67 -> #(event(call_id, "CHANNEL_UNBRIDGE", []), world)
    k if k < 71 -> #(
      event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
        #("Application-Name", doc.String("noop")),
      ]),
      world,
    )
    k if k < 77 -> {
      let #(which, rng) = rng.pick(world.rng, ["h1", "h2"])
      #(noop_done(core.barrier_id(handoff(which))), World(..world, rng: rng))
    }
    k if k < 79 -> #(event(call_id, "CHANNEL_TRANSFEREE", []), world)
    k if k < 83 ->
      case world.offers {
        [] -> #(core.QueueGone, world)
        offers -> {
          let #(offer, rng) = rng.pick(world.rng, offers)
          #(core.CallOff(offer.0), World(..world, rng: rng))
        }
      }
    k if k < 84 -> #(core.QueueGone, world)
    k if k < 87 -> {
      let #(available, rng) = rng.below(world.rng, 3)
      #(
        core.Positioned(Some(1), Some(2), Some(available)),
        World(..world, rng: rng),
      )
    }
    k if k < 93 -> an_originate_reply(world)
    k if k < 96 -> {
      let #(which, rng) = rng.pick(world.rng, ["h1", "h2"])
      #(core.Continuing(which), World(..world, rng: rng))
    }
    k if k < 98 -> #(joining("h2", settings()), world)
    // The switches saying the caller is on none of them: the end of the
    // channel, heard by an audit rather than an event.
    k if k < 99 -> #(core.Audited([call_id]), world)
    _ -> #(gone(call_id, "NORMAL_CLEARING"), world)
  }
}

fn a_leg_event(world: World) -> #(Input, World) {
  case world.offers {
    [] -> #(core.Tick, world)
    offers -> {
      let #(offer, rng) = rng.pick(world.rng, offers)
      let #(n, rng) = rng.below(rng, offer.1)
      let leg = leg_of(offer.0, n + 1)
      let #(what, rng) =
        rng.pick(rng, ["create", "answer", "answer", "park", "gone", "blind"])
      let #(cause, rng) =
        rng.pick(rng, [
          "NO_ANSWER", "LOSE_RACE", "ORIGINATOR_CANCEL", "NORMAL_CLEARING",
          "USER_BUSY",
        ])
      let input = case what {
        "create" -> event(leg, "CHANNEL_CREATE", [])
        "answer" -> event(leg, "CHANNEL_ANSWER", [])
        "park" -> call_script.parked(leg)
        "blind" -> gone(leg, "BLIND_TRANSFER")
        _ -> gone(leg, cause)
      }
      #(input, World(..world, rng: rng))
    }
  }
}

fn a_caller_bridge(world: World) -> #(Input, World) {
  let #(foreign, rng) = rng.chance(world.rng, 15)
  case foreign, world.offers {
    True, _ | _, [] -> #(bridged_to("somebody-else"), World(..world, rng: rng))
    False, offers -> {
      let #(offer, rng) = rng.pick(rng, offers)
      let #(n, rng) = rng.below(rng, offer.1)
      #(bridged_to(leg_of(offer.0, n + 1)), World(..world, rng: rng))
    }
  }
}

fn an_originate_reply(world: World) -> #(Input, World) {
  case world.offers {
    [] -> #(core.Tick, world)
    offers -> {
      let #(offer, rng) = rng.pick(world.rng, offers)
      let #(success, rng) = rng.chance(rng, 40)
      case success {
        True -> {
          let #(n, rng) = rng.below(rng, offer.1)
          #(
            originate_success(offer.0, leg_of(offer.0, n + 1)),
            World(..world, rng: rng),
          )
        }
        False -> {
          let #(cause, rng) =
            rng.pick(rng, ["NO_ANSWER", "USER_BUSY", "ORIGINATOR_CANCEL"])
          #(originate_error(offer.0, cause), World(..world, rng: rng))
        }
      }
    }
  }
}

// --- What a script did -----------------------------------------------------------

/// Everything the invariants need, gathered as the script runs.
type Seen {
  Seen(
    step: Int,
    /// The offers the call was asked to ring, by the step that asked.
    asked: Dict(String, Int),
    /// The step each offer was originated at.
    originated: Dict(String, Int),
    /// Every reply each offer had, in order.
    replies: Dict(String, List(types.OfferReply)),
    /// The steps the shard was told the caller left at.
    lefts: List(Int),
    /// The offers the caller left while they rang: the step that took the
    /// call out of the offer's ring also told the shard the caller left, so
    /// the dispatcher gave the offer up with the caller.
    left_ringing: List(String),
    /// The offers whose ring the caller deserted -- hung up while it rang --
    /// and that are not decided yet (`core.Desertion`): the step that
    /// decides one tells the shard the caller left, or the dispatcher that
    /// the offer was answered and ended.
    deserted: List(String),
    /// Barriers sent, by handoff.
    barriers: Dict(String, Int),
    /// Continues sent, by handoff: the branches, in order.
    continues: Dict(String, List(String)),
    resumes: Dict(String, Int),
    passages: Int,
    /// Callers handed over, and the dispatcher told where they stand.
    rejoins: Int,
    presents: Int,
    /// The offers told as found going on, by the step that told them.
    found: Dict(String, Int),
    problems: List(String),
  )
}

fn offer_key(id: types.OfferId) -> String {
  string.inspect(id)
}

/// Run one script, checking every step, and answer what it did.
fn run(seed: Int) -> #(Call, Seen) {
  let start =
    Seen(
      step: 0,
      asked: dict.new(),
      originated: dict.new(),
      replies: dict.new(),
      lefts: [],
      left_ringing: [],
      deserted: [],
      barriers: dict.new(),
      continues: dict.new(),
      resumes: dict.new(),
      passages: 0,
      rejoins: 0,
      presents: 0,
      found: dict.new(),
      problems: [],
    )
  list.fold(a_script(seed), #(fresh(), start), fn(acc, entry) {
    let #(call, seen) = acc
    let #(input, ms) = entry
    let clock = at_ms(ms)
    let seen = Seen(..seen, step: seen.step + 1)
    let seen = case input {
      core.Ring(request) ->
        Seen(
          ..seen,
          asked: dict.insert(seen.asked, offer_key(request.offer), seen.step),
        )
      core.Joined(_) -> Seen(..seen, passages: seen.passages + 1)
      core.Rejoined(..) ->
        Seen(..seen, passages: seen.passages + 1, rejoins: seen.rejoins + 1)
      _ -> seen
    }
    let #(after, effects) = core.step(call, input, clock)
    let seen =
      list.fold(effects, seen, fn(seen, effect) {
        check(call, after, input, seen, effect)
      })
    let seen = released(call, after, effects, seen)
    let seen = found_out(call, after, effects, seen)
    let wait = core.wait_ms(after, clock)
    let seen = case wait >= 1 && wait <= 30_000 {
      True -> seen
      False -> problem(seen, "sleeps " <> int.to_string(wait) <> " ms")
    }
    #(after, seen)
  })
}

/// An offer the step took the call out of, and whether the shard was told
/// the caller left in the same breath.
///
/// A caller found out about is put in the ring they were found in and then
/// hears what arrived meanwhile, all in one step: an offer that step told
/// the dispatcher of, and took the call out of again with the caller
/// leaving, was left ringing too.
fn released(
  before: Call,
  after: Call,
  effects: List(Effect),
  seen: Seen,
) -> Seen {
  let rung = case before.phase {
    core.Offering(offer: offer, ..) -> [offer.id]
    _ -> []
  }
  let found =
    list.filter_map(effects, fn(effect) {
      case effect {
        core.Present(Some(id), types.PresentRinging(..)) -> Ok(id)
        _ -> Error(Nil)
      }
    })
  let left =
    list.any(effects, fn(effect) {
      case effect {
        core.Left(_) -> True
        _ -> False
      }
    })
  // A deserted ring decided in this step: the shard is told the caller
  // left in it, or the offer's end is among its replies.
  let seen =
    list.fold(seen.deserted, Seen(..seen, deserted: []), fn(seen, key) {
      case is_deserted(after, key), left {
        True, _ -> Seen(..seen, deserted: [key, ..seen.deserted])
        False, True -> Seen(..seen, left_ringing: [key, ..seen.left_ringing])
        False, False -> seen
      }
    })
  list.fold(list.append(rung, found), seen, fn(seen, id) {
    let still = case after.phase {
      core.Offering(offer: other, ..) | core.Connected(offer: other, ..) ->
        other.id == id
      _ -> False
    }
    case still, left, is_deserted(after, offer_key(id)) {
      False, True, _ ->
        Seen(..seen, left_ringing: [offer_key(id), ..seen.left_ringing])
      False, False, True ->
        Seen(..seen, deserted: [offer_key(id), ..seen.deserted])
      _, _, _ -> seen
    }
  })
}

/// Whether the call holds the offer's ring as deserted and undecided.
fn is_deserted(call: Call, key: String) -> Bool {
  list.any(call.recalls, fn(recall) {
    offer_key(recall.offer.id) == key && option.is_some(recall.deserted)
  })
}

/// The step that ends the finding out about a caller handed over tells the
/// dispatcher where they stand, or the shard that they left.
fn found_out(
  before: Call,
  after: Call,
  effects: List(Effect),
  seen: Seen,
) -> Seen {
  let told =
    list.any(effects, fn(effect) {
      case effect {
        core.Present(..) | core.Left(_) -> True
        _ -> False
      }
    })
  case before.phase, after.phase, told {
    core.Recovering(..), core.Recovering(..), _ -> seen
    core.Recovering(..), _, False ->
      problem(seen, "found a caller handed over and told nobody")
    _, _, _ -> seen
  }
}

fn problem(seen: Seen, what: String) -> Seen {
  Seen(..seen, problems: [
    "step " <> int.to_string(seen.step) <> ": " <> what,
    ..seen.problems
  ])
}

/// One effect, as the step that made it.
fn check(before: Call, after: Call, input: Input, seen: Seen, effect: Effect) {
  let seen = case
    core.commands_caller(effect)
    && !core.allowed(before.phase, after.phase, effect)
  {
    True ->
      problem(
        seen,
        "sent the caller "
          <> string.inspect(effect)
          <> " going from "
          <> call_script.phase_name(before)
          <> " to "
          <> call_script.phase_name(after),
      )
    False -> seen
  }
  case effect {
    core.Originate(offer, ..) -> {
      let key = offer_key(offer)
      let seen = case dict.get(seen.originated, key) {
        Ok(_) -> problem(seen, "originated " <> key <> " twice")
        Error(Nil) -> seen
      }
      let seen = case input {
        core.Ring(request) if request.offer == offer -> seen
        _ -> problem(seen, "originated " <> key <> " unasked")
      }
      Seen(..seen, originated: dict.insert(seen.originated, key, seen.step))
    }
    core.Tell(offer, reply) -> {
      let key = offer_key(offer)
      let replies = dict.get(seen.replies, key) |> result_or([])
      let seen = told(seen, key, replies, reply)
      Seen(
        ..seen,
        replies: dict.insert(seen.replies, key, list.append(replies, [reply])),
      )
    }
    core.Left(_) -> Seen(..seen, lefts: [seen.step, ..seen.lefts])
    core.Present(offer, presence) -> {
      let seen = Seen(..seen, presents: seen.presents + 1)
      let seen = case seen.presents > seen.rejoins {
        True -> problem(seen, "told the dispatcher more often than rejoined")
        False -> seen
      }
      case offer, presence {
        Some(id), types.PresentRinging(..) ->
          Seen(..seen, found: dict.insert(seen.found, offer_key(id), seen.step))
        // A call found connected was answered where nobody here heard it:
        // its end is the one reply left to come.
        Some(id), types.PresentConnected(agent_id, leg, at, _) ->
          Seen(
            ..seen,
            found: dict.insert(seen.found, offer_key(id), seen.step),
            replies: dict.insert(seen.replies, offer_key(id), [
              types.Answered(agent_id, leg, at),
            ]),
          )
        _, _ -> seen
      }
    }
    core.Barrier(msg_id) ->
      Seen(..seen, barriers: dict.insert(seen.barriers, msg_id, seen.step))
    core.Continue(handoff, branch) -> {
      let barrier = core.barrier_id(handoff)
      let before = dict.get(seen.continues, handoff.id) |> result_or([])
      let seen = case dict.get(seen.barriers, barrier) {
        Error(Nil) ->
          problem(seen, "continued " <> handoff.id <> " unbarriered")
        Ok(_) -> seen
      }
      let seen = case before {
        [] -> seen
        [first, ..] if first == branch -> seen
        _ -> problem(seen, "continued " <> handoff.id <> " on another branch")
      }
      let seen = case list.length(before) >= core.continue_attempts {
        True -> problem(seen, "continued " <> handoff.id <> " too often")
        False -> seen
      }
      let seen = case dict.get(seen.resumes, handoff.id) {
        Ok(_) -> problem(seen, "continued " <> handoff.id <> " after resuming")
        Error(Nil) -> seen
      }
      Seen(
        ..seen,
        continues: dict.insert(
          seen.continues,
          handoff.id,
          list.append(before, [branch]),
        ),
      )
    }
    core.Resume(handoff, _branch) -> {
      let continued = dict.get(seen.continues, handoff.id) |> result_or([])
      let seen = case list.length(continued) == core.continue_attempts {
        True -> seen
        False ->
          problem(seen, "resumed " <> handoff.id <> " before asking enough")
      }
      let seen = case dict.get(seen.resumes, handoff.id) {
        Ok(_) -> problem(seen, "resumed " <> handoff.id <> " twice")
        Error(Nil) -> seen
      }
      Seen(..seen, resumes: dict.insert(seen.resumes, handoff.id, seen.step))
    }
    _ -> seen
  }
}

fn result_or(read: Result(a, Nil), default: a) -> a {
  case read {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

/// A reply, against the replies its offer has had.
fn told(
  seen: Seen,
  key: String,
  before: List(types.OfferReply),
  reply: types.OfferReply,
) -> Seen {
  let ended = list.any(before, is_terminal)
  let answered = list.any(before, is_answer)
  case reply {
    types.OfferRinging(_) ->
      case before {
        [] -> seen
        _ -> problem(seen, key <> " said ringing late")
      }
    types.Answered(..) ->
      case ended || answered {
        True -> problem(seen, key <> " answered after its end")
        False -> seen
      }
    types.Ended(..) ->
      case answered && !ended {
        True -> seen
        False -> problem(seen, key <> " ended unanswered or twice")
      }
    _ ->
      case ended || answered {
        True -> problem(seen, key <> " replied after its end or its answer")
        False -> seen
      }
  }
}

fn is_terminal(reply: types.OfferReply) -> Bool {
  case reply {
    types.OfferRinging(_) | types.Answered(..) -> False
    _ -> True
  }
}

fn is_answer(reply: types.OfferReply) -> Bool {
  case reply {
    types.Answered(..) -> True
    _ -> False
  }
}

/// What the script's end says about every offer, the shard's word and the
/// actor itself.
fn at_the_end(call: Call, seen: Seen) -> Seen {
  let seen = case core.finished(call) {
    True -> seen
    False -> problem(seen, "not finished: " <> call_script.phase_name(call))
  }
  let seen = case seen.deserted {
    [] -> seen
    keys ->
      problem(seen, "deserted and never decided: " <> string.join(keys, ", "))
  }
  let seen = case list.length(seen.lefts) <= seen.passages {
    True -> seen
    False -> problem(seen, "left more often than it joined")
  }
  let seen = case seen.rejoins > 0 && seen.presents == 0 && seen.lefts == [] {
    True -> problem(seen, "a caller handed over was never told of")
    False -> seen
  }
  dict.fold(dict.merge(seen.originated, seen.found), seen, fn(seen, key, _step) {
    let replies = dict.get(seen.replies, key) |> result_or([])
    let terminal = list.filter(replies, is_terminal) |> list.length
    let answered = list.any(replies, is_answer)
    let left_ringing = list.contains(seen.left_ringing, key)
    case terminal, answered, left_ringing {
      1, _, _ -> seen
      0, False, True -> seen
      _, _, _ ->
        problem(
          seen,
          key <> " ended in " <> string.inspect(replies) <> " and no leaving",
        )
    }
  })
}

// --- The property ------------------------------------------------------------

pub fn every_script_keeps_the_promises_test() {
  rng.upto(scripts)
  |> list.each(fn(seed) {
    let #(call, seen) = run(seed)
    let seen = at_the_end(call, seen)
    case seen.problems {
      [] -> Nil
      problems ->
        panic as {
          "seed "
          <> int.to_string(seed)
          <> ": "
          <> string.join(list.reverse(problems), "; ")
        }
    }
  })
}

/// The scripts reach every phase, or the property above proves less than it
/// says.
pub fn the_scripts_reach_every_phase_test() {
  let reached =
    rng.upto(scripts)
    |> list.flat_map(fn(seed) {
      a_script(seed)
      |> list.fold(#(fresh(), []), fn(acc, entry) {
        let #(call, names) = acc
        let #(after, _) = core.step(call, entry.0, at_ms(entry.1))
        #(after, [call_script.phase_name(after), ..names])
      })
      |> fn(result) { result.1 }
    })
    |> list.unique
  list.each(
    [
      "waiting", "ringing", "parking", "connecting", "connected", "leaving",
      "departed", "recovering", "resuming", "done",
    ],
    fn(name) {
      case list.contains(reached, name) {
        True -> Nil
        False -> panic as { "no script reached " <> name }
      }
    },
  )
}
