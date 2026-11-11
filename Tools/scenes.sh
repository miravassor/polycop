#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Captures the app's scenes, the states listed in App/PolycopTests/Scenes, each
# in a window of its own on a made-up library: the smallest window and one that
# fills a 13 inch screen, light and dark. For looking at, and for the
# screenshots a pull request that changes the interface needs; nothing is
# compared.
#
# Usage: Tools/scenes.sh [scene ...]
#   Tools/scenes.sh                      every scene
#   Tools/scenes.sh transcript warnings  those two
# The pictures and an index.html showing them go to build/scenes.
#
# The windows open behind the others and are captured one by one, never the
# screen, so they draw as a window in the background does: selections and
# accents in grey. It takes a screen that is neither locked nor asleep, and
# the Screen Recording permission for the terminal.

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The pictures of an earlier run would pass for this one's.
mkdir -p build/scenes
find build/scenes -mindepth 1 -delete

# Captures each window the test announces, then tells the test to go on.
capture() {
    while true; do
        for announced in build/scenes/*.window; do
            [ -e "$announced" ] || continue
            name="${announced%.window}"
            [ -e "$name.done" ] && continue
            screencapture -x -o -l "$(cat "$announced")" "$name.png" 2> /dev/null ||
                touch "$name.failed"
            touch "$name.done"
        done
        sleep 0.2
    done
}
capture &
watcher=$!
# The bash that ships with macOS leaves the loop running when interrupted,
# unless the interruption is made an exit.
trap 'kill "$watcher" 2>/dev/null || true' EXIT
trap 'exit 130' INT TERM

status=0
TEST_RUNNER_SCENE_DIR="$ROOT/build/scenes" TEST_RUNNER_SCENES="$*" xcodebuild test \
    -project App/Polycop.xcodeproj \
    -scheme Polycop \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/tests \
    -only-testing:PolycopTests/SceneShots > build/scenes/test.log 2>&1 || status=$?
# What failed, each with the reason the test gave on the line after it.
awk '/^\/.*: error: / || /^✘ / { if (!seen[$0]++) print; said = /recorded an issue/; next }
    said && /^↳ / { print } { said = 0 }' build/scenes/test.log
failed="$(find build/scenes -name '*.failed' | wc -l | tr -d ' ')"
find build/scenes \( -name '*.window' -o -name '*.done' -o -name '*.failed' \) -delete

count=0
{
    echo '<!doctype html><meta charset="utf-8"><title>Polycop scenes</title>'
    echo '<style>body{font:14px -apple-system;margin:24px}figure{display:inline-block;margin:0 16px 24px 0;vertical-align:top}img{max-width:640px;display:block;border:1px solid #8884}</style>'
    for picture in build/scenes/*.png; do
        [ -e "$picture" ] || continue
        name="$(basename "$picture" .png)"
        echo "<figure><figcaption>$name</figcaption><img src=\"$name.png\"></figure>"
        count=$((count + 1))
    done
} > build/scenes/index.html

if [ "$failed" -ne 0 ]; then
    echo "$failed windows could not be captured. That takes a screen that is neither locked" >&2
    echo "nor asleep, and the Screen Recording permission for the terminal." >&2
    exit 1
fi
if [ "$status" -ne 0 ] || [ "$count" -eq 0 ]; then
    echo "Failed after $count pictures: see build/scenes/test.log" >&2
    exit 1
fi
echo "$count pictures in build/scenes, shown by build/scenes/index.html"
