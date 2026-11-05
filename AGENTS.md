# AGENTS.md

Polycop is a macOS transcription and editing suite for lectures on Apple
Silicon, fully offline once a model is downloaded. New work goes into both: the
transcription and the tools to listen, correct and export. SwiftUI, Swift 6,
macOS 14 or later, arm64 only. Licence GPL-3.0-or-later.

This file holds the rules, for people and agents alike. The rest lives in one
place each: what the app does for students in `README.md`; updating dependencies
and releasing in `CONTRIBUTING.md`; how the parts fit, and why, in
`ARCHITECTURE.md`; how releases are attested and vulnerabilities reported in
`SECURITY.md`.

## Commands

Run from the repository root. Xcode 27 is required; the scripts set
`DEVELOPER_DIR` to `/Applications/Xcode.app` when it is not set.

```sh
Tools/build-ffmpeg.sh      # once: LGPL ffmpeg helper into build/ffmpeg (needs GnuPG)
Tools/build-audiocpp.sh    # once: audio.cpp framework into Packages/AudioCppFramework (needs CMake)
Tools/lint.sh              # swift-format for style, SwiftLint (pinned, downloaded once) for size
Tools/lint-workflows.sh    # actionlint and zizmor on .github, after changing anything in it
xcodebuild test -project App/Polycop.xcodeproj -scheme Polycop -destination 'platform=macOS,arch=arm64'
Tools/package.sh           # locally signed app and zip with its sources, in build/releases/
```

* The test suite takes about 3 minutes once built. Run it once per change set, not after each edit.
* Tests can run while Polycop is open. The app they run in opens an empty library of
  its own, keeps its settings in memory and clears no leftover files, so it leaves
  the user's copy alone.
* Tests that need a model skip themselves when that model is not installed.
* CI runs the suite under the thread and address sanitizers, but has no model, so it
  never reaches the engines. After changing `Engine/`, `Audio/`, a version in
  `Tools/versions.sh` or any code that uses unsafe pointers, run the suite locally
  with the models installed, once with `-enableThreadSanitizer YES` and once with
  `-enableAddressSanitizer YES`.
* In `.github/workflows/release.yml`, only the job that drafts the release may write
  to the repository.

## Layout

```
App/Polycop/
  Application/         PolycopApp, and AppModel: the one holder of app state,
                       split by concern into AppModel+*.swift
  Views/               SwiftUI views and sheets; Views/Entry/ holds the transcript page
  Engine/              TranscriptionEngine protocol, WhisperEngine (whisper.cpp), AudioCppEngine (audio.cpp)
  Audio/               AudioDecoder (runs the bundled ffmpeg), Player
  Models/              ModelCatalog (pinned URLs, sizes, SHA-256), ModelStore, ModelDownloader
  History/             Entry (a transcript and its edits), HistoryStore, TranscriptImport
  Output/              paragraphs, SRT, loop reduction, credits, word diff, search
  Glossary/            course glossaries and term extraction
  Support/             small helpers shared across folders: text decoding, file digests,
                       blocking work run on a queue
  Resources/Licenses/  licence texts shipped in the app
App/PolycopTests/      Swift Testing suites; Fixtures/ holds synthetic data only
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
* A `nonisolated async` function runs on its caller's actor (approachable concurrency),
  so blocking work in it blocks the main actor. Such work goes in a `@concurrent`
  function, or on a queue through `DispatchQueue.run` for a long C call.
* `@unchecked Sendable` only where a serial queue or a lock guards the state, with a comment
  saying which. Prefer checked `Sendable`.
* The build has no warnings: CI compiles with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
* Comments are English, short, and say why, not what. No dates, no measurement stories,
  and no comparison with another app in place of the reason.
* Every Swift file, script and workflow starts with
  `// SPDX-License-Identifier: GPL-3.0-or-later` (`#` in scripts and workflows).
* Formatting follows `.swift-format`; the lint must stay clean. No force unwrap or
  `try!`: where a value can never be missing, such as a URL built from literals, say
  why in a comment above a `swift-format-ignore` for that one rule.
* Size and complexity follow `.swiftlint.yml`. A warning there is debt: the lint
  fails on any not listed in `.swiftlint-baseline.json`, and that list only
  shrinks. Split code rather than raise a limit. When a split brings the largest
  case down, lower the error limit to just above what remains.
* No abstraction before a second use exists. Prefer the simplest code that reads well.
* `try?` only where a failure changes nothing the user relies on, such as removing a
  temporary file. A failure the user would notice is shown, or kept and retried as
  history writes are; one they would not notice but a maintainer needs is logged
  through `Log`.
* Layers call one way, as `ARCHITECTURE.md` draws them.
* A new dependency, tool or model is pinned to a version and checked against a digest,
  as the build scripts and `Tools/lint.sh` do. Versions of what ships with its source
  live in `Tools/versions.sh`; `Tools/check-versions.sh` checks that both
  `Package.swift` files and the notices agree. Three tools come unpinned from
  Homebrew or the build machine: GnuPG, which only checks a download already pinned
  by digest; CMake, which builds audio.cpp; and the ffmpeg of `Tools/fixtures.sh`,
  whose output is committed.
* Interface strings are in English. No emoji, and no dashes as punctuation, in the
  interface or the documentation.

## Official documentation

Apple's documentation and the Human Interface Guidelines settle interface and API
choices, not memory, which misses recent APIs and what macOS 14 lacks.

* Read the page before relying on an API, a flag or a behaviour; for a C library,
  its headers or source. Say so when it cannot be checked.
* Apple's pages need JavaScript, so read them as JSON, which also gives the
  version each API appeared in:
  `developer.apple.com/documentation/swiftui/buttonstyle` is
  `developer.apple.com/tutorials/data/documentation/swiftui/buttonstyle.json`, and
  `developer.apple.com/design/human-interface-guidelines/layout` is
  `developer.apple.com/tutorials/data/design/human-interface-guidelines/layout.json`.
* A pull request that makes an interface or API choice links the page it follows.
  Code that departs from it says why in a comment.
* Where this file and Apple's documentation disagree, the pull request says so
  rather than picking one in silence.

## Interface

Every page speaks the same visual language. The shared pieces live in
`Views/Styles.swift`; use them rather than a new variant.

* Settings and choices are the system's grouped form (`Form` with `.formStyle(.grouped)`),
  one setting a row: a page's in the system inspector
  (`InspectorColumn` gives every page the same width, `InspectorToggle` the same button), a sheet's in the
  sheet. No tinted cards or hand drawn boxes.
* An empty page is the system's empty state (`ContentUnavailableView`), with the way
  to fill it.
* A page's main action is one `ActionButton`: a large capsule with an SF Symbol, glass
  in the accent colour on macOS 26, centred right under what it acts on. The player
  is a capsule too, floating at the foot of the text, which scrolls under it: the
  previous and next paragraph either side of 5 seconds back, play and 5 seconds on,
  then the timeline and times, centred on one line, on `FloatingSurface` (glass on
  macOS 26, the system's material before). Find opens at the top, away from it.
  Work under way on a transcript is one capsule on the same surface, centred above
  the text, in the words of its row in the library.
* `FloatingSurface` keeps its glass in a `GlassEffectContainer`: glass placed in
  plain glass turns the floating player dark in a light window.
* A list's Add and Clear sit on its title line at the trailing edge, aligned with the
  rows, removal last. A list of things kept, such as courses, has the Mac's + and −
  inside the foot of its edge. Managing a choice ("Manage Models…") is the last item
  of that choice's menu.
* A page's tools are window toolbar items, drawn by the system, each also a menu
  command. Controls are the system's, never drawn by hand. The player's timeline is
  the one exception: no system slider marks where each paragraph opens.
* Text editors: `editorBorder()`, with the corners of a control.
* Warnings and failures: a `Notice`, `.warning` or `.failure`, each with one symbol
  and colour; a notice with a symbol of its own is a `Label` with `notice(_:)`. Colour
  goes on the icon only. Text stays in the label colours, since orange, red or green
  text is too faint to read on a light window; emphasis inside text is a line
  (underline, strikethrough).
* Spacing comes from its role in `Spacing`: `page` (28 points) around a page,
  `block` (16) between blocks, the transcript page's first one under the toolbar
  included, `sheet` (24) around a sheet; popovers have 20. The player floats 8 above
  the window's foot, level with the foot of the library beside it. A small gap
  inside a row is the stack's own.
* Type: a page's title is the window's (`navigationTitle`); a sheet's title is
  `.sheetTitle`. A row says what it is in a few words; a line under it only for what a
  student could not guess. Text styles only, no fixed point sizes.
* One prominent button per area, for its main action; the rest use the default style,
  except a button showing only an icon, in a row or a bar, which is `.borderless`.
  `.plain` hides that a button can be pressed: only for a row pressed as a whole.
* A button showing only an icon is a `Label` with `.labelStyle(.iconOnly)` and a
  `.help` in the same words, so VoiceOver and the tooltip say what it does.
* Names say what happens, in the app's own words: a recording is audio or video, an
  action that finds terms is Find Terms. One action keeps one name and one SF Symbol
  in the toolbar, the menu and the row.
* Buttons, menu items and window or sheet titles are in title case, with an ellipsis
  when the action asks for more before it acts. Labels, pickers, toggles and section
  headers are in sentence case.
* Alignment comes from the container: `Form`, `LabeledContent` for a label and its
  value, `Grid` for columns, a stack's alignment. No fixed width to line things up.
* Colour comes from the system: its styles (`.primary`, `.secondary`, `.tint`,
  `.fill`) for text and surfaces, its named colours (`.orange`, `.red`) only on the
  icon of a state. No colour or opacity chosen by hand outside the timeline. A state
  such as paused, stopped or failed keeps one colour and one symbol wherever it shows.
* Hover, focus and disabled states are the system's; animations use its defaults
  and respect Reduce Motion.
* A new view has a `#Preview` with made-up data.
* Text keeps a reading width, about 75 characters at the reader's size, centred:
  a wide window adds margins rather than longer lines, and the inspector can take
  the width. Check a change from the smallest window to full screen, in light and
  dark appearance, and a change to an `#available(macOS 26, *)` branch also with
  the look before it.
* No `.frame(minWidth:minHeight:)` around a whole page: SwiftUI asks for the minimum
  after every change, and such a frame measures the page to answer. The window and the
  detail column give theirs with `minimumSize` in `ContentView`.
* No `@AppStorage`, or a binding made from one, in a view that should stay as it is
  while the reader types: SwiftUI redoes such a view at every update of its parent. A
  setting the transcript page reads belongs in `ReadingSettings`, on the model.

## Things that break silently

* `Entry`, `Segment`, `Transcript.Paragraph`, `TranscriptFolder` and the course
  corrections (`<course>.corrections.json`) are stored as JSON, and glossaries as
  `<course>.txt`, in `~/Library/Application Support/Polycop/`. Never rename their stored properties or
  change their meaning: existing libraries must still load.
* A stored property added to them is optional. Synthesized decoding ignores default
  values, so `var isPinned = false` would make every record written before it fail
  to load. `RecordFormatTests` decodes records as each release wrote them; a release
  that changes what is stored adds its own to `App/PolycopTests/Fixtures/records/`.
* That promise has no end, and it runs one way. A record written by a later version
  is best effort: a version rewrites only what it knows, so what it does not know is
  lost. A stored property an earlier version would lose or misread raises
  `HistoryStore.knownFormat` and sets `requires` on the records that hold it, and no
  others. A version from 0.5.0 on then lists those records without opening or writing
  them (`UnavailableRecord`); earlier ones still strip them. Folders and course corrections have no such
  number: what they cannot lose goes in a new file, which earlier versions never open.
* Model files are identified by catalog id and verified by size and SHA-256. Changing
  a catalog entry means a new pinned file, never an edited hash.
* Typed text stays in the paragraph's text view and reaches the model after a pause,
  or before any click, shortcut, menu or quit (`TypingBuffer`). Code that reads a
  transcript outside those, such as a timer, calls `TypingBuffer.flush()` first.
* Space plays and pauses through a key monitor (`SpaceToPlay`) unless text being
  edited or a control reached with the keyboard has it. A new view that needs Space
  must be one of those, or the player takes the key.
* Engines call C APIs on their own serial queue: every call that uses a loaded
  context stays on that instance's queue. Loading a model and Whisper's silence
  detector run on queues of their own on purpose. Respect the object lifetimes
  documented next to them.
* The app must work offline. The only network uses are downloading catalog models and
  the update check, run when the user asks or daily once they allow it. A failed
  automatic check is only logged.
* `THIRD_PARTY_NOTICES.md` and `App/Polycop/Resources/Licenses/ThirdPartyNotices.txt`
  must stay identical (CI checks). A new bundled component needs its licence text there.

## Tests and data

* Tests use Swift Testing. Add a test with each behaviour change. A bug fix comes with
  the test that fails without it, unless the bug lives only in audio timing or on
  screen; the pull request then says how it was checked.
* Fixtures are synthetic: the recordings in `Fixtures/formats/` are made by
  `Tools/fixtures.sh` from the macOS `say` voices; records and paragraphs are written
  by hand from made-up text.
* Never commit, or attach to an issue or a pull request, recordings or transcripts of
  real lectures, model weights, or a screenshot that shows a real library: blur
  course names first, and use a short synthetic clip rather than a recording.
* Tests never touch the user's library, preferences or Trash: use a temporary folder or
  an injected one, and give a test its own settings in memory, as `PlayerTests` does:
  a set value leaves a file behind, and a registered one is shared by every test
  running at once.
* A test that waits for asynchronous work polls for its result with a bound, as
  `open(_:)` in `PlayerTests` does, rather than sleeping a fixed time: tests run in
  parallel, and on CI they keep the main actor busy for seconds.
* A test that fails once without a known cause becomes an issue. Running it again
  until it passes hides the bug it found.
* Player tests check what was asked, which the player shows at once, not what the
  audio does, and play muted under the test host (`TestHost`): fades and playback
  timing are checked by ear, since CI runs on busy virtual machines where audio
  timing is unreliable.

## Commits and pull requests

* English, imperative subject in lower case, one concern per commit and per pull
  request. A pull request is squash merged, so its title becomes the commit's
  subject: a title that needs "and" is two pull requests.
* A problem found and not fixed in the pull request at hand becomes a GitHub issue
  saying where it is and how it fails, not a TODO comment, a note file in the
  repository or a line in a merged pull request.
* A feature that adds a page or changes what is stored starts with an issue saying
  what the student does and what is stored, before any code.
* What a pull request needs before it is merged depends on what it changes:

  | It changes | It needs |
  |---|---|
  | behaviour | a test, as Tests and data says |
  | what the user sees or does | a line under Unreleased in `CHANGELOG.md`, in the user's words |
  | the interface | screenshots at the smallest window and full screen, light and dark, with no real course name |
  | `Engine/`, `Audio/`, unsafe pointers or `Tools/versions.sh` | the suite run locally under both sanitizers, as Commands says, and a second reading |
  | what is stored, or `.github/workflows/` | a second reading |
  | a dependency | a pull request of its own, as `CONTRIBUTING.md` says |
  | an interface or API choice | a link to the Apple page it follows, as Official documentation says |
  | a model setting | a measurement on corrected transcripts showing it does at least as well, and how it was measured |
  | what a document describes: a command, the layout, a flow in `ARCHITECTURE.md` | that document, updated in the same pull request |

  A second reading is a review by someone, or a coding agent, that did not write
  the change and reads the diff rather than its description.
* Before editing, and again before committing, read `git status` in full: another
  session may be changing the same files. Never overwrite changes you did not make,
  and stage only the paths the task changed.
* Before committing, read the diff itself, not a summary of it, and check that:
  * nothing in it exists already: search for the main word of each new function;
  * every new parameter, branch, type and file has a caller now;
  * what it replaces is deleted, with the tests that guarded only that;
  * each "cannot", "must" or "always" in a comment was checked, in the
    documentation or by trying it;
  * the system does not already do it: a formatter, `Form`, a menu command,
    observation, the undo manager;
  * a stored `Task` is cancelled when another replaces it, and a new `static var`
    says why it is safe to share;
  * a test checks what the user would see, not a state on the way such as "not
    busy", and an API added to production code for a test says so in its comment;
  * a fact in the documentation is stated in one place, and the others link to it.
* The lint and the test suite pass before a pull request is opened.
