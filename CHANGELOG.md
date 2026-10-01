# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org).

## Unreleased

### Added

* The text cursor can follow playback: after a correction, it moves with the word being heard, so the next one is typed where the audio is. Off by default, in Settings; a click keeps the cursor where you put it until you type.

### Changed

* Export Text (⌘S) and Export Text As… (⇧⌘S) are in the File menu. ⌘S updates the export, or asks where to put the first one, and works right after typing, when the button could still show the export as up to date.
* Quitting keeps the recordings that were only waiting in the queue: after a relaunch they wait for Start again instead of showing as stopped, and quitting asks first only when something is in progress. The recording being transcribed still stops, as its progress cannot be resumed.
* Opening Polycop while it is already open brings the open copy forward instead of starting a second one. Two copies each wrote what they had read at launch, so one could write over the other's corrections.

### Fixed

* Correcting a search result no longer makes the page scroll to the next one while you type. The next result waits where the corrected one was, and Next shows it.
* Replace moves on to the next result even when the replacement still matches the search, as "Freud" does "freud"; it used to stay on the word it had just replaced.
* Find, Replace All and course corrections read a curly apostrophe and a straight one as the same, so "l'inconscient" also finds "l’inconscient".
* Typing in a transcript keeps what is typed, whatever the system's text input settings: apostrophes no longer turn curly, double hyphens no longer become dashes, and spelling correction no longer rewrites names. A curly apostrophe hid the word from Find, Replace All and course corrections.
* Pausing after a dead key, before its letter, no longer saves the accent alone as a correction.
* A glossary edited in another application while the Glossary sheet is open is no longer written back to what the sheet read when it opened. Choosing a course reads its file again, and only what is typed in the sheet is saved.
* A transcript with course corrections that shows a hidden lines or repeats notice checks the corrections over its text once per update instead of up to six times, which slowed typing in long lectures.
* With Leave out hesitations, a paragraph that was only "Euh." is left out of the export instead of leaving a time with a lone full stop, and a hesitation said as a sentence of its own takes its full stop with it.
* Subtitles no longer contain empty captions for segments without text.
* A Markdown export escapes the characters Markdown would read as formatting, so "2*3*4" no longer shows the 3 in italics and a line typed as "# Freud" or "1. Le moi" no longer becomes a heading or a list.
* Terms from Documents finds names written with Œ, œ or Ÿ, names joined to an elided word ("d’Œdipe", "l’Allemagne"), and names whose accents a PDF stored apart from their letters.
* Terms from Documents ends in moments on a long document with thousands of names, and stops working when its sheet is closed.
* Jumping to a paragraph or along the timeline while playing no longer shows the old position again for a moment before the new one.
* Voxtral transcripts get a timestamp every 30 seconds, as they should, rather than one every five minutes, and keep the last words before each five-minute cut.
* A MOSS window that repeats itself until its token limit no longer ends the whole transcription: that window keeps what it had written, and the rest of the recording is transcribed.
* Stopping or quitting while a Whisper transcription is about to start takes effect at once, and its progress no longer goes past 100%.
* A recording in a folder the app cannot read is reported as unreadable, with the reason, rather than as moved.
* Transcribing the repeats again waits while a revert can still be undone, instead of losing the corrected text, and a transcript stopped part way stays marked as stopped once repaired.
* Undoing a revert brings back the corrections remembered for the course along with the text, so repairing the repeats and putting credits back stay possible.
* A transcript where a speaker starts before the one they follow, as MOSS can write when voices overlap, opens again after a relaunch instead of being reported as a file that could not be read.
* A retry waiting for a model you deleted keeps the settings of the transcript it repeats when you press Start, instead of taking those on the New Transcription page.
* A second transcript of a numbered lecture keeps its number: retrying or duplicating "Cours 12.m4a" now gives "Cours 12 (2).m4a" rather than "Cours 2.m4a", another lecture's name.
* Subtitles and timestamped text saved in Windows Latin, as older subtitle tools do, are imported instead of being refused as an unsupported format.
* Playback you pause just after it starts, as typing does, stays paused: the player no longer takes a late report from the audio system as a request to play again.
* A transcript whose recording is on a disk that is not connected no longer mounts that disk while the page draws, which could wait on the network or ask for a password while you type. The recording shows as unavailable until you connect the disk.
* The update check sends only the app's name: the system no longer adds your macOS version and languages to the request. It also accepts only a page of Polycop's own releases from the answer.
* An export never replaces a file the save panel did not ask about: naming it "cours.text" no longer writes over a "cours.txt" already in that folder.
* While the list of folders cannot be read, transcripts stay in their folders: moving them is refused until the list is repaired, rather than taking them out of folders the app can no longer name.

## 0.3.2 (2026-09-27)

### Added

* Playback that typing paused resumes on its own once you stop typing, two seconds later by default, stepping back as any resume does. Settings offers other delays, or never.
* A transcript opens where you left it, when you come back to it or reopen the app: at the paragraph you were reading, with playback ready to resume where it stopped.

### Fixed

* The word being heard stays highlighted in a paragraph where you deleted or rewrote words: a short word such as "de" could send the highlight astray for the rest of the paragraph.
* Option-click plays from anywhere in an edited paragraph, including text you rewrote, from a time between the words still found around the click, and right after typing.
* In a passage you rewrote, the highlight moves through your words while the original ones are heard, and while a passage you deleted is heard no word is lit, rather than the word before it staying lit as if playback were stuck.

## 0.3.1 (2026-09-26)

### Added

* Space plays and pauses when no text is being edited, as in any player, and Esc leaves the text. Shift Command Space still works while typing.

### Fixed

* Pausing, resuming, jumping and stopping no longer click: the audio fades out and back in over a few hundredths of a second.
* Typing in a long transcript no longer lags: a key redraws only the text being typed, the transcript takes it after a short pause or before anything reads it, and it is written to disk after a pause of a second, when you leave the transcript, or when you quit.

## 0.3.0 (2026-09-26)

Polycop now grows as a transcription and editing suite: this release is mostly
about working on the text once it is written.

### Added

* Find and replace in a transcript, with Replace All (Option Command F). A replacement is one correction to undo, and it matches every spelling that differs only in case or accents.
* Playback steps back 1.5 seconds when it resumes after a pause, and pauses when you start typing a correction. Both can be changed in Settings.
* Option Command Down and Up play the next and previous paragraph, counted from the one playing.
* Text export with or without timestamps, or as Markdown, and an option to leave out hesitations such as "euh" or "hum". Words that can carry meaning stay.
* Word timings for new Whisper transcripts, and for Qwen3-ASR with the aligner: Option-click a word to play from it, and the word being played is highlighted. Words Whisper was unsure of are underlined, which can be turned off. Earlier transcripts have no word timings.
* Replace All can remember a correction for the course, applied to whole words in its next transcripts as your own corrections. The glossary editor lists them, and each can be forgotten.
* A transcript exported as a Word document with timestamps, as recorder apps write it, can be imported with its recording.
* Follow playback steps aside when you scroll, search or click in the text, and Return to playback takes you back. The timeline marks the paragraph being played.

### Changed

* Polycop can run as two copies at once. Each keeps the edits it made last, and a copy leaves the other's downloads and playback files alone.
* Cards and header buttons share one size and one shape across the app.
* Importing a transcript made elsewhere has its own card on the New transcription page, and the page uses two columns in a wide window.
* Changing the text layout or the subtitles after an export asks where to export again, instead of offering an update that could not be written.

### Fixed

* The system controls can only set the playback speeds the app offers.

## 0.2.1 (2026-09-26)

### Added

* The keyboard media keys, Control Center and headphone buttons control playback: play and pause, five seconds back or forward, a chosen position and the playback speed.
* Releases include a disk image: open it and drag Polycop to Applications.

### Changed

* Whisper Large v3 turbo is the recommended model. The app starts on an installed model when the recommended one is not, and model descriptions state features and speed only.

## 0.2.0 (2026-09-25)

### Added

* MOSS-Transcribe-Diarize, which labels speaker turns, and Voxtral Realtime, both run by audio.cpp.
* Optional Qwen3 Forced Aligner: Qwen3-ASR transcripts get sentence timings and subtitles.
* Import of an existing timestamped transcript (TXT, SRT, VTT, Whisper or audio.cpp JSON) with its recording, to correct it while listening.
* Search in a transcript, review flags on passages, and a window listing the keyboard shortcuts.
* Glossaries are passed to MOSS as hotwords.
* Check for Updates… in the Polycop menu, and an optional daily check, asked once on the second launch.

### Changed

* Repeated words from an engine loop are shortened to one occurrence, as the official Qwen3-ASR toolkit does, instead of hiding the passage. The original stays available.
* MOSS and Voxtral read the recording in 5 minute windows cut at the quietest point; Voxtral is streamed.
* A stopped or failed transcription keeps the text decoded so far.
* Release archives include the corresponding sources of every bundled component and the licence texts.

### Fixed

* A model download could not resume after its partial data became unusable.
* A waiting recording showed an unrelated model download as its own.
* The sidebar did not show the progress of a repeat repair.
* System menus appeared in French, because French was the development language.

## 0.1.1

First public test version: Whisper and Qwen3-ASR transcription, glossaries, correction while listening, and export to text and SRT.
