#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks that Package.swift and the notices name the versions in
# Tools/versions.sh, so a version changed in one place cannot ship with the
# source or the notice of another.
#
# Usage: Tools/check-versions.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Tools/versions.sh
. "$ROOT/Tools/versions.sh"

failed=0
expect() {
    local file="$1" text="$2"
    if ! grep -qF -- "$text" "$ROOT/$file"; then
        echo "$file does not mention $text" >&2
        failed=1
    fi
}

expect Packages/WhisperFramework/Package.swift "download/$WHISPER_BUILD\""
expect Packages/WhisperFramework/Package.swift "whisper-$WHISPER_BUILD-xcframework.zip"
expect THIRD_PARTY_NOTICES.md "release $WHISPER_BUILD (version ${WHISPER_VERSION#v})"
expect THIRD_PARTY_NOTICES.md "unmodified $AUDIOCPP_VERSION source"
expect THIRD_PARTY_NOTICES.md "commit $AUDIOCPP_COMMIT"
expect THIRD_PARTY_NOTICES.md "signature-checked $FFMPEG_VERSION release"
expect THIRD_PARTY_NOTICES.md "ffmpeg-$FFMPEG_VERSION.tar.xz"
exit "$failed"
