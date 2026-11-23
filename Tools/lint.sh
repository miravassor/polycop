#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs both linters: swift-format for style, SwiftLint for size and complexity.
# SwiftLint is downloaded once at a pinned release and refused if its digest
# differs. Then checks the rules of AGENTS.md and ARCHITECTURE.md that a search
# can settle: SPDX headers, comment markers, documentation punctuation, layer
# boundaries and the reviewed list of files holding unsafe code.
#
# Usage: Tools/lint.sh
# Fails on a style violation, on any SwiftLint violation not listed in
# .swiftlint-baseline.json, or on a broken rule. The baseline lists the warnings
# already there and only ever shrinks. After removing one, and only while the
# lint passes, so that nothing new is taken in, rewrite it one field a line, so
# that its diff shows each entry removed:
#   build/swiftlint-$VERSION/swiftlint lint --quiet --write-baseline build/baseline.json
#   python3 -m json.tool build/baseline.json > .swiftlint-baseline.json

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
# The notices quote licences, which keep their own punctuation.
if git grep -nE '—|–' -- '*.md' ':!THIRD_PARTY_NOTICES.md'; then
    echo "No dashes as punctuation in the documentation" >&2
    failed=1
fi

# Searches git-tracked files, ignoring // comments (preserving :// URLs).
# Line-based: does not parse string literals or /* ... */ block comments.
grep_code() {
    local pattern="$1"
    shift
    local matches status=0
    matches="$(git grep --no-column --no-color -nE "$pattern" -- "$@")" || status=$?
    if [ "$status" -gt 1 ]; then
        return "$status"
    fi
    if [ -z "$matches" ]; then
        return 0
    fi
    printf '%s\n' "$matches" | PATTERN="$pattern" awk -F: '
        {
            code = substr($0, length($1) + length($2) + 3)
            sub(/(^|[[:space:]])\/\/.*/, "", code)
            if (code ~ ENVIRON["PATTERN"]) print
        }
    '
}

# Checks that files matching a pattern match an explicit allowlist exactly,
# printing matching lines for unexpected files and names for stale entries.
check_allowed_files() {
    local pattern="$1"
    local allowed="$2"
    local unexpected_message="$3"
    local stale_message="$4"
    shift 4

    local matches found allowed_sorted unexpected stale
    matches="$(grep_code "$pattern" "$@")"
    found="$(printf '%s\n' "$matches" | awk -F: 'NF { print $1 }' | LC_ALL=C sort -u)"
    allowed_sorted="$(printf '%s\n' "$allowed" | sed '/^$/d' | LC_ALL=C sort -u)"

    unexpected="$(LC_ALL=C comm -23 \
        <(printf '%s\n' "$found" | sed '/^$/d') \
        <(printf '%s\n' "$allowed_sorted" | sed '/^$/d'))"
    if [ -n "$unexpected" ]; then
        printf '%s\n' "$matches" | UNEXPECTED="$unexpected" awk -F: '
            BEGIN {
                n = split(ENVIRON["UNEXPECTED"], items, "\n")
                for (i = 1; i <= n; i++) bad[items[i]] = 1
            }
            $1 in bad { print }
        '
        echo "$unexpected_message" >&2
        failed=1
    fi
    stale="$(LC_ALL=C comm -13 \
        <(printf '%s\n' "$found" | sed '/^$/d') \
        <(printf '%s\n' "$allowed_sorted" | sed '/^$/d'))"
    if [ -n "$stale" ]; then
        printf '%s\n' "$stale"
        echo "$stale_message" >&2
        failed=1
    fi
}

import_kind='((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?'

# TermFinder is the one view still sitting under Glossary/.
check_allowed_files \
    "(^|[[:space:]])import[[:space:]]+${import_kind}(SwiftUI|SwiftUICore)([^A-Za-z0-9_]|$)" \
    "App/Polycop/Glossary/TermFinder.swift" \
    "SwiftUI belongs in Views/ and Application/, not lower layers" \
    "Listed as a SwiftUI exception in Tools/lint.sh but no longer imports SwiftUI; remove it from the list" \
    'App/Polycop/*.swift' ':!App/Polycop/Application/' ':!App/Polycop/Views/'

# Existing lower-layer files that import AppKit; new ones belong in Views/ or Application/.
appkit_allowed="$(printf '%s\n' \
    App/Polycop/Audio/PlaybackInterruptions.swift \
    App/Polycop/Audio/VideoPresentation.swift \
    App/Polycop/Glossary/Documents.swift \
    App/Polycop/History/TranscriptImport.swift \
    App/Polycop/Output/WordDocument.swift)"
check_allowed_files \
    "(^|[[:space:]])import[[:space:]]+${import_kind}(AppKit|Cocoa)([^A-Za-z0-9_]|$)" \
    "$appkit_allowed" \
    "AppKit belongs in Views/ and Application/, not lower layers (review before listing an exception)" \
    "Listed as an AppKit exception in Tools/lint.sh but no longer imports AppKit; remove it from the list" \
    'App/Polycop/*.swift' ':!App/Polycop/Application/' ':!App/Polycop/Views/'

check_allowed_files \
    '(^|[^A-Za-z0-9_])AppModel([^A-Za-z0-9_]|$)' \
    "" \
    "Lower layers must not depend on AppModel" \
    "" \
    'App/Polycop/*.swift' ':!App/Polycop/Application/' ':!App/Polycop/Views/'

# Files in the app target calling explicit unsafe Swift or C memory APIs.
# Implicit & C pointer bridging is not caught by text search; list every file
# matched here so that a new one gets a second reading and a sanitizer run.
unsafe_allowed="$(printf '%s\n' \
    App/Polycop/Audio/AudioDecoder.swift \
    App/Polycop/Engine/AudioCppEngine+Moss.swift \
    App/Polycop/Engine/AudioCppEngine+Qwen.swift \
    App/Polycop/Engine/AudioCppEngine+Voxtral.swift \
    App/Polycop/Engine/AudioCppEngine.swift \
    App/Polycop/Engine/WhisperEngine+Speech.swift \
    App/Polycop/Engine/WhisperEngine.swift)"
unsafe_pattern='(^|[^A-Za-z0-9_])((Autoreleasing)?Unsafe(Mutable)?(Raw)?(Buffer)?Pointer|UnsafeContinuation|UnsafeCurrentTask|CVaListPointer|withUnsafe[A-Za-z0-9_]+|unsafeUninitializedCapacity|Unmanaged|unsafeBitCast|unsafeDowncast|unsafeLoad(Unaligned)?|unsafelyUnwrapped|OpaquePointer|assumingMemoryBound|bindMemory|withMemoryRebound|withUTF8|withCString|withContiguous(Mutable)?StorageIfAvailable|bytesNoCopy)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])(strdup|malloc|calloc|realloc|free|memcpy|memmove|memset)[[:space:]]*\('
check_allowed_files \
    "$unsafe_pattern" \
    "$unsafe_allowed" \
    "Unsafe code outside the reviewed list in Tools/lint.sh; review the C boundary and run sanitizers before listing it" \
    "Listed as unsafe in Tools/lint.sh but no longer uses unsafe APIs; remove it from the list" \
    'App/Polycop/*.swift'

exit "$failed"
