#!/bin/sh
set -eu
app="${1:?Usage: SpotlightTests.sh APP}"
metadata="$(mktemp "${TMPDIR:-/tmp}/geuntae-bar-spotlight.XXXXXX")"
trap 'rm -f "$metadata"' EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/mdimport -t -o "$metadata" "$app"
if ! /usr/libexec/PlistBuddy -c 'Print :kMDItemAlternateNames' "$metadata" | grep -Fq '근태바'; then
    echo "Spotlight must find the app by 근태바" >&2
    exit 1
fi
echo "Spotlight Korean name check passed"
