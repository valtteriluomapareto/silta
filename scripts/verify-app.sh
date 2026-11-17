#!/usr/bin/env bash
# Test the isolated native app, validate xcresult evidence, then build Release.
#   scripts/verify-app.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
app_build="$PWD/.build/app"
mkdir -p "$app_build"
app_run="$(mktemp -d "$app_build/run.XXXXXX")"
app_home="$(mktemp -d "${TMPDIR:-/tmp}/silta-app-test.XXXXXX")"
mkdir -p "$app_home/user"
trap 'rm -rf "$app_home"' EXIT
swiftpm=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then swiftpm=(--disable-sandbox); fi
swift build ${swiftpm[@]+"${swiftpm[@]}"} --only-use-versions-from-resolved-file \
  --product silta -Xswiftc -warnings-as-errors
common=("SILTA_APP_TEST_CLI=$PWD/.build/debug/silta" -project App/SiltaApp.xcodeproj -scheme SiltaApp -destination 'platform=macOS'
  -derivedDataPath "$app_build/DerivedData" -clonedSourcePackagesDirPath "$app_build/SourcePackages"
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile)
xcodebuild "${common[@]}" -configuration Debug -resultBundlePath "$app_run/Test.xcresult" \
  "SILTA_APP_TEST_HOME=$app_home" test
xcrun xcresulttool get test-results summary --schema-version 0.4.0 --path "$app_run/Test.xcresult" > "$app_run/summary.json"
xcrun xcresulttool get test-results tests --schema-version 0.4.0 --path "$app_run/Test.xcresult" > "$app_run/tests.json"
python3 -B scripts/check-app-test-results.py "$app_run/summary.json" "$app_run/tests.json" AppStartupTests AppModelTests AppReadSessionTests BoardContentTests TaskDetailModelTests WorkspaceContentTests DocsModelTests
xcodebuild "${common[@]}" -configuration Release build
printf 'App verification passed; results: %s\n' "$app_run/Test.xcresult"
