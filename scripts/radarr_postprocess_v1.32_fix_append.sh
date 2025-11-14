#!/bin/sh
# radarr_postprocess_v1.32_fix_append.sh
# POSIX; mapping SRC->DST + .state (verrou/droits)
# Ecrit :
#   - $MAP (append: RADARR|<SRC>|<DST>) verrou via mkdir ${MAP}.lockdir
#   - $STATE_DIR/<basename>.state
# Par défaut, chemins **dans le conteneur** (montage /scripts → hôte /srv/.../data/scripts)

set -eu
umask 002

# ===== Réglages par défaut (chemins vus DANS le conteneur) =====
LOG="${LOG:-/scripts/synomap/log/radarr_postprocess.log}"
MAP="${MAP:-/scripts/synomap/mapping_entries.txt}"
STATE_DIR="${STATE_DIR:-/scripts/state}"
LOCKDIR="${LOCKDIR:-${MAP}.lockdir}"
MAP_OWNER="${MAP_OWNER:-}"
MAP_GROUP="${MAP_GROUP:-}"

ts(){ date '+%F %T'; }

# ===== Lecture variables Radarr (lower/UPPER) =====
EVT="${radarr_eventtype:-${RADARR_EVENTTYPE:-}}"
DST="${radarr_moviefile_path:-${RADARR_MOVIEFILE_PATH:-}}"
SRC_HINT="${radarr_moviefile_sourcepath:-${RADARR_MOVIEFILE_SOURCEPATH:-}}"
CAT="${radarr_download_client_category:-${RADARR_DOWNLOAD_CLIENT_CATEGORY:-radarr}}"

# ===== Sanity/dirs =====
mkdir -p "$(dirname "$MAP")" "$STATE_DIR" "$(dirname "$LOG")"

# ===== Détermination SRC =====
SRC=""
if [ -n "${SRC_HINT:-}" ] && [ -e "$SRC_HINT" ]; then
  SRC="$SRC_HINT"
else
  base="$(basename -- "$DST")"
  SRC="/data/torrents/completed/${CAT}/${base}"
fi

# ===== Journal (best-effort) =====
{
  echo "$(ts) [INFO] EVT=$EVT"
  echo "$(ts) [INFO] DST=$DST"
  echo "$(ts) [INFO] SRC=$SRC"
} >>"$LOG" 2>/dev/null || true

# ===== Ecriture mapping avec lock =====
i=0
while ! mkdir "$LOCKDIR" 2>/dev/null; do
  i=$((i+1))
  [ "$i" -ge 25 ] && { echo "$(ts) [WARN] lock busy, skip" >>"$LOG" 2>/dev/null || true; exit 0; }
  sleep 0.2
done
cleanup(){ rmdir "$LOCKDIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "RADARR|$SRC|$DST" >>"$MAP"
chmod 664 "$MAP" 2>/dev/null || true
if [ -n "$MAP_OWNER$MAP_GROUP" ]; then chown "$MAP_OWNER":"$MAP_GROUP" "$MAP" 2>/dev/null || true; fi

# ===== .state =====
state_name="$(basename -- "$DST" | tr '/\\' '_' ).state"
STATE_PATH="${STATE_DIR%/}/$state_name"
{
  echo "CAT=RADARR"
  echo "SRC=$SRC"
  echo "DST=$DST"
  echo "WHEN=$(date -Iseconds)"
} >"$STATE_PATH"
chmod 664 "$STATE_PATH" 2>/dev/null || true

echo "$(ts) [OK] mapping append + state -> $STATE_PATH" >>"$LOG" 2>/dev/null || true

exit 0
