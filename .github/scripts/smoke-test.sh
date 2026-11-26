#!/bin/bash
# Smoke test one built variant: unpack its apkovl into a clean Alpine
# container of the same branch and exercise what ships (see
# smoke-inside.sh). Run from the repository root after build.sh.
#
# Usage: .github/scripts/smoke-test.sh home|car
set -euo pipefail

VARIANT="${1:?usage: smoke-test.sh home|car}"
case "$VARIANT" in
    home|car) ;;
    *) echo "Unknown variant '$VARIANT' (expected home or car)"; exit 1 ;;
esac

ALPINE_VERSION=$(sed -n 's/^ALPINE_VERSION="\(.*\)"$/\1/p' build.sh)
if [ -z "$ALPINE_VERSION" ]; then
    echo "ERROR: could not read ALPINE_VERSION from build.sh"
    exit 1
fi

APKOVL="deploy/alphasound-${VARIANT}.apkovl.tar.gz"
if [ ! -f "$APKOVL" ]; then
    echo "ERROR: $APKOVL not found; run build.sh with VARIANT=$VARIANT first"
    exit 1
fi

docker run --rm \
    -v "$PWD/deploy:/deploy:ro" \
    -v "$PWD/.github/scripts:/scripts:ro" \
    -v "$PWD/overlay/alphasound.txt:/defaults/alphasound.txt:ro" \
    -e VARIANT="$VARIANT" \
    "alpine:${ALPINE_VERSION}" \
    sh /scripts/smoke-inside.sh
