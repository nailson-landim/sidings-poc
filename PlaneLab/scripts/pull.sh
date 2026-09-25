#!/usr/bin/env bash
# Pull SidingsAR recordings from the iPhone 13 ("Tricorder"), summarize them, and open them in Blender.
#
#   PlaneLab/scripts/pull.sh               the newest recording on the phone: pull, info, peek, blend, open in Blender
#   PlaneLab/scripts/pull.sh <name>        that recording (20260928-174840 or 20260928-174840.planelab)
#   PlaneLab/scripts/pull.sh --all         every recording not yet on the Mac (opens the newest of them)
#   PlaneLab/scripts/pull.sh --list        what's on the phone, and which are already on the Mac
#
#   --no-open   don't open Blender
#   --force     copy again even if the recording is already on the Mac
#
# It only reads the app's files, over the cable or the network; nothing is installed on the phone. A recording
# that's already on the Mac isn't copied again, but its peek.sqlite and replay.blend are rebuilt.
# Another phone or folder: PLANELAB_DEVICE=<udid> PLANELAB_SESSIONS=<dir> PlaneLab/scripts/pull.sh
set -euo pipefail

DEVICE="${PLANELAB_DEVICE:-782F0FCC-0A00-5F6F-82AE-AC575194E5CA}" # iPhone 13 "Tricorder" (xcrun devicectl list devices)
APP_ID="br.com.neuralnexgen.sidingsar"
SESSIONS="${PLANELAB_SESSIONS:-$HOME/PlaneLab/sessions}"
BLENDER_APP="${PLANELAB_BLENDER_APP:-/Applications/Blender.app}"
PLANELAB="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$PLANELAB/.venv/bin/python"
CONTAINER=(--device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP_ID")

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() {
    printf 'pull.sh: %s\n' "$*" >&2
    exit 1
}

# Recording names on the phone, oldest first (names are timestamps).
phone_sessions() {
    local json
    json="$(mktemp)"
    if ! xcrun devicectl device info files "${CONTAINER[@]}" --subdirectory Documents/Sessions \
        --json-output "$json" >/dev/null 2>&1; then
        rm -f "$json"
        die "can't read the phone: is the iPhone 13 unlocked and connected (cable, or the same network)?"
    fi
    "$PYTHON" - "$json" <<'PY'
import json
import sys

files = json.load(open(sys.argv[1]))["result"]["files"]
names = sorted(
    f["name"]
    for f in files
    if f["resources"]["isDirectory"] and "/" not in f["name"] and f["name"].endswith(".planelab")
)
print("\n".join(names))
PY
    rm -f "$json"
}

# Copies one recording into $SESSIONS, through a temporary folder so an interrupted copy never looks complete.
pull_one() {
    local name="$1"
    local target="$SESSIONS/$name"
    local partial="$SESSIONS/.partial-$name"
    if [[ -d "$target" && "$FORCE" -eq 0 ]]; then
        say "$name is already on the Mac"
        return
    fi
    mkdir -p "$SESSIONS"
    rm -rf "$partial"
    say "pulling $name ..."
    xcrun devicectl device copy from "${CONTAINER[@]}" --source "Documents/Sessions/$name" \
        --destination "$partial" >/dev/null 2>&1 || die "copying $name failed"
    rm -rf "$target"
    mv "$partial" "$target"
}

# info on screen (with the phone-vs-Mac cloud check, SPEC T30); peek.sqlite and replay.blend next to the recording.
process() {
    local target="$SESSIONS/$1"
    echo
    "$PYTHON" -m planelab info --check-cloud "$target"
    "$PYTHON" -m planelab peek "$target" >/dev/null
    echo "peek      $target/lab/peek.sqlite"
    "$PYTHON" -m planelab blend "$target" >/dev/null
    echo "blend     $target/lab/replay.blend"
}

ALL=0
LIST=0
OPEN=1
FORCE=0
NAME=""
for arg in "$@"; do
    case "$arg" in
        --all) ALL=1 ;;
        --list) LIST=1 ;;
        --no-open) OPEN=0 ;;
        --force) FORCE=1 ;;
        -h | --help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) die "unknown option $arg (see --help)" ;;
        *) NAME="${arg%.planelab}.planelab" ;;
    esac
done

[[ -x "$PYTHON" ]] || die "no Python environment at $PLANELAB/.venv (setup: PlaneLab/README.md)"

names="$(phone_sessions)"
[[ -n "$names" ]] || die "no recordings on the phone yet"

if [[ "$LIST" -eq 1 ]]; then
    while read -r name; do
        if [[ -d "$SESSIONS/$name" ]]; then echo "$name   (on the Mac)"; else echo "$name"; fi
    done <<<"$names"
    exit 0
fi

targets=()
if [[ -n "$NAME" ]]; then
    grep -qx "$NAME" <<<"$names" || die "$NAME isn't on the phone (see --list)"
    targets=("$NAME")
elif [[ "$ALL" -eq 1 ]]; then
    while read -r name; do
        if [[ "$FORCE" -eq 1 || ! -d "$SESSIONS/$name" ]]; then targets+=("$name"); fi
    done <<<"$names"
    if [[ "${#targets[@]}" -eq 0 ]]; then
        say "nothing new on the phone"
        exit 0
    fi
else
    targets=("$(tail -n 1 <<<"$names")")
fi

for name in "${targets[@]}"; do
    pull_one "$name"
    process "$name"
done

newest="${targets[${#targets[@]}-1]}"
if [[ "$OPEN" -eq 1 ]]; then
    say "opening $newest in Blender"
    open -a "$BLENDER_APP" "$SESSIONS/$newest/lab/replay.blend"
    echo "If the Plane Lab code changed since Blender started: F3 > Reload Scripts, then reopen the file."
fi
