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
# Duplicate filenames
# -------------------
# Google Drive allows several files to share a name inside one folder;
# ShareFile does not. A plain "rclone copy" hits this, prints "Duplicate
# object found in source - ignoring", keeps one file, and still exits 0 -
# so the loss is silent. These are not always the same document: one pair
# checked had different checksums and one was twice the size of the other.
#
# So this script does not let rclone resolve names. It lists every file with
# its Drive ID first, copies the unambiguous ones by explicit path list, and
# fetches each duplicate individually by ID, landing them as "name (2).docx",
# "name (3).docx" and so on. Nothing is dropped.
#
# Google Docs are exported on the way out (see EXPORT_FORMATS). They report a
# size of -1 in Drive because the export does not exist until it is asked for,
# and are treated as small so they always fall in pass 1.
#
# Video files are excluded from every pass - see video-excludes.txt. Pass
# --include-video to override.
#
# Passes split on file size:
#   1  = under 100M  (the clinical documents, plus all Google Docs; fast)
#   2  = 100M and over (archives, oversized scans)
#   all = no size filter
#
# Resumable. Each folder that finishes cleanly is recorded in .state/, and
# re-running skips it. Safe to interrupt with Ctrl-C and start again.

set -uo pipefail

GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
SF_REMOTE="${SF_REMOTE:-sharefile}"
SRC_ROOT="${SRC_ROOT:-_Client Documentation}"
PLAN="${PLAN:-migrate_plan.tsv}"
SIZE_SPLIT_BYTES="${SIZE_SPLIT_BYTES:-104857600}"   # 100 MiB
EXPORT_FORMATS="${EXPORT_FORMATS:-docx,xlsx,pptx}"
VIDEO_RE='\.(mp4|mov|m4v|avi|wmv|mkv|mpg|mpeg|3gp|3g2|webm|flv|f4v|mts|m2ts|m2v|vob|ogv|rm|asf|divx|mxf|ts)$'

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
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$PASS" in
  1|2|all) ;;
  *) echo "--pass must be 1, 2, or all" >&2; exit 2 ;;
esac

[[ -f "$PLAN" ]] || { echo "plan file not found: $PLAN" >&2; exit 1; }
command -v rclone >/dev/null || { echo "rclone not found" >&2; exit 1; }

mkdir -p .state logs
STATE=".state/done-pass${PASS}.txt"
touch "$STATE"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="logs/pass${PASS}-${STAMP}.log"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Deliberately no --fast-list: it buffers the whole listing, which hides
# progress and made throttling failures much harder to diagnose.
COMMON=(
  --drive-export-formats "$EXPORT_FORMATS"
  --tpslimit 10
  --retries 3
  --low-level-retries 10
  --drive-pacer-min-sleep 100ms
)
COPY_FLAGS=(
  "${COMMON[@]}"
  --transfers 4
  --checkers 8
  --stats 30s
  --stats-one-line
  --log-file "$LOG"
  --log-level INFO
)

# Split one folder's listing into the files we can copy by path (unique names)
# and the ones that need fetching by ID (duplicated names).
#   $1 listing  $2 -> unique paths  $3 -> "id<TAB>target" for duplicates
plan_folder() {
  sort -t$'\t' -k1,1 -k4,4 -k2,2 "$1" | awk -F'\t' -v OFS='\t' \
      -v uniq="$2" -v dup="$3" -v pass="$PASS" -v limit="$SIZE_SPLIT_BYTES" \
      -v skipvid="$SKIP_VIDEO" -v vidre="$VIDEO_RE" '
    function keep(path, size,   sz) {
      if (skipvid && tolower(path) ~ vidre) return 0
      # -1 is a Google Doc: no export exists yet, so treat it as small
      sz = (size == "-1" ? 0 : size + 0)
      if (pass == "1" && sz >= limit) return 0
      if (pass == "2" && sz <  limit) return 0
      return 1
    }
    NR == FNR { if (keep($1, $3)) n[$1]++; next }
    {
      if (!keep($1, $3)) next
      if (n[$1] == 1) { print $1 > uniq; next }
      k = ++seen[$1]
      target = $1
      if (k > 1) {
        i = match($1, /\.[^.\/]+$/)
        target = (i ? substr($1, 1, i-1) " (" k ")" substr($1, i) \
                    : $1 " (" k ")")
      }
      print $2, target > dup
    }
  ' "$1" "$1"
}

total=0; skipped=0; copied=0; failed=0; dupes_total=0
declare -a FAILED_ROWS=()

printf '%s\n' "plan:        $PLAN"
printf '%s\n' "pass:        $PASS  (split at $SIZE_SPLIT_BYTES bytes)"
printf '%s\n' "video:       $([[ $SKIP_VIDEO -eq 1 ]] && echo excluded || echo INCLUDED)"
printf '%s\n' "google docs: exported as $EXPORT_FORMATS"
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

while IFS=$'\t' read -r dest src files mb match; do
  [[ "$dest" == "dest_name" || -z "${dest:-}" ]] && continue
  [[ -n "$ONLY" && "$dest" != *"$ONLY"* && "$src" != *"$ONLY"* ]] && continue
  total=$((total + 1))

  src_path="${GDRIVE_REMOTE}:${SRC_ROOT}/${src}"
  dst_path="${SF_REMOTE}:${dest}"

  if [[ $GO -eq 1 ]] && grep -qxF "$dest" "$STATE"; then
    skipped=$((skipped + 1)); continue
  fi

  # Every mode needs the listing: it is what tells us the true expected count.
  LIST="$WORK/list"; UNIQ="$WORK/uniq"; DUP="$WORK/dup"
  : > "$LIST"; : > "$UNIQ"; : > "$DUP"
  if ! rclone lsf "$src_path" --recursive --files-only \
        --format "pist" --separator $'\t' "${COMMON[@]}" > "$LIST" 2>>"$LOG"; then
    printf 'LIST FAILED  %s\n' "$dest"
    failed=$((failed + 1)); FAILED_ROWS+=("$dest"); continue
  fi
  plan_folder "$LIST" "$UNIQ" "$DUP"
  n_uniq=$(wc -l < "$UNIQ" | tr -d ' ')
  n_dup=$(wc -l < "$DUP" | tr -d ' ')
  expected=$((n_uniq + n_dup))
  dupes_total=$((dupes_total + n_dup))

  if [[ $VERIFY -eq 1 ]]; then
    d=$(rclone size "$dst_path" --json "${COMMON[@]}" 2>/dev/null \
          | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
    d="${d:-0}"
    if [[ "$expected" == "$d" ]]; then
      printf 'OK    %5s = %-5s  %s\n' "$expected" "$d" "$dest"
      copied=$((copied + 1))
    else
      printf 'DIFF  src %-5s dst %-5s  %s\n' "$expected" "$d" "$dest"
      failed=$((failed + 1)); FAILED_ROWS+=("$dest")
    fi
    continue
  fi

  if [[ $GO -eq 0 ]]; then
    if [[ $n_dup -gt 0 ]]; then
      printf 'would copy  %-4s files (%s duplicated, renamed)  %s\n         ->  %s\n' \
        "$expected" "$n_dup" "$src" "$dest"
    else
      printf 'would copy  %-4s files  %s\n         ->  %s\n' "$expected" "$src" "$dest"
    fi
    continue
  fi

  printf '[%d] %s  (%s files' "$total" "$dest" "$expected"
  [[ $n_dup -gt 0 ]] && printf ', %s renamed' "$n_dup"
  printf ')\n'

  ok=1
  if [[ $n_uniq -gt 0 ]]; then
    rclone copy "$src_path" "$dst_path" --files-from "$UNIQ" "${COPY_FLAGS[@]}" || ok=0
  fi

  # Duplicates: fetch by Drive ID so the right file lands under the right name.
  while IFS=$'\t' read -r id target; do
    [[ -z "${id:-}" ]] && continue
    td="$WORK/one"; rm -rf "$td"; mkdir -p "$td"
    if ! rclone backend copyid "${GDRIVE_REMOTE}:" "$id" "$td/" \
           "${COMMON[@]}" --log-file "$LOG" --log-level INFO; then
      printf '     could not fetch duplicate: %s\n' "$target"; ok=0; continue
    fi
    got="$(ls -A "$td" 2>/dev/null | head -1)"
    if [[ -z "$got" ]]; then
      printf '     duplicate fetched nothing: %s\n' "$target"; ok=0; continue
    fi
    rclone copyto "$td/$got" "${dst_path}/${target}" "${COPY_FLAGS[@]}" || {
      printf '     could not upload duplicate: %s\n' "$target"; ok=0; }
  done < "$DUP"
  rm -rf "$WORK/one"

  if [[ $ok -eq 1 ]]; then
    printf '%s\n' "$dest" >> "$STATE"; copied=$((copied + 1))
  else
    printf '     FAILED (see %s)\n' "$LOG"
    failed=$((failed + 1)); FAILED_ROWS+=("$dest")
  fi
done < "$PLAN"

echo
if [[ $VERIFY -eq 1 ]]; then
  printf 'checked %d   matching %d   mismatched %d\n' "$total" "$copied" "$failed"
elif [[ $GO -eq 0 ]]; then
  printf '%d folders, %d files with duplicated names will be renamed.\n' \
    "$total" "$dupes_total"
  printf 'Nothing written. Add --go to run.\n'
else
  printf 'folders %d   copied %d   already done %d   failed %d   renamed %d\n' \
    "$total" "$copied" "$skipped" "$failed" "$dupes_total"
  printf 'log: %s\n' "$LOG"
fi

if [[ ${#FAILED_ROWS[@]} -gt 0 ]]; then
  echo; echo "needs attention:"; printf '  %s\n' "${FAILED_ROWS[@]}"
  exit 1
fi
