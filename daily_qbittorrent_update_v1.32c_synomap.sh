#!/bin/sh
# REGLAGES_CHATGPT - header env (local)
SYNO_ENV="${SYNO_ENV:-/srv/dev-disk-by-uuid-167c3d64-0b12-412d-9453-f941e78f8f6e/data/scripts/synomap/synomap.env}"
[ -f "$SYNO_ENV" ] && . "$SYNO_ENV" || true
# FIN_REGLAGES

# daily_qbittorrent_update_v1.31_synomap.sh
# - Lecture /scripts/mapping_entries.txt (SRC->DST)
# - Hardlink vers /syno/torrents/completed/<cat>/<original_name>
# - setLocation seulement si diffrent
# - tag=SYNO
# - recheck SKIPPED si le hardlink existe dj (mme inode)
# - ge par dfaut = 3 jours (259200s)

set -eu

ALLOW="${ALLOW:-sonarr radarr}"
MIN_AGE="${MIN_AGE:-259200}"
DEST_ROOT="${DEST_ROOT:-/syno/torrents/completed}"
LIMIT="${LIMIT:-0}"
WRITE=0
YES=0
MAP_FILE="${MAP_FILE:-/data/scripts/mapping_entries.txt}"

usage(){ echo "Usage: $0 [--allow "sonarr radarr"] [--min-age SEC] [--dest-root PATH] [--limit N] [--map-file PATH] [--write [--yes]]" >&2; exit 1; }
die(){ echo "[ERROR] $*" >&2; exit 1; }
now_epoch(){ date +%s; }
in_allow(){ _c="$1"; for w in $ALLOW; do [ "$_c" = "$w" ] && return 0; done; return 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --allow) shift; ALLOW="${1:-$ALLOW}";;
    --min-age) shift; MIN_AGE="${1:-$MIN_AGE}";;
    --dest-root) shift; DEST_ROOT="${1:-$DEST_ROOT}";;
    --limit) shift; LIMIT="${1:-$LIMIT}";;
    --map-file) shift; MAP_FILE="${1:-$MAP_FILE}";;
    --write) WRITE=1;;
    --yes) YES=1;;
    -h|--help) usage;;
    *) echo "[WARN] Unknown arg: $1" >&2;;
  esac
  shift || true
done

[ -n "${QB_URL:-}" ]  || die "QB_URL not set"
[ -n "${QB_USER:-}" ] || die "QB_USER not set"
[ -n "${QB_PASS:-}" ] || die "QB_PASS not set"
[ -f "$MAP_FILE" ]    || die "MAP_FILE not found: $MAP_FILE"

COOKIE="$(mktemp)"; trap 'rm -f "$COOKIE" 2>/dev/null || true' EXIT INT TERM
login_resp="$(curl -sS -c "$COOKIE" --data-urlencode username="$QB_USER" --data-urlencode password="$QB_PASS" "$QB_URL/api/v2/auth/login" || true)"
case "$login_resp" in *Ok.*) : ;; *) die "qB login failed (got: ${login_resp:-<empty>})";; esac

TI_JSON="$(mktemp)"
curl -sS -b "$COOKIE" "$QB_URL/api/v2/torrents/info" > "$TI_JSON"

now="$(now_epoch)"
count_total="$(jq -r 'length' "$TI_JSON" 2>/dev/null || echo 0)"
sel=0
printf "total=%s\n" "$count_total"

jq -r '.[] | [ .hash, (.category//""), (.state//""), (.completion_on//0), (.save_path//""), (.name//""), (.added_on//0) ] | @tsv' "$TI_JSON" \
| while IFS="$(printf '\t')" read -r H CAT STATE COMP SAVE NAME ADDED; do
  if ! in_allow "$CAT"; then echo "$H  $CAT  $STATE  SKIP:category"; continue; fi

  COMP_NUM=0
  case "$COMP" in ''|null) COMP_NUM=0 ;; *) COMP_NUM="$COMP" ;; esac
  [ "$COMP_NUM" -le 0 ] && [ -n "$ADDED" ] && COMP_NUM="$ADDED"
  [ -z "$COMP_NUM" ] || [ "$COMP_NUM" -le 0 ] && { echo "$H  $CAT  $STATE  SKIP:no_time"; continue; }
  AGE=$(( now - COMP_NUM ))
  [ "$AGE" -lt "$MIN_AGE" ] && { echo "$H  $CAT  $STATE  SKIP:age"; continue; }

  TOP="$NAME"
  case "$TOP" in *.mkv|*.mp4|*.avi|*.m4v|*.mov) : ;;
    *) FJSON="$(mktemp)"; curl -sS -b "$COOKIE" "$QB_URL/api/v2/torrents/files?hash=$H" > "$FJSON"
       TOP="$(jq -r 'max_by(.size // 0) | .name' "$FJSON" 2>/dev/null || echo "")"
       rm -f "$FJSON" || true ;;
  esac
  [ -n "$TOP" ] && [ "$TOP" != "null" ] || { echo "$H  $CAT  $STATE  SKIP:no_top"; continue; }

  case "$SAVE" in */) SRC="${SAVE}${TOP}" ;; *) SRC="${SAVE}/${TOP}" ;; esac

  MAP_LINE="$(awk -F'|' -v src="$SRC" '$2==src{print $0}' "$MAP_FILE" | head -n1)"
  [ -z "$MAP_LINE" ] && { echo "$H  $CAT  count=1  top='$TOP'  [MAPMISS] src_not_found_in_mapping  src=$SRC"; continue; }
  DST="$(printf "%s\n" "$MAP_LINE" | awk -F'|' '{print $3}')"
  [ -n "$DST" ] || { echo "$H  $CAT  count=1  top='$TOP'  [MAPMISS] dst_empty"; continue; }

  DEST_DIR="$DEST_ROOT/$CAT"
  DEST_PATH="$DEST_DIR/$TOP"
  [ "$WRITE" -eq 1 ] && mkdir -p "$DEST_DIR"

  DEV_DEST_DIR="$(stat -c '%d' "$DEST_DIR" 2>/dev/null || echo -1)"
  DEV_DST="$(stat -c '%d' "$DST" 2>/dev/null || echo -2)"
  [ "$DEV_DEST_DIR" -ge 0 ] && [ "$DEV_DST" -ge 0 ] || { echo "$H  $CAT  count=1  top='$TOP'  [NOSTAT] dev_check_failed  dest_dir=$DEST_DIR  dst=$DST"; continue; }
  [ "$DEV_DEST_DIR" -ne "$DEV_DST" ] && { echo "$H  $CAT  count=1  top='$TOP'  [CROSS-DEV] cannot_hardlink  dst=$DST  dest_dir=$DEST_DIR"; continue; }

  printf "%s  cat=%s  count=1  top='%s'  dest_dir=%s\n" "$H" "$CAT" "$TOP" "$DEST_DIR"
  echo "  plan: ln '$DST' -> '$DEST_PATH'"

  sel=$((sel+1)); [ "$LIMIT" -gt 0 ] && [ "$sel" -ge "$LIMIT" ] && break

  if [ "$WRITE" -eq 1 ]; then
    DO_RECHECK=1
    if [ -e "$DEST_PATH" ]; then
      INO_DST="$(stat -c '%i' "$DST" 2>/dev/null || echo 0)"
      INO_DEST_PATH="$(stat -c '%i' "$DEST_PATH" 2>/dev/null || echo -1)"
      if [ "$INO_DST" -gt 0 ] && [ "$INO_DST" = "$INO_DEST_PATH" ]; then
        echo "  [EXISTS] $DEST_PATH (same inode)"
        DO_RECHECK=0
      else
        echo "  [EXISTS] $DEST_PATH (different inode) -> relink"
        rm -f "$DEST_PATH"
        ln "$DST" "$DEST_PATH"
      fi
    else
      ln "$DST" "$DEST_PATH"
      echo "  [LINKED] $DEST_PATH"
    fi

    if [ "$SAVE" != "$DEST_DIR/" ] && [ "$SAVE" != "$DEST_DIR" ]; then
      curl -sS -b "$COOKIE" --data-urlencode "hashes=$H" --data-urlencode "location=$DEST_DIR" "$QB_URL/api/v2/torrents/setLocation" >/dev/null
    fi
    curl -sS -b "$COOKIE" --data-urlencode "hashes=$H" --data-urlencode "tags=SYNO" "$QB_URL/api/v2/torrents/addTags" >/dev/null

    if [ "$DO_RECHECK" -eq 1 ]; then
      curl -sS -b "$COOKIE" --data-urlencode "hashes=$H" "$QB_URL/api/v2/torrents/recheck" >/dev/null
    else
      echo "  [SKIP-RECHECK] already linked"
    fi
  fi
done

# v1.31  2025-11-10
exit 0