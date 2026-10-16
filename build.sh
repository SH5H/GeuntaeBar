#!/bin/sh
set -eu
cd -P "$(dirname "$0")"
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Install Command Line Tools with 'xcode-select --install', then run this script again." >&2
    exit 1
fi
S=Sources
app_sources="$S/Core.swift $S/Compensation.swift $S/FlexAPI.swift $S/FlexAttendance.swift $S/FlexConnectionView.swift $S/Onboarding.swift $S/OnboardingWindow.swift $S/Updater.swift $S/App.swift"
app="../Geuntae bar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Scripts/update.sh "$app/Contents/Resources/update.sh"
revision=local
if [ "$(git rev-parse --show-toplevel 2>/dev/null || true)" = "$PWD" ] &&
   [ -z "$(git status --porcelain)" ]; then
    revision="$(git rev-parse HEAD)"
fi
/usr/libexec/PlistBuddy -c "Add :GeuntaeBarRevision string $revision" "$app/Contents/Info.plist"
swiftc -O -module-name GeuntaeBar $app_sources -o "$app/Contents/MacOS/Geuntae bar"
./Scripts/sign-local.sh "$app" "${GEUNTAE_BAR_KEYCHAIN:-}"
echo "Built: $app"
