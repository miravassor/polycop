# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Downloads a tool at a pinned release for the lint scripts, which source it.

# Downloads an archive, checks its digest, and unpacks it into a folder of
# its own. The folder is filled beside its final place and moved there whole,
# with the digest it came from, so an interrupted unpacking is never reused.
# It runs in a subshell so that its trap removes the temporary files however
# it ends.
fetch() (
    url="$1" sha256="$2" folder="$3"
    [ "$(cat "$folder/.archive-sha256" 2>/dev/null)" != "$sha256" ] || exit 0
    mkdir -p "$(dirname "$folder")"
    archive="$(mktemp)"
    unpacked="$(mktemp -d "$folder.XXXXXX")"
    trap 'rm -rf "$archive" "$unpacked"' EXIT
    curl --fail --silent --show-error --location --output "$archive" "$url"
    echo "$sha256  $archive" | shasum -a 256 --check --quiet || {
        echo "$url does not match its pinned digest" >&2
        exit 1
    }
    case "$url" in
        *.zip) unzip -q "$archive" -d "$unpacked" ;;
        *) tar -xzf "$archive" -C "$unpacked" ;;
    esac
    echo "$sha256" > "$unpacked/.archive-sha256"
    rm -rf "$folder"
    mv "$unpacked" "$folder"
)
