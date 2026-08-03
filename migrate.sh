#!/usr/bin/env bash
#
# Drive -> ShareFile client folder migration.
#
# Copies each source folder listed in a plan file to its renamed destination.
# Dry run by default: nothing is written unless you pass --go.
#
#   ./migrate.sh --pass 1                 # show what pass 1 would do
#   ./migrate.sh --pass 1 --go            # run pass 1
#   ./migrate.sh --pass 1 --go --only Abbott
#   ./migrate.sh --pass 1 --verify        # compare file counts, both sides
#
# Video files are excluded from every pass - see video-excludes.txt. Pass
# --include-video to override that.
#
# Passes split on file size:
#   1  = files under 100M  (the clinical documents; fast)
#   2  = files 100M and over (archives, oversized scans; slower)
#   all = no size filter
#
# Resumable. Each folder that finishes cleanly is recorded in .state/, and
# re-running skips it. Safe to interrupt with Ctrl-C and start again.

set -uo pipefail

GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
SF_REMOTE="${SF_REMOTE:-sharefile}"
SRC_ROOT="${SRC_ROOT:-_Client Documentation}"
PLAN="${PLAN:-migrate_plan.tsv}"
SIZE_SPLIT="${SIZE_SPLIT:-100M}"
VIDEO_EXCLUDES="${VIDEO_EXCLUDES:-video-excludes.txt}"

PASS=1
GO=0
VERIFY=0
ONLY=""
SKIP_VIDEO=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pass)   PASS="$2"; shift 2 ;;
    --plan)   PLAN="$2"; shift 2 ;;
    --only)   ONLY="$2"; shift 2 ;;
    --go)     GO=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --include-video) SKIP_VIDEO=0; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$PASS" in
  1)   SIZE_FILTER=(--max-size "$SIZE_SPLIT") ;;
  2)   SIZE_FILTER=(--min-size "$SIZE_SPLIT") ;;
  all) SIZE_FILTER=() ;;
  *)   echo "--pass must be 1, 2, or all" >&2; exit 2 ;;
esac

[[ -f "$PLAN" ]] || { echo "plan file not found: $PLAN" >&2; exit 1; }
command -v rclone >/dev/null || { echo "rclone not found" >&2; exit 1; }

# Video is excluded by extension rather than by size, so a short clip that
# happens to be small still gets left behind. Applied to copies and to
# verification alike, so both sides are counted on the same basis.
if [[ $SKIP_VIDEO -eq 1 ]]; then
  [[ -f "$VIDEO_EXCLUDES" ]] || {
    echo "video exclude list not found: $VIDEO_EXCLUDES" >&2
    echo "(put it beside this script, or pass --include-video to migrate video too)" >&2
    exit 1
  }
  FILTER=(${SIZE_FILTER[@]+"${SIZE_FILTER[@]}"} --exclude-from "$VIDEO_EXCLUDES")
else
  FILTER=(${SIZE_FILTER[@]+"${SIZE_FILTER[@]}"})
fi

mkdir -p .state logs
STATE=".state/done-pass${PASS}.txt"
touch "$STATE"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="logs/pass${PASS}-${STAMP}.log"

# Deliberately no --fast-list: it buffers the whole listing, which hides
# progress and made throttling failures much harder to diagnose.
RCLONE_FLAGS=(
  --transfers 4
  --checkers 8
  --tpslimit 10
  --retries 3
  --low-level-retries 10
  --drive-pacer-min-sleep 100ms
  --stats 30s
  --stats-one-line
  --log-file "$LOG"
  --log-level INFO
)

# file count for a remote path, applying the current pass filter
count_files() {
  rclone size "$1" ${FILTER[@]+"${FILTER[@]}"} --json 2>/dev/null \
    | sed -n 's/.*"count":\([0-9]*\).*/\1/p'
}

total=0; skipped=0; copied=0; failed=0
declare -a FAILED_ROWS=()

printf '%s\n' "plan:        $PLAN"
SIZE_DESC="no size filter"
[[ ${#SIZE_FILTER[@]} -gt 0 ]] && SIZE_DESC="${SIZE_FILTER[*]}"
printf '%s\n' "pass:        $PASS  ($SIZE_DESC)"
if [[ $SKIP_VIDEO -eq 1 ]]; then
  printf '%s\n' "video:       excluded ($VIDEO_EXCLUDES)"
else
  printf '%s\n' "video:       INCLUDED"
fi
printf '%s\n' "source:      ${GDRIVE_REMOTE}:${SRC_ROOT}/"
printf '%s\n' "destination: ${SF_REMOTE}:"
if [[ $VERIFY -eq 1 ]]; then
  printf '%s\n' "mode:        VERIFY (reads only)"
elif [[ $GO -eq 1 ]]; then
  printf '%s\n' "mode:        LIVE - files will be written"
else
  printf '%s\n' "mode:        DRY RUN - nothing will be written"
fi
echo

# skip the header line
while IFS=$'\t' read -r dest src files mb match; do
  [[ "$dest" == "dest_name" || -z "${dest:-}" ]] && continue
  [[ -n "$ONLY" && "$dest" != *"$ONLY"* && "$src" != *"$ONLY"* ]] && continue
  total=$((total + 1))

  src_path="${GDRIVE_REMOTE}:${SRC_ROOT}/${src}"
  dst_path="${SF_REMOTE}:${dest}"

  if [[ $VERIFY -eq 1 ]]; then
    s="$(count_files "$src_path")"; d="$(count_files "$dst_path")"
    s="${s:-0}"; d="${d:-0}"
    if [[ "$s" == "$d" ]]; then
      printf 'OK    %5s = %-5s  %s\n' "$s" "$d" "$dest"
      copied=$((copied + 1))
    else
      printf 'DIFF  src %-5s dst %-5s  %s\n' "$s" "$d" "$dest"
      failed=$((failed + 1)); FAILED_ROWS+=("$dest")
    fi
    continue
  fi

  if grep -qxF "$dest" "$STATE"; then
    skipped=$((skipped + 1))
    continue
  fi

  if [[ $GO -eq 0 ]]; then
    printf 'would copy  %-4s files  %s\n         ->  %s\n' "$files" "$src" "$dest"
    continue
  fi

  printf '[%d] %s\n' "$total" "$dest"
  if rclone copy "$src_path" "$dst_path" ${FILTER[@]+"${FILTER[@]}"} "${RCLONE_FLAGS[@]}"; then
    printf '%s\n' "$dest" >> "$STATE"
    copied=$((copied + 1))
  else
    printf '     FAILED (see %s)\n' "$LOG"
    failed=$((failed + 1)); FAILED_ROWS+=("$dest")
  fi
done < "$PLAN"

echo
if [[ $VERIFY -eq 1 ]]; then
  printf 'checked %d   matching %d   mismatched %d\n' "$total" "$copied" "$failed"
elif [[ $GO -eq 0 ]]; then
  printf '%d folders in plan. Nothing written. Add --go to run.\n' "$total"
else
  printf 'folders %d   copied %d   already done %d   failed %d\n' \
    "$total" "$copied" "$skipped" "$failed"
  printf 'log: %s\n' "$LOG"
fi

if [[ ${#FAILED_ROWS[@]} -gt 0 ]]; then
  echo
  echo "needs attention:"
  printf '  %s\n' "${FAILED_ROWS[@]}"
  exit 1
fi
