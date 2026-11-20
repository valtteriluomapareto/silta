#!/usr/bin/env bash
# Build a pinned earlier writer for the full compatibility acceptance tests.
# Usage: scripts/build-prior-writer.sh <output-directory> [prior|v6|v8|v9]
#   prior  the pre-docs writer (default)
#   v6     the last writer before format 7
#   v8     the last writer before app and topic slug history
#   v9     the last writer before workspace removal
# The binary lands at <output-directory>/silta.
#
# With SILTA_PRIOR_WRITER_CACHE set, a verified binary from <cache>/<commit>/ is reused.
# An entry counts only if its stamp names the same commit and Swift toolchain and the
# binary's SHA-256 matches; anything else is rebuilt and replaced. CI keys its cache on
# this file, so the pinned commits live only here.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $# -ge 1 && $# -le 2 ]] || { echo 'usage: build-prior-writer.sh <output-directory> [prior|v6|v8|v9]' >&2; exit 64; }
case "${2:-prior}" in
  prior) prior_commit=dc868192e3877a29d79dc54681f0f57b72c3f56f ;;
  v6) prior_commit=b65eab8994b7ada9f54495f9c050ebe5a3090d74 ;;
  v8) prior_commit=605a8a69d553be1207f1fecb649dc8e30ba70724 ;;
  v9) prior_commit=9e956c388729d35d23ae4d9317a901e0f7cfa1db ;;
  *) echo "build-prior-writer: unknown writer '$2'; use prior, v6, v8 or v9" >&2; exit 64 ;;
esac
out="$1"
mkdir -p "$out"

toolchain="$(swift --version 2>/dev/null | sed -n 1p)"
# The stamp must name the toolchain, or a toolchain change would reuse a stale binary.
[[ -n "$toolchain" ]] || { echo 'build-prior-writer: swift --version printed nothing' >&2; exit 1; }
stamp_for() { printf 'commit=%s\nswift=%s\nsha256=%s\n' "$prior_commit" "$toolchain" "$1"; }
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

cache="${SILTA_PRIOR_WRITER_CACHE:-}"
entry="${cache:+$cache/$prior_commit}"
if [[ -n "$entry" && -f "$entry/silta" && -f "$entry/stamp" ]]; then
  if [[ "$(cat "$entry/stamp")" == "$(stamp_for "$(sha_of "$entry/silta")")" ]]; then
    cp "$entry/silta" "$out/silta"
    echo "build-prior-writer: reused cached ${prior_commit} ($toolchain)" >&2
    exit 0
  fi
  # A ::warning:: shows in the CI summary, since an exact cache hit is not saved again.
  echo "::warning::build-prior-writer: cached ${prior_commit} does not match its stamp; rebuilding" >&2
fi

mkdir -p "$out/source"
git archive "$prior_commit" | tar -x -C "$out/source"
swiftpm=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  swiftpm=(--disable-sandbox)
fi
swift build --package-path "$out/source" ${swiftpm[@]+"${swiftpm[@]}"} \
  -c release --only-use-versions-from-resolved-file >&2
cp "$out/source/.build/release/silta" "$out/silta"

if [[ -n "$entry" ]]; then
  # Stage beside the entry, then swap it in, so an interrupted store never leaves a
  # binary without its stamp.
  mkdir -p "$cache"
  staging="$(mktemp -d "$cache/.staging.XXXXXX")"
  cp "$out/silta" "$staging/silta"
  stamp_for "$(sha_of "$staging/silta")" > "$staging/stamp"
  rm -rf "$entry"
  mv "$staging" "$entry"
  echo "build-prior-writer: cached ${prior_commit}" >&2
fi
