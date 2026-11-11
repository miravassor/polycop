#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks a branch before its pull request: nothing left uncommitted, commit
# subjects in lower case, the lint, the pinned versions, the notices and the
# test suite. Then prints the table of AGENTS.md that says what each kind of
# change needs, beside the folders this branch touches, for its author to
# answer: a script can see which files changed, not what the change needs.
#
# Usage: Tools/preflight.sh [--no-tests] [base]
#   base is what the branch is compared with, origin/main by default.
#   --no-tests leaves the suite out, for a first look while still building.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

tests=1
base="origin/main"
for argument in "$@"; do
    case "$argument" in
        --no-tests) tests=0 ;;
        *) base="$argument" ;;
    esac
done
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
# A class, since a range such as a-z takes capitals in too under most locales.
while IFS= read -r subject; do
    case "$subject" in
        [[:lower:]]*) ;;
        *) fail "Subject not in lower case: $subject" ;;
    esac
done <<< "$subjects"

files="$(git diff --name-only "$base...HEAD")"

Tools/lint.sh || fail "Tools/lint.sh"
Tools/check-versions.sh || fail "Tools/check-versions.sh"
cmp -s THIRD_PARTY_NOTICES.md App/Polycop/Resources/Licenses/ThirdPartyNotices.txt ||
    fail "The notices shipped in the app differ from THIRD_PARTY_NOTICES.md"
if grep -q '^\.github/' <<< "$files"; then
    Tools/lint-workflows.sh || fail "Tools/lint-workflows.sh"
fi
if [ "$tests" -eq 1 ]; then
    Tools/test.sh || fail "Tools/test.sh"
fi

lines="$(git diff --numstat "$base...HEAD" -- . ':!App/PolycopTests' |
    awk '{ sum += $1 + $2 } END { print sum + 0 }')"
echo
echo "This branch changes $lines lines outside the tests, in:"
# A folder of the app, or else the first folder or the file itself.
awk -F/ 'NF {
    place = ($1 == "App" && $2 == "Polycop" && NF > 3) ? $1 "/" $2 "/" $3 : (NF > 1 ? $1 : $0)
    count[place]++
} END { for (place in count) printf "  %s (%d)\n", place, count[place] }' <<< "$files" | sort
echo
echo "What a change needs before it is merged, from AGENTS.md:"
awk -F' *[|] *' '/^  [|] It changes [|]/ { table = 1; next }
    table && /^  [|]---/ { next }
    table && !/^  [|]/ { exit }
    table { printf "  [ ] %s: %s\n", $2, $3 }' AGENTS.md

exit "$failed"
