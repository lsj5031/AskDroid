# Plan 004: Test the SettingsStore migration paths

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
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `b380f1b`, 2026-08-20

## Why this matters

`SettingsStore.load(from:)` silently migrates old stored values on first load
after an upgrade: a stored implicit `autonomy` of `""` (the old "Droid
default") becomes `.high`, and legacy `~`/home/folder or `~/Droid-Answers`
paths are rewritten to the App Support defaults. These migrations change what
the user gets on their next launch, and they mutate the store — yet none of
them have a single test. A regression here would silently re-point answers at
the wrong folder or reset autonomy on upgrade. This plan adds tests for each
migration branch so the behavior is pinned down.

## Current state

- `Sources/AskDroid/Core/AppSettings.swift`, `SettingsStore.load` migration
  blocks (lines 201–220):

  ```swift
  // Product default moved from Droid's read-only default to high.
  // Migrate anyone who stored the old implicit default; respect explicit choices.
  if settings.autonomy == .droidDefault {
      settings.autonomy = .high
      suite.set(settings.autonomy.rawValue, forKey: "autonomy")
  }
  if let cwd = suite.string(forKey: "workingDirectory"), !cwd.isEmpty {
      settings.workingDirectory = cwd
  }
  if AppSettings.isLegacyHomeWorkingDirectory(settings.workingDirectory) {
      settings.workingDirectory = AppSettings.defaultWorkingDirectory
      suite.set(settings.workingDirectory, forKey: "workingDirectory")
  }
  if let answers = suite.string(forKey: "answersDirectory"), !answers.isEmpty {
      settings.answersDirectory = answers
  }
  if AppSettings.isLegacyHomeAnswersDirectory(settings.answersDirectory) {
      settings.answersDirectory = AppSettings.defaultAnswersDirectory
      suite.set(settings.answersDirectory, forKey: "answersDirectory")
  }
  ```

  Note: `AppSettings.isLegacyHomeWorkingDirectory("~")` and
  `isLegacyHomeAnswersDirectory("~/Droid-Answers")` both return `true`
  (see `AppSettings.swift:157-169`).

- Existing test scaffolding in `Tests/AskDroidTests/AskDroidTests.swift`,
  `SettingsStoreTests` (lines 1103–1164), already has an ephemeral-suite
  helper:

  ```swift
  private func freshSuite() -> UserDefaults {
      let name = "AskDroidTests-\(UUID().uuidString)"
      let suite = UserDefaults(suiteName: name)!
      suite.removePersistentDomain(forName: name)
      return suite
  }
  ```

## Commands you will need

| Purpose   | Command           | Expected on success |
|-----------|-------------------|---------------------|
| Build     | `swift build`     | exit 0              |
| Tests     | `swift test`      | 65 tests executed, 0 failures (1 skipped) plus the new tests |

## Scope

**In scope** (the only file you should modify):
- `Tests/AskDroidTests/AskDroidTests.swift`

**Out of scope** (do NOT touch, even though they look related):
- `Sources/AskDroid/Core/AppSettings.swift` — the migrations themselves are
  not changing; this plan only pins their current behavior with tests.
- Any other source file.

## Git workflow

- Branch: `advisor/004-settings-migration-tests`
- Conventional commit, e.g. `test(settings): pin legacy migration behavior`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the three migration tests to `SettingsStoreTests`

Use the existing `freshSuite()` helper in each. Seed values with `suite.set`,
call `SettingsStore.load(from: suite)`, assert the migrated settings, and
additionally assert the migration was *persisted* back into the suite (that is
the observable contract of `load`, and it is the part at risk).

1. `testLegacyAutonomyMigratesToHigh`
   ```swift
   let suite = freshSuite()
   suite.set("", forKey: "autonomy")        // old implicit "Droid default"
   let loaded = SettingsStore.load(from: suite)
   XCTAssertEqual(loaded.autonomy, .high)
   XCTAssertEqual(suite.string(forKey: "autonomy"), "high")   // written back
   ```

2. `testLegacyHomeWorkingDirectoryMigratesToAppSupport`
   ```swift
   let suite = freshSuite()
   suite.set("~", forKey: "workingDirectory")
   let loaded = SettingsStore.load(from: suite)
   XCTAssertEqual(loaded.workingDirectory, AppSettings.defaultWorkingDirectory)
   XCTAssertEqual(suite.string(forKey: "workingDirectory"), AppSettings.defaultWorkingDirectory)
   ```

3. `testLegacyDroidAnswersDirectoryMigratesToAppSupport`
   ```swift
   let suite = freshSuite()
   suite.set("~/Droid-Answers", forKey: "answersDirectory")
   let loaded = SettingsStore.load(from: suite)
   XCTAssertEqual(loaded.answersDirectory, AppSettings.defaultAnswersDirectory)
   XCTAssertEqual(suite.string(forKey: "answersDirectory"), AppSettings.defaultAnswersDirectory)
   ```

Also add one negative case proving that a *legitimate* custom path is
respected (i.e. the migration is not over-eager):

4. `testCustomDirectoriesAreNotMigrated`
   ```swift
   let suite = freshSuite()
   suite.set("/Users/tester/custom-workspace", forKey: "workingDirectory")
   suite.set("/Users/tester/custom-answers", forKey: "answersDirectory")
   let loaded = SettingsStore.load(from: suite)
   XCTAssertEqual(loaded.workingDirectory, "/Users/tester/custom-workspace")
   XCTAssertEqual(loaded.answersDirectory, "/Users/tester/custom-answers")
   ```

Assertions must use `XCTAssertEqual` (not `XCTAssertTrue(...)` on a string
containment) so a failure names the exact wrong value.

**Verify**: `swift test` → 65 + 4 new tests, 0 failures.

## Test plan

- Four new tests (above): the three migration branches plus the
  don't-migrate-valid-paths guard.
- Structural pattern: existing `SettingsStoreTests.testSettingsStoreRoundTrip`
  (lines 1117–1131) — same suite helper, same assert style.
- Verification: `swift test` → all pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0 (unchanged sources still compile)
- [ ] `swift test` exits 0, passes 65 + the 4 new tests
- [ ] `grep -n "testLegacyAutonomyMigratesToHigh\|testLegacyHomeWorkingDirectoryMigratesToAppSupport\|testLegacyDroidAnswersDirectoryMigratesToAppSupport\|testCustomDirectoriesAreNotMigrated" Tests/AskDroidTests/AskDroidTests.swift` shows all four
- [ ] `git status` shows only `Tests/AskDroidTests/AskDroidTests.swift` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The migration blocks in `AppSettings.swift:201-220` differ from the excerpt
  (drift — the tests must be written against the *current* behavior, not the
  excerpt).
- Any new test fails against the unchanged implementation (that would indicate
  the migration behavior does not match the excerpt; report before changing
  source code).

## Maintenance notes

- If a future plan changes the migration policy (e.g. a settings-export/import
  feature), these four tests are the contract to update deliberately.
- `freshSuite()` uses a UUID-named suite and `removePersistentDomain`, so the
  tests stay hermetic and never touch the real `UserDefaults.standard`.
- If more settings gain migrations later, mirror the pattern: seed the old
  value, assert the new settings value AND the persisted value.