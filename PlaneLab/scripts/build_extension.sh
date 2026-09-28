#!/usr/bin/env bash
# Builds the Plane Lab Blender extension zip into PlaneLab/dist/ (SPEC.md §17.4 P6).
# In the repository, blender/planelab_blender/vendor/planelab is a symlink to src/planelab; the zip needs the real
# files, so the extension is staged with symlinks resolved before `blender --command extension build`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
OUT="${1:-$HERE/dist}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

rsync -a --copy-links --exclude '__pycache__' --exclude '*.pyc' \
  "$HERE/blender/planelab_blender/" "$STAGE/planelab_blender/"
mkdir -p "$OUT"
"$BLENDER" --factory-startup --command extension build \
  --source-dir "$STAGE/planelab_blender" --output-dir "$OUT"
