# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org).

## Unreleased

### Added

* Find and replace in a transcript, with Replace All (Option Command F). A replacement is one correction to undo, and it matches every spelling that differs only in case or accents.

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
