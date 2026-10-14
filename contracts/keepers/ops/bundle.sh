#!/bin/bash
# Builds the keepers bundle from ONE reviewed commit (build 17 K4): only the files the image needs, with a SHA256
# manifest. The Fly image is built from a bundle only, never from a working tree, so hot keys only ever run code that
# was reviewed and merged. The host never gets repository access (no deploy key).
#
#   contracts/keepers/ops/bundle.sh [COMMIT] [--out DIR] [--allow-unmerged]
#
# COMMIT defaults to origin/main (run `git fetch origin` first). It must be on origin/main unless --allow-unmerged,
# which marks the bundle UNREVIEWED: fine for a local image test, refused by deploy-fly.sh.
# Writes DIR/dyor-keepers-<short sha>/ (the Docker build context) and DIR/dyor-keepers-<short sha>.tar.gz (to archive),
# DIR defaulting to $TMPDIR/dyor-keepers-bundles, and prints the bundle directory on the last line.
# Runs on macOS (bash 3.2) and Linux. Never add `set -x`.
set -euo pipefail

commit=origin/main
out=
allow_unmerged=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { echo "bundle: --out needs a directory" >&2; exit 64; }; out=$2; shift ;;
    --allow-unmerged) allow_unmerged=1 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "bundle: unknown option $1" >&2; exit 64 ;;
    *) commit=$1 ;;
  esac
  shift
done

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "bundle: run it inside the IOS-app repository" >&2; exit 2; }
cd "$top"
sha=$(git rev-parse --verify --quiet "$commit^{commit}") || { echo "bundle: $commit is not a commit" >&2; exit 2; }
short=$(git rev-parse --short=12 "$sha")

reviewed="UNREVIEWED"
main=$(git rev-parse --verify --quiet "origin/main^{commit}" || true)
if [ -n "$main" ] && git merge-base --is-ancestor "$sha" "$main"; then
  reviewed="reviewed: on origin/main ($main)"
elif [ "$allow_unmerged" = 1 ]; then
  echo "bundle: $short is not on origin/main: the bundle is marked UNREVIEWED (local tests only)" >&2
else
  echo "bundle: $short is not on origin/main (reviewed and merged code only; git fetch origin first, or --allow-unmerged for a local test)" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then SHA256=(sha256sum); else SHA256=(shasum -a 256); fi

out=${out:-${TMPDIR:-/tmp}/dyor-keepers-bundles}
name="dyor-keepers-$short"
dest="$out/$name"
[ -e "$dest" ] && { echo "bundle: $dest already exists: remove it or choose another --out" >&2; exit 1; }
mkdir -p "$dest"

# The image needs the keepers (code, tests, ops), the public deployment records and the lockfile, nothing else.
git archive --format=tar "$sha" -- contracts/keepers ':(glob)contracts/deployments/*.json' package.json package-lock.json | tar -x -C "$dest"
for need in contracts/keepers/keeper.mjs contracts/keepers/ops/Dockerfile contracts/keepers/ops/fly.toml contracts/deployments/143.json contracts/deployments/moments-143.json package-lock.json; do
  [ -f "$dest/$need" ] || { echo "bundle: $need is missing at $short" >&2; exit 1; }
done

printf '%s\n' "$sha" > "$dest/BUNDLE_COMMIT"
printf '%s\n' "$reviewed" > "$dest/BUNDLE_REVIEWED"
# One hash per file, sorted by path (repository paths hold no whitespace).
(cd "$dest" && find . -type f ! -name BUNDLE_MANIFEST.sha256 | sed 's|^\./||' | LC_ALL=C sort | xargs "${SHA256[@]}") > "$dest/BUNDLE_MANIFEST.sha256"
(cd "$out" && tar -czf "$name.tar.gz" "$name")

count=$(wc -l < "$dest/BUNDLE_MANIFEST.sha256" | tr -d ' ')
echo "bundle: $short ($reviewed), $count files"
echo "bundle: tarball $out/$name.tar.gz sha256 $("${SHA256[@]}" "$out/$name.tar.gz" | cut -d' ' -f1)"
echo "$dest"
