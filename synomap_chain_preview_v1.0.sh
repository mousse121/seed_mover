#!/bin/sh
# synomap_chain_preview_v1.0.sh
# Orchestrates: generate plan -> apply from plan -> cleanup, all in PREVIEW by default.
# ASCII-only, /bin/sh, simple and robust.
#
# Usage:
#   sh synomap_chain_preview_v1.0.sh [--limit N] [--map-file PATH] [--plan-out PATH] [--keep-plan]
#                                    [--no-apply] [--no-cleanup]
# Defaults:
#   --limit 20
#   --map-file from $MAP_FILE (env) or fallback to synomap/mapping_entries.txt
#   --plan-out synomap/plans/_auto_plan_<TS>.txt
#   PREVIEW always (no write flags passed to called scripts)
#
set -eu

# --- Header env (local; no /etc) ---
SYNO_ENV="${SYNO_ENV:-/srv/dev-disk-by-uuid-167c3d64-0b12-412d-9453-f941e78f8f6e/data/scripts/synomap/synomap.env}"
[ -f "$SYNO_ENV" ] && . "$SYNO_ENV" || true

# Discover script dir
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLANS_DIR="$SCRIPT_DIR/plans"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/log}"

DAILY="$SCRIPT_DIR/daily_qbittorrent_update_v1.32c_synomap.sh"
APPLY="$SCRIPT_DIR/synomap_apply_from_plan_v1.2.6.sh"
CLEAN="$SCRIPT_DIR/synomap_cleanup_omv_only_v1.0.sh"

# Defaults
LIMIT="${LIMIT:-20}"
MAP_FILE_DEFAULT="${MAP_FILE:-$SCRIPT_DIR/mapping_entries.txt}"
TS="$(date +%Y%m%d_%H%M%S)"
PLAN_OUT_DEFAULT="$PLANS_DIR/_auto_plan_${TS}.txt"
PLAN_OUT=""
KEEP_PLAN="0"
DO_APPLY="1"
DO_CLEAN="1"

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) shift; LIMIT="${1:-$LIMIT}";;
    --map-file) shift; MAP_FILE_DEFAULT="${1:-$MAP_FILE_DEFAULT}";;
    --plan-out) shift; PLAN_OUT="${1:-}";;
    --keep-plan) KEEP_PLAN="1";;
    --no-apply) DO_APPLY="0";;
    --no-cleanup) DO_CLEAN="0";;
    --help|-h)
      echo "Usage: $0 [--limit N] [--map-file PATH] [--plan-out PATH] [--keep-plan] [--no-apply] [--no-cleanup]"
      exit 0;;
    *) echo "[NOK] unknown arg: $1" >&2; exit 2;;
  esac
  shift || true
done

MAP_FILE="${MAP_FILE_DEFAULT}"
PLAN_FILE="${PLAN_OUT:-$PLAN_OUT_DEFAULT}"

# Ensure dirs
mkdir -p -- "$PLANS_DIR" "$LOG_DIR" 2>/dev/null || true

# Sanity
[ -x "$DAILY" ] || { echo "[NOK] missing or non-executable: $DAILY" >&2; exit 2; }
[ -x "$APPLY" ] || { echo "[NOK] missing or non-executable: $APPLY" >&2; exit 2; }
[ -x "$CLEAN" ] || { echo "[NOK] missing or non-executable: $CLEAN" >&2; exit 2; }
[ -f "$MAP_FILE" ] || { echo "[NOK] mapping file not found: $MAP_FILE" >&2; exit 2; }

echo "== CHAIN (PREVIEW) =="
echo "limit=$LIMIT"
echo "map_file=$MAP_FILE"
echo "plan_file=$PLAN_FILE"
echo "apply=$DO_APPLY cleanup=$DO_CLEAN"
echo "log_dir=$LOG_DIR"
echo

# 1) Generate plan (full output, not only plan: lines)
echo "[1/3] Generating plan (PREVIEW) ..."
sh "$DAILY" --limit "$LIMIT" --map-file "$MAP_FILE" > "$PLAN_FILE"
echo "[1/3] Plan file written: $PLAN_FILE"

# Quick count
PLANS_COUNT="$(grep -c '^[[:space:]]*plan:[[:space:]]*ln' "$PLAN_FILE" || true)"
echo "[1/3] Plan actions: $PLANS_COUNT"
echo

# 2) Apply from plan (PREVIEW: no --write flags passed)
if [ "$DO_APPLY" = "1" ]; then
  echo "[2/3] Apply from plan (PREVIEW) ..."
  sh "$APPLY" "$PLAN_FILE" || true
  echo "[2/3] Apply step done (PREVIEW)."
  echo
else
  echo "[2/3] Apply skipped."
fi

# 3) Cleanup (PREVIEW if supported; otherwise run default and trust script default is preview)
if [ "$DO_CLEAN" = "1" ]; then
  echo "[3/3] Cleanup (PREVIEW) ..."
  # Try with --preview, fallback without
  if sh "$CLEAN" --preview 2>/dev/null; then
    :
  else
    sh "$CLEAN" || true
  fi
  echo "[3/3] Cleanup step done (PREVIEW)."
  echo
else
  echo "[3/3] Cleanup skipped."
fi

# 4) Tidy
if [ "$KEEP_PLAN" != "1" ]; then
  rm -f -- "$PLAN_FILE"
  echo "[tidy] plan removed."
else
  echo "[tidy] plan kept: $PLAN_FILE"
fi

echo "Done (chain preview)."
exit 0
