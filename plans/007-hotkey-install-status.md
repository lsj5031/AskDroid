# Plan 007: Surface Carbon handler-install failure in the hotkey conflict notice

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
- **Category**: bug
- **Planned at**: commit `b380f1b`, 2026-08-20

## Why this matters

`HotkeyCenter.register` installs the Carbon event handler and registers the
hotkey, but only checks `registerStatus`. If `InstallEventHandler` fails yet
`RegisterEventHotKey` succeeds, the hotkey is registered at the Carbon level
but no event handler will ever dispatch it — the global hotkey is silently
dead (only the local-monitor fallback works while AskDroid is focused).
Because `register` returns `registerStatus` (likely `noErr`), `AppDelegate`
never shows its "could not exclusively register" notice, so the user has no
signal that the hotkey is broken. Surface the failure the same way as a
registration conflict.

## Current state

- `Sources/AskDroid/App/HotkeyCenter.swift`, the registration body
  (lines 19–64); the relevant portion:

  ```swift
  let installStatus = InstallEventHandler(GetEventDispatcherTarget(), { … }, 1, &eventType, userData, &handler)
  // handler is a var EventHandlerRef?; untouched if install fails

  let hotKeyID = EventHotKeyID(signature: OSType(0x41534B44), id: 1) // ASKD
  let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
  AskLog.line("hotkey carbon install=\(installStatus) register=\(registerStatus) key=\(keyCode) mods=\(modifiers)")
  if registerStatus != noErr {
      AskLog.line("hotkey carbon failed; local monitor is the fallback while AskDroid is focused")
  }

  localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { … }
  return registerStatus
  ```

- The caller in `Sources/AskDroid/App/AskDroidApp.swift` (lines 112–132)
  treats a non-`noErr` return as a conflict:

  ```swift
  if status != noErr {
      session.notice = "Could not exclusively register \(session.settings.hotkeyDisplay). Another app may already own that shortcut."
      AskLog.line("hotkey register failed status=\(status)")
  } else if session.notice?.contains("Could not exclusively register") == true {
      session.notice = nil
  }
  ```

  So the fix is just to return `installStatus` when it is non-zero (and to
  unregister the hotkey ref so `unregister()` doesn't touch a hotkey whose
  dispatcher never runs).

## Commands you will need

| Purpose   | Command           | Expected on success |
|-----------|-------------------|---------------------|
| Build     | `swift build`     | exit 0              |
| Tests     | `swift test`      | 65 tests executed, 0 failures (1 skipped) |

## Scope

**In scope** (the only file you should modify):
- `Sources/AskDroid/App/HotkeyCenter.swift`

**Out of scope** (do NOT touch, even though they look related):
- `Sources/AskDroid/App/AskDroidApp.swift` — the conflict-notice path already
  exists and is correct; it just never receives the failure status today.
- `Sources/AskDroid/HUD/HotkeyRecorder.swift`, `SettingsPane.swift`.

## Git workflow

- Branch: `advisor/007-hotkey-install-status`
- Conventional commit, e.g. `fix(hotkey): report handler-install failures like registration conflicts`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fail registration when the handler cannot be installed

In `register(...)`, after the `RegisterEventHotKey` call and the logging, add
a check for `installStatus`:

```swift
if installStatus != noErr {
    // InstallEventHandler failed: even a successful RegisterEventHotKey will
    // never dispatch, so unregister the ref and fail loudly like a conflict.
    if let hotKeyRef {
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }
    self.handler = nil
    AskLog.line("hotkey carbon handler install failed status=\(installStatus); local monitor fallback only")
}
```

and change the return so the caller surfaces this state:

```swift
return installStatus != noErr ? installStatus : registerStatus
```

Keep the local-monitor registration exactly where it is (it is the fallback
while the app is focused, and it should be installed even on failure).

**Verify**: `swift build` → exit 0.

### Step 2: Run the full suite

The change is Carbon-side and not exercised by the current test suite; the
build plus suite is the gate.

**Verify**: `swift test` → 65 tests, 0 failures.

## Test plan

- No new unit tests: `HotkeyCenter` drives the Carbon API directly and can't
  be mocked without a protocol seam that would be over-engineering for a
  three-line change (recorded as accepted debt).
- Existing coverage unaffected: no test touches `HotkeyCenter`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0, 65 tests, 0 failures
- [ ] `grep -n "installStatus != noErr" Sources/AskDroid/App/HotkeyCenter.swift` shows the guard
- [ ] `grep -n "return installStatus != noErr ? installStatus : registerStatus" Sources/AskDroid/App/HotkeyCenter.swift` shows the return shape
- [ ] `git status` shows only `Sources/AskDroid/App/HotkeyCenter.swift` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The registration body at `HotkeyCenter.swift:19-64` differs from the excerpt
  (drift).
- The compiler rejects the optional-binding `if let hotKeyRef` (it shouldn't —
  `hotKeyRef` is `EventHotKeyRef?`).
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

- The notice text ("Another app may already own that shortcut") is now also
  used for a failed handler install. If that leads to user confusion, split the
  copy in `AskDroidApp.swift` — out of scope here, but the seam (a non-zero
  status) already supports it.
- The local monitor fallback remains installed in every path, so a broken
  global hotkey still works while AskDroid is focused — the notice tells the
  user why it only works "inside" AskDroid.
- If the app ever moves to `CGEventTap` or multi-modifier registration, the
  same rule applies: a registration that cannot dispatch must report failure,
  not silently succeed.