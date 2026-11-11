#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Captures the app's scenes, the states listed in App/PolycopTests/Scenes, each
# in a window of its own on a made-up library: the smallest window and a full
# screen, light and dark. For looking at, and for the screenshots a pull
# request that changes the interface needs; nothing is compared.
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
            screencapture -x -o -l "$(cat "$announced")" "$name.png" 2> /dev/null || true
            touch "$name.done"
        done
        sleep 0.2
    done
}
capture &
watcher=$!
trap 'kill "$watcher" 2>/dev/null || true' EXIT

status=0
TEST_RUNNER_SCENE_DIR="$ROOT/build/scenes" TEST_RUNNER_SCENES="$*" xcodebuild test \
    -project App/Polycop.xcodeproj \
    -scheme Polycop \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/tests \
    -only-testing:PolycopTests/SceneShots > build/scenes/test.log 2>&1 || status=$?
grep -E '^/.*: error: |^✘ ' build/scenes/test.log | awk '!seen[$0]++' || true
find build/scenes \( -name '*.window' -o -name '*.done' \) -delete

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

if [ "$count" -eq 0 ] && grep -q '^✘ .*was not captured' build/scenes/test.log; then
    echo "No window could be captured. That takes a screen that is neither locked nor" >&2
    echo "asleep, and the Screen Recording permission for the terminal." >&2
    exit 1
fi
if [ "$status" -ne 0 ] || [ "$count" -eq 0 ]; then
    echo "Failed after $count pictures: see build/scenes/test.log" >&2
    exit 1
fi
echo "$count pictures in build/scenes, shown by build/scenes/index.html"
