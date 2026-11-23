# Contributing to Reprise

Reprise is developed at
[github.com/reprise-voice/reprise](https://github.com/reprise-voice/reprise).
Report bugs and propose features in its
[issues](https://github.com/reprise-voice/reprise/issues); send changes as
pull requests against `main`. Report security problems privately, as
[SECURITY.md](SECURITY.md) describes, not in an issue. Everyone taking part
is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).

Reprise is one tree: `core/`, `applications/`, the FreeSWITCH module and the
configurations are committed here, not fetched. Branch from `main`, keep
a change to the directories it concerns, and run the checks below before
opening a pull request. Releases are `v*` tags on `main`.

The tree is distributed under the Mozilla Public License 2.0, and
contributions are accepted under the same license. Keep the license header
on files that have one, and add it to new Erlang files.

## Before you open a pull request

* `make changed` lists what the branch touches against the base branch
  named in `.base_branch`.
* Erlang: `make fmt` (formats the changed files), `make code_checks`,
  `make eunit` (or `make -C applications/<app> eunit` for one
  application), `make elvis`, and [dialyzer](doc/engineering/dialyzer.md)
  on the modules you changed (`make dialyze-changed`).
* Gleam (`core/kazoo_gleam` and the Gleam applications): `make gleam-check`
  runs the manifest check, `gleam format --check` and `gleam test` in every
  Gleam package.
* The FreeSWITCH module: `make test` (and `make test-call-paths` for
  changes to call handling) in the `reprise-freeswitch-dev` image; see
  [doc/building.md](doc/building.md#the-freeswitch-module).
* Documentation: update the application's `doc/` or README with the
  behaviour you changed; `make apis` regenerates schemas and reference docs
  after a schema change.

The coding guidelines below come from upstream Kazoo and still apply to the
Erlang code. Gleam code follows `gleam format` and the conventions in
`core/kazoo_gleam/README.md`.

## Coding Standards

The most important rule: **Be consistent both with your code and the project.**

If, in the project, we have been using a variable name to represent an object, continue that in your code. Attempt to mirror existing conventions first, even if you may not agree with them! We can discuss changing it globally but every effort should be made to have a unified and consistent code base.

The full coding standard that we tend to use, and will likely adapt shortly in our documentation effort, is available [here](https://github.com/inaka/erlang_guidelines).

Some of the highlights:

* Loud errors
  * Don't let unhandled errors and exceptions go unlogged.
  * If it is a log line that requires manual intervention or action, then it should be documented in "runbook" style for a system operator to act upon.
* Keep functions small
  * Try to write functions with a small number of expressions, and that do only one thing. 12 expressions per function except for integration tests is a good measure.
* Maintain existing style
  * When editing a module written by someone else, stick to the style in which it was written. If a project has an overall style, stick to that when writing new modules as well.
* Use your spacebar
  * Surround operators and commas with spaces.
* No trailing whitespace
  * Remove trailing whitespace at the end of lines
  * Remove extraneous endlines at the end of the file
  * One blank line between functions only
* Avoid deep nesting
  * Avoid nesting case or any conditionals. If nesting is required do not exceed three levels. It is better to call a well-named function to encapsulate the decision making of the inner case.
  * An [example](https://github.com/2600hz/kazoo/blob/b7eff7b7a356f38eb3d36100256b660012bb0313/applications/callflow/src/module/cf_park.erl#L67-L106) of nesting that needs refactoring, and the [example refactored](https://github.com/2600hz/kazoo/blob/master/applications/callflow/src/module/cf_park.erl#L67-L106).
* Do not use `if` statements.
  * In some circumstances `if` introduces static boolean logic in your code, reducing code flexibility.
  * In other cases, a case or a function call with pattern matching in its clauses is just more declarative.
  * For newcomers (that have learned to use if in other languages), Erlang's `if` can be either hard to understand or easily abused.
  * `if` only allows guards while `case` allows expressions to be evaluated for branching
* Honor DRY.
  * Don't write the same code in many places, use functions and variables for that.
* More, smaller functions over case expressions
  * Use pattern-matching in function clauses rather than case clauses.
* No God modules
  * Don't design your system using god modules (modules that have a huge number of functions and/or deal with very unrelated things - eg core/whistle/src/wh_util.erl)
* Group modules in subdirectories by functionality
  * When having lots of modules, use subdirectories for them, named with a nice descriptive name for what that "package" does.
* Don't write spaghetti code
  * For example, a list comprehension with a case inside, or blocks with begin/end, and nested stuff
* Don't share your records
  * Records should not be shared among multiple modules. If you need to share objects that are represented as records, use opaque exported types and provide adequate accessor functions in your module.
* Always add types for your records:
  ```erlang
    -record(foo, {bar :: binary()}).
    -type foo() :: #foo{}.
    -type foos() :: [foo()].
   ```
   ```erlang
   -type state() :: #state{}.
   ```
* Types in records
  * Always add type definitions to your record fields
* Properly use logging levels
  * `debug`: Very low-level info, that may cover your screen and don't let you type in it :P
  * `info`: The system's life, in some detail. Things that happen usually, but not all the time. You should be able to use the console with acceptable interruptions in this level.
  * `notice`: Meaningful things that are worth noticing, like the startup or termination of supervisors or important gen_servers, etc…
  * `warning`: Handled errors, the system keeps working as usual, but something out of the ordinary happened
  * `error`: Something bad and unexpected happen, usually an exception or error (DO log the stack trace here)
  * `critical`: The system (or a part of it) crashed and somebody should be informed and take action about it
* Simple unit tests
  * Single responsibility applies to tests as well. When writing unit tests, keep them short and don't put more than 1 or 2 asserts per test

Kazoo conventions:

* Tickie all atoms
  * Use `'foo'` not `foo`
* Write accurate specs for all functions
  * Use the most restrictive type(s) you can.
  ```erlang
  -spec foo(any()) -> any(). % is of no use to anyone!
  ```
  * Run [dialyzer](doc/engineering/dialyzer.md) on any modules you make changes to, plus any modules your new code makes calls to.
* When creating lists or binaries, drop the comma and next element to a new line
  * This includes `-export([...])` directives.
  * No:
  ```erlang
  [this, list, is, wrong]
  ```
  * Yes:
  ```erlang
  [this
  ,list
  ,is
  ,right
  ]
  ```
* Exports should be grouped by functionality.
  * Do not export all functions nor add all exports to a single export directive.
* Code should be self documenting.
  * It is not a forum for you to prove how amazing you are at the language.
  * We always prefer readability over complexity. Which means simple language constructs and explicit variable/function names.
    * `AccountId` instead of `Id` or `AcctId`
* The function name should clearly describe what it will do.
  * Common patterns include:
    * The use of plural to singular. For example, `process_accounts` calls to `process_account` for each account.
    * The use of `maybe_X` executing `X` if a condition is met. For example, `maybe_process_accounts` calls to `process_accounts` if there are accounts present in the system.
* Never introduce a single letter variable.
  * It is marginally acceptable to use a single letter in “inner” scope variables but they should match the first letter of a fully named variable they are shadowing. For example, in the predicate function it is OK to use `A` to represent `Account` if the `Account` variable is used outside the predicate.
* Do not chain functions
  * Do not call the next function of a sequence of functions from the previous function.
  * If you need to chain functions together to make a sequence fold over a list of functions.
  * No:
  ```erlang
  do_x() ->
      X = lookup(),
      do_y(X).
  do_y(X) ->
      Y = transform_x(X),
      do_z(Y).
  do_z(Y) ->
      apply_z(Y).
  ```
  * Yes:
  ```erlang
  do_x() ->
      lists:foldl(fun(F, Acc) -> F(Acc) end, lookup(), [fun do_y/1, do_z/1]).
  ```
* No [magic numbers](https://en.wikipedia.org/wiki/Magic_number_(programming)#Unnamed_numerical_constants) please
  * If you are doing timeouts and similar, there are [macros](core/kazoo_stdlib/include/kz_types.hrl) that can help make it more apparent what the unit of time is, for instance:
  ```erlang
  receive
      X -> do_something_with(X)
  after
      5 * ?MILLISECONDS_IN_SECOND -> fail()
  end
  ```
  Now we can easily see that the receive will block for 5 seconds (but the value is in milliseconds)

Some additional guidance can be found:
* http://www.erlang.se/doc/programming_rules.shtml
* https://www.youtube.com/watch?v=CQyt9Vlkbis

[Elvis](https://github.com/inaka/elvis) enforces part of this style: `make elvis` lints the files changed against the base branch.

## Testing Your Code

**DONT JUST PROVE IT WORKS, PROVE YOU CANT BREAK IT!**

Erlang tests are EUnit (and PropEr where it helps) under each application's
`test/`; Gleam tests are gleeunit under each package's `test/`, mirroring
`src/`, and run against the in-memory fake in `kazoo/testing/fake` rather
than a live datastore or broker.

## Commits and Commit Messages

Please have git set up with consistent user information for each commit in a pull request, preferably with your real name and a working email address.

For quick reference, here are the relevant git commands:

```shell
git config --global user.name "Your Name Comes Here"
git config --global user.email you@yourdomain.example.com
```

Make separate commits for separate changes. If you cannot describe what the commit does in one sentence, it is probably a mix of changes and should be separated into several commits.

The subject line names the area in lower case, then says what is now true as
a declarative sentence, for example
`konami: a transfer is cancelled by the key that started it` or
`callcenter: an exit key pressed while an agent rings is heard at once`.

A well-crafted git commit message is the best way to communicate context about a change to fellow developers (and indeed to their future selves). A diff will tell you what changed, but only the commit message can properly tell you why.

### General Guidelines

Here are some general guidelines for submitting new code.

* Follow the guidelines for writing good commit messages.
* Do not commit commented-out code or files that are no longer needed.
* Check for unnecessary whitespace before committing with git diff --check.
* Run the checks in "Before you open a pull request" yourself; a pull request is reviewed once they pass.
* See [commit guidelines](doc/engineering/commits.md) for more.
* Ensure that each pull request addresses one piece of work.
* Keep the changes in a pull request as concise as possible. If the pull request is a bug fix it should be the simplest possible approach with minimal code changes.
* Rebase the work onto `main` before submitting the pull request.

### Bug Fix Guidelines

Bug fixes must never introduce new features.

Branch from an up-to-date `main` and open the pull request against
`main`.

An appropriate test (unit, quickcheck, shell script) should also be submitted to ensure that the bug is not accidentally reintroduced in the future.

### New Functionality/Features Guidelines

If you are implementing a new feature, also write new test cases. The primary reason for writing test cases is not to prove that the new feature works correctly, but to make sure that it will be noticed if future changes — perhaps to code that seems unrelated — break the feature.

If you are implementing a new feature, also update the documentation to describe the feature. If the documentation belongs to a missing document, such as an addition to an undocumented API it is acceptable to only document the addition. It is nice to create the full missing documentation section ;)

Make sure the patch does not break backward compatibility. In general, we only break backward compatibility in major releases and only for a very good reason and usually after first deprecating the feature one or two releases beforehand.

If you must submit an incompatible change we prefer that the incompatible behaviour require an admin to enable the new functionality via a configuration parameter.

## Be Ego-less

Pulled from [here](https://blog.codinghorror.com/the-ten-commandments-of-egoless-programming/)

### Understand and accept that you will make mistakes.

The point is to find them early, before they make it into production. Fortunately, except for the few of us developing rocket guidance software at JPL, mistakes are rarely fatal in our industry, so we can, and should, learn, laugh, and move on.

### You are not your code.

Remember that the entire point of a review is to find problems, and problems will be found. Don't take it personally when one is uncovered.

### No matter how much "karate" you know, someone else will always know more.

Such an individual can teach you some new moves if you ask. Seek and accept input from others, especially when you think it's not needed.

### Don't rewrite code without consultation.

There's a fine line between "fixing code" and "rewriting code." Know the difference, and pursue stylistic changes within the framework of a code review, not as a lone enforcer. Don’t use a sledgehammer on a problem to try and drive in a finishing nail - if code isn’t doing what you want and you don’t know how it’s supposed to work, ask first.

### Treat people who know less than you with respect, deference, and patience.

Nontechnical people who deal with developers on a regular basis almost universally hold the opinion that we are prima donnas at best and crybabies at worst. Don't reinforce this stereotype with anger and impatience.

### The only constant in the world is change.

Be open to it and accept it with a smile. Look at each change to your requirements, platform, or tool as a new challenge, not as some serious inconvenience to be fought.

### The only true authority stems from knowledge, not from position.

Knowledge engenders authority, and authority engenders respect – so if you want respect in an ego-less environment, cultivate knowledge.

### Fight for what you believe, but gracefully accept defeat.

Understand that sometimes your ideas will be overruled. Even if you do turn out to be right, don't take revenge or say, "I told you so" more than a few times at most, and don't make your dearly departed idea a martyr or rallying cry.

### Don't be "the guy in the room."

Don't be the guy coding in the dark office emerging only to buy cola. The guy in the room is out of touch, out of sight, and out of control and has no place in an open, collaborative environment.

### Be kind to the coder, not to the code.

As much as possible, make all of your comments positive and oriented to improving the code. Relate comments to local standards, program specs, increased performance, etc.

MR: Always think about security; think twice when deciding to hard-code something that can be different in other regions/countries;

### Hold Us Accountable

These are the standards that we set to ourselves as well as our partners. As we push and the demands grow it is easy to forget some of these points in favor of speed or agility. Occasional slips are marginally acceptable but we need to hold all those involved to the same standard. If you see us not adhering to these guidelines call us out on it!  We welcome productive criticism!
