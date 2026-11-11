#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the test suite, or the tests named, with warnings as errors as CI has
# them. Prints what failed and how many tests ran, and keeps the whole log.
#
# Usage: Tools/test.sh [--thread | --address] [name ...]
#   Tools/test.sh                                the whole suite
#   Tools/test.sh InterruptionTests              one suite
#   Tools/test.sh 'spacePlaysOutsideTheText()'   one test that belongs to no suite
#   Tools/test.sh --thread                       the suite under the thread sanitizer
# A name is a suite, or a test function with its parentheses: most tests are
# functions of their own, outside any suite. Each sanitizer builds into a folder
# of its own, so that switching does not build everything again.
# Fails when the build, a test or the test host fails, when Swift warns about
# the project's code, and when no test ran.

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

build="tests"
options=()
case "${1:-}" in
    --thread)
        build="tests-thread"
        options+=(-enableThreadSanitizer YES)
        shift
        ;;
    --address)
        build="tests-address"
        options+=(-enableAddressSanitizer YES)
        shift
        ;;
esac
for name in "$@"; do
    options+=("-only-testing:PolycopTests/$name")
done

cd "$ROOT"
mkdir -p build
log="build/$build.log"
status=0
# An empty array is unbound to the bash that ships with macOS.
xcodebuild test \
    -project App/Polycop.xcodeproj \
    -scheme Polycop \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "build/$build" \
    ${options[@]+"${options[@]}"} \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES > "$log" 2>&1 || status=$?

# What the compiler says opens with a file's path, or with "macro expansion"
# inside #expect; the app's own log lines, which also say "error", open with
# a date.
said='^(/.*|macro expansion .*): (error|warning): '
grep -E "$said|^(error|ld|xcodebuild): |^✘ |SUMMARY: |Fatal error|crashed" "$log" |
    awk '!seen[$0]++' || true
if [ "$status" -ne 0 ]; then
    echo "Failed: see $log" >&2
    exit "$status"
fi
# A warning inside a macro's expansion is not made an error by the compiler.
if grep -qE "${said/(error|warning)/warning}" "$log"; then
    echo "The build has a warning: see $log" >&2
    exit 1
fi
ran="$(sed -nE 's/^(✔|✘) Test run with ([0-9]+) tests? in .*/\2/p' "$log" | tail -1)"
if [ -z "$ran" ] || [ "$ran" -eq 0 ]; then
    echo "No test ran: check the names given. See $log" >&2
    exit 1
fi
grep -E '^✔ Test run with ' "$log" | tail -1
