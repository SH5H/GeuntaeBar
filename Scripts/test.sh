#!/bin/sh
set -eu
cd -P "$(dirname "$0")/.."
build_tmp="$(mktemp -d "${TMPDIR:-/tmp}/geuntae-bar-tests.XXXXXX")"
trap 'rm -rf "$build_tmp"' EXIT
trap 'exit 1' HUP INT TERM
S=Sources T=Tests
swiftc $S/Onboarding.swift $T/OnboardingTests.swift -o "$build_tmp/onboarding-tests"
"$build_tmp/onboarding-tests"
swiftc $S/Core.swift $S/Compensation.swift $T/CoreTests.swift -o "$build_tmp/core-tests"
"$build_tmp/core-tests"
swiftc $S/Core.swift $S/Compensation.swift $T/CompensationTests.swift -o "$build_tmp/compensation-tests"
"$build_tmp/compensation-tests"
swiftc $S/Core.swift $S/Compensation.swift $S/FlexAPI.swift $S/FlexAttendance.swift $T/FlexTests.swift -o "$build_tmp/flex-tests"
"$build_tmp/flex-tests"
app_sources="$S/Core.swift $S/Compensation.swift $S/FlexAPI.swift $S/FlexAttendance.swift $S/FlexConnectionView.swift $S/Onboarding.swift $S/OnboardingWindow.swift $S/Updater.swift $S/App.swift"
swiftc -DWORKBAR_TESTS $app_sources $T/UpdaterTests.swift -o "$build_tmp/updater-tests"
"$build_tmp/updater-tests"
swiftc -DWORKBAR_TESTS $app_sources $T/LoginTests.swift -o "$build_tmp/login-tests"
swiftc -DWORKBAR_TESTS $app_sources $T/FlexViewTests.swift -o "$build_tmp/flex-view-tests"
"$build_tmp/flex-view-tests"
"$build_tmp/login-tests"
swiftc -DWORKBAR_TESTS $app_sources $T/MenuTests.swift -o "$build_tmp/menu-tests"
"$build_tmp/menu-tests"
echo "All checks passed"
