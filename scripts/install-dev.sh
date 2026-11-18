#!/usr/bin/env bash
# Install the CLI and the Mac app, both built from clean main that matches origin/main;
# never prompt.
#
#   scripts/install-dev.sh
#
# Takes no arguments. Installs `silta` into SILTA_INSTALL_DIR (default ~/.local/bin) and
# `Silta Dev.app` into SILTA_APP_INSTALL_DIR (default ~/Applications). Both are built
# before either is replaced, so a failed build leaves both previous installs in place.
set -euo pipefail
root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$root"
branch="$(git symbolic-ref --quiet --short HEAD || true)"
if [[ "$branch" != main ]]; then
  echo 'install-dev: use a clean checkout of main.' >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo 'install-dev: commit or remove changes before building from main.' >&2
  exit 1
fi
git fetch --quiet origin main || { echo 'install-dev: could not fetch origin main.' >&2; exit 1; }
read -r ahead behind < <(git rev-list --left-right --count main...origin/main)
if (( ahead != 0 || behind != 0 )); then
  printf 'install-dev: local main is %s ahead and %s behind origin/main; pull or reset it first.\n' \
    "$ahead" "$behind" >&2
  exit 1
fi
commit="$(git rev-parse HEAD)"
short="$(git rev-parse --short=12 HEAD)"

swift build -c release --only-use-versions-from-resolved-file
binary="$root/.build/release/silta"
[[ -f "$binary" ]] || { echo 'install-dev: release binary is missing.' >&2; exit 1; }
app_build="$root/.build/app"
xcodebuild -project App/SiltaApp.xcodeproj -scheme SiltaApp -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$app_build/DerivedData" \
  -clonedSourcePackagesDirPath "$app_build/SourcePackages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  "CURRENT_PROJECT_VERSION=$short" -quiet build
app="$app_build/DerivedData/Build/Products/Release/SiltaApp.app"
[[ -d "$app" ]] || { echo 'install-dev: release app is missing.' >&2; exit 1; }
# The app's CFBundleVersion is the commit, so a stale product from another build is refused.
built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || true)"
[[ "$built" == "$short" ]] || {
  echo "install-dev: the release app is not from commit $short." >&2
  exit 1
}

destination="${SILTA_INSTALL_DIR:-$HOME/.local/bin}"
apps="${SILTA_APP_INSTALL_DIR:-$HOME/Applications}"
installed_app="$apps/Silta Dev.app"
temporary="" staging=""
trap 'rm -rf "$temporary" "$staging"' EXIT
mkdir -p "$destination" "$apps"
temporary="$(mktemp "$destination/.silta.XXXXXX")"
staging="$(mktemp -d "$apps/.silta-app.XXXXXX")"
install -m 755 "$binary" "$temporary"
ditto "$app" "$staging/Silta Dev.app"
# Swap the app first and the CLI last; on any failure put the previous app back.
restore_app() {
  [[ ! -e "$installed_app" ]] || mv "$installed_app" "$staging/failed.app"
  [[ ! -e "$staging/previous.app" ]] || mv "$staging/previous.app" "$installed_app"
  echo 'install-dev: could not replace the installs; kept the previous app and CLI.' >&2
  exit 1
}
[[ ! -e "$installed_app" ]] || mv "$installed_app" "$staging/previous.app"
mv "$staging/Silta Dev.app" "$installed_app" || restore_app
mv -f "$temporary" "$destination/silta" || restore_app
printf 'Installed %s and %s from commit %s.\n' "$destination/silta" "$installed_app" "$commit"
echo 'Reopen Silta Dev.app if it is running.'
printf 'Next: follow %s/docs/getting-started.md.\n' "$root"
