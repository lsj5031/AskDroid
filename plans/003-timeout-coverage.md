# Plan 003: Expose engine timeout constants for tests and cover the timeout branches

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: This repo may have uncommitted working-tree
> changes (the ongoing AskDroid refactor round). The excerpts below describe
> the *current working tree*. Compare each excerpt against the live file
> before starting. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `b380f1b`, 2026-08-20

## Why this matters

`EngineProcessRunner.Configuration` already accepts
`acceptTimeoutSeconds`/`turnTimeoutSeconds`, but both engines hardcode 25 s
and 600 s when they build the configuration, and nothing can shorten them from
a test. The two timeout failure branches of the runner
(`acceptTimeout`/`turnTimeout`, `EngineSupport.swift:402-418`) therefore have
zero test coverage: the only way to exercise them today would be to wait 25 s
or 10 minutes in a test. Making the values per-request (defaulting to the
current constants) lets tests cover both branches in about a second each,
protecting the most failure-prone part of the state machine against future
refactors.

## Current state

- `Sources/AskDroid/Core/EngineSupport.swift`, `EngineRequest` (lines 62–66):

  ```swift
  struct EngineRequest: Sendable {
      var prompt: String
      var images: [AttachedImage]
      var settings: AppSettings
  }
  ```

- Pi engine hardcodes the timeouts (`Sources/AskDroid/Core/PiEngine.swift`,
  lines 79–93):

  ```swift
  let config = EngineProcessRunner.Configuration(
      engine: .pi,
      request: request,
      runID: runID,
      initialActivity: "Opening a Pi session…",
      sendInitialMessage: { … },
      acceptTimeoutMessage: "Pi did not accept the prompt in time.",
      turnTimeoutMessage: "Pi did not finish in 10 minutes.",
      acceptTimeoutSeconds: 25,   // hardcoded — not in excerpt above because…
      turnTimeoutSeconds: 600,    // …the init signature in EngineSupport.swift:347-360 declares defaults 25/600
      …
  ```

  (The `Configuration` initializer has default parameter values
  `acceptTimeoutSeconds: Int = 25` and `turnTimeoutSeconds: Int = 600`; the
  engines rely on those defaults today.)

- Droid engine does the same (`Sources/AskDroid/Core/DroidEngine.swift`,
  lines 78–92) with `acceptTimeoutMessage: "Droid did not start a session in time."`
  and `turnTimeoutMessage: "Droid did not finish in 10 minutes."`.

- The runner uses the values in the two timeout tasks (`EngineSupport.swift:402-418`)
  and the terminal failure path surfaces `session.lastError`
  (`EngineSupport.swift:461-463`), so a timeout surfaces as `.failed(runID, message)`.

- Test infrastructure ready to reuse:
  `MockLauncher`/`MockProcess`/`EventBox` and `waitForProcesses` in
  `Tests/AskDroidTests/AskDroidTests.swift`, plus the existing Droid engine
  state-machine tests in `EngineStateMachineTests`.

## Commands you will need

| Purpose   | Command           | Expected on success |
|-----------|-------------------|---------------------|
| Build     | `swift build`     | exit 0              |
| Tests     | `swift test`      | 65 tests executed, 0 failures (1 skipped) plus the 2 new tests |

## Scope

**In scope** (the only files you should modify):
- `Sources/AskDroid/Core/EngineSupport.swift`
- `Sources/AskDroid/Core/PiEngine.swift`
- `Sources/AskDroid/Core/DroidEngine.swift`
- `Tests/AskDroidTests/AskDroidTests.swift`

**Out of scope** (do NOT touch, even though they look related):
- The `EngineProcessRunner.run` logic and the timeout task bodies themselves.
- `AppSettings` — do not add timeout fields there; the request already travels
  through `EngineRequest`.

## Git workflow

- Branch: `advisor/003-timeout-coverage`
- Conventional commit, e.g. `test(engine): cover accept and turn timeout branches`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add per-request timeout fields

In `EngineSupport.swift`, extend `EngineRequest` with the current constants as
defaults:

```swift
struct EngineRequest: Sendable {
    var prompt: String
    var images: [AttachedImage]
    var settings: AppSettings
    var acceptTimeoutSeconds: Int = 25
    var turnTimeoutSeconds: Int = 600
}
```

Swift's memberwise initializer keeps the existing 3-argument call sites
working because the new parameters have defaults. Verify that.

**Verify**: `swift build` → exit 0 with no call-site changes anywhere.

### Step 2: Wire the request values into both engines

In `PiEngine.swift`, inside the `Configuration(...)` call, replace the two
`acceptTimeoutSeconds`/`turnTimeoutSeconds` arguments (or, if the call relies
on the defaults and passes none, add them):

```swift
acceptTimeoutSeconds: request.acceptTimeoutSeconds,
turnTimeoutSeconds: request.turnTimeoutSeconds,
```

Same in `DroidEngine.swift`.

**Verify**: `swift build` → exit 0. Existing tests must still pass —
`EngineRequest` built in tests uses the defaults, so behavior is unchanged.

### Step 3: Add the accept-timeout test

In `EngineStateMachineTests`, add:

```swift
func testAcceptTimeoutEmitsTimeoutFailure() async {
    let launcher = MockLauncher()
    let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
    let box = EventBox()
    var settings = Self.makeSettings()
    let answers = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    settings.answersDirectory = answers.path
    var request = DroidRunRequest(prompt: "hi", images: [], settings: settings)
    request.acceptTimeoutSeconds = 1
    request.turnTimeoutSeconds = 30

    // No init response at all: the accept timeout must fire on its own.
    await runEngine(engine, request: request, box: box)

    let failure = box.snapshot().compactMap { event -> String? in
        if case .failed(_, let message) = event { return message }
        return nil
    }.last
    XCTAssertEqual(failure, "Droid did not start a session in time.")
    XCTAssertTrue(launcher.processes[0].terminated)
    try? FileManager.default.removeItem(at: answers)
}
```

No driver task is needed: the runner self-terminates the process when the
accept timeout fires, so `runEngine` returns by itself (the MockProcess write
ends close on `terminate()`, unblocking the drain tasks).

**Verify**: `swift test` → the new test passes and completes in ~1–2 s.

### Step 4: Add the turn-timeout test

Add the counterpart that passes the acceptance phase and then stalls:

```swift
func testTurnTimeoutEmitsTimeoutFailure() async {
    let launcher = MockLauncher()
    let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
    let box = EventBox()
    var settings = Self.makeSettings()
    let answers = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    settings.answersDirectory = answers.path
    var request = DroidRunRequest(prompt: "hi", images: [], settings: settings)
    request.acceptTimeoutSeconds = 30
    request.turnTimeoutSeconds = 1

    let driver = Task.detached {
        await waitForProcesses(launcher, count: 1)
        let process = launcher.processes[0]
        process.feedStdout(#"{"jsonrpc":"2.0","id":"1","result":{"session":{"settings":{"modelId":"gpt-5"}}}}"#)
    }

    await runEngine(engine, request: request, box: box)
    await driver.value

    let failure = box.snapshot().compactMap { event -> String? in
        if case .failed(_, let message) = event { return message }
        return nil
    }.last
    XCTAssertEqual(failure, "Droid did not finish in 10 minutes.")
    try? FileManager.default.removeItem(at: answers)
}
```

(Acceptance is satisfied by the init response; with no further messages the
turn timeout fires after 1 s.)

**Verify**: `swift test` → the new test passes in ~1–2 s; the full suite still
runs with 0 failures.

## Test plan

- `testAcceptTimeoutEmitsTimeoutFailure` and
  `testTurnTimeoutEmitsTimeoutFailure` as specified above.
- Structural pattern: `EngineStateMachineTests` siblings like
  `testCompletedTurnEmitsResult` (lines 727–758).
- Verification: `swift test` → 65 + 2 new tests, 0 failures, both new tests
  finishing in seconds (proving the timeouts actually took effect).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0, passes 65 + the 2 new tests in seconds
- [ ] `grep -rn "acceptTimeoutSeconds" Sources/AskDroid/Core/` shows the field in `EngineRequest` and both engines reading `request.acceptTimeoutSeconds`
- [ ] Existing 3-argument `EngineRequest(...)` call sites compile unchanged
- [ ] `git status` shows only the in-scope files modified (4 files)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `EngineRequest` struct in `EngineSupport.swift:62-66` differs from the
  excerpt (drift).
- Adding defaulted members to `EngineRequest` breaks existing 3-argument call
  sites (unexpected — the language shouldn't allow it; if it does, report).
- The accept-timeout test hangs rather than completing (the timeout tasks
  were changed between plan time and execution).
- The illustrative test asserts `failure == "Droid did not start a session in time."`
  but the live message text has drifted — then adjust to the *actual current*
  message string and note it in the report, do not invent a different behavior.

## Maintenance notes

- The timeout messages are still the literal "10 minutes" texts; with
  injectable durations that wording is now technically wrong for tests but
  remains correct for production defaults. Re-parameterize the messages only if
  a future plan makes durations user-configurable.
- If `AppSettings` ever grows per-user timeout settings, the natural migration
  is to compute these `EngineRequest` fields from settings at `submit()` time
  in `AskSession`.