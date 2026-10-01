#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a locally signed app and archive. No publication or notarization.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# A release must match a commit, so the working tree has to be clean.
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "Commit or stash your changes before packaging" >&2
    exit 1
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# shellcheck source=Tools/versions.sh
. "$ROOT/Tools/versions.sh"
"$ROOT/Tools/check-versions.sh"

# The binaries shipped must come from the sources shipped beside them, so a
# build left from another version is built again.
FFMPEG_TARBALL="$ROOT/build/ffmpeg-source/ffmpeg-$FFMPEG_VERSION.tar.xz"
ffmpeg_built() {
    [ -x "$ROOT/build/ffmpeg/bin/ffmpeg" ] && [ -f "$FFMPEG_TARBALL" ] \
        && [ "$(cat "$ROOT/build/ffmpeg/BUILT_FROM" 2>/dev/null)" \
            = "ffmpeg $FFMPEG_VERSION $(shasum -a 256 "$FFMPEG_TARBALL" | cut -d ' ' -f 1)" ]
}
audiocpp_built() {
    [ -d "$ROOT/Packages/AudioCppFramework/audiocpp.xcframework" ] \
        && [ "$(cat "$ROOT/build/audiocpp/BUILT_FROM" 2>/dev/null)" \
            = "audio.cpp $AUDIOCPP_VERSION $AUDIOCPP_COMMIT" ]
}
ffmpeg_built || "$ROOT/Tools/build-ffmpeg.sh"
ffmpeg_built || { echo "build/ffmpeg is not FFmpeg $FFMPEG_VERSION" >&2; exit 1; }
audiocpp_built || "$ROOT/Tools/build-audiocpp.sh"
audiocpp_built || { echo "The audio.cpp framework is not $AUDIOCPP_VERSION" >&2; exit 1; }

# Ad-hoc signatures have no Team ID for hardened library validation.
xcodebuild build \
    -project "$ROOT/App/Polycop.xcodeproj" \
    -scheme Polycop -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT/build/local-derived" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO

APP="$ROOT/build/local-derived/Build/Products/Release/Polycop.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="${POLYCOP_PACKAGE_DIR:-$ROOT/build/releases/Polycop-$VERSION}"
# Exclusive creation keeps every previous package, including the same version.
mkdir -p "$ROOT/build/releases"
mkdir "$OUTPUT" || { echo "Package already exists: $OUTPUT" >&2; exit 1; }
STAGE="$(mktemp -d "$OUTPUT/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
FOLDER="$STAGE/Polycop $VERSION"
mkdir -p "$FOLDER"
ditto "$APP" "$FOLDER/Polycop.app"
codesign --verify --deep --strict "$FOLDER/Polycop.app"
cat > "$FOLDER/READ-ME.txt" <<NOTE
Polycop $VERSION

For Apple Silicon Macs with macOS 14 or later.

INSTALL

Check the archive against the SHA-256 checksum published with it.
Quit any older version, then move Polycop.app to Applications. Replacing an
older version keeps your library in ~/Library/Application Support/Polycop/.
Nothing is installed or deleted automatically.

FIRST LAUNCH

Polycop has no Apple Developer ID signature, so macOS refuses to open it the
first time. Open System Settings, then Privacy & Security, and click
Open Anyway next to the message about Polycop:
https://support.apple.com/102445
If there is no Open Anyway button, run this once in Terminal:
    xattr -dr com.apple.quarantine /Applications/Polycop.app
It removes the mark macOS puts on downloaded files, for this app only. Do it
only if the checksum matched.

USE

Download a model in the app, add your recordings, then click Start
Transcription. Listen back, correct the text and export it. Corrections are
kept in the library, apart from the exports. Help > Keyboard Shortcuts lists
the shortcuts, including Shift Command Space to play and pause. Recordings
never leave your Mac.

SOURCE

The Source folder holds the code of this version and the sources of the
bundled libraries. Speech recognition models are downloaded separately, under
their own licences.
NOTE

SOURCE="$FOLDER/Source"
mkdir -p "$SOURCE/Dependencies"
# The source is exactly the commit the app was built from.
git -C "$ROOT" archive --format=tar HEAD | tar -C "$SOURCE" -xf -
for name in audiocpp whisper; do
    if [ "$name" = audiocpp ]; then
        CHECKOUT="$ROOT/build/audiocpp-source"
        REF="$AUDIOCPP_COMMIT"
    else
        CHECKOUT="$ROOT/build/whisper-source"
        # By commit: a tag can be moved, the commit of the shipped build cannot.
        REF="$WHISPER_COMMIT"
        if [ ! -d "$CHECKOUT/.git" ]; then
            git clone --depth 1 --branch "$WHISPER_VERSION" \
                https://github.com/ggml-org/whisper.cpp.git "$CHECKOUT"
        fi
    fi
    git -C "$CHECKOUT" diff --quiet HEAD --
    test "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$(git -C "$CHECKOUT" rev-parse "$REF^{commit}")"
    git -C "$CHECKOUT" archive --format=tar --prefix="$name/" "$REF" \
        | gzip > "$SOURCE/Dependencies/$name.tar.gz"
done
cp "$FFMPEG_TARBALL" "$FFMPEG_TARBALL.asc" "$SOURCE/Dependencies/"
cp "$ROOT/build/ffmpeg-source/ffmpeg-devel.asc" "$SOURCE/Dependencies/"
cat > "$SOURCE/BUILD.txt" <<'NOTE'
Build with Xcode 27, CMake, GnuPG, Git and an Apple Silicon Mac.
Run Tools/build-ffmpeg.sh and Tools/build-audiocpp.sh, then open
App/Polycop.xcodeproj and build the Polycop scheme. Swift Package Manager
verifies the pinned official whisper.cpp XCFramework archive.
Tools/fixtures.sh documents how the synthetic test recordings were generated.

Dependencies contains the corresponding pinned audio.cpp, whisper.cpp and
FFmpeg sources. The audio.cpp server frontend submodule is not built or shipped.
To use the included audio.cpp archive instead of cloning, extract it into
build/audiocpp-source and run the CMake commands in Tools/build-audiocpp.sh;
its initial Git checkout check applies only to Git checkouts.
The FFmpeg source archive can be placed in build/ffmpeg-source before running
Tools/build-ffmpeg.sh; its signature and the official release key are required.
whisper.cpp includes its upstream XCFramework build scripts under scripts/.
The application source is GPL-3.0-or-later. See LICENSE and third-party notices.
NOTE

ARCHIVE="$OUTPUT/Polycop-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$FOLDER" "$STAGE/package.zip"

# The disk image holds the app and a link to Applications, to drag it there.
# hdiutil fails now and then on busy runners, so it gets a few attempts.
IMAGE="$OUTPUT/Polycop-$VERSION.dmg"
mkdir "$STAGE/image"
ditto "$FOLDER/Polycop.app" "$STAGE/image/Polycop.app"
ln -s /Applications "$STAGE/image/Applications"
for attempt in 1 2 3; do
    hdiutil create -quiet -volname "Polycop $VERSION" -srcfolder "$STAGE/image" \
        -format UDZO "$STAGE/package.dmg" && break
    [ "$attempt" = 3 ] && { echo "Could not create the disk image" >&2; exit 1; }
    sleep 5
done

# Hard links publish each complete file without replacing any existing one.
ln "$STAGE/package.zip" "$ARCHIVE"
ln "$STAGE/package.dmg" "$IMAGE"
mv "$FOLDER/Polycop.app" "$OUTPUT/Polycop.app"
cp "$FOLDER/READ-ME.txt" "$OUTPUT/READ-ME.txt"
(
    cd "$OUTPUT"
    shasum -a 256 "Polycop-$VERSION.zip" > "Polycop-$VERSION.zip.sha256"
    shasum -a 256 "Polycop-$VERSION.dmg" > "Polycop-$VERSION.dmg.sha256"
)
echo "Local app: $OUTPUT/Polycop.app"
echo "Disk image: $IMAGE"
echo "Archive with sources: $ARCHIVE"
cat "$OUTPUT/Polycop-$VERSION.dmg.sha256" "$OUTPUT/Polycop-$VERSION.zip.sha256"
