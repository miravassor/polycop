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
* A release is published by pushing a tag `vX.Y.Z` that matches `MARKETING_VERSION`;
  `.github/workflows/release.yml` builds, tests and drafts the GitHub release.

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

## Things that break silently

* `Entry`, `Segment`, `Transcript.Paragraph`, `TranscriptFolder`, glossaries and the
  course corrections beside them (`<course>.corrections.json`) are stored as JSON in
  `~/Library/Application Support/Polycop/`. Never rename their stored properties or
  change their meaning: existing libraries must still load.
* Model files are identified by catalog id and verified by size and SHA-256. Changing
  a catalog entry means a new pinned file, never an edited hash.
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
* Never commit recordings, transcripts of real lectures, or model weights.

## Commits and pull requests

* English, imperative subject, one concern per commit.
* Before committing, read `git status` in full and stage only the paths the task changed.
* The lint and the test suite pass before a pull request is opened.
