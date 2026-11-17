#!/usr/bin/env bash
# Build and open the Debug app against a fresh private synthetic data home.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
app_build="$PWD/.build/app"
if [[ "${1:-}" != "--no-build" ]]; then
  xcodebuild -project App/SiltaApp.xcodeproj -scheme SiltaApp -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$app_build/DerivedData" \
    -clonedSourcePackagesDirPath "$app_build/SourcePackages" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
fi
open -n "$app_build/DerivedData/Build/Products/Debug/SiltaApp.app" --args -SiltaFixture v2
