//// The agents API: the paths it claims, who may change whose status, and
//// the shapes the log and the counters answer.

import gleam/list
import gleam/option.{None, Some}
import kazoo/crossbar
import kazoo/doc
import kazoo/kazoo.{type Kazoo}
import kazoo/testing/fake

import callcenter/agent_state
import callcenter/agents
import callcenter/types.{Available, LoggedOut, OnBreak}
import cb_agents

const jane = "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91"

const john = "8bd2ec3c8c8c9b58f7db4c9d1b2e6d3a"

/// The methods of a path length, which is all this phase can say: it is
/// given the tokens and not the context, so `/agents` and
/// `/queues/{id}/agents` are one path length to it and the verbs are the
/// union of both. There is no `PUT` or `DELETE` of an agent: making somebody
/// one is an edit of their user document, through `/users`.
pub fn allowed_methods_test() {
  assert cb_agents.allowed_methods([]) == ["GET", "PUT"]
  assert cb_agents.allowed_methods(["u1"]) == ["GET", "PATCH", "DELETE"]
  assert cb_agents.allowed_methods(["u1", "status"]) == ["GET", "PATCH"]
  assert cb_agents.allowed_methods(["u1", "log"]) == ["GET"]
  assert cb_agents.allowed_methods(["u1", "stats"]) == ["GET"]

  assert cb_agents.allowed_methods(["u1", "tiers"]) == []
  assert cb_agents.allowed_methods(["u1", "status", "x"]) == []
}

pub fn resource_exists_test() {
  assert cb_agents.resource_exists(["u1", "status"])
  assert !cb_agents.resource_exists(["u1", "tiers"])
}

/// Which request this is comes from the nouns Crossbar parsed, deepest
/// first: a queue under the agents noun is a tier, and anything else is the
/// account's own agents.
pub fn parent_queue_test() {
  assert cb_agents.parent_queue([
      #("agents", []),
      #("queues", ["q1"]),
      #("accounts", ["a1"]),
    ])
    == Some("q1")
  assert cb_agents.parent_queue([
      #("agents", ["u1"]),
      #("queues", ["q1"]),
      #("accounts", ["a1"]),
    ])
    == Some("q1")

  assert cb_agents.parent_queue([#("agents", []), #("accounts", ["a1"])])
    == None
  assert cb_agents.parent_queue([
      #("agents", ["u1", "status"]),
      #("accounts", ["a1"]),
    ])
    == None
  assert cb_agents.parent_queue([]) == None
}

fn body(fields: List(#(String, doc.Value))) -> doc.Value {
  doc.object(fields)
}

/// An agent changes their own availability and nobody else's.
pub fn an_agent_changes_only_their_own_test() {
  let asked = body([#("availability", doc.String("on_break"))])

  assert cb_agents.requested(asked, Some(jane), jane, False)
    == Ok(cb_agents.Change("on_break", "ui", 0))

  let assert Error(#(property, code, _message)) =
    cb_agents.requested(asked, Some(jane), john, False)
  assert property == ["availability"]
  assert code == "forbidden"
}

/// A supervisor is an account administrator, and may change anybody's.
pub fn a_supervisor_changes_anybodys_test() {
  let asked =
    body([
      #("availability", doc.String("logged_out")),
      #("source", doc.String("supervisor")),
    ])
  assert cb_agents.requested(asked, Some(john), jane, True)
    == Ok(cb_agents.Change("logged_out", "supervisor", 0))
}

/// An agent may not claim the change came from a supervisor, even about
/// themselves: the status log has to be able to tell the two apart.
pub fn an_agent_may_not_claim_supervisor_test() {
  let asked =
    body([
      #("availability", doc.String("available")),
      #("source", doc.String("supervisor")),
    ])
  let assert Error(#(property, code, _message)) =
    cb_agents.requested(asked, Some(jane), jane, False)
  assert property == ["source"]
  assert code == "forbidden"
}

/// A request with no token behind it is nobody, and changes nothing.
pub fn an_anonymous_request_changes_nothing_test() {
  let asked = body([#("availability", doc.String("available"))])
  let assert Error(#(_property, code, _message)) =
    cb_agents.requested(asked, None, jane, False)
  assert code == "forbidden"
}

pub fn the_availability_is_required_and_checked_test() {
  let assert Error(#(property, code, _)) =
    cb_agents.requested(body([]), Some(jane), jane, False)
  assert property == ["availability"]
  assert code == "required"

  let assert Error(#(property, code, _)) =
    cb_agents.requested(
      body([#("availability", doc.String("paused"))]),
      Some(jane),
      jane,
      False,
    )
  assert property == ["availability"]
  assert code == "enum"
}

/// Activity is derived, so `source` names where the choice came from and
/// only the two the API offers are choices.
pub fn the_source_is_checked_test() {
  let assert Error(#(property, code, _)) =
    cb_agents.requested(
      body([
        #("availability", doc.String("available")),
        #("source", doc.String("phone")),
      ]),
      Some(jane),
      jane,
      True,
    )
  assert property == ["source"]
  assert code == "enum"
}

/// The counters an agent who has answered nothing still has, so a client
/// never has to tell absent from none.
pub fn counters_default_to_zero_test() {
  assert cb_agents.to_api(doc.object([]))
    == doc.object([
      #("calls_answered", doc.Int(0)),
      #("talk_time_s", doc.Int(0)),
      #("missed", doc.Int(0)),
      #("last_call_end", doc.Null),
    ])

  assert cb_agents.to_api(
      doc.object([
        #("calls_answered", doc.Int(12)),
        #("talk_time_s", doc.Int(2831)),
        #("missed", doc.Int(1)),
        #("last_call_end", doc.Int(63_929_304_822)),
      ]),
    )
    == doc.object([
      #("calls_answered", doc.Int(12)),
      #("talk_time_s", doc.Int(2831)),
      #("missed", doc.Int(1)),
      #("last_call_end", doc.Int(63_929_304_822)),
    ])
}

/// A range inside one month is one database to read; one that crosses a
/// month boundary is two, and a year of them is twelve.
pub fn months_in_a_range_test() {
  // 2024-01-01, in the Gregorian seconds every stored timestamp is in.
  let january = 63_871_286_400
  let day = 86_400
  assert list.length(cb_agents.months(january, january + day)) == 1
  assert list.length(cb_agents.months(january, january + 40 * day)) == 2
  assert list.length(cb_agents.months(january, january + 365 * day)) == 12

  // A range given backwards is still a range, and one instant is one month.
  assert list.length(cb_agents.months(january, january)) == 1
}

fn a_queue() -> doc.Value {
  doc.object([
    #("_id", doc.String("37139638ff5b68f155d8445178524df1")),
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Support Queue")),
    #(
      "agents",
      doc.List([
        doc.object([
          #("id", doc.String("jane")),
          #("level", doc.Int(1)),
          #("position", doc.Int(1)),
        ]),
        // No level and no position: the schema's defaults apply.
        doc.object([#("id", doc.String("john"))]),
      ]),
    ),
  ])
}

/// An entry that left `level` and `position` out reads as the schema's
/// defaults, so a strategy never sees a tier without them.
pub fn tiers_default_test() {
  let tiers = cb_agents.tiers(a_queue())
  assert list.length(tiers) == 2
  let assert [jane, john] = tiers
  assert doc.get_int(jane, ["level"]) == Ok(1)
  assert doc.get_int(john, ["level"]) == Ok(1)
  assert doc.get_int(john, ["position"]) == Ok(1)
  assert doc.get_string(john, ["id"]) == Ok("john")
}

/// An entry with no `id` names nobody and is not a tier.
pub fn tiers_need_a_user_test() {
  let queue =
    doc.object([
      #("agents", doc.List([doc.object([#("level", doc.Int(2))])])),
    ])
  assert cb_agents.tiers(queue) == []
  assert cb_agents.tiers(doc.object([])) == []
}

pub fn existing_tier_test() {
  let assert Some(jane) = cb_agents.existing_tier(a_queue(), "jane")
  assert doc.get_int(jane, ["position"]) == Ok(1)
  assert cb_agents.existing_tier(a_queue(), "nobody") == None
}

/// Changing one tier leaves the others where they were, which is the whole
/// reason tiers are edited one at a time.
pub fn replace_test() {
  let tiers = cb_agents.tiers(a_queue())
  let changed =
    cb_agents.replace(tiers, "john", with: Some(cb_agents.tier("john", 2, 3)))
  let assert [jane, john] = changed
  assert doc.get_string(jane, ["id"]) == Ok("jane")
  assert doc.get_int(jane, ["level"]) == Ok(1)
  assert doc.get_int(john, ["level"]) == Ok(2)
  assert doc.get_int(john, ["position"]) == Ok(3)
}

pub fn remove_test() {
  let tiers = cb_agents.tiers(a_queue())
  let left = cb_agents.replace(tiers, "jane", with: None)
  let assert [john] = left
  assert doc.get_string(john, ["id"]) == Ok("john")

  // Removing somebody who was never there changes nothing.
  assert cb_agents.replace(tiers, "nobody", with: None) == tiers
}

/// A tier is exactly three fields, whatever the client sent.
pub fn tier_shape_test() {
  assert cb_agents.tier("jane", 2, 5)
    == doc.object([
      #("id", doc.String("jane")),
      #("level", doc.Int(2)),
      #("position", doc.Int(5)),
    ])
}

// --- Who may write -----------------------------------------------------------

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const queue = "37139638ff5b68f155d8445178524df1"

/// A third user of the account, who has no tier yet.
const bob = "0d3e5f7a9b1c2d4e6f8a0b2c4d6e8f0a"

@external(erlang, "crossbar_context_ffi", "context")
fn context_as(
  account_id: String,
  account_admin: Bool,
  superduper_admin: Bool,
) -> crossbar.Context

@external(erlang, "crossbar_context_ffi", "with_verb")
fn with_verb(context: crossbar.Context, verb: String) -> crossbar.Context

@external(erlang, "crossbar_context_ffi", "with_nouns")
fn with_nouns(
  context: crossbar.Context,
  nouns: List(#(String, List(String))),
) -> crossbar.Context

@external(erlang, "crossbar_context_ffi", "with_auth_user_id")
fn with_auth_user_id(
  context: crossbar.Context,
  user_id: String,
) -> crossbar.Context

@external(erlang, "crossbar_context_ffi", "system_error")
fn system_error(context: crossbar.Context) -> Result(String, Nil)

@external(erlang, "crossbar_context_ffi", "validation_errors")
fn validation_errors(context: crossbar.Context) -> List(#(List(String), String))

/// Who is asking: Jane, who is an agent, or an administrator.
type Who {
  Admin
  Superduper
  Jane
}

/// The account's three users, Jane and John agents and Bob not yet.
fn datastore() -> Kazoo {
  let f = fake.new()
  list.each([jane, john, bob], fn(user_id) {
    fake.put_doc(
      f,
      kazoo.account_db(account),
      doc.object([
        #("_id", doc.String(user_id)),
        #("pvt_type", doc.String("user")),
        #("call_center", doc.object([#("agent_ring_timeout", doc.Int(15))])),
      ]),
    )
  })
  fake.kazoo(f)
}

/// The queue with Jane and John in it.
fn staffed() -> doc.Value {
  doc.object([
    #("_id", doc.String(queue)),
    #("pvt_type", doc.String("queue")),
    #(
      "agents",
      doc.List([cb_agents.tier(jane, 1, 1), cb_agents.tier(john, 1, 2)]),
    ),
  ])
}

fn asking(who: Who, verb: String, body: List(#(String, doc.Value))) {
  let #(admin, superduper) = case who {
    Admin -> #(True, False)
    Superduper -> #(False, True)
    Jane -> #(False, False)
  }
  context_as(account, admin, superduper)
  |> with_auth_user_id(jane)
  |> with_verb(verb)
  |> crossbar.set_req_data(doc.object(body))
}

/// A request to the queue's tiers. Outside a release `load_doc` answers the
/// context it was given, so a context that arrives holding the queue with a
/// success status stands for a load that found it.
fn to_tiers(
  who: Who,
  verb: String,
  tokens: List(String),
  body: List(#(String, doc.Value)),
) -> crossbar.Context {
  let context =
    asking(who, verb, body)
    |> with_nouns([
      #("agents", tokens),
      #("queues", [queue]),
      #("accounts", [account]),
    ])
    |> crossbar.set_doc(staffed())
    |> crossbar.set_resp_status_success
  cb_agents.validate_with(datastore(), context, tokens)
}

/// Every write to the tiers, with the path and a body that would be valid.
fn tier_writes() -> List(#(String, List(String), List(#(String, doc.Value)))) {
  [
    #("PUT", [], [#("id", doc.String(bob))]),
    #("PATCH", [jane], [#("level", doc.Int(2))]),
    #("DELETE", [jane], []),
  ]
}

/// Anybody with a token for the account reads a queue's tiers.
pub fn anybody_reads_the_tiers_test() {
  let answer = to_tiers(Jane, "GET", [], [])
  assert crossbar.is_success(answer)
  assert system_error(answer) == Error(Nil)
  let assert doc.List(listed) = crossbar.resp_data(answer)
  assert list.length(listed) == 2
}

/// Adding, moving and removing an agent is running the queue: anybody but
/// an administrator is a 403, the queue is left as it was found, and
/// Crossbar saves nothing after a validate that did not succeed.
pub fn only_an_administrator_changes_the_tiers_test() {
  list.each(tier_writes(), fn(write) {
    let #(verb, tokens, body) = write
    let answer = to_tiers(Jane, verb, tokens, body)
    assert system_error(answer) == Ok("forbidden")
    assert !crossbar.is_success(answer)
    assert crossbar.doc(answer) == staffed()

    list.each([Admin, Superduper], fn(who) {
      let answer = to_tiers(who, verb, tokens, body)
      assert crossbar.is_success(answer)
      assert system_error(answer) == Error(Nil)
      assert crossbar.doc(answer) != staffed()
    })
  })
}

/// The refusal is the first thing said: a tier with no `id` is a 400 for an
/// administrator and still only a 403 for anybody else.
pub fn the_refusal_comes_first_test() {
  let answer = to_tiers(Jane, "PUT", [], [])
  assert system_error(answer) == Ok("forbidden")
  assert validation_errors(answer) == []

  let answer = to_tiers(Admin, "PUT", [], [])
  assert system_error(answer) == Error(Nil)
  assert validation_errors(answer) == [#(["id"], "required")]
}

fn change_status(
  kz: Kazoo,
  who: Who,
  of user_id: String,
  to availability: String,
) -> crossbar.Context {
  let tokens = [user_id, "status"]
  let context =
    asking(who, "PATCH", [#("availability", doc.String(availability))])
    |> with_nouns([#("agents", tokens), #("accounts", [account])])
  cb_agents.validate_with(kz, context, tokens)
}

/// Their own availability is an agent's to change, administrator or not.
pub fn an_agent_changes_their_own_availability_test() {
  let kz = datastore()
  let answer = change_status(kz, Jane, of: jane, to: "available")
  assert crossbar.is_success(answer)
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert state.availability == Available
}

/// Somebody else's is an administrator's, a superduper administrator
/// included.
pub fn only_an_administrator_changes_another_agents_availability_test() {
  let kz = datastore()
  let answer = change_status(kz, Jane, of: john, to: "on_break")
  assert validation_errors(answer) == [#(["availability"], "forbidden")]
  let assert Ok(state) = agent_state.get(kz, account, john)
  assert state.availability == LoggedOut

  let answer = change_status(kz, Superduper, of: john, to: "available")
  assert crossbar.is_success(answer)
  let answer = change_status(kz, Superduper, of: john, to: "on_break")
  assert crossbar.is_success(answer)
  let assert Ok(state) = agent_state.get(kz, account, john)
  assert state.availability == OnBreak
}

// --- A break with an end -------------------------------------------------------

/// `timeout` is the feature code's: seconds, 0 or absent for no end, and
/// nothing but a whole number of them.
pub fn the_timeout_is_checked_test() {
  let on_break = fn(timeout) {
    cb_agents.requested(
      body([#("availability", doc.String("on_break")), #("timeout", timeout)]),
      Some(jane),
      jane,
      False,
    )
  }
  assert on_break(doc.Int(300)) == Ok(cb_agents.Change("on_break", "ui", 300))
  assert on_break(doc.Int(0)) == Ok(cb_agents.Change("on_break", "ui", 0))
  assert on_break(doc.Null) == Ok(cb_agents.Change("on_break", "ui", 0))

  let assert Error(#(property, code, _)) = on_break(doc.Int(-1))
  assert property == ["timeout"]
  assert code == "minimum"
  let assert Error(#(property, code, _)) = on_break(doc.String("ten"))
  assert property == ["timeout"]
  assert code == "type"
}

/// A break is a pause in a login: `on_break` for an agent who is logged out
/// is a 400, `forbidden` on `availability`, for the agent and a supervisor
/// alike and with or without a `timeout`, and nothing is written -- a timed
/// break would otherwise end by logging in somebody who never did.
pub fn a_logged_out_agent_is_refused_a_break_test() {
  let kz = datastore()
  list.each([#(Jane, 0), #(Jane, 600), #(Superduper, 600)], fn(asked) {
    let #(who, timeout) = asked
    let answer =
      change_status_with(kz, who, of: jane, body: [
        #("availability", doc.String("on_break")),
        #("timeout", doc.Int(timeout)),
      ])
    assert !crossbar.is_success(answer)
    assert validation_errors(answer) == [#(["availability"], "forbidden")]
  })
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert state.availability == LoggedOut
  assert state.break_ends == None
}

fn change_status_with(
  kz: Kazoo,
  who: Who,
  of user_id: String,
  body fields: List(#(String, doc.Value)),
) -> crossbar.Context {
  let tokens = [user_id, "status"]
  let context =
    asking(who, "PATCH", fields)
    |> with_nouns([#("agents", tokens), #("accounts", [account])])
  cb_agents.validate_with(kz, context, tokens)
}

/// A break through the API with a timeout stores its end, and the answer
/// and the agent's status say when it is. Anything else ends the end.
pub fn a_break_through_the_api_has_an_end_test() {
  let kz = datastore()
  let assert True =
    crossbar.is_success(change_status(kz, Jane, of: jane, to: "available"))

  let answer =
    change_status_with(kz, Jane, of: jane, body: [
      #("availability", doc.String("on_break")),
      #("timeout", doc.Int(900)),
    ])
  assert crossbar.is_success(answer)
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert state.availability == OnBreak
  let assert Some(ends) = state.break_ends
  assert ends - state.timestamp == 900
  assert doc.get_int(crossbar.resp_data(answer), ["break_ends"]) == Ok(ends)

  let answer = change_status(kz, Jane, of: jane, to: "available")
  assert crossbar.is_success(answer)
  assert doc.get(crossbar.resp_data(answer), ["break_ends"]) == Error(Nil)
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert state.break_ends == None
}

/// A timeout on anything but a break is nothing.
pub fn a_timeout_on_anything_but_a_break_is_nothing_test() {
  let kz = datastore()
  let answer =
    change_status_with(kz, Jane, of: jane, body: [
      #("availability", doc.String("available")),
      #("timeout", doc.Int(900)),
    ])
  assert crossbar.is_success(answer)
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert state.availability == Available
  assert state.break_ends == None
}

// --- Deleted and disabled users ------------------------------------------------

/// Jane deleted by Crossbar's soft delete, John disabled, Bob as he was.
fn with_leavers() -> Kazoo {
  let f = fake.new()
  let user = fn(user_id, fields) {
    doc.object([
      #("_id", doc.String(user_id)),
      #("pvt_type", doc.String("user")),
      #("call_center", doc.object([#("agent_ring_timeout", doc.Int(15))])),
      ..fields
    ])
  }
  fake.put_doc(
    f,
    kazoo.account_db(account),
    user(jane, [#("pvt_deleted", doc.Bool(True))]),
  )
  fake.put_doc(
    f,
    kazoo.account_db(account),
    user(john, [#("enabled", doc.Bool(False))]),
  )
  fake.put_doc(f, kazoo.account_db(account), user(bob, []))
  fake.kazoo(f)
}

fn read_agent(kz: Kazoo, user_id: String) -> crossbar.Context {
  let tokens = [user_id]
  let context =
    asking(Admin, "GET", [])
    |> with_nouns([#("agents", tokens), #("accounts", [account])])
  cb_agents.validate_with(kz, context, tokens)
}

/// A deleted user is no agent, whichever way they are asked for: the
/// listing's view leaves them out, and one read by id is a 404, as it would
/// be had the document gone. A disabled one is still an agent -- their tiers
/// are kept for when they are enabled again -- and every listing marks them
/// `enabled: false`, beside the availability that says they are logged out.
pub fn a_deleted_user_is_no_agent_and_a_disabled_one_is_marked_test() {
  let kz = with_leavers()
  assert agents.fetch(kz, account, jane) == Error(kazoo.NotFound)
  assert system_error(read_agent(kz, jane)) == Ok("bad_identifier")

  let answer = read_agent(kz, john)
  assert crossbar.is_success(answer)
  assert doc.get_bool(crossbar.resp_data(answer), ["enabled"]) == Ok(False)
  assert doc.get_bool(crossbar.resp_data(read_agent(kz, bob)), ["enabled"])
    == Ok(True)
}

/// A disabled user may be logged out and nothing else: a login or a break
/// is a 400, `forbidden` on `availability`, and nothing is written. A
/// deleted one is a 404, as every read of them is.
pub fn a_disabled_user_may_only_be_logged_out_test() {
  let kz = with_leavers()
  list.each(["available", "available_on_demand", "on_break"], fn(to) {
    let answer = change_status(kz, Superduper, of: john, to: to)
    assert !crossbar.is_success(answer)
    assert validation_errors(answer) == [#(["availability"], "forbidden")]
  })
  assert agent_state.availability_of(kz, account, john) == LoggedOut

  let answer = change_status(kz, Superduper, of: john, to: "logged_out")
  assert crossbar.is_success(answer)

  let answer = change_status(kz, Superduper, of: jane, to: "available")
  assert system_error(answer) == Ok("bad_identifier")
  assert agent_state.availability_of(kz, account, jane) == LoggedOut

  let answer = change_status(kz, Superduper, of: bob, to: "available")
  assert crossbar.is_success(answer)
}

/// Bob, with do-not-disturb set on his user.
fn bob_on_dnd(kz: Kazoo) -> Nil {
  let db = kazoo.account_db(account)
  let assert Ok(bob_user) = kz.datamgr.open_doc(db, bob)
  let assert Ok(_) =
    kz.datamgr.save_doc(
      db,
      doc.set(
        bob_user,
        ["do_not_disturb"],
        doc.object([#("enabled", doc.Bool(True))]),
      ),
    )
  Nil
}

/// A user on do-not-disturb is refused as a disabled one is: a login, on
/// demand and a break are a 400, `forbidden` on `availability`, saying why,
/// and nothing is written; logged out is allowed.
pub fn a_user_on_do_not_disturb_may_only_be_logged_out_test() {
  let kz = with_leavers()
  bob_on_dnd(kz)
  list.each(["available", "available_on_demand", "on_break"], fn(to) {
    let answer = change_status(kz, Superduper, of: bob, to: to)
    assert !crossbar.is_success(answer)
    assert validation_errors(answer) == [#(["availability"], "forbidden")]
  })
  assert agent_state.availability_of(kz, account, bob) == LoggedOut

  let answer = change_status(kz, Superduper, of: bob, to: "logged_out")
  assert crossbar.is_success(answer)
}

/// Who the dispatcher may offer a caller to: somebody there, enabled and
/// not on do-not-disturb. A user nobody could read is taken as there, since
/// a datastore that did not answer has said nothing about them.
pub fn who_can_be_offered_test() {
  let kz = with_leavers()
  let db = kazoo.account_db(account)
  assert !agents.can_be_offered(kz.datamgr.open_cache_doc(db, jane))
  assert !agents.can_be_offered(kz.datamgr.open_cache_doc(db, john))
  assert agents.can_be_offered(kz.datamgr.open_cache_doc(db, bob))
  bob_on_dnd(kz)
  assert !agents.can_be_offered(kz.datamgr.open_cache_doc(db, bob))
  assert !agents.can_be_offered(Error(kazoo.NotFound))
  assert agents.can_be_offered(Error(kazoo.Unavailable))
}

/// A deleted user is taken out of a queue's tiers, and nobody else is.
pub fn a_tier_is_taken_out_of_a_queue_test() {
  let queue =
    doc.object([
      #(
        "agents",
        doc.List([cb_agents.tier(jane, 1, 1), cb_agents.tier(john, 2, 1)]),
      ),
    ])
  assert agents.without_tier(queue, jane)
    == doc.object([#("agents", doc.List([cb_agents.tier(john, 2, 1)]))])
  assert agents.without_tier(queue, bob) == queue
}
