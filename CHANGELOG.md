# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org).

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
