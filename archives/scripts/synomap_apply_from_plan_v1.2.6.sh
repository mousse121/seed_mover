#!/bin/sh
# REGLAGES_CHATGPT - header env (local)
SYNO_ENV="${SYNO_ENV:-/srv/dev-disk-by-uuid-167c3d64-0b12-412d-9453-f941e78f8f6e/data/scripts/synomap/synomap.env}"
[ -f "$SYNO_ENV" ] && . "$SYNO_ENV" || true
# FIN_REGLAGES
# synomap_apply_from_plan_v1.2.6.sh
# POSIX sh only, no awk. Parses plan file (hash header + "plan: ln 'SRC' -> 'DST'")
# Actions: create hardlink on mirror, set qBittorrent save path, add tag "SYNO", and recheck only on fresh link.
# Usage:  synomap_apply_from_plan_v1.2.6.sh [--write] /path/to/plan.txt

set -eu

usage() {
  echo "Usage: $(basename "$0") [--write] /path/to/plan.txt" >&2
  exit 1
}

WRITE=0
PLAN=""
if [ "$#" -eq 2 ] && [ "$1" = "--write" ]; then
  WRITE=1
  PLAN="$2"
elif [ "$#" -eq 1 ]; then
  PLAN="$1"
else
  usage
fi

[ -f "$PLAN" ] || { echo "ERR: plan not found: $PLAN" >&2; exit 1; }

# Optional env for qBittorrent / Sonarr / Radarr
# REGLAGES_CHATGPT - header env (local)
SYNO_ENV="${SYNO_ENV:-/srv/dev-disk-by-uuid-167c3d64-0b12-412d-9453-f941e78f8f6e/data/scripts/synomap/synomap.env}"
[ -f "$SYNO_ENV" ] && . "$SYNO_ENV" || true
# FIN_REGLAGES

# Cookie for qBittorrent API
COOKIE=""
if [ -n "${QB_URL:-}" ] && [ -n "${QB_USER:-}" ] && [ -n "${QB_PASS:-}" ]; then
  COOKIE="$(mktemp)"
  trap 'rm -f "$COOKIE" 2>/dev/null || true' EXIT INT TERM
  # Login (ignore failure)
  curl -sS -c "$COOKIE" --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS" \
    "$QB_URL/api/v2/auth/login" >/dev/null || true
fi

items=0
seen=" "          # dedup by hash with naive set in a string
prev=""
bad=0

# Utility: extract dest_dir=... from header
get_dest_dir() {
  # $1 = header line
  echo "$1" | sed -n 's/.*dest_dir=\([^ ]*\).*/\1/p'
}

# Utility: parse SRC/DST from "plan: ln 'SRC' -> 'DST'"
parse_src() {
  # $1=plan line
  # POSIX sed with capture groups
  echo "$1" | sed -n "s/.*plan: ln '\(.*\)' -> '.*'/\1/p"
}
parse_dst() {
  echo "$1" | sed -n "s/.*plan: ln '.*' -> '\(.*\)'/\1/p"
}

# Loop over plan file
# State: waiting a header -> got header -> waiting plan line
while IFS= read -r line || [ -n "$line" ]; do
  # header = 40 hex then space
  if printf '%s\n' "$line" | grep -Eq '^[0-9a-f]{40}[[:space:]]'; then
    prev="$line"
    if printf '%s\n' "$line" | grep -q 'SKIP:\|\[NOSTAT\]'; then bad=1; else bad=0; fi
    continue
  fi

  # plan line with optional indentation
  if printf '%s\n' "$line" | grep -Eq '^[[:space:]]*plan:[[:space:]]*ln[[:space:]]'; then
    [ -n "$prev" ] || continue
    [ "$bad" -eq 0 ] || { prev=""; continue; }

    H="$(printf '%s\n' "$prev" | cut -c1-40)"
    case " $seen " in
      *" $H "*) prev=""; continue ;;
    esac
    seen="$seen$H "

    DEST_DIR="$(get_dest_dir "$prev")"
    [ -n "$DEST_DIR" ] || DEST_DIR="${DEST_ROOT:-}"

    SRC="$(parse_src "$line")"
    DST="$(parse_dst "$line")"
    if [ -z "$SRC" ] || [ -z "$DST" ]; then prev=""; continue; fi

    echo "hash=$H dest=$DEST_DIR"

    if [ "$WRITE" -eq 1 ]; then
      umask "${UMASK:-002}"
      # mkdir (best effort)
      mkdir -p "$DEST_DIR" 2>/dev/null || true
      recheck=0
      if [ -e "$DST" ]; then
        if [ "$(stat -c '%d:%i' "$SRC" 2>/dev/null || echo x)" = "$(stat -c '%d:%i' "$DST" 2>/dev/null || echo y)" ]; then
          echo "LINK-EXISTS '$DST' (same inode)"
        else
          echo "SKIP link (dst exists, different inode)"
        fi
      else
        if ln "$SRC" "$DST" 2>/dev/null; then
          echo "ln '$SRC' -> '$DST'"
          recheck=1
        else
          echo "ERR ln '$SRC' -> '$DST'"
        fi
      fi

      # qBittorrent API calls (best effort)
      if [ -n "${QB_URL:-}" ] && [ -n "$COOKIE" ] && [ -s "$COOKIE" ]; then
        curl -sS -b "$COOKIE" --data-urlencode "hashes=$H" --data-urlencode "location=$DEST_DIR" \
          "$QB_URL/api/v2/torrents/setLocation" >/dev/null || true
        echo "qB:setLocation '$H' -> '$DEST_DIR'"
        curl -sS -b "$COOKIE" --data-urlencode "hashes=$H" --data-urlencode "tags=SYNO" \
          "$QB_URL/api/v2/torrents/addTags" >/dev/null || true
        echo "qB:addTags '$H' SYNO"
        if [ "$recheck" -eq 1 ]; then
          curl -sS -b "$COOKIE" --data-urlencode "hashes=$H" \
            "$QB_URL/api/v2/torrents/recheck" >/dev/null || true
          echo "qB:recheck '$H'"
        else
          echo "SKIP recheck (link existed or error)"
        fi
      fi
    else
      echo "[preview] mkdir -p '$DEST_DIR'"
      if [ -e "$DST" ] && [ "$(stat -c '%d:%i' "$SRC" 2>/dev/null || echo x)" = "$(stat -c '%d:%i' "$DST" 2>/dev/null || echo y)" ]; then
        echo "[preview] LINK-EXISTS '$DST' (same inode)"
        echo "[preview] SKIP recheck (link existed or error)"
      else
        echo "[preview] ln '$SRC' -> '$DST'"
        echo "[preview] qB:recheck '$H'"
      fi
      echo "[preview] qB:setLocation '$H' -> '$DEST_DIR'"
      echo "[preview] qB:addTags '$H' SYNO"
    fi

    items=$((items+1))
    prev=""
    continue
  fi
done < "$PLAN"

if [ "$WRITE" -eq 1 ]; then
  echo "Done (apply from plan, WRITE mode, items=$items)"
else
  echo "Done (apply from plan, PREVIEW, items=$items)"
fi
