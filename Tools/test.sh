#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the test suite, or the tests named, with warnings as errors as CI has
# them. Prints what failed and how many tests ran, and keeps the whole log.
#
# Usage: Tools/test.sh [--thread | --address] [name ...]
#   Tools/test.sh                              the whole suite
#   Tools/test.sh PlayerTests 'opensAFile()'   one suite and one test
#   Tools/test.sh --thread                     the suite under the thread sanitizer
# A name is a suite or a test function of PolycopTests. Each sanitizer builds
# into a folder of its own, so that switching does not build everything again.
# Fails when the build or a test fails, and when no test ran.

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

# Compiler messages open with the file's path; the app's own log lines, which
# also say "error", open with a date.
grep -E '^/.*: (error|warning): |^(error|ld): |^✘ |SUMMARY: ' "$log" | awk '!seen[$0]++' || true
ran="$(sed -nE 's/^(✔|✘) Test run with ([0-9]+) tests? in .*/\2/p' "$log" | tail -1)"
if [ "$status" -ne 0 ]; then
    echo "Failed: see $log" >&2
    exit "$status"
fi
if [ -z "$ran" ] || [ "$ran" -eq 0 ]; then
    echo "No test ran: check the names given. See $log" >&2
    exit 1
fi
grep -E '^✔ Test run with ' "$log" | tail -1
