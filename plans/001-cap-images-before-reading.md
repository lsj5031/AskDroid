# Plan 001: Reject oversized images before reading or decoding a file

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
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `b380f1b`, 2026-08-20

## Why this matters

The app caps attached images at 5 MB each / 15 MB total, but the cap is
enforced only in `AskSession.attach(images:)` — *after* `AttachedImage` has
already read the file into memory and (for files needing transcoding, or when
the type is unrecognized) decoded it through `NSImage`. That read and decode
run on the main thread. Dropping or pasting a large file (e.g. a 2 GB
screenshot restored into Downloads) reads the whole thing and stalls the UI
before the size check rejects it. The fix is to check the file size on disk
*before* the read, and count oversized files so the user still sees the
existing "Skipped an image over the size limit" notice.

## Current state

- `Sources/AskDroid/Core/AttachedImage.swift` — image model; `fromFileURL`
  is the file-loading entry point (lines 90–95):

  ```swift
  static func fromFileURL(_ url: URL) -> AttachedImage? {
      let resolved = url.standardizedFileURL
      guard let data = try? Data(contentsOf: resolved) else { return nil }   // line 92: full read, no size check
      let type = UTType(filenameExtension: resolved.pathExtension.lowercased())
      return fromData(data, hintedType: mimeType(for: type), filename: resolved.lastPathComponent)
  }
  ```

- `Sources/AskDroid/App/AskSession.swift` — the cap constants live here
  (lines 35–36) and the cap check after the fact (lines 218–231):

  ```swift
  static let maxImageBytes = 5 * 1024 * 1024
  static let maxTotalImageBytes = 15 * 1024 * 1024
  ```

  ```swift
  for image in incoming where !images.contains(where: { $0.data == image.data }) {
      let wouldBeTotal = images.reduce(0) { $0 + $1.data.count } + image.data.count
      if image.data.count > Self.maxImageBytes || wouldBeTotal > Self.maxTotalImageBytes {
          skipped += 1
          continue
      }
      ...
  ```

  and the URL entry point (lines 241–243):

  ```swift
  func attach(urls: [URL]) {
      attach(images: urls.compactMap(AttachedImage.fromFileURL))
  }
  ```

- `Sources/AskDroid/HUD/HUDRootView.swift` — drops route through
  `session.attach(urls:)` on the main thread (lines 528–552).

## Commands you will need

| Purpose   | Command           | Expected on success |
|-----------|-------------------|---------------------|
| Build     | `swift build`     | exit 0              |
| Tests     | `swift test`      | 65 tests executed, 0 failures (1 skipped) plus the new tests |

## Scope

**In scope** (the only files you should modify):
- `Sources/AskDroid/Core/AttachedImage.swift`
- `Sources/AskDroid/App/AskSession.swift`
- `Tests/AskDroidTests/AskDroidTests.swift`

**Out of scope** (do NOT touch, even though they look related):
- `Sources/AskDroid/HUD/HUDRootView.swift` — the drop handler stays as-is;
  `attach(urls:)` absorbs the size pre-check.
- `Sources/AskDroid/Core/EngineSupport.swift`, the engines, or any other file.

## Git workflow

- Branch: `advisor/001-cap-images-before-reading`
- Commit style follows the repo: conventional commits, e.g.
  `perf(images): reject oversized attachments before reading them` (mirroring
  existing `feat(…)`, `refactor(…)`, `docs(…)` messages in `git log`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Pre-check the on-disk size in `fromFileURL`

In `AttachedImage.swift`, change `fromFileURL` so it reads the file size from
disk first and bails out for anything over the cap, before touching a byte:

```swift
static func fromFileURL(_ url: URL) -> AttachedImage? {
    let resolved = url.standardizedFileURL
    if let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
       size > maxDataBytes
    {
        return nil
    }
    guard let data = try? Data(contentsOf: resolved) else { return nil }
    let type = UTType(filenameExtension: resolved.pathExtension.lowercased())
    return fromData(data, hintedType: mimeType(for: type), filename: resolved.lastPathComponent)
}
```

Also move the single-image cap onto `AttachedImage` so both layers share one
constant. Add next to the existing struct members:

```swift
/// Size cap for a single attached image (shared with AskSession).
static let maxDataBytes = 5 * 1024 * 1024
```

**Verify**: `swift build` → exit 0. (`AskSession` still references its own
constant at this point; that's fine.)

### Step 2: Count oversized URLs in `AskSession.attach(urls:)` and keep the notice

In `AskSession.swift`, replace `attach(urls:)` so it pre-checks sizes before
building images, counts the rejects, and reuses the existing notice path:

```swift
func attach(urls: [URL]) {
    var oversized = 0
    var accepted: [AttachedImage] = []
    for url in urls {
        let resolved = url.standardizedFileURL
        if let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size > Self.maxImageBytes
        {
            oversized += 1
            continue
        }
        if let image = AttachedImage.fromFileURL(url) {
            accepted.append(image)
        }
    }
    let added = attach(images: accepted)
    if oversized > 0 {
        notice = oversized == 1
            ? "Skipped an image over the size limit (5 MB each, 15 MB total)."
            : "Skipped \(oversized) images over the size limit (5 MB each, 15 MB total)."
        AskLog.line("skipped \(oversized) oversized image(s)")
    }
}
```

`attach(images:)` can now also validate per-image size (drop the
`image.data.count > Self.maxImageBytes` clause is NOT required — keep it as a
second net for pasteboard-sourced images; it costs nothing). Keep the
aggregate 15 MB check exactly as it is.

Then point `AskSession.maxImageBytes` at the shared constant so future changes
rely on one value:

```swift
static let maxImageBytes = AttachedImage.maxDataBytes
```

**Verify**: `swift build` → exit 0.

### Step 3: Add regression tests

In `Tests/AskDroidTests/AskDroidTests.swift`, extend `AttachedImageTests`:

1. `testFromFileURLRejectsOversizedFile`
   - Create a temp file whose contents exceed `AskSession.maxImageBytes`
     (e.g. `Data(repeating: 0x00, count: AskSession.maxImageBytes)` plus nothing
     — write a file of exactly `maxImageBytes` then call a slice larger; the
     simplest reliable approach: write `Data(repeating: 0xFF, count: 5_242_880)`
     for 5 MiB + 1 byte).
   - Assert `AttachedImage.fromFileURL(url) == nil` and that the file was not
     read either way (the check itself suffices: it returns nil).
   - Clean up the temp dir.

2. `testAttachURLsSkipsOversizedAndKeepsNotice` (in `AskSessionTests`, which
   already has the `makeSession(launcher:)` helper)
   - Build a session, write one oversized temp file and one tiny valid PNG
     (the bytes `Data([0x89, 0x50, 0x4E, 0x47])` are sniffed as PNG).
   - `session.attach(urls: [oversized, tiny])` → `session.images.count == 1`
     (only the tiny file), `session.notice` contains "Skipped an image over the
     size limit".

**Verify**: `swift test` → 65 + 2 new tests, 0 failures.

## Test plan

- New tests (above): oversized file never attaches; the notice still appears;
  the happy path (existing `testPasteboardPNGBecomesAttachedImage`) still passes.
- Structural pattern: `AskSessionTests` in the same file already constructs
  sessions with `makeSession(launcher: MockLauncher())` and a temp directory;
  `AttachedImageTests` already uses temp files — match those patterns.
- Verification: `swift test` → all pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0, passes 65 + the 2 new tests
- [ ] `grep -n "Data(contentsOf: resolved)\|Data(contentsOf: url)" Sources/AskDroid/Core/AttachedImage.swift` shows the read now guarded by the size pre-check
- [ ] `git status` shows only the in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at `AttachedImage.swift:90-95` or `AskSession.swift:241-243` does
  not match the excerpts above (drift).
- A step's verification fails twice after a reasonable fix attempt.
- The fix appears to require touching an out-of-scope file (in particular the
  drop handler in `HUDRootView.swift`).

## Maintenance notes

- If the per-image cap constant changes, it now lives in exactly one place:
  `AttachedImage.maxDataBytes`. Keep `AskSession.maxImageBytes` as a
  forwarding alias, or delete it in a later cleanup once all callers are gone
  — do not introduce a second value.
- The aggregate 15 MB check in `attach(images:)` remains the authority for
  pasteboard-sourced images (already in memory). If downsampling is ever added,
  it should live in `AttachedImage.fromData` and will automatically apply to
  both file and pasteboard paths.