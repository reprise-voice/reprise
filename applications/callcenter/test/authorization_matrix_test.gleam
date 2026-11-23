//// Who may do what to the call center, as one table: every verb on every
//// path of `queues` and `agents`, asked by a user of the account who is not
//// an administrator, by an account administrator and by a superduper
//// administrator.
////
//// Reading is anybody's with a token for the account. Running the call
//// center -- the queues, their tiers, eavesdrop and pickup, and anybody's
//// availability but one's own -- is an administrator's
//// (`callcenter/permission`). A refusal is a 403 said before anything else
//// about the request, or, for an availability change, a `forbidden`
//// validation error on the property the change was refused for.
////
//// Each row is checked both ways: a row allowed to a role is asked by that
//// role and not refused, and one refused is asked and refused. The other
//// test modules say what an allowed request then does.

import gleam/list
import gleam/string
import kazoo/crossbar
import kazoo/doc
import kazoo/kazoo.{type Kazoo}
import kazoo/testing/fake

import cb_agents
import cb_queues

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const queue = "37139638ff5b68f155d8445178524df1"

/// Jane is an agent and nobody's administrator.
const jane = "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91"

/// John is another agent of the account.
const john = "8bd2ec3c8c8c9b58f7db4c9d1b2e6d3a"

/// Bob is a user of the account who is in no queue yet.
const bob = "0d3e5f7a9b1c2d4e6f8a0b2c4d6e8f0a"

/// The account administrator, who is an agent as well.
const ada = "a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0"

/// The superduper administrator, who is an agent of this account too.
const sam = "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"

pub type Role {
  User
  AccountAdmin
  Superduper
}

fn roles() -> List(Role) {
  [User, AccountAdmin, Superduper]
}

/// Who each role is.
fn who(role: Role) -> String {
  case role {
    User -> jane
    AccountAdmin -> ada
    Superduper -> sam
  }
}

/// What a row allows.
pub type Rule {
  Anybody
  AdminOnly
}

pub type Noun {
  Queues
  Tiers
  Agents
}

pub type Row {
  Row(
    noun: Noun,
    verb: String,
    tokens: List(String),
    body: List(#(String, doc.Value)),
    rule: Rule,
  )
}

/// Every verb on every path, as `allowed_methods` lists them.
fn table(role: Role) -> List(Row) {
  let own = who(role)
  [
    // /queues
    Row(Queues, "GET", [], [], Anybody),
    Row(Queues, "PUT", [], [#("name", doc.String("Sales"))], AdminOnly),
    Row(Queues, "GET", [queue], [], Anybody),
    Row(Queues, "POST", [queue], [#("name", doc.String("Sales"))], AdminOnly),
    Row(Queues, "PATCH", [queue], [#("name", doc.String("Sales"))], AdminOnly),
    Row(Queues, "DELETE", [queue], [], AdminOnly),
    Row(Queues, "GET", [queue, "status"], [], Anybody),
    Row(Queues, "PUT", [queue, "eavesdrop"], supervise(), AdminOnly),
    Row(Queues, "PUT", [queue, "pickup"], supervise(), AdminOnly),
    // /queues/{id}/agents
    Row(Tiers, "GET", [], [], Anybody),
    Row(Tiers, "PUT", [], [#("id", doc.String(bob))], AdminOnly),
    Row(Tiers, "PATCH", [john], [#("level", doc.Int(2))], AdminOnly),
    Row(Tiers, "DELETE", [john], [], AdminOnly),
    // /agents
    Row(Agents, "GET", [], [], Anybody),
    Row(Agents, "GET", [john], [], Anybody),
    Row(Agents, "GET", [john, "status"], [], Anybody),
    Row(Agents, "GET", [john, "log"], [], Anybody),
    Row(Agents, "GET", [john, "stats"], [], Anybody),
    // One's own availability is one's own; anybody else's, and saying a
    // change came from a supervisor, is an administrator's.
    Row(Agents, "PATCH", [own, "status"], available("ui"), Anybody),
    Row(Agents, "PATCH", [john, "status"], available("ui"), AdminOnly),
    Row(Agents, "PATCH", [john, "status"], available("supervisor"), AdminOnly),
    Row(Agents, "PATCH", [own, "status"], available("supervisor"), AdminOnly),
  ]
}

fn supervise() -> List(#(String, doc.Value)) {
  [#("device_id", doc.String("9f8e7d6c")), #("call_id", doc.String("c1"))]
}

fn available(source: String) -> List(#(String, doc.Value)) {
  [#("availability", doc.String("available")), #("source", doc.String(source))]
}

/// The whole table, every role.
pub fn the_matrix_test() {
  list.each(roles(), fn(role) {
    list.each(table(role), fn(row) {
      let answer = ask(role, row)
      let refused = refused(answer)
      let expected = case row.rule, role {
        Anybody, _ -> False
        AdminOnly, User -> True
        AdminOnly, _ -> False
      }
      case refused == expected {
        True -> Nil
        False -> panic as describe(role, row, refused)
      }
      // An allowed request reached the path it asked for: not a 404 for a
      // user or queue the fixtures lack, nor a method the path does not
      // serve, either of which would pass for "not refused" here.
      case refused, system_error(answer) {
        False, Ok("bad_identifier") | False, Ok("invalid_method") -> {
          let message =
            describe(role, row, refused)
            <> " but answered "
            <> string.inspect(system_error(answer))
          panic as message
        }
        _, _ -> Nil
      }
    })
  })
}

/// The table covers every method every path allows: a verb added to a path
/// is a row to add here.
pub fn the_matrix_is_every_method_test() {
  let rows = table(User)
  let covered = fn(noun, tokens: List(String), verb) {
    list.any(rows, fn(row) {
      row.noun == noun
      && row.verb == verb
      && list.length(row.tokens) == list.length(tokens)
      && list.last(row.tokens) == list.last(tokens)
    })
  }
  list.each(
    [[], [queue], [queue, "status"], [queue, "eavesdrop"], [queue, "pickup"]],
    fn(tokens) {
      list.each(cb_queues.allowed_methods(tokens), fn(verb) {
        assert covered(Queues, tokens, verb)
      })
    },
  )
  list.each([[], [john]], fn(tokens) {
    list.each(tier_methods(tokens), fn(verb) {
      assert covered(Tiers, tokens, verb)
    })
  })
  list.each(
    [[], [john], [john, "status"], [john, "log"], [john, "stats"]],
    fn(tokens) {
      list.each(agent_methods(tokens), fn(verb) {
        assert covered(Agents, tokens, verb)
      })
    },
  )
}

/// `allowed_methods` answers for a path length, not a noun: `/agents` and
/// `/queues/{id}/agents` share it. These are the ones each actually serves.
fn tier_methods(tokens: List(String)) -> List(String) {
  case tokens {
    [] -> ["GET", "PUT"]
    _ -> ["PATCH", "DELETE"]
  }
  |> list.filter(list.contains(cb_agents.allowed_methods(tokens), _))
}

fn agent_methods(tokens: List(String)) -> List(String) {
  case tokens {
    [] | [_] -> ["GET"]
    _ -> cb_agents.allowed_methods(tokens)
  }
  |> list.filter(list.contains(cb_agents.allowed_methods(tokens), _))
}

// --- Asking --------------------------------------------------------------------

fn ask(role: Role, row: Row) -> crossbar.Context {
  let #(admin, superduper) = case role {
    User -> #(False, False)
    AccountAdmin -> #(True, False)
    Superduper -> #(False, True)
  }
  let context =
    context_as(account, admin, superduper)
    |> with_auth_user_id(who(role))
    |> with_verb(row.verb)
    |> crossbar.set_req_data(doc.object(row.body))
  case row.noun {
    Queues ->
      context
      // Outside a release a load answers the context it was given, so one
      // holding the queue stands for a load that found it.
      |> crossbar.set_doc(staffed())
      |> crossbar.set_resp_status_success
      |> cb_queues.validate(row.tokens)
    Tiers ->
      context
      |> with_nouns([
        #("agents", row.tokens),
        #("queues", [queue]),
        #("accounts", [account]),
      ])
      |> crossbar.set_doc(staffed())
      |> crossbar.set_resp_status_success
      |> cb_agents.validate_with(datastore(), _, row.tokens)
    Agents ->
      context
      |> with_nouns([#("agents", row.tokens), #("accounts", [account])])
      |> cb_agents.validate_with(datastore(), _, row.tokens)
  }
}

/// A 403, or a change refused on the property it was refused for.
fn refused(answer: crossbar.Context) -> Bool {
  system_error(answer) == Ok("forbidden")
  || list.any(validation_errors(answer), fn(error) { error.1 == "forbidden" })
}

fn describe(role: Role, row: Row, refused: Bool) -> String {
  string.inspect(role)
  <> " "
  <> row.verb
  <> " "
  <> string.inspect(row.noun)
  <> "/"
  <> string.join(row.tokens, "/")
  <> " "
  <> string.inspect(row.body)
  <> case refused {
    True -> " was refused"
    False -> " was allowed"
  }
}

fn datastore() -> Kazoo {
  let f = fake.new()
  list.each([jane, john, bob, ada, sam], fn(user_id) {
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
  fake.put_doc(f, kazoo.account_db(account), staffed())
  fake.kazoo(f)
}

fn staffed() -> doc.Value {
  doc.object([
    #("_id", doc.String(queue)),
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Sales")),
    #(
      "agents",
      doc.List([cb_agents.tier(jane, 1, 1), cb_agents.tier(john, 1, 2)]),
    ),
  ])
}

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
