#!/usr/bin/env bash
#
# Build a record of what the migration actually landed in ShareFile.
#
#   ./make-manifest.sh                      # writes migration-manifest.tsv
#   ./make-manifest.sh --out record.tsv
#
# Reads the destination and the source once each - two recursive listings
# rather than one per folder - and reports, per client folder:
#
#   what is in ShareFile now, what Drive holds that was eligible to come
#   across, whether those agree, and how much video was deliberately left
#   behind.
#
# Client name, date of birth and case id are split out of the folder name so
# the result can be read as a clinical record rather than a list of paths.
#
# The output is tab separated and opens directly in Excel. It contains client
# names and dates of birth - keep it with the other migration files and do not
# put it anywhere public.
#
# Folders in Drive that no plan row covers are listed too, with the status
# not_in_plan, so nothing is silently absent from the record.
#
# Reads only. Nothing is copied, moved or deleted.

set -uo pipefail

GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
SF_REMOTE="${SF_REMOTE:-sharefile}"
SRC_ROOT="${SRC_ROOT:-_Client Documentation}"
PLAN="${PLAN:-migrate_plan.tsv}"
REVIEW_PLAN="${REVIEW_PLAN:-migrate_plan_review.tsv}"
EXPORT_FORMATS="${EXPORT_FORMATS:-docx,xlsx,pptx}"
OUT="migration-manifest.tsv"
VIDEO_RE='\.(mp4|mov|m4v|avi|wmv|mkv|mpg|mpeg|3gp|3g2|webm|flv|f4v|mts|m2ts|m2v|vob|ogv|rm|asf|divx|mxf|ts)$'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)    OUT="$2"; shift 2 ;;
    --plan)   PLAN="$2"; shift 2 ;;
    --review) REVIEW_PLAN="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$PLAN" ]] || { echo "plan file not found: $PLAN" >&2; exit 1; }
command -v rclone >/dev/null || { echo "rclone not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "listing Drive ..." >&2
rclone lsf "${GDRIVE_REMOTE}:${SRC_ROOT}" --recursive --files-only \
  --format "ps" --separator $'\t' \
  --drive-export-formats "$EXPORT_FORMATS" > "$WORK/drive" || exit 1

echo "listing ShareFile ..." >&2
rclone lsf "${SF_REMOTE}:" --recursive --files-only \
  --format "ps" --separator $'\t' > "$WORK/sf" || exit 1

# Tag each source so one awk pass can tell them apart regardless of whether
# any of them came back empty.
{
  awk -F'\t' -v OFS='\t' 'FNR > 1 && $1 != "" { print "P", $1, $2, "migrated" }' "$PLAN"
  [[ -f "$REVIEW_PLAN" ]] && \
    awk -F'\t' -v OFS='\t' 'FNR > 1 && $1 != "" { print "P", $1, $2, "needs_review" }' "$REVIEW_PLAN"
  awk -F'\t' -v OFS='\t' '{ print "D", $1, $2 }' "$WORK/drive"
  awk -F'\t' -v OFS='\t' '{ print "S", $1, $2 }' "$WORK/sf"
} > "$WORK/all"

awk -F'\t' -v OFS='\t' -v vidre="$VIDEO_RE" '
  function top(p,   i) { i = index(p, "/"); return i ? substr(p, 1, i - 1) : p }
  # Folder names read Name_YYYY-MM-DD_CaseId, with _1 or _2 appended only
  # where one client has more than one folder. Anchoring on the date is what
  # makes a name containing underscores safe to split.
  function split_name(d, out,   n, a, i, dob, name, j) {
    n = split(d, a, "_")
    dob = 0
    for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { dob = i; break }
    if (!dob) { out["name"] = d; out["dob"] = ""; out["case"] = ""; out["seq"] = ""; return }
    name = a[1]
    for (j = 2; j < dob; j++) name = name "_" a[j]
    out["name"] = name
    out["dob"]  = a[dob]
    out["case"] = (dob + 1 <= n ? a[dob + 1] : "")
    out["seq"]  = (dob + 2 <= n ? a[dob + 2] : "")
  }

  $1 == "P" { dest[$2] = $3; state[$2] = $4; src_is_planned[$3] = 1; next }

  $1 == "D" {
    f = top($2)
    sz = ($3 == "-1" ? 0 : $3 + 0)     # a Google Doc has no size until exported
    if (tolower($2) ~ vidre) { dvid[f]++; dvidb[f] += sz }
    else                     { dkeep[f]++; dkeepb[f] += sz }
    seen_src[f] = 1
    next
  }

  $1 == "S" {
    f = top($2)
    sfn[f]++
    sfb[f] += ($3 == "-1" ? 0 : $3 + 0)
    next
  }

  END {
    print "client", "dob", "case_id", "folder", "sharefile_folder", "drive_folder",
          "status", "files_in_sharefile", "files_expected", "mb_in_sharefile",
          "videos_left_in_drive", "video_gb_left"

    for (d in dest) {
      s = dest[d]
      split_name(d, p)
      expect = dkeep[s] + 0
      got = sfn[d] + 0
      if (state[d] == "needs_review")   st = "needs_review"
      else if (got == 0 && expect > 0)     st = "NOT_COPIED"
      else if (got != expect)              st = "MISMATCH"
      else                              st = "match"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%.1f\t%d\t%.2f\n",
        p["name"], p["dob"], p["case"], (p["seq"] == "" ? "1" : p["seq"]),
        d, s, st, got, expect, sfb[d] / 1048576, dvid[s] + 0, dvidb[s] / 1073741824
      done_src[s] = 1
    }

    # Anything in Drive that no plan row claims - the folders still to be
    # tracked down, and the master template if it is still there.
    for (f in seen_src) {
      if (f in done_src) continue
      split_name(f, p)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%.1f\t%d\t%.2f\n",
        p["name"], p["dob"], p["case"], (p["seq"] == "" ? "1" : p["seq"]),
        "", f, "not_in_plan", 0, dkeep[f] + 0, 0, dvid[f] + 0, dvidb[f] / 1073741824
    }
  }
' "$WORK/all" > "$WORK/rows"

head -1 "$WORK/rows" > "$OUT"
tail -n +2 "$WORK/rows" | sort -f >> "$OUT"

awk -F'\t' 'NR > 1 {
  n++; got += $8; expect += $9; mb += $10; vid += $11; vgb += $12; st[$7]++
} END {
  printf "\n%d folders, %d files in ShareFile, %.1f GB\n", n, got, mb / 1024
  printf "%d videos left in Drive, %.1f GB\n", vid, vgb
  printf "\nby status:\n"
  for (s in st) printf "  %-14s %d\n", s, st[s]
}' "$OUT" >&2

echo >&2
echo "written: $OUT" >&2
