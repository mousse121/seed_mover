#!/bin/sh
# sonarr_postprocess_v1.32_fix_append.sh
# POSIX; enregistre le mapping SRC->DST et un .state
# Ecrit :
#   - $MAP (append: SONARR|<SRC>|<DST>), verrou via mkdir ${MAP}.lockdir
#   - $STATE_DIR/<basename>.state
# Par défaut, chemins **dans le conteneur** (montage /scripts → hôte /srv/.../data/scripts)
# Dossiers créés si absents.
# Journalisation minimaliste dans $LOG.
# Compatible Sonarr v3/v4 (variables env lower/UPPER).

set -eu
umask 002

# ===== Réglages par défaut (chemins vus DANS le conteneur) =====
LOG="${LOG:-/scripts/synomap/log/sonarr_postprocess.log}"
MAP="${MAP:-/scripts/synomap/mapping_entries.txt}"
STATE_DIR="${STATE_DIR:-/scripts/state}"
LOCKDIR="${LOCKDIR:-${MAP}.lockdir}"
MAP_OWNER="${MAP_OWNER:-}"
MAP_GROUP="${MAP_GROUP:-}"

ts(){ date '+%F %T'; }

# ===== Lecture variables Sonarr (lower/UPPER) =====
EVT="${sonarr_eventtype:-${SONARR_EVENTTYPE:-}}"
DST="${sonarr_episodefile_path:-${SONARR_EPISODEFILE_PATH:-}}"
SRC_HINT="${sonarr_episodefile_sourcepath:-${SONARR_EPISODEFILE_SOURCEPATH:-}}"
CAT="${sonarr_download_client_category:-${SONARR_DOWNLOAD_CLIENT_CATEGORY:-sonarr}}"

# ===== Sanity/dirs =====
mkdir -p "$(dirname "$MAP")" "$STATE_DIR" "$(dirname "$LOG")"

# ===== Détermination SRC =====
SRC=""
if [ -n "${SRC_HINT:-}" ] && [ -e "$SRC_HINT" ]; then
  SRC="$SRC_HINT"
else
  # Fallback déterministe : /data/torrents/completed/<cat>/<basename>
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
# retry court pour éviter collision multi-import
i=0
while ! mkdir "$LOCKDIR" 2>/dev/null; do
  i=$((i+1))
  [ "$i" -ge 25 ] && { echo "$(ts) [WARN] lock busy, skip" >>"$LOG" 2>/dev/null || true; exit 0; }
  sleep 0.2
done
# S'assure de libérer le lock
cleanup(){ rmdir "$LOCKDIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Append ligne mapping
echo "SONARR|$SRC|$DST" >>"$MAP"
chmod 664 "$MAP" 2>/dev/null || true
if [ -n "$MAP_OWNER$MAP_GROUP" ]; then chown "$MAP_OWNER":"$MAP_GROUP" "$MAP" 2>/dev/null || true; fi

# ===== .state =====
state_name="$(basename -- "$DST" | tr '/\\' '_' ).state"
STATE_PATH="${STATE_DIR%/}/$state_name"
{
  echo "CAT=SONARR"
  echo "SRC=$SRC"
  echo "DST=$DST"
  echo "WHEN=$(date -Iseconds)"
} >"$STATE_PATH"
chmod 664 "$STATE_PATH" 2>/dev/null || true

# ===== Log OK =====
echo "$(ts) [OK] mapping append + state -> $STATE_PATH" >>"$LOG" 2>/dev/null || true

exit 0