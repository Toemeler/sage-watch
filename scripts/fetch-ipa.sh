#!/usr/bin/env bash
# Waits for the IPA job of the newest CI run of a commit (default: HEAD) and downloads Sage.ipa into out/.
# On a failed build it prints only the compiler errors, so a fix can follow at once.
# usage: scripts/fetch-ipa.sh [sha]
set -euo pipefail
cd "$(dirname "$0")/.."
SHA=$(git rev-parse "${1:-HEAD}")

run=""
for _ in $(seq 1 30); do
  run=$(gh run list --commit "$SHA" --workflow "Build IPA" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
  [ -n "$run" ] && break
  sleep 4
done
[ -n "$run" ] || { echo "no CI run for $SHA"; exit 1; }
echo "run $run"

start=$(date +%s)
while :; do
  read -r status conclusion < <(gh run view "$run" --json jobs \
    --jq '.jobs[] | select(.name=="ipa") | "\(.status) \(.conclusion // "-")"')
  [ "$status" = "completed" ] && break
  sleep 8
done
echo "ipa job: $conclusion after $(( $(date +%s) - start )) s"

if [ "$conclusion" != "success" ]; then
  job=$(gh run view "$run" --json jobs --jq '.jobs[] | select(.name=="ipa") | .databaseId')
  gh run view --job "$job" --log 2>/dev/null | grep -E "error:|❌|Error |\*\* BUILD FAILED" | sed -E 's/^.*Z //' | head -40
  exit 1
fi

tag=$(gh release list --limit 20 --json tagName,name --jq '.[].tagName' | while read -r t; do
  if [ "$(gh release view "$t" --json targetCommitish --jq .targetCommitish)" = "$SHA" ]; then echo "$t"; break; fi
done)
[ -n "$tag" ] || tag=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')
mkdir -p out
gh release download "$tag" --pattern Sage.ipa --dir out --clobber
cp out/Sage.ipa "out/Sage-$tag.ipa"
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
echo "out/Sage-$tag.ipa"
echo "LINK https://github.com/$repo/releases/download/$tag/Sage.ipa"
