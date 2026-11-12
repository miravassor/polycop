#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the test suite, or the tests named, with warnings as errors as CI has
# them. Prints what failed and how many tests ran, and keeps the whole log.
#
# Usage: Tools/test.sh [--thread | --address | --coverage] [name ...]
#   Tools/test.sh                                the whole suite
#   Tools/test.sh InterruptionTests              one suite
#   Tools/test.sh 'spacePlaysOutsideTheText()'   one test that belongs to no suite
#   Tools/test.sh --thread                       the suite under the thread sanitizer
#   Tools/test.sh --coverage                     the suite, with what it covers in build/Tests.xcresult
# A name is a suite, or a test function with its parentheses: most tests are
# functions of their own, outside any suite. Each sanitizer, and the coverage,
# builds into a folder of its own, so that switching does not build everything
# again.
# Fails when the build, a test or the test host fails, when Swift warns about
# the project's code, when a sanitizer reports, and when no test ran. On CI the
# whole log is printed as it comes, since a run that hangs is cancelled with
# nothing else to read.

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
    --coverage)
        build="tests-coverage"
        options+=(-enableCodeCoverage YES -resultBundlePath build/Tests.xcresult)
        # xcodebuild refuses to write over the results of an earlier run.
        rm -rf "$ROOT/build/Tests.xcresult"
        shift
        ;;
esac
for name in "$@"; do
    case "$name" in
        "" | --*)
            echo "Not a suite or a test: '$name'. One option at most, first." >&2
            exit 2
            ;;
    esac
    options+=("-only-testing:PolycopTests/$name")
done

cd "$ROOT"
mkdir -p build
log="build/$build.log"

# An empty array is unbound to the bash that ships with macOS.
run() {
    xcodebuild test \
        -project App/Polycop.xcodeproj \
        -scheme Polycop \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "build/$build" \
        ${options[@]+"${options[@]}"} \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
}
status=0
if [ -n "${CI:-}" ]; then
    run 2>&1 | tee "$log" || status=$?
else
    run > "$log" 2>&1 || status=$?
fi

# What the compiler says opens with a file's path, or with "macro expansion"
# inside #expect; the app's own log lines, which also say "error", open with
# a date.
grep -E '^(/.*|macro expansion .*): (error|warning): |^(error|ld|xcodebuild): |^✘ |SUMMARY: |Fatal error|crashed' "$log" |
    awk '!seen[$0]++' || true
if [ "$status" -ne 0 ]; then
    echo "Failed: see $log" >&2
    exit "$status"
fi
# A warning inside a macro's expansion is not made an error by the compiler.
# Only Swift's about a source file count: the linker has some of its own
# under a sanitizer.
if grep -qE '^(/.*\.swift:[0-9]+:[0-9]+|macro expansion .*): warning: ' "$log"; then
    echo "The build has a warning: see $log" >&2
    exit 1
fi
# The thread sanitizer reports a race and lets the tests go on.
if grep -qE '^SUMMARY: (Thread|Address)Sanitizer' "$log"; then
    echo "A sanitizer reported: see $log" >&2
    exit 1
fi
ran="$(sed -nE 's/^(✔|✘) Test run with ([0-9]+) tests? in .*/\2/p' "$log" | tail -1)"
if [ -z "$ran" ] || [ "$ran" -eq 0 ]; then
    echo "No test ran: check the names given. See $log" >&2
    exit 1
fi
grep -E '^✔ Test run with ' "$log" | tail -1
