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

# The hardened runtime stays on. Ad hoc signatures carry no Team ID, so the
# app's entitlements lift library validation, the one check that needs one,
# and nothing else.
xcodebuild build \
    -project "$ROOT/App/Polycop.xcodeproj" \
    -scheme Polycop -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT/build/local-derived" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

APP="$ROOT/build/local-derived/Build/Products/Release/Polycop.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
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
# A debugging entitlement or a signature without the runtime would let other
# processes read or inject code into an app trusted with recordings. Every
# executable counts: the helper parses shared files, the frameworks run models.
# Read whole before matching: grep -q stops early, which under pipefail
# would fail codesign with a broken pipe.
while IFS= read -r -d '' file; do
    [[ "$(file -b "$file")" == Mach-O* ]] || continue
    name="${file#"$FOLDER/"}"
    entitlements="$(codesign -d --entitlements - --xml "$file" 2>/dev/null)"
    signature="$(codesign -dv "$file" 2>&1)"
    if [[ "$entitlements" == *get-task-allow* || "$entitlements" == *allow-dyld-environment-variables* ]]; then
        echo "$name allows debugging or injection; it must not be packaged" >&2
        exit 1
    fi
    if [[ "$signature" != *flags=*runtime* ]]; then
        echo "$name is not signed with the hardened runtime" >&2
        exit 1
    fi
done < <(find "$FOLDER/Polycop.app/Contents" -type f -print0)
cat > "$FOLDER/READ-ME.txt" <<NOTE
Polycop $VERSION, built from commit $COMMIT
https://github.com/miravassor/polycop

For Apple Silicon Macs with macOS 14 or later.

INSTALL

Check the download against the SHA-256 checksum published with it: a match
shows the file arrived intact. To check that it was built by the project's
release workflow from the commit above, with the GitHub command line tool:
    gh attestation verify Polycop-$VERSION.dmg --repo miravassor/polycop \
        --signer-workflow miravassor/polycop/.github/workflows/release.yml
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
only for a copy you checked.

USE

Download a model in the app, add your recordings, then click Start
Transcription. Listen back, correct the text and export it. Corrections are
kept in the library, apart from the exports. Help > Keyboard Shortcuts lists
the shortcuts, including Shift Command Space to play and pause. Recordings
never leave your Mac.

SOURCE AND LICENCES

Polycop is free software under the GNU General Public License version 3 or
later. Polycop-$VERSION.zip, published with this disk image, holds the same
app and, in its Source folder, the complete corresponding source of the app
and of every bundled component, at the commit named above. The licence texts
are in Polycop.app/Contents/Resources, listed in ThirdPartyNotices.txt. Speech recognition models are
downloaded separately, under their own licences.
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
    # Nothing beside the commit, tracked or not, may have gone into the build.
    [ -z "$(git -C "$CHECKOUT" status --porcelain --ignored)" ] || {
        echo "$CHECKOUT holds changes or extra files" >&2
        exit 1
    }
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

# The disk image holds the app, the notes saying where its source is, and a
# link to Applications to drag the app there.
# hdiutil fails now and then on busy runners, so it gets a few attempts.
IMAGE="$OUTPUT/Polycop-$VERSION.dmg"
mkdir "$STAGE/image"
ditto "$FOLDER/Polycop.app" "$STAGE/image/Polycop.app"
cp "$FOLDER/READ-ME.txt" "$STAGE/image/READ-ME.txt"
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
# The debugging symbols of this exact build: without them a crash report
# from a user cannot be read back to lines of code.
ditto -c -k --keepParent "$APP.dSYM" "$OUTPUT/Polycop-$VERSION.dSYM.zip"
(
    cd "$OUTPUT"
    shasum -a 256 "Polycop-$VERSION.zip" > "Polycop-$VERSION.zip.sha256"
    shasum -a 256 "Polycop-$VERSION.dmg" > "Polycop-$VERSION.dmg.sha256"
    shasum -a 256 "Polycop-$VERSION.dSYM.zip" > "Polycop-$VERSION.dSYM.zip.sha256"
)
echo "Local app: $OUTPUT/Polycop.app"
echo "Disk image: $IMAGE"
echo "Archive with sources: $ARCHIVE"
echo "Debugging symbols: $OUTPUT/Polycop-$VERSION.dSYM.zip"
cat "$OUTPUT/Polycop-$VERSION.dmg.sha256" "$OUTPUT/Polycop-$VERSION.zip.sha256"
