#!/usr/bin/env bash
# Restore the pinned Taffy source checkout used for verification.
#
# Usage: bash tools/fetch-reference.sh
# This never changes an existing checkout. Remove the directory explicitly if
# you intentionally want it reconstructed at the pin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=pin.env
source "$ROOT/tools/pin.env"

DESTINATION="$ROOT/.references/taffy"

if [[ -d "$DESTINATION/.git" ]]; then
    actual="$(git -C "$DESTINATION" rev-parse HEAD)"
    if [[ "$actual" != "$TAFFY_REV" ]]; then
        echo "error: taffy is at $actual, expected $TAFFY_REV: $DESTINATION" >&2
        echo "remove that checkout explicitly, then run this script again" >&2
        exit 1
    fi
    echo "ok: taffy at $TAFFY_REV"
    exit 0
fi

if [[ -e "$DESTINATION" ]]; then
    echo "error: reference destination exists but is not a Git checkout: $DESTINATION" >&2
    exit 1
fi

mkdir -p "$(dirname "$DESTINATION")"
echo "cloning taffy at $TAFFY_REV ..."
git clone --filter=blob:none --no-checkout "$TAFFY_REPO" "$DESTINATION"
git -C "$DESTINATION" checkout --detach --quiet "$TAFFY_REV"
actual="$(git -C "$DESTINATION" rev-parse HEAD)"
[[ "$actual" == "$TAFFY_REV" ]] || {
    echo "error: taffy resolved to $actual, expected $TAFFY_REV" >&2
    exit 1
}
echo "ok: taffy at $TAFFY_REV"
