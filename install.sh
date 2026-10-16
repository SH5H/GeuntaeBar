#!/bin/sh
set -eu
cd "$(dirname "$0")"
./build.sh

install_dir="${1:-$HOME/Applications}"
mkdir -p "$install_dir"
install_dir="$(cd "$install_dir" && pwd)"
app="$install_dir/Geuntae bar.app"
staging="$(mktemp -d "$install_dir/.geuntae-bar-install.XXXXXX")"
cleanup() {
    if [ -e "$staging/previous.app" ] && [ ! -e "$app" ]; then
        if ! mv "$staging/previous.app" "$app"; then
            echo "Restore the previous app from: $staging/previous.app" >&2
            return
        fi
        open "$app" || true
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
ditto '../Geuntae bar.app' "$staging/Geuntae bar.app"
codesign --verify --strict "$staging/Geuntae bar.app"

user_id="$(id -u)"
pkill -u "$user_id" -x 'Geuntae bar' || [ "$?" -eq 1 ]
for attempt in 1 2 3 4 5; do
    if ! pgrep -u "$user_id" -x 'Geuntae bar' >/dev/null; then break; fi
    sleep 1
done
if pgrep -u "$user_id" -x 'Geuntae bar' >/dev/null; then
    echo "Quit Geuntae bar and run this script again." >&2
    exit 1
fi
if [ -e "$app" ]; then mv "$app" "$staging/previous.app"; fi
mv "$staging/Geuntae bar.app" "$app"
open "$app"
echo "Installed: $app"
