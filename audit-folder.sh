#!/usr/bin/env bash
#
# Explain a count mismatch for one migrated folder.
#
#   ./audit-folder.sh "Simpson Khristian_2012-10-02_10770214198_1"
#   ./audit-folder.sh --pass 1 "Simpson Khristian_2012-10-02_10770214198_1"
#
# Takes the destination name from the plan, finds the matching Drive folder,
# and reports every file that is in one side and not the other. Renamed
# duplicates are accounted for rather than ignored: three copies of "X.pdf"
# are expected to land as X.pdf, X (2).pdf and X (3).pdf, so a fourth is
# reported as an extra and a missing third is reported as missing.
#
# It applies the same filters migrate.sh does, otherwise every excluded video
# and every file held back for pass 2 reads as missing. Match --pass to the
# pass you are checking; the default of "all" is what you want once both have
# run.
#
# Files left behind by an interrupted upload are reported as PARTIAL. rclone
# uploads to a temporary "<name>.<hash>.partial" and renames it on success, so
# one of these means a transfer was killed part way. They are safe to remove
# once the real file is present.
#
# Reads only. Nothing is copied, moved or deleted.

set -uo pipefail

GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
SF_REMOTE="${SF_REMOTE:-sharefile}"
SRC_ROOT="${SRC_ROOT:-_Client Documentation}"
PLAN="${PLAN:-migrate_plan.tsv}"
EXPORT_FORMATS="${EXPORT_FORMATS:-docx,xlsx,pptx}"
SIZE_SPLIT_BYTES="${SIZE_SPLIT_BYTES:-104857600}"   # 100 MiB
VIDEO_RE='\.(mp4|mov|m4v|avi|wmv|mkv|mpg|mpeg|3gp|3g2|webm|flv|f4v|mts|m2ts|m2v|vob|ogv|rm|asf|divx|mxf|ts)$'

PASS=all
SKIP_VIDEO=1
DEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pass) PASS="$2"; shift 2 ;;
    --plan) PLAN="$2"; shift 2 ;;
    --include-video) SKIP_VIDEO=0; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) DEST="$1"; shift ;;
  esac
done

case "$PASS" in
  1|2|all) ;;
  *) echo "--pass must be 1, 2, or all" >&2; exit 2 ;;
esac

[[ -n "$DEST" ]] || { echo "usage: $0 [--pass 1|2|all] \"<destination folder>\"" >&2; exit 2; }
[[ -f "$PLAN" ]] || { echo "plan file not found: $PLAN" >&2; exit 1; }

SRC="$(awk -F'\t' -v d="$DEST" '$1 == d { print $2; exit }' "$PLAN")"
[[ -n "$SRC" ]] || { echo "no row in $PLAN with destination: $DEST" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "drive:     ${SRC_ROOT}/${SRC}"
echo "sharefile: ${DEST}"
echo "filters:   pass $PASS, video $([[ $SKIP_VIDEO -eq 1 ]] && echo excluded || echo included)"
echo

rclone lsf "${GDRIVE_REMOTE}:${SRC_ROOT}/${SRC}" --recursive --files-only \
  --format "ps" --separator $'\t' \
  --drive-export-formats "$EXPORT_FORMATS" > "$WORK/src" || exit 1
rclone lsf "${SF_REMOTE}:${DEST}" --recursive --files-only \
  --format "ps" --separator $'\t' > "$WORK/dst" || exit 1

# Drive counts copies of a name; ShareFile spells them out as "X (2).pdf".
# Reducing each ShareFile name back to its base makes the two directly
# comparable, so a surplus or a shortfall shows up per name.
awk -F'\t' -v pass="$PASS" -v limit="$SIZE_SPLIT_BYTES" \
    -v skipvid="$SKIP_VIDEO" -v vidre="$VIDEO_RE" '
  function keep(path, size,   sz) {
    if (skipvid && tolower(path) ~ vidre) return 0
    sz = (size == "-1" ? 0 : size + 0)          # -1 is a Google Doc: treat as small
    if (pass == "1" && sz >= limit) return 0
    if (pass == "2" && sz <  limit) return 0
    return 1
  }
  function base(p,   s, i) {
    if (match(p, / \([0-9]+\)$/)) {
      k = substr(p, RSTART + 2, RLENGTH - 3) + 0
      return substr(p, 1, RSTART - 1)
    }
    if (match(p, / \([0-9]+\)\.[^.\/]+$/)) {
      s = substr(p, RSTART, RLENGTH)
      i = index(s, ")")
      k = substr(s, 3, i - 3) + 0
      return substr(p, 1, RSTART - 1) substr(s, i + 1)
    }
    k = 1
    return p
  }
  NR == FNR { if (keep($1, $2)) src[$1]++; next }
  {
    # An interrupted upload leaves "<name>.<hash>.partial" behind. Report it
    # rather than letting it read as an unexplained extra.
    if ($1 ~ /\.[0-9a-f]+\.partial$/) { partial[$1] = 1; next }
    if (!keep($1, $2)) { unexpected[$1] = 1; next }
    b = base($1); dst[b]++; if (k > high[b]) high[b] = k
  }
  END {
    for (b in partial)
      printf "PARTIAL  leftover from an interrupted upload            %s\n", b
    for (b in unexpected)
      printf "EXTRA    in sharefile but filtered out of this pass     %s\n", b
    for (b in dst) {
      if (!(b in src))
        printf "EXTRA    %d in sharefile, none in drive                 %s\n", dst[b], b
      else if (dst[b] > src[b])
        printf "EXTRA    %d in sharefile, %d in drive                      %s\n", dst[b], src[b], b
      else if (dst[b] < src[b])
        printf "MISSING  %d in sharefile, %d in drive                      %s\n", dst[b], src[b], b
      if (high[b] > dst[b])
        printf "GAP      numbered up to (%d) but only %d present         %s\n", high[b], dst[b], b
    }
    for (b in src)
      if (!(b in dst))
        printf "MISSING  0 in sharefile, %d in drive                      %s\n", src[b], b
  }
' "$WORK/src" "$WORK/dst" | sort

echo
echo "(no lines above means the two sides agree)"
