#!/bin/sh
set -eu
cd -P "$(dirname "$0")/.."
updater="$PWD/Scripts/update.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/geuntae-update-script-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
trap 'exit 1' HUP INT TERM
export GEUNTAE_BAR_UPDATE_REPOSITORY="$test_dir/repository"
export GIT_AUTHOR_NAME=UpdaterTests GIT_AUTHOR_EMAIL=updater@example.invalid
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
git init -q -b main "$GEUNTAE_BAR_UPDATE_REPOSITORY"
cd "$GEUNTAE_BAR_UPDATE_REPOSITORY"
git -c commit.gpgsign=false commit -q --allow-empty -m 'Already installed'
base="$(git rev-parse HEAD)"
git -c commit.gpgsign=false commit -q --allow-empty -m 'fix(flex): 접속 토큰 자동 갱신' -m 'Commit bodies are not update titles.'
first="$(git rev-parse --short HEAD)"
git -c commit.gpgsign=false commit -q --allow-empty -m 'fix(flex): 근무 집계 중복 수정'
latest="$(git rev-parse HEAD)"
last="$(git rev-parse --short HEAD)"
app="$test_dir/Test.app"
mkdir -p "$app/Contents"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :GeuntaeBarRevision string $base" "$plist" >/dev/null
expected="available:$latest
$last fix(flex): 근무 집계 중복 수정
$first fix(flex): 접속 토큰 자동 갱신"
[ "$(/bin/sh "$updater" check "$app")" = "$expected" ]
/usr/libexec/PlistBuddy -c "Set :GeuntaeBarRevision $latest" "$plist"
[ "$(/bin/sh "$updater" check "$app")" = current ]
/usr/libexec/PlistBuddy -c 'Set :GeuntaeBarRevision local' "$plist"
[ "$(/bin/sh "$updater" check "$app")" = local ]
git checkout -q -b local "$base"
git -c commit.gpgsign=false commit -q --allow-empty -m 'Local-only change'
/usr/libexec/PlistBuddy -c "Set :GeuntaeBarRevision $(git rev-parse HEAD)" "$plist"
[ "$(/bin/sh "$updater" check "$app")" = local ]
echo "Update script checks passed"
