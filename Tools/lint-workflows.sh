#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks the GitHub workflows: actionlint for mistakes, zizmor for security
# (credentials, injection, permissions), with every finding shown rather than
# only the most likely ones. Both are downloaded once at a pinned
# release and refused if their digest differs. zizmor also asks GitHub about
# the actions used when GH_TOKEN is set, and stays offline otherwise.
#
# Usage: Tools/lint-workflows.sh

set -euo pipefail

ACTIONLINT="1.7.12"
ZIZMOR="1.30.1"

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        ACTIONLINT_ASSET="actionlint_${ACTIONLINT}_darwin_arm64.tar.gz"
        ACTIONLINT_SHA256="aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f"
        ZIZMOR_ASSET="zizmor-aarch64-apple-darwin.tar.gz"
        ZIZMOR_SHA256="e28d22b087f9ebb8d99da6e740d348c930f559961c7c3f12badda54f882195a2"
        ;;
    Linux-x86_64)
        ACTIONLINT_ASSET="actionlint_${ACTIONLINT}_linux_amd64.tar.gz"
        ACTIONLINT_SHA256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
        ZIZMOR_ASSET="zizmor-x86_64-unknown-linux-gnu.tar.gz"
        ZIZMOR_SHA256="e65324f4430c2717591937edcec90ccbefaf14c174f8ec9415e03ca875b46e1a"
        ;;
    *)
        echo "No pinned workflow linters for $(uname -s) $(uname -m)" >&2
        exit 1
        ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/build/workflow-linters"

# Downloads an archive, checks its digest, and unpacks it into a folder of
# its own. The folder is filled beside its final place and moved there whole,
# with the digest it came from, so an interrupted unpacking is never reused.
fetch() {
    local url="$1" sha256="$2" folder="$3"
    [ "$(cat "$folder/.archive-sha256" 2>/dev/null)" = "$sha256" ] && return
    local archive unpacked
    archive="$(mktemp)"
    curl --fail --silent --show-error --location --output "$archive" "$url"
    echo "$sha256  $archive" | shasum -a 256 --check --quiet || {
        echo "$url does not match its pinned digest" >&2
        rm -f "$archive"
        exit 1
    }
    mkdir -p "$(dirname "$folder")"
    unpacked="$(mktemp -d "$folder.XXXXXX")"
    tar -xzf "$archive" -C "$unpacked"
    rm -f "$archive"
    echo "$sha256" > "$unpacked/.archive-sha256"
    rm -rf "$folder"
    mv "$unpacked" "$folder"
}

fetch "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT/$ACTIONLINT_ASSET" \
    "$ACTIONLINT_SHA256" "$TOOLS/actionlint-$ACTIONLINT"
fetch "https://github.com/zizmorcore/zizmor/releases/download/v$ZIZMOR/$ZIZMOR_ASSET" \
    "$ZIZMOR_SHA256" "$TOOLS/zizmor-$ZIZMOR"

cd "$ROOT"
"$TOOLS/actionlint-$ACTIONLINT/actionlint"
if [ -n "${GH_TOKEN:-}" ]; then
    "$TOOLS/zizmor-$ZIZMOR/zizmor" --persona=auditor .github/workflows
else
    "$TOOLS/zizmor-$ZIZMOR/zizmor" --persona=auditor --offline .github/workflows
fi
