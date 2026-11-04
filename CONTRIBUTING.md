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

Tests can run while Polycop is open: the app they run in opens an empty library
of its own. Tests that need a model are skipped unless it is installed.

## Dependencies

Dependabot proposes updates of the GitHub Actions. Everything else is pinned and
updated by hand, before each release, and at once for a security fix:

* ffmpeg, whisper.cpp and audio.cpp, in `Tools/versions.sh`. ffmpeg decodes
  files from anywhere, so its fixes come first; they are listed on
  [ffmpeg.org/security.html](https://ffmpeg.org/security.html). whisper.cpp and
  audio.cpp publish GitHub releases, which GitHub can notify (Watch, Custom,
  Releases). `Tools/check-versions.sh` names the other files that must agree,
  and `Packages/WhisperFramework/Package.swift` says how to update whisper.cpp.
* SwiftLint in `Tools/lint.sh`, actionlint and zizmor in
  `Tools/lint-workflows.sh`, each with its digest.

Each update is its own pull request.

## Releasing

1. Update the dependencies, as above.
2. On a branch `release/X.Y.Z`, set the new version, three plain numbers with
   no suffix, in `MARKETING_VERSION`, and raise `CURRENT_PROJECT_VERSION` for
   both targets, Polycop and PolycopTests, in Debug and Release: four lines in
   `App/Polycop.xcodeproj/project.pbxproj`.
   `grep MARKETING_VERSION App/Polycop.xcodeproj/project.pbxproj | sort -u` must
   show one value, or the release workflow refuses the tag.
3. If the release stores something new in a record (see "Things that break
   silently" in [AGENTS.md](AGENTS.md)), add a record as this version writes it
   to `App/PolycopTests/Fixtures/records/`, such as `entry-X.Y.Z.json`, and
   decode it in `RecordFormatTests`. Later versions must still load it.
4. In `CHANGELOG.md`, turn "Unreleased" into the version's own section, headed
   `## X.Y.Z (YYYY-MM-DD)`, and merge the branch.
5. Optionally, run the Release workflow by hand on main: it builds and packages
   without publishing anything.
6. Once CI has passed on the merged commit, push a tag `vX.Y.Z` on it. The
   release workflow checks that CI passed there and that the tag matches the
   version, builds ffmpeg and audio.cpp from their pinned sources, runs the
   tests and packages the app in a job that can only read the repository. A
   second job, in the `release` environment that only version tags may use,
   attests the disk image and the zips, then drafts a GitHub release with them,
   the debugging symbols, their SHA-256 files and the changelog section as
   notes. Releases are immutable once published.
7. Read the draft and publish it. Check for Updates finds a release only once it
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
