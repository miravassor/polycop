# Contributing

Thanks for helping. Bug reports, fixes and measured improvements are welcome.

## Build

You need an Apple Silicon Mac with macOS 14 or later, Xcode 27, CMake and GnuPG
(`brew install cmake gnupg`).

```sh
Tools/build-ffmpeg.sh       # the LGPL ffmpeg helper, verified against the FFmpeg signing key
Tools/build-audiocpp.sh     # the audio.cpp framework, from its pinned commit
open App/Polycop.xcodeproj  # then run the Polycop scheme
```

## Before a pull request

```sh
Tools/lint.sh
xcodebuild test -project App/Polycop.xcodeproj -scheme Polycop -destination 'platform=macOS,arch=arm64'
```

Quit any running copy of Polycop before testing: the app allows only one
instance. Tests that need a model are skipped unless it is installed.

## Releasing

1. Set the new version in `MARKETING_VERSION` and raise `CURRENT_PROJECT_VERSION`
   (target Polycop, General tab in Xcode).
2. In `CHANGELOG.md`, give the version its own section, headed
   `## X.Y.Z (YYYY-MM-DD)`.
3. Commit, then push a tag `vX.Y.Z` on that commit. The release workflow checks
   that the tag matches the version, builds every dependency from its pinned
   source, runs the tests and drafts a GitHub release with the archive, its
   SHA-256 and the changelog section as notes.
4. Read the draft and publish it. Check for Updates finds a release only once it
   is published.

## Guidelines

* The conventions are in [AGENTS.md](AGENTS.md); they apply to people and coding agents alike.
* Keep a pull request to one concern, with a test for any behaviour change.
* A change to a model setting needs a measurement showing it does at least as
  well on corrected transcripts; say how it was measured.
* Never attach real lecture recordings or their transcripts to an issue or a
  pull request. Use a short synthetic clip instead.

By contributing, you agree that your contribution is licensed under the
GPL-3.0-or-later, like the rest of the project.
