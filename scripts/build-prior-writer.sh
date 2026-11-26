#!/usr/bin/env bash
# Build pinned earlier writers for the full compatibility acceptance tests.
# Usage:
#   scripts/build-prior-writer.sh <output-directory> [writer]  one writer (default prior),
#                                                              at <output-directory>/silta
#   scripts/build-prior-writer.sh --all <root>                 every writer, at <root>/<writer>/silta
#   scripts/build-prior-writer.sh --list                       "<writer> <commit>", one per line
#
# The table below is the only place the writers are pinned. verify.sh and CI's warm-caches
# job build them all with --all, and CI keys its cache on this file, so adding a writer
# here refills the cache. verify.sh exports each binary as SILTA_<WRITER>_BINARY.
#
# With SILTA_PRIOR_WRITER_CACHE set, a verified binary from <cache>/<commit>/ is reused.
# An entry counts only if its stamp names the same commit and Swift toolchain and the
# binary's SHA-256 matches; anything else is rebuilt and replaced. With
# SILTA_PRIOR_WRITER_CACHE_HIT=true (CI's restore step reported an exact hit), a writer
# that would have to be built fails instead: the saved cache is missing it, and an exact
# hit is never saved again, so every later run would rebuild it silently.
set -euo pipefail
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$self")/.."

# writer  commit                                    the last writer before
writers='
prior   dc868192e3877a29d79dc54681f0f57b72c3f56f  documents
v6      b65eab8994b7ada9f54495f9c050ebe5a3090d74  format 7
v8      605a8a69d553be1207f1fecb649dc8e30ba70724  app and topic slug history
v9      9e956c388729d35d23ae4d9317a901e0f7cfa1db  workspace removal
v10     cf3f7df4a59d4b71c626781ecef36315cfa985b2  map slug retirement
'

usage() { echo 'usage: build-prior-writer.sh <output-directory> [writer] | --all <root> | --list' >&2; exit 64; }
list() { printf '%s\n' "$writers" | awk 'NF { print $1, $2 }'; }

case "${1:-}" in
  --list)
    [[ $# -eq 1 ]] || usage
    list
    exit 0
    ;;
  --all)
    [[ $# -eq 2 && -n "$2" ]] || usage
    list | while read -r name _; do
      # Its stdin is not the list, so a build step can't swallow the remaining writers.
      bash "$self" "$2/$name" "$name" < /dev/null
    done
    exit 0
    ;;
  ''|-*) usage ;;
esac
[[ $# -le 2 ]] || usage
prior_commit="$(list | awk -v name="${2:-prior}" '$1 == name { print $2 }')"
[[ -n "$prior_commit" ]] || {
  echo "build-prior-writer: unknown writer '${2:-}'; use one of: $(list | awk '{ print $1 }' | xargs)" >&2
  exit 64
}
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
  problem="does not match its stamp"
else
  problem="is missing"
fi
if [[ -n "$entry" && "${SILTA_PRIOR_WRITER_CACHE_HIT:-}" == true ]]; then
  echo "::error::build-prior-writer: the restored cache was an exact hit, but writer ${2:-prior} (${prior_commit}) ${problem}." \
    "To refill it, merge any change to scripts/build-prior-writer.sh: that changes the cache key, and main's warm-caches job then builds and saves every writer." >&2
  exit 1
fi
if [[ -n "$entry" && "$problem" != "is missing" ]]; then
  # A ::warning:: shows in the CI summary; this run stores what it builds.
  echo "::warning::build-prior-writer: cached ${prior_commit} ${problem}; rebuilding" >&2
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
