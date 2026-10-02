#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs both linters: swift-format for style, SwiftLint for size and complexity.
# SwiftLint is downloaded once at a pinned release and refused if its digest
# differs.
#
# Usage: Tools/lint.sh
# Fails on a style violation or on a SwiftLint error; SwiftLint warnings are
# printed and left to review.

set -euo pipefail

VERSION="0.65.1"
SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"

# Use Xcode's toolchain even when xcode-select points to the Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/build/swiftlint-$VERSION"
SWIFTLINT="$TOOL/swiftlint"

# Unpacked beside its final place and moved there whole, with the digest it
# came from, so an interrupted unpacking is never taken for the tool.
if [ "$(cat "$TOOL/.archive-sha256" 2>/dev/null)" != "$SHA256" ]; then
    ARCHIVE="$(mktemp -t swiftlint).zip"
    mkdir -p "$ROOT/build"
    UNPACKED="$(mktemp -d "$ROOT/build/swiftlint.XXXXXX")"
    trap 'rm -rf "$ARCHIVE" "$UNPACKED"' EXIT
    curl --fail --silent --show-error --location --output "$ARCHIVE" \
        "https://github.com/realm/SwiftLint/releases/download/$VERSION/portable_swiftlint.zip"
    echo "$SHA256  $ARCHIVE" | shasum -a 256 --check --quiet || {
        echo "The SwiftLint $VERSION download does not match its pinned digest" >&2
        exit 1
    }
    unzip -q "$ARCHIVE" -d "$UNPACKED"
    echo "$SHA256" > "$UNPACKED/.archive-sha256"
    rm -rf "$TOOL"
    mv "$UNPACKED" "$TOOL"
fi

cd "$ROOT"
xcrun swift-format lint --strict --recursive App Packages
"$SWIFTLINT" lint --quiet
