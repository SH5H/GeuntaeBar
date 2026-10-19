#!/bin/sh
set -eu

mode="${1:?Usage: update.sh check|install APP}"
app="${2:?Usage: update.sh check|install APP}"
case "$mode" in check|install|install-locked) ;; *) exit 2 ;; esac
target="${3:-}"
if [ "$mode" != check ] && ! printf '%s\n' "$target" | grep -Eq '^[0-9a-f]{40}$'; then
    echo 'Pass the checked revision to install: update.sh install APP REVISION' >&2
    exit 2
fi
if [ "$mode" = install ]; then
    exec /usr/bin/lockf -k -t 0 "$(dirname "$app")/.geuntae-bar-update.lock" \
        /bin/sh "$0" install-locked "$app" "$target"
fi
revision="$(/usr/libexec/PlistBuddy -c 'Print :GeuntaeBarRevision' "$app/Contents/Info.plist" 2>/dev/null || true)"
if ! printf '%s\n' "$revision" | grep -Eq '^[0-9a-f]{40}$'; then
    echo local
    exit 0
fi

export GIT_TERMINAL_PROMPT=0
repository="${GEUNTAE_BAR_UPDATE_REPOSITORY:-https://github.com/SH5H/GeuntaeBar.git}"
remote="$(git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 \
    ls-remote --exit-code "$repository" refs/heads/main)"
latest="$(printf '%s\n' "$remote" | awk '{print $1}')"
if [ "$latest" = "$revision" ]; then
    echo current
    exit 0
fi

update_dir="$(mktemp -d "${TMPDIR:-/tmp}/geuntae-bar-update.XXXXXX")"
trap 'rm -rf "$update_dir"' EXIT
trap 'exit 1' HUP INT TERM
[ "$mode" = check ] || echo "progress:download"
git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 \
    clone --quiet --single-branch --branch main "$repository" "$update_dir/source"
latest="$(git -C "$update_dir/source" rev-parse HEAD)"
if [ "$mode" != check ]; then
    if ! git -C "$update_dir/source" merge-base --is-ancestor "$target" "$latest" 2>/dev/null; then
        echo 'The checked revision is no longer available on main. Check for updates again.' >&2
        exit 1
    fi
    latest="$target"
fi
if [ "$latest" = "$revision" ]; then
    echo current
    exit 0
fi
if ! git -C "$update_dir/source" merge-base --is-ancestor "$revision" "$latest" 2>/dev/null; then
    echo local
    exit 0
fi
if [ "$mode" = check ]; then
    echo "available:$latest"
    git -C "$update_dir/source" log --no-color --format='%h %s' "$revision..$latest"
    exit 0
fi

cd "$update_dir/source"
git checkout --quiet --detach "$latest"
./install.sh "$(dirname "$app")"
