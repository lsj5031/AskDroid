# Plan 005: Deduplicate the tool-activity label mapping

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

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `b380f1b`, 2026-08-20

## Why this matters

Two nearly identical `toolName → label` switch statements exist:
`EngineSupport.activityLabel` and `DroidEngine.activityLabel`. They have
already drifted: `EngineSupport` maps `find` to "Searching…", the Droid copy
doesn't. Every future label addition must be made in two places and the drift
shows the discipline is already failing. `PiEngine.activityLabel` was already
collapsed to a one-line forwarder to `EngineSupport` — Droid should be
collapsed the same way so there is exactly one mapping.

## Current state

- `Sources/AskDroid/Core/EngineSupport.swift`, canonical mapping (lines 294–311):

  ```swift
  static func activityLabel(for toolName: String) -> String {
      switch toolName.lowercased() {
      case "read", "readfile", "read_file":
          "Reading files…"
      case "grep", "rg", "search", "search_files", "find":
          "Searching…"
      case "glob", "ls", "list", "list_files":
          "Listing files…"
      case "execute", "execute-cli", "bash", "shell":
          "Running a command…"
      case "applypatch", "apply_patch", "edit", "write":
          "Editing…"
      case "web_search":
          "Searching the web…"
      default:
          toolName.isEmpty ? "Working…" : "Using \(toolName)…"
      }
  }
  ```

- `Sources/AskDroid/Core/DroidEngine.swift`, the drift copy (lines 277–294):

  ```swift
  static func activityLabel(for toolName: String) -> String {
      switch toolName.lowercased() {
      case "read", "readfile", "read_file":
          "Reading files…"
      case "grep", "rg", "search", "search_files":        // ← no "find"
          "Searching…"
      case "glob", "ls", "list", "list_files":
          "Listing files…"
      case "execute", "execute-cli", "bash", "shell":
          "Running a command…"
      case "applypatch", "apply_patch", "edit", "write":
          "Editing…"
      case "web_search":
          "Searching the web…"
      default:
          toolName.isEmpty ? "Working…" : "Using \(toolName)…"
      }
  }
  ```

- The precedent to match: `PiEngine.activityLabel` (PiEngine.swift:323-325)
  is already a one-line forwarder:

  ```swift
  static func activityLabel(for toolName: String) -> String {
      EngineSupport.activityLabel(for: toolName)
  }
  ```

- `Tests/AskDroidTests/AskDroidTests.swift:182-186` asserts on the Droid
  label (the forwarder keeps these passing; the only behavior change is that
  `find` now also becomes "Searching…" for Droid, which is the intended
  alignment).

## Commands you will need

| Purpose   | Command           | Expected on success |
|-----------|-------------------|---------------------|
| Build     | `swift build`     | exit 0              |
| Tests     | `swift test`      | 65 tests executed, 0 failures (1 skipped) |

## Scope

**In scope** (the only file you should modify):
- `Sources/AskDroid/Core/DroidEngine.swift`

**Out of scope** (do NOT touch, even though they look related):
- `Sources/AskDroid/Core/EngineSupport.swift` — the canonical mapping stays
  as-is; do not rename or reorder it.
- `Sources/AskDroid/Core/PiEngine.swift` — already a forwarder.
- Any test file — existing `testActivityLabels` covers the forwarder.

## Git workflow

- Branch: `advisor/005-activity-label-dedup`
- Conventional commit, e.g. `refactor(engine): reuse EngineSupport activity labels from DroidEngine`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the DroidEngine body with the forwarder

Replace the entire switch body of `DroidEngine.activityLabel` (lines 277–294)
with:

```swift
static func activityLabel(for toolName: String) -> String {
    EngineSupport.activityLabel(for: toolName)
}
```

Keep the function signature exactly as-is — callers and the test reference
`DroidEngine.activityLabel`.

**Verify**: `swift build` → exit 0.

### Step 2: Confirm the Droid label behavior is still covered

`swift test` (runs `testActivityLabels`, which calls `DroidEngine.activityLabel`
and asserts "Reading files…", "Searching…", "Using CustomTool…").

**Verify**: `swift test` → 65 tests, 0 failures.

### Step 3: (Assigning behavior alignment) Verify the `find` alignment

The only externally visible change is that `DroidEngine.activityLabel(for: "find")`
now returns "Searching…" instead of "Using find…". That is the point of the
dedup. No further change needed — do not add "find" to any other switch, since
the canonical mapping already has it.

**Verify**: `grep -n "activityLabel" Sources/AskDroid/Core/DroidEngine.swift`
shows exactly one `static func activityLabel`, body is the one-line forwarder.

## Test plan

- No new tests: the existing `testActivityLabels` (AskDroidTests.swift:182-186)
  exercises the forwarder through both engines' public entry points.
- Verification: `swift test` → all pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0, 65 tests, 0 failures
- [ ] `grep -n "Searching…" Sources/AskDroid/Core/DroidEngine.swift` returns no matches (the switch is gone)
- [ ] `grep -rn "activityLabel" Sources/AskDroid/Core/EngineSupport.swift Sources/AskDroid/Core/DroidEngine.swift Sources/AskDroid/Core/PiEngine.swift` shows one canonical switch + two one-line forwarders
- [ ] `git status` shows only `Sources/AskDroid/Core/DroidEngine.swift` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `DroidEngine.activityLabel` is no longer at `DroidEngine.swift:277-294` or
  has a different signature (drift).
- Any test fails after the dedup (it should not — the canonical mapping
  satisfies every assertion).
- The canonical `EngineSupport.activityLabel` mapping has gained or lost cases
  compared to the excerpt (then align against the *live* canonical version and
  note it).

## Maintenance notes

- Future label additions happen in exactly one place:
  `EngineSupport.activityLabel`. If per-engine differences are ever needed,
  revisit this: a single mapping can't express engine-specific labels.
- Reviewers should flag any new `switch` on tool names that appears in engine
  or HUD code — that's the drift this plan eliminates.
- The nickname "Using X…" fallback and the empty-name "Working…" case come
  from the canonical mapping automatically for both engines.