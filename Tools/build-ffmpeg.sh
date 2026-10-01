#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the ffmpeg executable shipped inside the app: FFmpeg under the LGPL,
# arm64 only, without network access, with only what audio decoding needs.
# The source tarball is verified against the FFmpeg release signing key.
#
# Usage: Tools/build-ffmpeg.sh
# Result: build/ffmpeg/bin/ffmpeg

set -euo pipefail

# shellcheck source=Tools/versions.sh
. "$(dirname "$0")/versions.sh"
VERSION="$FFMPEG_VERSION"
KEY_FINGERPRINT="$FFMPEG_KEY_FINGERPRINT"

# The app targets macOS 14. Without this, the helper would inherit the
# deployment target of the build machine.
export MACOSX_DEPLOYMENT_TARGET=14.0

# What audio decoding needs, and nothing else.
DEMUXERS="aac,aiff,amr,asf,caf,flac,matroska,mov,mp3,ogg,wav"
PARSERS="aac,aac_latm,flac,mpegaudio,opus,vorbis"
DECODERS="aac,aac_latm,adpcm_ima_qt,adpcm_ms,alac,amrnb,amrwb,flac,mp3,mp3float,opus,vorbis,wmapro,wmav1,wmav2,pcm_alaw,pcm_mulaw,pcm_u8,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le,pcm_s32be,pcm_s32le,pcm_f32be,pcm_f32le,pcm_f64le"
FILTERS="aformat,anull,aresample"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/ffmpeg-source"
PREFIX="$ROOT/build/ffmpeg"
TARBALL="ffmpeg-$VERSION.tar.xz"

# Use Xcode's toolchain even when xcode-select points to the Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Removed first, so a build that fails leaves no claim about what is there.
rm -f "$PREFIX/BUILT_FROM"
mkdir -p "$WORK"
cd "$WORK"

for file in "$TARBALL" "$TARBALL.asc" ffmpeg-devel.asc; do
    if [ ! -f "$file" ]; then
        url="https://ffmpeg.org/releases/$file"
        if [ "$file" = ffmpeg-devel.asc ]; then url="https://ffmpeg.org/$file"; fi
        curl -fL "$url" -o "$file.part"
        mv "$file.part" "$file"
    fi
done

# A throwaway keyring leaves the user's own keyring untouched.
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --quiet --import ffmpeg-devel.asc
if ! gpg --status-fd 1 --verify "$TARBALL.asc" "$TARBALL" 2>/dev/null | grep -q "VALIDSIG .*$KEY_FINGERPRINT"; then
    echo "Signature check failed for $TARBALL" >&2
    exit 1
fi
echo "Signature verified, SHA256 $(shasum -a 256 "$TARBALL" | cut -d ' ' -f 1)"

rm -rf "ffmpeg-$VERSION"
tar -xf "$TARBALL"
cd "ffmpeg-$VERSION"

# Containers and codecs of common recordings: phones, voice recorders, video
# calls and downloaded videos.
./configure \
    --prefix="$PREFIX" \
    --arch=arm64 \
    --extra-cflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    --extra-ldflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    --cc=clang \
    --disable-everything \
    --disable-autodetect \
    --disable-network \
    --disable-doc \
    --disable-debug \
    --disable-ffplay \
    --disable-ffprobe \
    --enable-ffmpeg \
    --enable-swresample \
    --enable-protocol=file,pipe \
    --enable-demuxer="$DEMUXERS" \
    --enable-parser="$PARSERS" \
    --enable-decoder="$DECODERS" \
    --enable-filter="$FILTERS" \
    --enable-encoder=pcm_f32le,pcm_s16le \
    --enable-muxer=pcm_f32le,pcm_s16le,wav \
    | tee configure.log

if ! grep -q "License: LGPL version 2.1 or later" configure.log; then
    echo "The configuration is not LGPL only" >&2
    exit 1
fi

make -j "$(sysctl -n hw.ncpu)"
make install

# configure silently ignores unknown component names, so the built binary is
# checked for each one. The muxer is pcm_f32le here and f32le on the command
# line. Parsers are not listed by ffmpeg, so they are read from the list
# configure generated.
# The list is read whole before matching: grep -q stops at the first match,
# which under pipefail would fail the commands still writing to it.
require() {
    local listed
    listed="$("$PREFIX/bin/ffmpeg" -hide_banner "-${1}s" 2>/dev/null \
        | awk 'seen { print $2 } /^ *--/ { seen = 1 }' \
        | tr ',' '\n')"
    grep -qx "$2" <<< "$listed" || {
        echo "The build has no $2 $1" >&2
        exit 1
    }
}

# A helper built for a newer macOS than the app's minimum would fail to load
# there, without a clear error.
minimum="$(otool -l "$PREFIX/bin/ffmpeg" | awk '/LC_BUILD_VERSION/ {found = 1} found && /minos/ {print $2; exit}')"
if [ "$minimum" != "$MACOSX_DEPLOYMENT_TARGET" ]; then
    echo "The helper targets macOS $minimum, not $MACOSX_DEPLOYMENT_TARGET" >&2
    exit 1
fi

require muxer f32le
require muxer wav
require encoder pcm_s16le
for name in ${DEMUXERS//,/ }; do require demuxer "$name"; done
for name in ${DECODERS//,/ }; do require decoder "$name"; done
for name in ${FILTERS//,/ }; do require filter "$name"; done
for name in ${PARSERS//,/ }; do
    grep -q "&ff_${name}_parser," libavcodec/parser_list.c || {
        echo "The build has no $name parser" >&2
        exit 1
    }
done

# What this build came from, which Tools/package.sh checks before shipping
# the helper next to a source archive.
echo "ffmpeg $VERSION $(shasum -a 256 "$WORK/$TARBALL" | cut -d ' ' -f 1)" > "$PREFIX/BUILT_FROM"
echo "ffmpeg installed in $PREFIX/bin"
