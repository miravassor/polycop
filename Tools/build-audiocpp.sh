#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the audio.cpp library the app links for Qwen3-ASR, MOSS and Voxtral:
# its C API only, arm64, Metal, with no other model family compiled in. The
# source is checked out at a pinned commit and refused if the checkout differs.
#
# Usage: Tools/build-audiocpp.sh
# Result: Packages/AudioCppFramework/audiocpp.xcframework, and the
# audiocpp_cli of the same source that the parity test compares it with.

set -euo pipefail

# shellcheck source=Tools/versions.sh
. "$(dirname "$0")/versions.sh"
VERSION="$AUDIOCPP_VERSION"
COMMIT="$AUDIOCPP_COMMIT"

export MACOSX_DEPLOYMENT_TARGET=14.0
# Use Xcode's toolchain even when xcode-select points to the Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/build/audiocpp-source"
BUILD="$ROOT/build/audiocpp-build"
FRAMEWORK="$ROOT/build/audiocpp/audiocpp.framework"
OUTPUT="$ROOT/Packages/AudioCppFramework/audiocpp.xcframework"

if [ ! -d "$SOURCE/.git" ]; then
    git clone --depth 1 --branch "$VERSION" https://github.com/0xShug0/audio.cpp.git "$SOURCE"
fi
if [ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]; then
    echo "The checkout in $SOURCE is not audio.cpp $VERSION ($COMMIT)" >&2
    exit 1
fi
# Untracked and ignored files count too: the build compiles in every model
# specification file it finds.
[ -z "$(git -C "$SOURCE" status --porcelain --ignored)" ] || {
    echo "The audio.cpp checkout has local changes; refusing to package them as $VERSION" >&2
    exit 1
}

# OpenMP is off because Apple's compiler ships no runtime for it. The model
# specifications are compiled in, so the library needs no files at run time.
# Options that would add network code or fetch unpinned sources are off by
# name, so a new upstream default cannot turn them on.
cmake -S "$SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DAUDIOCPP_BUILD_C_API=ON \
    -DAUDIOCPP_DEPLOYMENT_BUILD=ON \
    -DAUDIOCPP_MODEL_SET=custom \
    -DAUDIOCPP_MODELS="qwen3_asr;moss_transcribe_diarize;voxtral_realtime" \
    -DENGINE_ENABLE_METAL=ON \
    -DENGINE_ENABLE_NATIVE_CPU=OFF \
    -DENGINE_ENABLE_OPENMP=OFF \
    -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=OFF \
    -DAUDIOCPP_STATIC_ESPEAK=OFF \
    -DGGML_CPU_KLEIDIAI=OFF \
    -DSPM_ABSL_PROVIDER=internal \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON
cmake --build "$BUILD" --target audiocpp audiocpp_cli -j "$(sysctl -n hw.perflevel0.logicalcpu)"

# A framework rather than a bare library: Xcode embeds and signs it like the
# whisper.cpp one, and the module map lets Swift import the C header.
rm -rf "$FRAMEWORK" "$OUTPUT"
mkdir -p "$FRAMEWORK/Versions/A/Headers" "$FRAMEWORK/Versions/A/Modules" \
    "$FRAMEWORK/Versions/A/Resources"
cp "$BUILD/bin/libaudiocpp.0.1.0.dylib" "$FRAMEWORK/Versions/A/audiocpp"
install_name_tool -id @rpath/audiocpp.framework/Versions/A/audiocpp \
    "$FRAMEWORK/Versions/A/audiocpp"
cp "$SOURCE/include/audiocpp.h" "$FRAMEWORK/Versions/A/Headers/"
cp "$SOURCE/LICENSE" "$FRAMEWORK/Versions/A/Resources/LICENSE"
cat > "$FRAMEWORK/Versions/A/Modules/module.modulemap" <<'EOF'
framework module audiocpp [system] {
    umbrella header "audiocpp.h"
    export *
}
EOF
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>audiocpp</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.miravassor.Polycop.audiocpp</string>
    <key>CFBundleName</key>
    <string>audiocpp</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION#v}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION#v}</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MACOSX_DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
ln -s A "$FRAMEWORK/Versions/Current"
for item in audiocpp Headers Modules Resources; do
    ln -s "Versions/Current/$item" "$FRAMEWORK/$item"
done

xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$OUTPUT"
# What this build came from, which Tools/package.sh checks.
echo "audio.cpp $VERSION $COMMIT" > "$ROOT/build/audiocpp/BUILT_FROM"
echo "Built $OUTPUT from audio.cpp $VERSION ($COMMIT)"
