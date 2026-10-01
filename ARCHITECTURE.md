# Architecture

How Polycop is put together: who owns which state, where work runs, and how
data moves from a recording to a corrected transcript. The conventions and the
rules that break silently are in `AGENTS.md`; this file explains the shape they
protect.

## Layers

```
Views (SwiftUI, AppKit text views)          main actor
   │  read state, call AppModel methods
   ▼
AppModel (+ one extension per concern)      main actor, the only @Observable app state
   │  starts tasks, receives their results
   ├──► Player, NowPlaying                  main actor, AVPlayer and media keys
   ├──► AudioDecoder                        off the main actor, runs the bundled ffmpeg
   ├──► WhisperEngine, AudioCppEngine       own serial queues, C libraries
   ├──► ModelDownloader, ModelStore         URLSession, SHA-256 proofs
   └──► HistoryStore, GlossaryStore         JSON and text files in Application Support
Output/                                     pure functions on values: paragraphs,
                                            SRT, word timing, loop and credit rules
```

Arrows point one way. Views never read or write files through a store, nor
call an engine or the decoder; stores and engines never know about views or
`AppModel`. `Output/` and
`Glossary/Terms` are pure and hold no state, which is why most tests live
there.

## State

* `AppModel` is the single holder of application state: the library
  (`entries`, `folders`), the queue (`stage`, `running`, `scheduled`), the
  selection (`pane`), settings on screen, and failures to show. Its
  extensions (`AppModel+Transcription`, `+Editing`, `+Library`, ...) add
  behaviour, never stored state.
* `Entry` is a value: one recording, its settings, the segments the engine
  wrote, the paragraphs as corrected, and where the reader left it. Every
  change to an entry goes through `AppModel.updateEntry`, which writes it to
  disk; a new entry is written by the action that makes it (adding, retrying,
  duplicating or importing).
* `Player` owns playback state (position, playing, speed) and is owned by
  `AppModel`. Views read it; `AppModel`, the player bar and the pause for
  typing in `EntryView` change it.
* Views keep only presentation state (`@State`: hover, popovers, scroll
  frames). What must survive a view going away belongs to `AppModel`.
* Text being typed lives in the paragraph's `NSTextView` until
  `TypingBuffer` hands it over, after a pause or before anything else reads
  the transcript.

## Concurrency

* Everything is main actor by default (Swift 6, approachable concurrency).
  Types that run elsewhere are marked `nonisolated` and are `Sendable`.
* Each engine keeps its native context on a serial `DispatchQueue` of its
  own, bridged to `async` with continuations. A transcription blocks for
  minutes, so it never runs on the concurrency pool. That queue is the only
  reason the engines may be `@unchecked Sendable`.
* A job is a `Task` stored in `AppModel.work`, numbered by `beginJob()`.
  Results are applied only while `isCurrent(number)` holds, so a job
  cancelled after a newer one started cannot overwrite the newer state.
* Cancellation is cooperative: tasks check it between steps, the engines
  answer it from the callbacks the C libraries call while they compute, and
  the decoder terminates ffmpeg.
* Progress and segments reach the main actor through `@Sendable` callbacks;
  segments are also collected under a lock, so a paused job keeps what it had
  decoded.

## A transcription

1. `transcribe(_:)` adds entries in the waiting state; nothing starts until
   the user asks (`start()`).
2. `startNext()` picks the oldest scheduled entry; `run(_:)` decodes the
   recording through ffmpeg into 16 kHz mono samples.
3. `preparedEngine(for:)` reuses the loaded engine or opens one through
   `AppModel.engines`, which loads the model after proving its size and SHA-256.
4. The engine streams segments, which `run(_:)` collects as they arrive. The
   entry receives them when the job finishes, pauses, stops or fails, so the
   page shows its progress and a placeholder while the job runs.
5. The entry keeps the segments as the engine wrote them and is marked
   finished. What the page shows is derived from them through `Output/`:
   credits set aside, loops shortened, paragraphs laid out.
6. `finish()` starts the next entry, or releases the engine when none waits.

Quitting stops the job and keeps the segments it had decoded, flushes typing,
and writes every pending change before the app replies to the termination
request. A paused job cannot resume after a relaunch: its samples lived in
memory.

## Editing and playback

* A paragraph is an `NSTextView` (`ParagraphEditor`) inside a lazy list
  (`TranscriptView`). Word times come from `WordLayout`, which places the
  engine's timed words on the corrected text with a word diff (`Edits`).
* An edit becomes a correction in `AppModel.corrections`, so undo and revert
  work per transcript. Typing is saved after a one second pause; any other
  change is saved at once.
* The player bar and `SpaceToPlay` drive `Player`; `NowPlaying` connects it to
  the media keys and Control Center.

## Persistence

Everything lives in `~/Library/Application Support/Polycop/`:

| Folder | Content | Owner |
|---|---|---|
| `History/` | one JSON file per entry | `HistoryStore` |
| `Glossaries/` | one text file per course, and its remembered corrections | `GlossaryStore`, `CourseCorrections` |
| `Models/` | downloaded or imported weights | `ModelStore`, `ModelDownloader` |

There is no index: the directory listing is the library. A file that fails to
decode is left in place and reported, never overwritten. A write that fails is
kept in memory and retried, and quitting asks before losing it. Stored
property names never change (see `AGENTS.md`).

## Outside the app

* whisper.cpp and audio.cpp, as binary frameworks in `Packages/`, built or
  downloaded at pinned versions with checked digests.
* ffmpeg, an LGPL helper inside the app bundle, built by
  `Tools/build-ffmpeg.sh`.
* The network, only for model downloads and the update check.

## Tests

`App/PolycopTests/` has one suite per subject. Pure code in `Output/`,
`Glossary/` and `History/` is tested directly on values. `AppModel` is
tested with a temporary library folder and settings in memory. Its queue is
also tested with a scripted engine given through `Engines`, so pause, resume,
stop, quit and failures run in CI; engine tests run only when their model is
installed. Audio timing is never asserted: CI
runs on shared machines.
