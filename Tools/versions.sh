# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The pinned version of every component built from source or shipped with
# its source, read by the build and packaging scripts. Package.swift and
# THIRD_PARTY_NOTICES.md name them too; Tools/check-versions.sh checks that
# they agree.

# shellcheck disable=SC2034 # read by the scripts that source this file

FFMPEG_VERSION="9.0.2"
FFMPEG_KEY_FINGERPRINT="FCF986EA15E6E293A5644F10B4322F04D67658D8"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"

AUDIOCPP_VERSION="v0.8.1"
AUDIOCPP_COMMIT="f2b4937306daa25f5c78520f3c626ed31495a37a"

# The official XCFramework is published as a build number; the tag of the
# same commit names the version.
WHISPER_VERSION="v1.9.4"
WHISPER_BUILD="b5130"
WHISPER_COMMIT="927cfce34f31707e17f2bff35c349632fb9e2c3a"
