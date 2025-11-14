#!/bin/sh
# synomap_prune_mapping_write_v1.1.sh
# Writer: create a cleaned mapping file by removing lines proven migrated (hardlink exists).
# Changes vs v1.0:
#  - backups go to <map_dir>/backup/mapping_entries/
#  - mkdir -p for backup directory and output parent directory
#  - keep ASCII-only and /bin/sh
#
# Default: PREVIEW (no write). To write, pass --write --yes.
#
# Usage:
#   sh synomap_prune_mapping_write_v1.1.sh [--input <mapfile>] [--output <cleaned>] [--in-place] [--write] [--yes]
#
# Env (via synomap.env if present):
#   MAP_FILE, ALLOW, SYNO_ENV
set -eu

# ---- Header env (local; no /etc) ----
SYNO_ENV="${SYNO_ENV:-/srv/dev-disk-by-uuid-167c3d64-0b12-412d-9453-f941e78f8f6e/data/scripts/synomap/synomap.env}"
[ -f "$SYNO_ENV" ] && . "$SYNO_ENV" || true

# Defaults
ALLOW="${ALLOW:-sonarr radarr}"
MAP_FILE_INPUT="${MAP_FILE:-/srv/dev-disk-by-uuid-167c3d64-0b12-412d-9453-f941e78f8f6e/data/scripts/synomap/mapping_entries.txt}"
OUT_FILE_DEFAULT="$(dirname "$MAP_FILE_INPUT")/mapping_entries.cleaned.txt"

WRITE="0"
YES="0"
OUT_FILE=""
INPLACE="0"

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --input) shift; MAP_FILE_INPUT="${1:-$MAP_FILE_INPUT}";;
    --output) shift; OUT_FILE="${1:-}";;
    --in-place|--inplace) INPLACE="1";;
    --write) WRITE="1";;
    --yes|-y) YES="1";;
    --help|-h) echo "Usage: $0 [--input <map>] [--output <cleaned>] [--in-place] [--write] [--yes]"; exit 0;;
    *) echo "[NOK] unknown arg: $1" >&2; exit 2;;
  esac
  shift || true
done

[ -f "$MAP_FILE_INPUT" ] || { echo "[NOK] mapping file not found: $MAP_FILE_INPUT" >&2; exit 2; }

if [ "$INPLACE" = "1" ]; then
  OUT_FILE="$MAP_FILE_INPUT"
fi
if [ -z "${OUT_FILE:-}" ]; then
  OUT_FILE="$OUT_FILE_DEFAULT"
fi

# Helpers
in_list() { needle="$1"; shift; for w in "$@"; do [ "$w" = "$needle" ] && return 0; done; return 1; }
deduce_cat() {
  _orig="$1"; _src="$2"
  case "$_orig" in *SONARR*|SONARR) echo "sonarr"; return 0;; *RADARR*|RADARR) echo "radarr"; return 0;; esac
  case "$_src" in */sonarr/*) echo "sonarr"; return 0;; */radarr/*) echo "radarr"; return 0;; esac
  echo "unknown"; return 0
}
CR="$(printf '\r')"
trim_field() {
  _s="$1"
  case "$_s" in *"$CR") _s=$(printf %s "$_s" | tr -d '\r');; esac
  while :; do case "$_s" in *'|') _s=${_s%|};; *) break;; esac; done
  printf %s "$_s"
}
to_syno_src() {
  _cat="$1"; _src="$2"
  case "$_src" in
    /syno/*) echo "$_src"; return 0;;
    /data/torrents/completed/"$_cat"/*)
      bn="${_src##*/}"; echo "/syno/torrents/completed/$_cat/$bn"; return 0;;
  esac
  bn="${_src##*/}"; echo "/syno/torrents/completed/$_cat/$bn"; return 0
}

# Pass 1: compute decisions and build cleaned content in a temp file
TS="$(date +%Y%m%d_%H%M%S)"
OUT_PARENT="$(dirname "$OUT_FILE")"
TMP="${OUT_FILE}.tmp.$$"

# Ensure output parent exists (for --output cases)
mkdir -p -- "$OUT_PARENT" 2>/dev/null || true
: > "$TMP"

purge=0; keep=0; skip=0; total=0

while IFS= read -r line || [ -n "$line" ]; do
  total=$((total+1))
  case "$line" in
    ""|\#*) skip=$((skip+1)); printf "%s\n" "$line" >>"$TMP"; continue;;
  esac

  ORIG="${line%%|*}"; rest="${line#*|}"; SRC="${rest%%|*}"; DST="${rest#*|}"
  if [ -z "$ORIG" ] || [ -z "$SRC" ] || [ -z "$DST" ] || [ "$ORIG" = "$rest" ]; then
    keep=$((keep+1)); printf "%s\n" "$line" >>"$TMP"; continue
  fi

  ORIG=$(trim_field "$ORIG"); SRC=$(trim_field "$SRC"); DST=$(trim_field "$DST")
  catg=$(deduce_cat "$ORIG" "$SRC")
  case "$catg" in sonarr|radarr) : ;; *) keep=$((keep+1)); printf "%s\n" "$ORIG|$SRC|$DST" >>"$TMP"; continue;; esac
  if ! in_list "$catg" $ALLOW; then keep=$((keep+1)); printf "%s\n" "$ORIG|$SRC|$DST" >>"$TMP"; continue; fi

  SRC_SYNO=$(to_syno_src "$catg" "$SRC")

  if [ -f "$DST" ] && [ -f "$SRC_SYNO" ]; then
    s_src=$(stat -c '%d %i' "$SRC_SYNO" 2>/dev/null || echo "")
    s_dst=$(stat -c '%d %i' "$DST"      2>/dev/null || echo "")
    if [ -n "$s_src" ] && [ -n "$s_dst" ] && [ "$s_src" = "$s_dst" ]; then
      purge=$((purge+1))
      continue
    fi
  fi

  keep=$((keep+1)); printf "%s\n" "$ORIG|$SRC|$DST" >>"$TMP"
done < "$MAP_FILE_INPUT"

echo "== PREVIEW SUMMARY =="
echo "target_output=$OUT_FILE"
echo "purge=$purge keep=$keep skip=$skip total=$total"

# If no write requested, stop here.
if [ "$WRITE" != "1" ]; then
  rm -f "$TMP"
  exit 0
fi

if [ "$YES" != "1" ]; then
  echo "[NOK] --write requires --yes confirmation." >&2
  rm -f "$TMP"
  exit 3
fi

# Write path
if [ "$INPLACE" = "1" ]; then
  MAP_DIR="$(dirname "$MAP_FILE_INPUT")"
  BAK_DIR="${MAP_DIR}/backup/mapping_entries"
  mkdir -p -- "$BAK_DIR" 2>/dev/null || true
  BAK="${BAK_DIR}/$(basename "$MAP_FILE_INPUT").bak_${TS}"
  cp -f -- "$MAP_FILE_INPUT" "$BAK"
  mv -f -- "$TMP" "$MAP_FILE_INPUT"
  echo "[OK] in-place replaced. Backup: $BAK"
else
  # OUT_FILE already has parent created; just move
  mv -f -- "$TMP" "$OUT_FILE"
  echo "[OK] written cleaned file: $OUT_FILE"
fi

exit 0
