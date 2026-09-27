# AGENTS.md

Polycop is a macOS transcription and editing suite for lectures on Apple
Silicon, fully offline once a model is downloaded. New work goes into both: the
transcription and the tools to listen, correct and export. SwiftUI, Swift 6,
macOS 14 or later, arm64 only. Licence GPL-3.0-or-later.

## Commands

Run from the repository root. Xcode 27 is required; the scripts set
`DEVELOPER_DIR` to `/Applications/Xcode.app` when it is not set.

```sh
Tools/build-ffmpeg.sh      # once: LGPL ffmpeg helper into build/ffmpeg (needs GnuPG)
Tools/build-audiocpp.sh    # once: audio.cpp framework into Packages/AudioCppFramework (needs CMake)
xcrun swift-format lint --strict --recursive App Packages
xcodebuild test -project App/Polycop.xcodeproj -scheme Polycop -destination 'platform=macOS,arch=arm64'
Tools/package.sh           # locally signed app and zip with its sources, in build/releases/
```

* The test suite takes about 6 minutes. Run it once per change set, not after each edit.
* Tests can run while Polycop is open. Two copies share the library, so each keeps the
  edits it made last; a copy does not clear leftover files while another runs.
* Tests that need a model skip themselves when that model is not installed.
* A release starts on a branch `release/X.Y.Z` that sets `MARKETING_VERSION`, raises
  `CURRENT_PROJECT_VERSION`, and turns the changelog's "Unreleased" into "X.Y.Z (date)".
  Once it is merged, pushing the tag `vX.Y.Z` makes `.github/workflows/release.yml`
  build, test and draft the GitHub release.

## Layout

```
App/Polycop/
  Application/         PolycopApp, and AppModel: the single @Observable state holder,
                       split by concern into AppModel+*.swift
  Views/               SwiftUI views and sheets; Views/Entry/ holds the transcript page
  Engine/              TranscriptionEngine protocol, WhisperEngine (whisper.cpp), AudioCppEngine (audio.cpp)
  Audio/               AudioDecoder (runs the bundled ffmpeg), Player
  Models/              ModelCatalog (pinned URLs, sizes, SHA-256), ModelStore, ModelDownloader
  History/             Entry (a transcript and its edits), HistoryStore, TranscriptImport
  Output/              paragraphs, SRT, loop reduction, credits, word diff, search
  Glossary/            course glossaries and term extraction
  Support/             small helpers shared across folders: text decoding, file digests
  Resources/Licenses/  licence texts shipped in the app
App/PolycopTests/      Swift Testing suites; Fixtures/ holds synthetic audio only
Packages/              local packages wrapping the whisper.cpp and audio.cpp binaries
Tools/                 build, fixture and packaging scripts
```

## Code conventions

* Swift 6 language mode, main actor by default. Engine and value types are `nonisolated`.
* `@Observable` classes hold state, structs carry values, caseless enums group pure functions.
* Names follow the Swift API Design Guidelines: explicit, no abbreviations, and
  Booleans that read as assertions (`isEditable`, `showsChanges`). Stored names of
  persisted types are the exception: they never change.
* Views bind to `AppModel` through `@Bindable`, never through hand-written `Binding(get:set:)`.
* `@unchecked Sendable` only where a serial queue or a lock guards the state, with a comment
  saying which. Prefer checked `Sendable`.
* The build has no warnings: CI compiles with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
* Comments are English, short, and say why, not what. No dates, no measurement stories.
* Every file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` (`#` in scripts).
* Formatting follows `.swift-format`; the lint must stay clean.
* No abstraction before a second use exists. Prefer the simplest code that reads well.
* Interface strings are in English. No emoji, and no dashes as punctuation, in the
  interface or the documentation.

## Interface

Every page speaks the same visual language. The shared pieces live in
`Views/Styles.swift`; use them rather than a new variant.

* Cards: `panel()`, corners of 10, 16 points of padding, one fill and border.
  Controls and rows inside a card have corners of 6.
* Header icon buttons and menus: `iconControl()`, 32 by 28.
* Spacing: 28 points around a page, 16 between blocks, 12 between a card's label and
  its buttons. Sheets have 24 points of padding, popovers 20.
* Type: a page title in `.title2` semibold, a section heading in `.title3` semibold
  with a `.callout` line under it, a card title in `.headline` with a `.callout`
  line. Text styles only, no fixed point sizes.
* One prominent button per area, for its main action; the rest use the default style.
* A wide window, as in full screen, uses its width through columns rather than one
  narrow column beside empty space. Check a change in a narrow and a wide window.
* No `.frame(minWidth:minHeight:)` around a whole page: SwiftUI asks for the minimum
  after every change, and such a frame measures the page to answer. The window and the
  detail column give theirs with `minimumSize` in `ContentView`.

## Things that break silently

* `Entry`, `Segment`, `Transcript.Paragraph`, `TranscriptFolder`, glossaries and the
  course corrections beside them (`<course>.corrections.json`) are stored as JSON in
  `~/Library/Application Support/Polycop/`. Never rename their stored properties or
  change their meaning: existing libraries must still load.
* Model files are identified by catalog id and verified by size and SHA-256. Changing
  a catalog entry means a new pinned file, never an edited hash.
* Typed text stays in the paragraph's text view and reaches the model after a pause,
  or before any click, shortcut, menu or quit (`TypingBuffer`). Code that reads a
  transcript outside those, such as a timer, calls `TypingBuffer.flush()` first.
* Space plays and pauses through a key monitor (`SpaceToPlay`) unless text being
  edited or a control reached with the keyboard has it. A new view that needs Space
  must be one of those, or the player takes the key.
* Engines call C APIs on their own serial queue. Keep every whisper.cpp and audio.cpp
  call on that queue and respect the object lifetimes documented next to them.
* The app must work offline. The only network uses are downloading catalog models and
  the update check, run when the user asks or daily once they allow it. A failed
  automatic check is only logged.
* `THIRD_PARTY_NOTICES.md` and `App/Polycop/Resources/Licenses/ThirdPartyNotices.txt`
  must stay identical (CI checks). A new bundled component needs its licence text there.

## Tests and data

* Tests use Swift Testing. Add a test with each behaviour change.
* Fixtures are synthetic, made with `Tools/fixtures.sh` and the macOS `say` voices.
* Never commit recordings, transcripts of real lectures, or model weights, nor a
  screenshot that shows a real library: blur course names first.
* Tests never touch the user's library, preferences or Trash: use a temporary folder or
  an injected one, and give a test its own settings in memory, as `PlayerTests` does:
  a set value leaves a file behind, and a registered one is shared by every test
  running at once.
* A test that waits for asynchronous work polls for its result with a bound, as
  `open(_:)` in `PlayerTests` does, rather than sleeping a fixed time: tests run in
  parallel, and on CI they keep the main actor busy for seconds.
* Player tests check what was asked, which the player shows at once, not what the
  audio does: fades and playback timing are checked by ear, since CI runs on busy
  virtual machines where audio timing is unreliable.

## Commits and pull requests

* English, imperative subject, one concern per commit.
* Before committing, read `git status` in full and stage only the paths the task changed.
* The lint and the test suite pass before a pull request is opened.
