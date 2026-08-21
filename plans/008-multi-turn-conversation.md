# Plan 008: Keep talking to the agent — persistent multi-turn conversation

> **Executor instructions**: Follow this plan phase by phase. Each phase ends
> with a verification gate; do not start the next phase until the current one
> is green. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: The excerpts below were taken from the working
> tree at the commit named in Status. Compare each excerpt against the live
> file before starting. On a mismatch, treat it as a STOP condition.
>
> **This plan conflicts with plans 002 and 003.** Both touch
> `EngineProcessRunner.run`, which Phase 1 restructures. Read "Interaction with
> plans 002 and 003" before writing code.

## Status

- **Priority**: P1
- **Effort**: XL (phased; Phases 1–5 are the minimum shippable slice)
- **Risk**: MEDIUM
- **Depends on**: none (but see the 002/003 conflict note)
- **Category**: feature
- **Planned at**: commit `1d8cad0`, 2026-08-21
- **Baseline verified**: `swift build` exit 0; `swift test` → 65 tests, 1
  skipped, 0 failures

## Why this matters

AskDroid is one-shot by construction. Every `submit()` wipes the answer and
spawns a brand-new CLI process; both engines are killed the instant the turn
ends. You cannot ask a follow-up question. For an ambient HUD whose whole
premise is "ask the agent something," the inability to say "no, I meant the
other file" is the single largest functional gap.

The important discovery: **both CLIs already support multi-turn on one
process.** No protocol invention is required, no conversation-replay hack, no
prompt-stuffing. The current code is throwing away a live, context-carrying
session after every turn. This plan stops doing that.

## Verified evidence (re-runnable)

Everything in this section was confirmed on the wire against the installed
CLIs on 2026-08-21, not inferred from documentation. An executor who doubts a
claim should re-probe before redesigning around it.

**Droid** (`droid exec --input-format stream-jsonrpc --output-format
stream-jsonrpc`), single process:

| Probe | Result |
|-------|--------|
| Two `droid.add_user_message` calls on one process | Both completed |
| `agent_turn_completed.reason` values observed | `"completed"` and `"error"` |
| Process alive after turn 1 | `True` |
| Context carryover ("remember PELICAN" → "what was the word?") | Replied `PELICAN` |
| `droid.get_context_stats` | `{"used":14601,"remaining":907399,"limit":922000,"accuracy":"estimated"}` |

**Pi** (`pi --mode rpc --no-session`), single process:

| Probe | Result |
|-------|--------|
| Three `prompt` commands on one process | All three settled |
| Context carryover | Replied `PELICAN` |
| `new_session` then re-ask | No longer knew the word — context cleared, process never restarted |
| Process alive after each `agent_settled` | `True` |

**Method surface** — `strings` on the droid binary lists these JSON-RPC
methods, which is why a turn is not the end of a session:

```
droid.add_user_message      droid.close_session       droid.interrupt_session
droid.compact_session       droid.get_context_stats   droid.get_context_breakdown
droid.load_session          droid.fork_session        droid.rename_session
droid.resolve_queued_user_message                     droid.change_working_directory
```

**Pi's RPC contract** is documented on disk at
`$(dirname $(readlink -f $(which pi)))/../docs/rpc.md`. Read it before
touching `PiEngine`. Key points for this plan: `prompt` is repeatable;
`--no-session` disables *disk* persistence only (Pi's own interactive example
client passes it); `new_session` resets context in-process; `steer` /
`follow_up` / `streamingBehavior` provide mid-run input; `abort` stops a turn.

**Corrections to earlier assumptions** (do not reintroduce these):

- `--no-session` does **not** prevent multi-turn. Keep the flag.
- Conversation-history replay (stuffing prior turns into the prompt string) is
  **not** a fallback for either engine. It is strictly worse and unnecessary.
- Process death recovery is **not** transcript replay. Both CLIs resume
  natively by session id (`droid -s/--session-id`, `droid.load_session`; Pi
  `--session-id` / `switch_session`).
- Context growth is **not** an unsolved risk. `droid.compact_session` and Pi
  `compact` / `set_auto_compaction` (default on) exist.
- Do **not** name the new client method `followUp` — Pi already has a
  `follow_up` command with different delivery semantics.

## Product decisions (settled with the operator — do not relitigate)

1. **Transcript**: collapsed history. Only the newest turn renders full-size;
   older turns collapse to a one-line row that expands on demand. The
   collapsed row *is* the "question as a line" that `DESIGN.md` already
   specifies, so the 280 pt answer viewport cap survives.
2. **Cancel**: interrupts the turn and **keeps the session alive**. Cancel must
   stop being "kill the process."
3. **Steering**: in scope. Typing while the agent works is included.

## Interaction with plans 002 and 003

- **002 (force EOF on pipes after exit)**: its invariant still matters, but
  Phase 1 moves the exit-wait off the completion path, so the `closeReaders()`
  call site changes. If 002 has already landed, keep `closeReaders()` and call
  it from the new death-watch. If 002 has not landed, implement
  `closeReaders()` as part of Phase 1 Step 4 and mark 002 as superseded in
  `plans/README.md` rather than doing it twice.
- **003 (expose timeout constants)**: Phase 1 replaces the single-shot
  `turnTimeout` with a per-turn timer. If 003 has landed, keep its injectable
  constants and re-point them at the per-turn timer. If not, add the timeouts
  to the new `Configuration` with `internal` visibility so 003 becomes a no-op.

## Current state

### The runner treats process exit as the end of the run

`Sources/AskDroid/Core/EngineSupport.swift`, `EngineProcessRunner.run`
(anchors: `enum EngineProcessRunner` line 332, `static func run(` line 376,
`let stdoutTask` line 420, `waitUntilExit()` line 451):

```swift
let stdoutTask = Task.detached {
    let reader = LineReader()
    while true {
        let data = process.standardOutput.availableData
        if data.isEmpty { break }
        for line in reader.push(data) {
            await config.handleLine(line, process, session)
            if await session.isFinished { return }   // <- reader dies at turn 1
        }
    }
}

let status = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: process.waitUntilExit())   // <- completion path
    }
}
```

Three structural problems: the reader returns on the first completed turn; the
function's return is gated on process exit; and `run()` is the only entry
point, so there is no way to send a second message.

### Both engines kill the session at turn end

`DroidEngine.swift` line 218, inside `case .turnCompleted`:

```swift
await session.complete(durationMs: durationMs, tokenUsage: usage)
await EngineSupport.emitCompletion(session: session, runID: runID, engine: Engine.droid, onEvent: onEvent)
process.terminate()          // <- discards a live, context-carrying session
```

`PiEngine.swift` line 274, `case "agent_settled"`:

```swift
case "agent_settled":
    if await session.lastError == nil {
        await session.complete()
        await EngineSupport.emitCompletion(session: session, runID: runID, engine: Engine.pi, onEvent: onEvent)
    }
    process.terminate()      // <- same
```

### `agent_turn_completed.reason` is dropped (pre-existing bug)

`Sources/AskDroid/Core/JSONRPC.swift` line 130:

```swift
case "agent_turn_completed":
    return .turnCompleted(
        durationMs: doubleValue(payload["durationMs"]),
        tokenUsage: tokenUsage(from: payload["tokenUsage"])
    )
```

A real captured failure payload (unreachable model on the probing machine):

```json
{"type":"agent_turn_completed","reason":"error","turnId":"e141747a-…",
 "tokenUsage":{"inputTokens":0,"outputTokens":0}}
```

Because `reason` is ignored, an errored turn is reported as a successful turn
with no text, and `AskSession.emptyAnswerMessage()` shows "ended the turn
without writing an answer" instead of the actual `Connection error.` that
arrived moments earlier. In multi-turn this is worse: an errored turn must not
tear the session down.

### Hardcoded request ids

- `DroidEngine.swift` line 172: `id: "2"` for every user message (and `"1"`
  for initialize).
- `PiEngine.swift` line 299: `"id": "1"` inside `promptParams` for every
  prompt.

Multi-turn needs unique ids or responses cannot be correlated.

### Cancel kills the process

`AskSession.swift` line 174 `cancelRun()` cancels the task and calls
`client.cancel(runID:)`; `DroidEngine.cancel` (line 16) goes straight to
`process.terminate()`; `PiEngine.cancel` (line 16) writes `abort` and *then*
terminates anyway, discarding the session it just cleanly stopped.

### `RunSession` conflates session and turn scope

`EngineSupport.swift` line 177. Session-scoped: `didInitialize`, `model`,
`request`. Turn-scoped: `answer`, `tokenUsage`, `startedAt`, `lastError`,
`finished`, `hasStreamedText`.

### `submit()` hard-blocks during a run

`AskSession.swift` line 137: `guard canSubmit, phase != .running else { return }`,
followed by a block that clears `answer`, `thinking`, `runLog`, `archiveURL`,
`tokenSummary`, `durationText`.

### Already correct — do not "fix" these

- `LineReader` (`EngineSupport.swift`, near the end) splits on `0x0A` only and
  strips a trailing `\r`. Pi's spec explicitly warns that readers splitting on
  `U+2028`/`U+2029` are non-compliant. This implementation is correct.
- `--no-session` on Pi. Keep it.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build   | `swift build` | exit 0 |
| Tests   | `swift test`  | 65 baseline tests + this plan's new tests, 0 failures |
| Pi spec | `cat "$(dirname "$(readlink -f "$(which pi)")")/../docs/rpc.md"` | the RPC contract |
| Droid methods | `strings -a "$(which droid)" \| grep -oE '"?droid\.[a-z_]+' \| tr -d '"' \| sort -u` | method list |

## Scope

**In scope**:
- `Sources/AskDroid/Core/EngineSupport.swift`
- `Sources/AskDroid/Core/DroidEngine.swift`
- `Sources/AskDroid/Core/PiEngine.swift`
- `Sources/AskDroid/Core/JSONRPC.swift`
- `Sources/AskDroid/Core/AnswerArchive.swift`
- `Sources/AskDroid/App/AskSession.swift`
- `Sources/AskDroid/App/AskDroidApp.swift` (reposition sinks only)
- `Sources/AskDroid/HUD/HUDRootView.swift`
- `Tests/AskDroidTests/AskDroidTests.swift`
- `DESIGN.md` (Surfaces list — Phase 6)

**Out of scope**:
- `NotchPanelController`, `NotchMetrics`, `NotchShape`, `PanelLayout`,
  `SurfaceGuard`, `Theme` — panel geometry and the notch math stay as they are.
- `HotkeyCenter`, `HotkeyRecorder`, `AppSettings` persistence keys.
- `AttachedImage`, `BinaryDiscovery`.
- Session *resumption across app restarts*. The session id is retained in
  memory only (see Maintenance notes for the follow-up).

## Git workflow

- Branch: `advisor/008-multi-turn-conversation`
- One conventional commit per phase, e.g.
  `refactor(engine): keep the CLI process alive across turns`,
  `feat(engine): interrupt a turn without ending the session`,
  `feat(hud): collapsed conversation transcript`.
- Do NOT push or open a PR unless the operator instructed it.

---

## Phase 0 — Spike: droid mid-run queueing (gate for Phase 7 only)

Everything else in this plan is wire-verified. This is not.

`droid.resolve_queued_user_message` was found only in a `strings` dump. Its
direction (client→agent request, or agent→client request needing a reply) and
its params are unknown. Pi's steering is documented, but was not exercised.

1. Probe Pi first: start `pi --mode rpc --no-session`, send a long-running
   prompt, then send
   `{"type":"prompt","message":"…","streamingBehavior":"steer"}` mid-stream.
   Confirm the response is `success: true` and that a `queue_update` event
   arrives. Note that omitting `streamingBehavior` during streaming is a
   documented error.
2. Probe droid: during a live turn, send a second `droid.add_user_message` and
   record what comes back. Watch for any agent→client request whose method is
   `droid.resolve_queued_user_message`.

**Gate**: if droid queueing cannot be established in one focused session, ship
Phase 7 for Pi only and record droid steering as a follow-up plan. Do not
block Phases 1–6 on this.

---

## Phase 1 — Persistent runner lifecycle

The one genuinely hard piece. Goal: the process outlives a turn; turn
completion is a protocol event, not process exit.

### Step 1.1 — Split `RunSession`

Replace the single actor with two:

```swift
/// Lives as long as the CLI process.
actor EngineSession {
    let engine: Engine
    let settings: AppSettings
    private(set) var sessionID: String?      // droid sessionId / pi sessionId
    private(set) var model: String?
    private(set) var didInitialize = false
    private(set) var didAccept = false
    private(set) var isClosed = false
    private(set) var nextRequestID = 1       // monotonic, replaces hardcoded ids

    func claimRequestID() -> String { defer { nextRequestID += 1 }; return String(nextRequestID) }
}

/// Lives for exactly one turn.
actor TurnState {
    let turnID: UUID
    let request: EngineRequest
    private(set) var startedAt: Date
    private(set) var answer = ""
    private(set) var tokenUsage: TokenUsage?
    private(set) var lastError: String?
    private(set) var outcome: TurnOutcome?    // .completed | .failed | .interrupted
    private(set) var log: [String] = []       // per-turn, fixes diagnostics bleed
}
```

`TurnState.log` matters: `AskSession.emptyAnswerMessage()` currently reads the
session-wide `runLog`, so without this the "connection error" heuristic would
match a *previous* turn's log.

**Verify**: `swift build` exit 0 (temporarily keep `RunSession` as a
deprecated alias if it shortens the transition, then delete it before the
phase gate).

### Step 1.2 — Turn-scoped completion signal

`EngineSession`/`TurnState` must let a handler say "this turn ended" without
saying "this process ended". Add to the runner's configuration:

```swift
/// Called by the engine's line handler when a turn reaches a terminal state.
/// The runner finalizes the turn and returns to idle — the process keeps running.
let onTurnEnd: @Sendable (TurnState, TurnOutcome) async -> Void
```

### Step 1.3 — Restructure the reader

The stdout reader becomes process-lifetime, not turn-lifetime. Remove
`if await session.isFinished { return }`. The loop exits only on EOF.

```swift
let stdoutTask = Task.detached {
    let reader = LineReader()
    while true {
        let data = process.standardOutput.availableData
        if data.isEmpty { break }               // EOF == process gone, only exit
        for line in reader.push(data) {
            await config.handleLine(line, process, sessionState)
        }
    }
}
```

### Step 1.4 — Death-watch instead of completion-wait

`waitUntilExit()` moves into a supervisory task that reports *unexpected*
exit:

```swift
let deathWatch = Task.detached {
    let status = await withCheckedContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async {
            c.resume(returning: process.waitUntilExit())
        }
    }
    process.closeReaders()          // see plan 002 — force EOF from our side
    _ = await stdoutTask.result
    _ = await stderrTask.result
    await config.onProcessExit(status)
}
```

`onProcessExit` distinguishes: expected (we called `close()`), or unexpected
(crash → surface a failure and mark the session dead so the next `send()`
relaunches).

### Step 1.5 — Per-turn timeout

The single-shot 600 s `turnTimeout` becomes a timer started per turn and
cancelled on turn end. The 25 s accept timeout stays session-scoped (it guards
initialization).

**Phase 1 gate**: `swift build` exit 0; `swift test` → 65 baseline tests pass
unchanged. Behavior is still one-shot at this point because the engines still
call `terminate()`; that is expected and correct for this gate.

> **Test-harness warning for later phases**: `MockProcess.feedStdout` guards on
> `!didExit`, and `runEngine` awaits `engine.run(...)` to completion. Once
> `run()` stops returning at turn end, that helper will hang. Phase 3 must add
> a non-blocking variant (start the session, drive turns, then close) rather
> than reusing `runEngine` for multi-turn tests.

---

## Phase 2 — `EngineClient` surface

Replace the one-shot protocol (`EngineSupport.swift` line 4):

```swift
protocol EngineClient: AnyObject, Sendable {
    /// Launch the CLI and initialize a session. Idempotent per handle.
    func begin(settings: AppSettings, onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> SessionHandle

    /// Send a new turn on an existing session.
    func send(_ request: EngineRequest, turnID: UUID, to handle: SessionHandle) async

    /// Deliver input while a turn is streaming (Phase 7).
    func queue(_ request: EngineRequest, to handle: SessionHandle) async throws

    /// Stop the current turn. The session stays usable.
    func interrupt(_ handle: SessionHandle) async

    /// Clear conversation context without relaunching the process.
    func reset(_ handle: SessionHandle) async

    /// Graceful shutdown.
    func close(_ handle: SessionHandle) async
}
```

Keep the legacy `run(_:runID:onEvent:)` as a thin convenience
(`begin` → `send` → await turn end → `close`) so existing tests and the
`Droid*` typealias facade keep compiling. `plans/README.md` records those
typealiases as intentionally retained.

`EngineEvent` gains turn identity and new terminal cases:

```swift
enum EngineEvent: Sendable {
    case sessionReady(SessionHandle, model: String?)
    case started(UUID)
    case activity(UUID, String)
    case thinking(UUID, String)
    case textDelta(UUID, String)
    case log(UUID, String)
    case completed(UUID, EngineResult)
    case failed(UUID, String)
    case interrupted(UUID)                       // NEW: turn stopped, session alive
    case contextStats(used: Int, limit: Int)      // NEW: footer meta
    case queueChanged([String])                   // NEW: Phase 7
    case sessionEnded(String?)                    // NEW: reason, nil = clean
}
```

**Phase 2 gate**: `swift build` exit 0; `swift test` unchanged at 65.

---

## Phase 3 — Droid engine

### Step 3.1 — Stop killing the session

Delete `process.terminate()` from `case .turnCompleted` (line 218). Call
`onTurnEnd` instead.

### Step 3.2 — Honor `reason`

`JSONRPC.swift` line 130:

```swift
case "agent_turn_completed":
    return .turnCompleted(
        reason: payload["reason"] as? String,        // "completed" | "error" | …
        durationMs: doubleValue(payload["durationMs"]),
        tokenUsage: tokenUsage(from: payload["tokenUsage"])
    )
```

In `DroidEngine.handle`, `reason == "error"` ends the turn as `.failed`,
preferring any `error` notification text already captured this turn over a
generic message. **The session stays open.**

### Step 3.3 — Monotonic ids

Replace `id: "1"` / `id: "2"` with `await session.claimRequestID()`. The
`stringID(message["id"]) == "1"` / `== "2"` branches become a pending-request
map (id → kind), since ids are no longer fixed.

### Step 3.4 — Real interrupt

```swift
func interrupt(_ handle: SessionHandle) async {
    try? handle.process.write(try JSONRPC.encodeLine(JSONRPC.request(
        id: await handle.session.claimRequestID(),
        method: "droid.interrupt_session", params: [:])))
}
```

No `terminate()`. `close()` sends `droid.close_session`, then terminates after
a short grace period.

### Step 3.5 — Reset and context stats

`reset()` closes the session and initializes a fresh one on the same process
if droid permits it; otherwise relaunch. Verify against the real CLI. After
each turn end, send `droid.get_context_stats` and emit `.contextStats`.

Also stop discarding `session_title_updated` (currently falls into `.ignored`)
— route it to a milestone the HUD header can use.

**Phase 3 gate**: `swift build` exit 0. New tests:
`testDroidServesTwoTurnsOnOneProcess`,
`testDroidErrorReasonFailsTurnButKeepsSessionAlive`,
`testDroidInterruptDoesNotTerminateProcess`.

---

## Phase 4 — Pi engine

### Step 4.1 — Stop killing the session

Delete `process.terminate()` from `case "agent_settled"` (line 279). Call
`onTurnEnd`. Keep `--no-session`.

Distinguish the two events precisely, per Pi's spec: `agent_end` is one
low-level run (retry/compaction may follow); `agent_settled` is the real turn
boundary. The current code already keys off `agent_settled` — preserve that.

### Step 4.2 — Unique prompt ids

`promptParams` (line 299) takes an id parameter instead of hardcoding `"1"`.

### Step 4.3 — Interrupt without terminate

`cancel` becomes `interrupt`: write `{"type":"abort"}` and stop. Remove the
follow-on `terminate()`. `plans/README.md` lists the
"abort-then-terminate race" as harmless-and-retained; this plan supersedes
that note, so update it.

### Step 4.4 — Reset via `new_session`

```swift
func reset(_ handle: SessionHandle) async {
    try? handle.process.write(try Self.encodeJSON(["type": "new_session"]))
}
```

Verified: this clears context in-process.

### Step 4.5 — Context stats

After each turn end, send `{"type":"get_session_stats"}` and emit
`.contextStats` from `data.contextUsage` (`tokens`, `contextWindow`,
`percent`). Per the spec, `contextUsage` can be absent and its fields can be
`null` immediately after compaction — handle both.

**Phase 4 gate**: `swift build` exit 0. New tests:
`testPiServesTwoTurnsOnOneProcess`,
`testPiNewSessionClearsContextWithoutRelaunch`,
`testPiAbortKeepsProcessAlive`.

---

## Phase 5 — `AskSession` transcript

### Step 5.1 — Turn model

```swift
struct Turn: Identifiable, Equatable {
    let id: UUID
    var question: String
    var images: [AttachedImage]
    var answer: String
    var thinking: String
    var log: [String]
    var status: Status          // .running | .completed | .failed | .interrupted
    var errorMessage: String?
    var durationText: String?
    var tokenSummary: String?
    var archiveURL: URL?
}
```

`AskSession` gains `@Published var transcript: [Turn] = []`. Keep `answer`,
`activity`, and `phase` as computed conveniences over the newest turn where
that avoids churning `HUDRootView` and `ScreenshotRender` — but the newest
turn is the source of truth.

### Step 5.2 — `submit()` no longer wipes history

Append a new `Turn` instead of clearing state. Do not clear `transcript`.
`prompt` and `images` clear (the composer empties); everything else moves into
the turn.

If no session exists, `begin()` first, then `send()`. If a session exists,
`send()` directly.

### Step 5.3 — New `.interrupted` phase

Add to `Phase` (line 8). `cancelRun()` becomes `interruptTurn()`: calls
`engine.interrupt`, marks the turn `.interrupted`, sets `phase` so the
composer is immediately usable. It must **not** set `errorMessage` to
"Cancelled." as though the conversation ended.

### Step 5.4 — `resetComposer()` → `startNewConversation()`

Calls `engine.reset(handle)`, clears `transcript`. The footer's existing "New"
button maps here. Retain a `newTurn()`-style path for simply clearing the
composer without dropping context.

### Step 5.5 — Idle timeout and engine switch

An idle timer (start at 10 minutes; expose as a constant, not a literal)
calls `close()` and retains `sessionID`. Switching engines in Settings closes
the current session; the transcript is cleared because sessions are
engine-specific.

Guard the `.completed` / `.failed` / `.interrupted` late-event paths on turn
id: `AskSession.handle` currently compares against a single `currentRunID`
(and has a `notifyLateArchive` path for stragglers). With a persistent
session, events must be routed to the turn they belong to.

**Phase 5 gate**: `swift build` exit 0. New tests:
`testFollowUpKeepsPriorTurnsInTranscript`,
`testInterruptLeavesSessionUsableForNextTurn`,
`testStartNewConversationClearsTranscript`,
`testEngineSwitchClosesSession`.

**This is the minimum shippable slice.** Phases 6–8 are additive.

---

## Phase 6 — HUD: collapsed transcript

`HUDRootView.swift`. Current structure: `showingResult` chooses between
`composer` and `questionLine` + `answerBlock` + `footer`.

### Step 6.1 — Collapsed rows

Above the newest turn, render one row per prior turn: status glyph, question
truncated to a single line, duration. Tap expands to reveal that turn's
answer. Reuse the visual language of the existing `questionLine` (13 pt,
`Theme.mute`) — per `DESIGN.md` the question-as-a-line already exists, so this
is a repetition of an established row, not a new component.

### Step 6.2 — Newest turn unchanged

Full-size in the existing `answerBlock`, keeping `.frame(maxHeight: 280)` and
`.defaultScrollAnchor(.bottom)`. The collapsed rows scroll with it inside one
`ScrollView` so the panel does not grow unbounded.

### Step 6.3 — Composer persists after completion

After a turn completes, the composer stays available below the transcript
instead of the surface being replaced. "Ask" sends a follow-up; "New" starts a
fresh conversation.

### Step 6.4 — Footer context meta

Add a context-fill `MetaLabel` from `.contextStats`. In a notch panel where
the conversation scrolls out of view, this is the one number worth surfacing.

### Step 6.5 — Fix the reposition sinks

`AskDroidApp.swift` observes `session.$answer.map { !$0.isEmpty }`, which only
fires on the empty→non-empty edge and will not track a growing transcript.
Add a sink on `transcript.count` and on the expanded/collapsed row set.

### Step 6.6 — Update `DESIGN.md`

The **Surfaces** list currently reads "Completed answer with copy / open
file". Add the multi-turn surface and describe the collapsed row in
**Components**. The file carries an `impeccable:design-schema 1` marker, so
keep the existing section structure and terminology.

**Phase 6 gate**: `swift build` exit 0; `swift test` green; `DESIGN.md`
updated.

---

## Phase 7 — Steering (gated by Phase 0)

### Step 7.1 — `submit()` branches on phase

Replace `guard canSubmit, phase != .running else { return }` with: if a turn
is streaming, `queue()`; otherwise `send()`.

### Step 7.2 — Pi

Send `prompt` with `streamingBehavior: "steer"`. Omitting it during streaming
is a documented error, so the flag is mandatory on this path. Surface
`queue_update` as `.queueChanged`.

### Step 7.3 — Droid

Per Phase 0's findings. If droid queueing is not established, disable steering
for droid (`queue()` throws a typed "not supported on this engine" error and
the composer keeps its current block) and file a follow-up plan.

### Step 7.4 — Pending indicator

Show queued messages under the composer so a steered message is visibly
pending rather than apparently lost.

**Phase 7 gate**: `swift build` exit 0. New test:
`testSteeredMessageQueuesWhileTurnIsRunning`.

---

## Phase 8 — Archive and polish

### Step 8.1 — Archive the conversation

`AnswerArchive.write` takes the whole transcript. The markdown grows a
`## Turn N` structure with per-turn Question/Answer. Keep the existing
`uniqueBaseName` prefix scheme and image naming so the answers directory stays
backward compatible.

Decide and document: append to the same file as the conversation grows, or
write once at conversation end. Prefer rewriting the same file per turn so a
crash mid-conversation still leaves the turns so far on disk.

### Step 8.2 — Session title

Use droid's `session_title_updated` / Pi's `set_session_name` for the HUD
header and the archive filename.

**Phase 8 gate**: `swift build` exit 0; `swift test` green.

---

## Test plan

Add to `EngineStateMachineTests` and `AskSessionTests`. The existing harness
(`MockProcess` line 534, `MockLauncher` line 608, `EventBox` line 633,
`waitForProcesses` line 654, `runEngine` line 661) is the pattern to follow —
with the Phase 1 caveat that `runEngine` blocks until `run()` returns and so
cannot drive a multi-turn session.

Required new coverage:

| Test | Locks in |
|------|----------|
| `testDroidServesTwoTurnsOnOneProcess` | one process, two `.completed`, no terminate between |
| `testPiServesTwoTurnsOnOneProcess` | same for Pi |
| `testDroidErrorReasonFailsTurnButKeepsSessionAlive` | `reason:"error"` → `.failed`, session usable |
| `testDroidInterruptDoesNotTerminateProcess` | `interrupt_session` written, process alive |
| `testPiAbortKeepsProcessAlive` | `abort` written, no terminate |
| `testPiNewSessionClearsContextWithoutRelaunch` | `new_session` written, launcher count still 1 |
| `testFollowUpKeepsPriorTurnsInTranscript` | history not wiped |
| `testInterruptLeavesSessionUsableForNextTurn` | `.interrupted` then a successful turn |
| `testStartNewConversationClearsTranscript` | reset semantics |
| `testUnexpectedProcessExitFailsTurnAndMarksSessionDead` | crash handling |
| `testPerTurnLogDoesNotLeakIntoNextTurnDiagnostics` | the `emptyAnswerMessage()` heuristic |
| `testSteeredMessageQueuesWhileTurnIsRunning` | Phase 7 (Pi at minimum) |

Assert on **bytes written to the mock** (`MockProcess.written`) for the
interrupt/reset/close paths — that is what distinguishes "interrupted the
turn" from "killed the session," and it is the regression most likely to
silently reappear.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; 65 baseline tests still pass; every test in the
      table above present and passing
- [ ] `grep -c "process.terminate()" Sources/AskDroid/Core/DroidEngine.swift
      Sources/AskDroid/Core/PiEngine.swift` shows no occurrence inside the
      turn-completion handlers (`case .turnCompleted` / `case "agent_settled"`)
- [ ] `grep -n "droid.interrupt_session\|droid.close_session" Sources/AskDroid/Core/DroidEngine.swift` shows both
- [ ] `grep -n "new_session" Sources/AskDroid/Core/PiEngine.swift` shows the reset path
- [ ] `grep -n "reason" Sources/AskDroid/Core/JSONRPC.swift` shows `agent_turn_completed` parsing it
- [ ] `grep -n '"id": "1"' Sources/AskDroid/Core/PiEngine.swift` returns nothing
- [ ] `grep -n "no-session" Sources/AskDroid/Core/PiEngine.swift` still shows the flag
- [ ] `grep -n "case interrupted" Sources/AskDroid/App/AskSession.swift` shows the new phase
- [ ] `DESIGN.md` Surfaces list includes the multi-turn surface
- [ ] `git status` shows only in-scope files modified
- [ ] `plans/README.md` status row updated, and the two superseded notes
      (002 placement, Pi abort-then-terminate) amended

## STOP conditions

Stop and report back (do not improvise) if:

- Any excerpt above does not match the live file (drift).
- Removing `if await session.isFinished { return }` from the stdout reader
  makes any existing test hang. A hanging suite is itself a STOP condition —
  do not paper over it with a sleep or a timeout bump.
- `droid.interrupt_session` turns out to end the session rather than the turn.
  The whole cancel decision rests on it; re-probe and report before
  redesigning.
- Pi's `new_session` does not clear context on the installed version (it did
  when probed — a change means the CLI moved under us).
- An engine cannot serve a second turn on one process. That contradicts direct
  observation; suspect a code error first, but if the CLI genuinely regressed,
  stop — this plan's premise is gone.
- Phase 0's droid queueing probe is inconclusive: do not guess at the
  `resolve_queued_user_message` contract. Ship Pi-only steering.

## Maintenance notes

- **The invariant to protect**: a turn ending and a session ending are
  different events. Every future change to the runner, the engines, or cancel
  must preserve that separation. The regression that will keep trying to come
  back is a stray `process.terminate()` on a turn-terminal path.
- **Session resumption across app restarts** is deliberately out of scope but
  now cheap: both CLIs resume by id (`droid -s`/`droid.load_session`, Pi
  `--session-id`/`switch_session`). Persist `sessionID` in `AppSettings` and
  reattach on launch. Natural follow-up plan.
- **Compaction** is available (`droid.compact_session`, Pi `compact` /
  `set_auto_compaction`, default on). Once context-fill is visible in the
  footer, a manual "Compact" affordance is a small addition.
- **Do not reintroduce** conversation-history replay, `--no-session` removal,
  or a `followUp()` method name. The reasoning is in "Corrections to earlier
  assumptions" above.
- **Re-probing** is cheap and documented in "Verified evidence". Prefer a
  30-second probe against the real CLI over reasoning about the protocol from
  the Swift code.
- **Machine-specific note for whoever probes**: on the machine where this plan
  was written, droid's default model was a custom local MLX endpoint at
  `192.168.1.111` that was unreachable, producing `Connection error.` turns.
  Pass an explicit reachable `modelId` (e.g. `"auto"`) in
  `initialize_session` params when probing, or you will misread a network
  failure as a protocol failure.
