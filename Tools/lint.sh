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

# Searches git-tracked files while stripping // comments (preserving :// URLs).
grep_code() {
    local pattern="$1"
    shift
    local matches status=0
    matches="$(git grep -nE "$pattern" -- "$@")" || status=$?
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

# WordDocument uses NSAttributedString to write .docx files.
ui_imports="$(grep_code '(^|[[:space:]])import[[:space:]]+(SwiftUI|AppKit)([^A-Za-z0-9_]|$)' \
    App/Polycop/Output/ App/Polycop/Engine/ App/Polycop/Models/ App/Polycop/Support/ \
    ':!App/Polycop/Output/WordDocument.swift')"
if [ -n "$ui_imports" ]; then
    printf '%s\n' "$ui_imports"
    echo "Lower layers must not import SwiftUI or AppKit (WordDocument.swift is the one exception)" >&2
    failed=1
fi

# TermFinder is the one view still sitting under Glossary/.
swiftui_imports="$(grep_code '(^|[[:space:]])import[[:space:]]+SwiftUI([^A-Za-z0-9_]|$)' \
    'App/Polycop/' ':!App/Polycop/Application/' ':!App/Polycop/Views/' \
    ':!App/Polycop/Glossary/TermFinder.swift')"
if [ -n "$swiftui_imports" ]; then
    printf '%s\n' "$swiftui_imports"
    echo "SwiftUI belongs in Views/ and Application/, not lower layers" >&2
    failed=1
fi

app_model_refs="$(grep_code '(^|[^A-Za-z0-9_])AppModel([^A-Za-z0-9_]|$)' \
    'App/Polycop/' ':!App/Polycop/Application/' ':!App/Polycop/Views/')"
if [ -n "$app_model_refs" ]; then
    printf '%s\n' "$app_model_refs"
    echo "Lower layers must not depend on AppModel" >&2
    failed=1
fi

# Every file in the app target that touches raw pointers or unmanaged memory is
# listed here so that a new one gets a second reading and a sanitizer run.
unsafe_allowed="$(printf '%s\n' \
    App/Polycop/Audio/AudioDecoder.swift \
    App/Polycop/Engine/AudioCppEngine+Moss.swift \
    App/Polycop/Engine/AudioCppEngine+Qwen.swift \
    App/Polycop/Engine/AudioCppEngine+Voxtral.swift \
    App/Polycop/Engine/AudioCppEngine.swift \
    App/Polycop/Engine/WhisperEngine+Speech.swift \
    App/Polycop/Engine/WhisperEngine.swift | LC_ALL=C sort -u)"
unsafe_pattern='(^|[^A-Za-z0-9_])((Autoreleasing)?Unsafe(Mutable)?(Raw)?(Buffer)?Pointer|UnsafeContinuation|withUnsafe[A-Za-z]+|Unmanaged|unsafeBitCast|unsafeDowncast|OpaquePointer|assumingMemoryBound|bindMemory)([^A-Za-z0-9_]|$)'
unsafe_found="$(grep_code "$unsafe_pattern" App/Polycop/ | awk -F: '{print $1}' | LC_ALL=C sort -u)"

unexpected_unsafe="$(LC_ALL=C comm -23 <(printf '%s\n' "$unsafe_found") <(printf '%s\n' "$unsafe_allowed") | sed '/^$/d')"
if [ -n "$unexpected_unsafe" ]; then
    printf '%s\n' "$unexpected_unsafe"
    echo "Unsafe code outside the reviewed list in Tools/lint.sh; review the C boundary and run sanitizers before listing it" >&2
    failed=1
fi
stale_unsafe="$(LC_ALL=C comm -13 <(printf '%s\n' "$unsafe_found") <(printf '%s\n' "$unsafe_allowed") | sed '/^$/d')"
if [ -n "$stale_unsafe" ]; then
    printf '%s\n' "$stale_unsafe"
    echo "Listed as unsafe in Tools/lint.sh but no longer uses unsafe APIs; remove it from the list" >&2
    failed=1
fi

exit "$failed"
