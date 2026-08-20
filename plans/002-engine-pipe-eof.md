# Plan 002: Force EOF on engine pipes after process exit so the runner can never deadlock

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

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `b380f1b`, 2026-08-20

## Why this matters

`EngineProcessRunner.run` drains engine stdout/stderr with two detached tasks
that loop on the blocking `availableData` call, then waits for the process to
exit, then awaits those tasks. `availableData` returns empty (EOF) only when
*every* writer to the pipe closes its end. If the CLI process spawns a
grandchild (a hook, a backgrounded tool, `nohup`, an in-process server) that
inherits the stdout/stderr pipe file descriptors, the write ends stay open
after the child exits. `waitUntilExit()` returns, but the runner is then
parked forever at `await stdoutTask.result` / `await stderrTask.result`
(`EngineSupport.swift:456-457`). Neither timeout can fire (they were already
cancelled), so the run never emits `.completed` or `.failed` and the HUD shows
"running" indefinitely.

The fix: after the process has exited, close the read ends of the pipes from
the parent side. `availableData` on a closed `NSFileHandle` returns empty
immediately, so both drain tasks terminate promptly and the runner always
reaches its terminal event. Closing after `waitUntilExit()` cannot lose
streamed lines: the drain tasks are just finishing whatever is already
buffered.

## Current state

- `Sources/AskDroid/Core/EngineSupport.swift`, `ProcessIO` protocol
  (lines 104–110):

  ```swift
  protocol ProcessIO: AnyObject, Sendable {
      var standardOutput: FileHandle { get }
      var standardError: FileHandle { get }
      func write(_ line: String) throws
      func terminate()
      func waitUntilExit() -> Int32
  }
  ```

- `EngineProcessRunner.run` drain + wait structure (lines 420–457):

  ```swift
  let stdoutTask = Task.detached {
      let reader = LineReader()
      while true {
          let data = process.standardOutput.availableData   // blocking read, no EOF guarantee after child exit
          if data.isEmpty { break }
          for line in reader.push(data) {
              await config.handleLine(line, process, session)
              if await session.isFinished { return }
          }
      }
  }

  let stderrTask = Task.detached { /* ... same loop on standardError ... */ }

  let status = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(returning: process.waitUntilExit())
      }
  }
  acceptTimeout.cancel()
  turnTimeout.cancel()
  _ = await stdoutTask.result     // can hang here forever
  _ = await stderrTask.result
  ```

- `final class FoundationProcess: ProcessIO` (lines 112–145) owns the pipes;
  `standardOutput`/`standardError` are stored `FileHandle` properties.
- `Tests/AskDroidTests/AskDroidTests.swift`, `MockProcess` (lines 534–606)
  implements the `ProcessIO` protocol via the `DroidProcessIO` typealias and
  has `closeStdout()`, `closeStderr()`, and a `setExit(_:)` that does *not*
  close the pipes — which is exactly what the regression test needs.

## Commands you will need

| Purpose   | Command           | Expected on success |
|-----------|-------------------|---------------------|
| Build     | `swift build`     | exit 0              |
| Tests     | `swift test`      | 65 tests executed, 0 failures (1 skipped) plus the new test |

## Scope

**In scope** (the only files you should modify):
- `Sources/AskDroid/Core/EngineSupport.swift`
- `Tests/AskDroidTests/AskDroidTests.swift`

**Out of scope** (do NOT touch, even though they look related):
- `Sources/AskDroid/Core/DroidEngine.swift`, `Sources/AskDroid/Core/PiEngine.swift` — the engines are unchanged; this is purely in the shared runner.
- The `LineReader` type and the timeout tasks.

## Git workflow

- Branch: `advisor/002-engine-pipe-eof`
- Conventional commit, e.g. `fix(engine): close pipes after exit so runner never deadlocks`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add `closeReaders()` to the `ProcessIO` protocol

Add one requirement with a default no-op implementation so unconcerned
conformers keep compiling:

```swift
protocol ProcessIO: AnyObject, Sendable {
    var standardOutput: FileHandle { get }
    var standardError: FileHandle { get }
    func write(_ line: String) throws
    func terminate()
    func waitUntilExit() -> Int32
    /// Force EOF on the read pipes after the child has exited, so blocked
    /// readers return promptly even if a grandchild inherited the write ends.
    func closeReaders()
}

extension ProcessIO {
    func closeReaders() {}
}
```

**Verify**: `swift build` → exit 0 (no conformer yet needs a real
implementation; `FoundationProcess` and `MockProcess` use the default).

### Step 2: Implement it in `FoundationProcess`

```swift
func closeReaders() {
    try? standardOutput.close()
    try? standardError.close()
}
```

**Verify**: `swift build` → exit 0.

### Step 3: Call it from the runner after the process exits

Between `turnTimeout.cancel()` and the two `await … .result` lines, insert:

```swift
// The child is gone; EOF may never arrive if a grandchild inherited the
// pipe write ends, so force it from our side before draining.
process.closeReaders()
```

**Verify**: `swift build` → exit 0. Existing engine state-machine tests must
still pass (`swift test`), because `MockProcess.terminate()` closes the pipes
itself in those flows.

### Step 4: Implement `closeReaders()` in the test double

In `MockProcess`, add:

```swift
func closeReaders() {
    try? standardOutput.close()
    try? standardError.close()
}
```

This mirrors the production implementation so the regression test exercises
the real close path. (`standardOutput`/`standardError` are the pipe read ends
created in `init()`.)

**Verify**: `swift build` → exit 0.

### Step 5: Add the regression test

In `EngineStateMachineTests`, add:

```swift
func testExitWithoutClosingPipesStillCompletes() async {
    // Regression: a grandchild inheriting the stdout/stderr write ends leaves
    // the pipes open after the child exits; the runner must force EOF itself
    // instead of blocking forever draining stdout.
    let launcher = MockLauncher()
    let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
    let box = EventBox()
    let answers = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var settings = Self.makeSettings()
    settings.answersDirectory = answers.path

    let driver = Task.detached {
        await waitForProcesses(launcher, count: 1)
        let process = launcher.processes[0]
        process.feedStdout(#"{"jsonrpc":"2.0","id":"1","result":{"session":{"settings":{"modelId":"gpt-5"}}}}"#)
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"Hello"}}"#)
        try? await Task.sleep(for: .milliseconds(150))
        // Exit WITHOUT closing stdout/stderr: mimics the child gone but the
        // write ends still open (grandchild inherited them).
        process.setExit(0)
    }

    await runEngine(engine, request: DroidRunRequest(prompt: "hi", images: [], settings: settings), box: box)
    await driver.value

    let result = box.snapshot().compactMap { event -> DroidRunResult? in
        if case .completed(_, let r) = event { return r }
        return nil
    }.last
    XCTAssertEqual(result?.text, "Hello")
    try? FileManager.default.removeItem(at: answers)
}
```

Note the deliberate structure: `waitForProcesses` + feeds happen on a detached
driver like the sibling tests in that class (model after
`testCompletedTurnEmitsResult`, lines 727–758).

Sanity check for the executor: before this fix, `testRunIDsAreUniquePerRun`
may still pass because `MockProcess` in those tests calls `setExit` without
closing pipes — meaning they too would hang on the old code. That is expected:
the fix exists precisely to make the unclosed-pipe path resolve, and this new
test locks it in.

**Verify**: `swift test` → all engine tests (including the new one) pass; the
new test completes in well under a few seconds.

## Test plan

- `testExitWithoutClosingPipesStillCompletes` — the regression test above.
- Existing tests in the same class remain the structural pattern for the
  driver task and event assertions.
- Verification: `swift test` → 65 + 1 new test, 0 failures.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0, passes 65 + the 1 new test
- [ ] `grep -n "func closeReaders" Sources/AskDroid/Core/EngineSupport.swift Tests/AskDroidTests/AskDroidTests.swift` shows both implementations
- [ ] `grep -n "process.closeReaders()" Sources/AskDroid/Core/EngineSupport.swift` shows the runner call, placed after the timeout cancels
- [ ] `git status` shows only the in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The runner excerpt at `EngineSupport.swift:420-457` differs from the
  excerpts above (drift — e.g. if the drain logic was restructured).
- `MockProcess` no longer contains `setExit`/`feedStdout`.
- A step's verification fails twice after a reasonable fix attempt.
- Any existing test starts hanging (a suite that never terminates is itself a
  STOP condition — do not add a workaround that leaves it hanging).

## Maintenance notes

- If the runner is ever re-architected (non-blocking reads, `readToEnd`,
  `readabilityHandler`), the invariant to preserve is: *the drain phase must
  terminate once the process has exited, independent of pipe EOF*. This plan
  relies on parent-side close of the read handles; keep that or replace it
  with an equally hard guarantee.
- `MockProcess.closeReaders()` should stay in sync with
  `FoundationProcess.closeReaders()`; both close the two read handles and
  nothing else.
- The Pi engine shares `EngineProcessRunner.run`, so this fix applies to both
  engines without touching either engine file.