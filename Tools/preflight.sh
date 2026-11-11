#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks a branch before its pull request: nothing left uncommitted, commit
# subjects in lower case, the lint, the pinned versions and the test suite.
# Then lists what the table of "Commits and pull requests" in AGENTS.md asks of
# a change that touches these files, for the author to answer: a script can see
# that a test changed, not that it is the right one.
#
# Usage: Tools/preflight.sh [--no-tests] [base]
#   base is what the branch is compared with, origin/main by default.
#   --no-tests leaves the suite out, for a first look while still building.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

tests=1
if [ "${1:-}" = "--no-tests" ]; then
    tests=0
    shift
fi
base="${1:-origin/main}"
failed=0

fail() {
    echo "✘ $1" >&2
    failed=1
}

if [ -n "$(git status --porcelain)" ]; then
    git status --short
    fail "Files left uncommitted: commit them, or remove what does not belong"
fi

subjects="$(git log --format=%s "$base..HEAD")"
if [ -z "$subjects" ]; then
    echo "No commit on this branch that $base lacks" >&2
    exit 1
fi
while IFS= read -r subject; do
    case "$subject" in
        [a-z]*) ;;
        *) fail "Subject not in lower case: $subject" ;;
    esac
done <<< "$subjects"

files="$(git diff --name-only "$base...HEAD")"
touches() { grep -qE "$1" <<< "$files"; }

Tools/lint.sh || fail "Tools/lint.sh"
Tools/check-versions.sh || fail "Tools/check-versions.sh"
cmp -s THIRD_PARTY_NOTICES.md App/Polycop/Resources/Licenses/ThirdPartyNotices.txt ||
    fail "The notices shipped in the app differ from THIRD_PARTY_NOTICES.md"
if touches '^\.github/'; then
    Tools/lint-workflows.sh || fail "Tools/lint-workflows.sh"
fi
if [ "$tests" -eq 1 ]; then
    Tools/test.sh || fail "Tools/test.sh"
fi

lines="$(git diff --numstat "$base...HEAD" -- . ':!App/PolycopTests' |
    awk '{ sum += $1 + $2 } END { print sum + 0 }')"
echo
echo "$(wc -l <<< "$files" | tr -d ' ') files changed, $lines lines outside the tests."
echo "What AGENTS.md asks of this change:"
ask() { echo "  [ ] $1"; }
met() { echo "  [x] $1"; }

if touches '^App/Polycop/'; then
    if touches '^App/PolycopTests/'; then
        met "a test: the tests changed"
    else
        ask "a test, or why none fits: no test changed"
    fi
    if touches '^CHANGELOG\.md$'; then
        met "a line in CHANGELOG.md"
    else
        ask "a line under Unreleased in CHANGELOG.md, if a user sees or does anything differently"
    fi
fi
if touches '^App/Polycop/Views/'; then
    ask "screenshots at the smallest window and full screen, light and dark"
    ask "a link to the Apple page an interface or API choice follows"
fi
if touches '^App/Polycop/(Engine|Audio)/|^Tools/versions\.sh$' ||
    git diff "$base...HEAD" -- App/Polycop | grep -qE '^\+.*Unsafe[A-Za-z]*Pointer'; then
    ask "Tools/test.sh --thread and --address with the models installed, and a second reading"
fi
if touches '^App/Polycop/History/|^App/PolycopTests/Fixtures/records/|^\.github/workflows/'; then
    ask "a second reading; for what is stored, a record in Fixtures/records and an optional property"
fi
if touches 'Package\.swift$|Package\.resolved$|^Tools/versions\.sh$'; then
    ask "a dependency changes in a pull request of its own, as CONTRIBUTING.md says"
fi
if touches '^Tools/'; then
    if touches '^(AGENTS|ARCHITECTURE|CONTRIBUTING)\.md$'; then
        met "the document that describes a script: one changed"
    else
        ask "the document that describes a script (AGENTS.md, ARCHITECTURE.md, CONTRIBUTING.md)"
    fi
fi
if touches '^App/Polycop/Models/ModelCatalog\.swift$'; then
    ask "for a model setting, a measurement on corrected transcripts and how it was made"
fi

exit "$failed"
