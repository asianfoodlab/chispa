#!/usr/bin/env bash
#
# Explain a count mismatch for one migrated folder.
#
#   ./audit-folder.sh "Simpson Khristian_2012-10-02_10770214198_1"
#
# Takes the destination name from the plan, finds the matching Drive folder,
# and reports every file that is in one side and not the other. Renamed
# duplicates are accounted for rather than ignored: three copies of "X.pdf"
# are expected to land as X.pdf, X (2).pdf and X (3).pdf, so a fourth is
# reported as an extra and a missing third is reported as missing.
#
# Reads only. Nothing is copied, moved or deleted.

set -uo pipefail

GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
SF_REMOTE="${SF_REMOTE:-sharefile}"
SRC_ROOT="${SRC_ROOT:-_Client Documentation}"
PLAN="${PLAN:-migrate_plan.tsv}"
EXPORT_FORMATS="${EXPORT_FORMATS:-docx,xlsx,pptx}"

DEST="${1:-}"
[[ -n "$DEST" ]] || { echo "usage: $0 \"<destination folder name>\"" >&2; exit 2; }
[[ -f "$PLAN" ]] || { echo "plan file not found: $PLAN" >&2; exit 1; }

SRC="$(awk -F'\t' -v d="$DEST" '$1 == d { print $2; exit }' "$PLAN")"
[[ -n "$SRC" ]] || { echo "no row in $PLAN with destination: $DEST" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "drive:     ${SRC_ROOT}/${SRC}"
echo "sharefile: ${DEST}"
echo

rclone lsf "${GDRIVE_REMOTE}:${SRC_ROOT}/${SRC}" --recursive --files-only \
  --drive-export-formats "$EXPORT_FORMATS" > "$WORK/src" || exit 1
rclone lsf "${SF_REMOTE}:${DEST}" --recursive --files-only > "$WORK/dst" || exit 1

printf 'drive %s files, sharefile %s files\n\n' \
  "$(wc -l < "$WORK/src" | tr -d ' ')" "$(wc -l < "$WORK/dst" | tr -d ' ')"

# Drive counts copies of a name; ShareFile spells them out as "X (2).pdf".
# Reducing each ShareFile name back to its base makes the two directly
# comparable, so a surplus or a shortfall shows up per name.
awk -F'\t' '
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
  NR == FNR { src[$0]++; next }
  { b = base($0); dst[b]++; if (k > high[b]) high[b] = k }
  END {
    for (b in dst) {
      if (!(b in src))      printf "EXTRA    %d in sharefile, none in drive   %s\n", dst[b], b
      else if (dst[b] > src[b]) printf "EXTRA    %d in sharefile, %d in drive        %s\n", dst[b], src[b], b
      else if (dst[b] < src[b]) printf "MISSING  %d in sharefile, %d in drive        %s\n", dst[b], src[b], b
      if (high[b] > dst[b])
        printf "GAP      numbered up to (%d) but only %d present    %s\n", high[b], dst[b], b
    }
    for (b in src)
      if (!(b in dst)) printf "MISSING  0 in sharefile, %d in drive        %s\n", src[b], b
  }
' "$WORK/src" "$WORK/dst" | sort

echo
echo "(no lines above means the two sides agree)"
