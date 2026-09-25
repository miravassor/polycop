#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Writes the clips the decoder tests read: one French sentence spoken by a
# system voice, in every container the app accepts. The clips are committed, so
# this script runs only when the matrix changes.
#
# Needs a complete ffmpeg (brew install ffmpeg). The one shipped in the app
# decodes but does not encode, which is why it cannot build its own fixtures.
#
# Usage: Tools/fixtures.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/App/PolycopTests/Fixtures/formats"
VOICE="Flo (Français (France))"
PHRASE="Bonjour, ceci est un cours de psychologie clinique."

command -v ffmpeg >/dev/null || {
    echo "ffmpeg not found. brew install ffmpeg" >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SOURCE="$WORK/source.aiff"
say -v "$VOICE" -o "$SOURCE" "$PHRASE"

mkdir -p "$OUT"

# Same audio every time, so a duration difference between two files can only
# come from the codec.
write() {
    local name="$1"
    shift
    ffmpeg -nostdin -v error -y -i "$SOURCE" "$@" "$OUT/$name"
}

write clip.wav -c:a pcm_s16le -ar 16000 -ac 1
write clip.aiff -c:a pcm_s16be
write clip.caf -c:a alac
write clip.flac -c:a flac
write clip.mp3 -c:a libmp3lame -b:a 64k
write clip.m4a -c:a aac -b:a 64k
write clip.mp4 -c:a aac -b:a 64k
write clip.mov -c:a aac -b:a 64k
write clip.aac -c:a aac -b:a 64k
# Vorbis has no external encoder here, and the native one writes stereo only.
# The app downmixes on the way in, so the channel count of a fixture is free.
write clip.ogg -c:a vorbis -strict -2 -ac 2 -q:a 3
write clip.opus -c:a libopus -b:a 32k
write clip.webm -c:a libopus -b:a 32k
write clip.mkv -c:a vorbis -strict -2 -ac 2 -q:a 3
write clip.wma -c:a wmav2 -b:a 64k

# A downloaded video: the app ignores the picture.
ffmpeg -nostdin -v error -y \
    -f lavfi -i "color=c=gray:s=160x120:r=5" -i "$SOURCE" \
    -map 0:v -map 1:a -shortest \
    -c:v mpeg4 -c:a vorbis -strict -2 -ac 2 -q:a 3 \
    "$OUT/clip-video.mkv"

# A video without an audio track: the app must report it rather than call the
# file damaged.
ffmpeg -nostdin -v error -y \
    -f lavfi -i "color=c=gray:s=160x120:r=5:d=2" \
    -c:v mpeg4 \
    "$OUT/clip-silent.mp4"

ls -1 "$OUT"
