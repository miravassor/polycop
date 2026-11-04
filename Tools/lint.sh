#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs both linters: swift-format for style, SwiftLint for size and complexity.
# SwiftLint is downloaded once at a pinned release and refused if its digest
# differs. Then checks three rules of AGENTS.md that a search can settle.
#
# Usage: Tools/lint.sh
# Fails on a style violation, on any SwiftLint violation not listed in
# .swiftlint-baseline.json, or on a broken rule. The baseline lists the warnings
# already there; it only ever shrinks. After removing one, rewrite it with
#   build/swiftlint-$VERSION/swiftlint lint --quiet --write-baseline .swiftlint-baseline.json

set -euo pipefail

VERSION="0.65.1"
SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"

# Use Xcode's toolchain even when xcode-select points to the Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/build/swiftlint-$VERSION"

# shellcheck source=Tools/fetch.sh
. "$(dirname "$0")/fetch.sh"
fetch "https://github.com/realm/SwiftLint/releases/download/$VERSION/portable_swiftlint.zip" \
    "$SHA256" "$TOOL"

cd "$ROOT"
xcrun swift-format lint --strict --recursive App Packages
"$TOOL/swiftlint" lint --quiet --strict --baseline .swiftlint-baseline.json

failed=0
for file in $(git ls-files '*.swift' '*.sh' '.github/workflows/*.yml'); do
    head -3 "$file" | grep -q 'SPDX-License-Identifier: GPL-3.0-or-later' ||
        { echo "$file: no SPDX licence line in its first lines" >&2; failed=1; }
done
# The words are split so that this file does not match itself.
if git grep -nwE 'TO''DO|FIX''ME' -- '*.swift' '*.sh' '*.yml'; then
    echo "A problem left for later is an issue, not a comment in the code" >&2
    failed=1
fi
if git grep -nE '—|–' -- '*.md'; then
    echo "No dashes as punctuation in the documentation" >&2
    failed=1
fi
exit "$failed"
