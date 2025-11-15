#!/bin/sh
# synomap_apply_from_plan_v1.6.9_sequential.sh
# Hotfix: remove accidental "end if" causing ";; unexpected (expecting fi)".
# Also minor robustness tweaks in bind section.
# Date: 2025-11-13
set -eu

ts() { date '+%Y-%m-%d %H:%M:%S'; }
die() { echo "[ERR] $*" >&2; exit 1; }

SCRIPT="$0"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SCRIPT")" && pwd)

WRITE=0
SLEEP_SECS=2
MOVE_TIMEOUT=900
RECHECK_TIMEOUT=900
SIDECARS_MODE="copy"   # copy|ignore|redownload
USE_BIND=1
DEBUG=0
PLAN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --write) WRITE=1; shift ;;
    --sleep-seconds) SLEEP_SECS="${2:?}"; shift 2 ;;
    --move-timeout-sec) MOVE_TIMEOUT="${2:?}"; shift 2 ;;
    --recheck-timeout-sec) RECHECK_TIMEOUT="${2:?}"; shift 2 ;;
    --sidecars) SIDECARS_MODE="${2:?}"; shift 2 ;;
    --no-bind) USE_BIND=0; shift ;;
    --debug) DEBUG=1; shift ;;
    --help|-h) echo "Usage: $0 [--write] [--sidecars copy|ignore|redownload] [--no-bind] PLANFILE"; exit 0 ;;
    *) PLAN="$1"; shift ;;
  esac
done

[ -n "${PLAN:-}" ] || die "plan file required"
[ -f "$PLAN" ] || die "plan not found: $PLAN"

# Charger env si dispo
if [ -z "${QB_URL:-}" ] && [ -f "$SCRIPT_DIR/synomap.env" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/synomap.env"
fi
: "${QB_URL:?env QB_URL missing}"
: "${QB_USER:?env QB_USER missing}"
: "${QB_PASS:?env QB_PASS missing}"

COOKIE="/tmp/qb_cookie_$$"
trap 'rm -f "$COOKIE"' EXIT INT TERM

need() { command -v "$1" >/dev/null 2>&1 || die "missing dep: $1"; }
need curl; need jq; need sed; need awk; need ln; need mount; need umount; need cp; need tr; need nl

qb_login() {
  curl -s -c "$COOKIE" --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS" \
    "$QB_URL/api/v2/auth/login" >/dev/null || die "qB login failed"
}

# Sanitize helper: strip control chars except TAB and NL (avoid jq parse errors)
sanitize() {
  tr -d '\000\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037'
}

qb_post_raw() { ep="$1"; shift; curl -s -b "$COOKIE" "$QB_URL/api/v2/$ep" "$@"; }

qb_info_json() { qb_post_raw "torrents/info" --data-urlencode "hashes=$1" | sanitize; }
qb_info_all()  { qb_post_raw "torrents/info" | sanitize; }
qb_info_cat()  { qb_post_raw "torrents/info" --data-urlencode "category=$1" | sanitize; }
qb_files_json(){ qb_post_raw "torrents/files" --data-urlencode "hash=$1" | sanitize; }

qb_pause() { qb_post_raw "torrents/pause" --data-urlencode "hashes=$1" >/dev/null; }
qb_resume() { qb_post_raw "torrents/resume" --data-urlencode "hashes=$1" >/dev/null; }
qb_auto_tmm_off() { qb_post_raw "torrents/setAutoTMM" --data-urlencode "hashes=$1" --data-urlencode "enable=false" >/dev/null || true; }
qb_set_location() { qb_post_raw "torrents/setLocation" --data-urlencode "hashes=$1" --data-urlencode "location=$2" >/dev/null; }
qb_recheck() { qb_post_raw "torrents/recheck" --data-urlencode "hashes=$1" >/dev/null; }
qb_add_tags() { qb_post_raw "torrents/addTags" --data-urlencode "hashes=$1" --data-urlencode "tags=$2" >/dev/null; }

get_field() { echo "$1" | jq -r "$2 // empty"; }
get_info_field() { echo "$1" | jq -r '.[0]'"$2 // empty"; }

enter_checking_or_timeout() {
  h="$1"; timeout="$2"; waited=0; entered=0
  while :; do
    info="$(qb_info_json "$h")"
    state="$(get_info_field "$info" '.state')"
    prog="$(get_info_field "$info" '.progress')"
    printf "[%s] ck: state=%s progress=%s\n" "$(ts)" "$state" "$prog"
    echo "$state" | grep -qi '^checking' && { entered=1; break; }
    echo "$state" | grep -qi 'queuedForChecking' && { entered=1; break; }
    [ "$prog" = "1" ] && break
    sleep 2; waited=$((waited+2))
    [ $waited -ge "$timeout" ] && break
  done
  [ $entered -eq 1 ]
}

wait_check_done() {
  h="$1"; timeout="$2"; waited=0
  while :; do
    info="$(qb_info_json "$h")"
    state="$(get_info_field "$info" '.state')"
    prog="$(get_info_field "$info" '.progress')"
    printf "[%s] recheck: state=%s progress=%s\n" "$(ts)" "$state" "$prog"
    [ "$prog" = "1" ] && break
    echo "$state" | grep -qi '^checking' || echo "$state" | grep -qi 'queuedForChecking' || break
    sleep 2; waited=$((waited+2))
    [ $waited -ge "$timeout" ] && { echo "[WARN] recheck timeout"; return 1; }
  done
  return 0
}

list_sidecars_indexes_and_names() {
  qb_files_json "$1" | jq -r '
    to_entries[]
    | select(.value.name | test("\\.(nfo|jpg|jpeg|png|sfv|txt|srt|ass|ssa)$"; "i"))
    | "\(.key)|\(.value.name)"
  '
}

copy_sidecars_simple() {
  h="$1"; src_dir="$2"; dst_dir="$3"
  list="$(list_sidecars_indexes_and_names "$h" | cut -d'|' -f2-)"
  [ -n "$list" ] || { echo "[sidecars] none to copy"; return 0; }
  echo "$list" | while IFS= read -r rel; do
    base=$(basename -- "$rel")
    s="$src_dir/$base"
    d="$dst_dir/$base"
    if [ -f "$s" ]; then
      cp -a "$s" "$d" && echo "[sidecars] copied: $base"
    else
      echo "[sidecars] missing local: $s"
    fi
  done
}

set_sidecars_prio() {
  h="$1"; prio="$2"
  idxs="$(list_sidecars_indexes_and_names "$h" | cut -d'|' -f1 | paste -sd '|' -)"
  [ -n "$idxs" ] || { echo "[sidecars] no indexes"; return 0; }
  qb_post_raw "torrents/filePrio" \
    --data-urlencode "hashes=$h" \
    --data-urlencode "id=$idxs" \
    --data-urlencode "priority=$prio" >/dev/null || true
  echo "[sidecars] priority=$prio on [$idxs]"
}

infer_hash() {
  dst="$1"
  dir=$(dirname -- "$dst")
  base=$(basename -- "$dst")
  base_noext=$(echo "$base" | sed 's/\.[^.]*$//')
  folder=$(basename -- "$dir")

  all="$(qb_info_all || true)"
  H2=$(echo "$all" | jq -r --arg d "$dir" '
    .[] | select((.content_path != null and (.content_path|startswith($d+"/") or .content_path==$d))
                 or (.save_path|startswith($d+"/") or .save_path==$d))
        | .hash
  ' 2>/dev/null | head -n 1)
  if [ -n "$H2" ] && [ "$H2" != "null" ]; then echo "$H2|by_path"; return 0; fi

  H2=$(echo "$all" | jq -r --arg b "$base_noext" --arg f "$folder" '
    .[] | select(.name != null) | select((.name|test($b;"i")) or (.name|test($f;"i"))) | .hash
  ' 2>/dev/null | head -n 1)
  if [ -n "$H2" ] && [ "$H2" != "null" ]; then echo "$H2|by_name"; return 0; fi

  cat=""; echo "$dst" | grep -qi "/radarr/" && cat="radarr"; echo "$dst" | grep -qi "/sonarr/" && cat="sonarr"
  if [ -n "$cat" ]; then
    ac="$(qb_info_cat "$cat" || true)"
    H2=$(echo "$ac" | jq -r --arg b "$base_noext" --arg f "$folder" '
      .[] | select(.name != null) | select((.name|test($b;"i")) or (.name|test($f;"i"))) | .hash
    ' 2>/dev/null | head -n 1)
    if [ -n "$H2" ] && [ "$H2" != "null" ]; then echo "$H2|by_category"; return 0; fi
  fi

  echo "|"; return 1
}

# --------- PARSING ---------
RAW="/tmp/plan_raw_$$"
HASHES="/tmp/plan_hashes_$$"
PAIRS="/tmp/plan_pairs_$$"
ITEMS="/tmp/plan_items_$$"
trap 'rm -f "$RAW" "$HASHES" "$PAIRS" "$ITEMS" "$COOKIE"' EXIT INT TERM

tr -d '\r' < "$PLAN" > "$RAW"

grep -nE '^[0-9a-f]{40}\b' "$RAW" | sed 's/:/|/' | awk -F'|' '{print $1 "|" $2}' > "$HASHES" || true
nl -ba "$RAW" | sed -n "s/^[[:space:]]*\\([0-9]\\+\\)[[:space:]]\\+.*plan: ln '\\([^']*\\)' -> '\\([^']*\\)'.*/\\1|\\2|\\3/p" > "$PAIRS" || true

if [ "${DEBUG:-0}" -eq 1 ]; then
  echo "[debug] plan-lines=$(wc -l < "$PAIRS" | awk '{print $1}')"
  head -n 3 "$PAIRS" || true
fi

if [ -s "$HASHES" ]; then
  awk -F'|' '
    FNR==NR { HN[NR]=$1; HH[$1]=$2; HMAX=NR; next }
    { nr=$1; src=$2; dst=$3; hash="";
      for (i=1; i<=HMAX; i++) { if (HN[i] <= nr) hash=HH[HN[i]]; else break }
      print hash "|" src "|" dst;
    }
  ' "$HASHES" "$PAIRS" > "$ITEMS" || true
else
  awk -F'|' '{print "" "|" $2 "|" $3}' "$PAIRS" > "$ITEMS" || true
fi

if [ "${DEBUG:-0}" -eq 1 ]; then
  echo "[debug] items=$(wc -l < "$ITEMS" | awk '{print $1}')"
  head -n 5 "$ITEMS" || true
fi

qb_login

# --------- LOOP ---------
while IFS='|' read -r HASH SRC DST; do
  [ -n "${SRC:-}" ] && [ -n "${DST:-}" ] || { echo "[WARN] ligne invalide -> skip"; continue; }

  if [ -z "${HASH:-}" ]; then
    ih="$(infer_hash "$DST" || true)"
    HASH=$(echo "$ih" | cut -d'|' -f1)
    HOW=$(echo "$ih" | cut -d'|' -f2-)
    if [ -n "${HASH:-}" ]; then
      [ "${DEBUG:-0}" -eq 1 ] && echo "[debug] hash inferred ($HOW): $HASH"
    else
      echo "[WARN] no hash found for DST=$DST (skip)"
      continue
    fi
  fi

  DEST_DIR=$(dirname -- "$DST")
  echo "--- [$HASH] ---"
  echo "SRC=$SRC"; echo "DST=$DST"; echo "DEST_DIR=$DEST_DIR"

  qb_pause "$HASH"
  qb_auto_tmm_off "$HASH"

  if [ -f "$DST" ]; then
    echo "link: exists"
  else
    ln "$SRC" "$DST" 2>/dev/null && echo "link: created" || echo "link: create failed (continue)"
  fi

  # Déterminer ROOT (torrent root path) pour bind correct
  info="$(qb_info_json "$HASH")"
  savep="$(get_info_field "$info" '.save_path')"
  first_file="$(qb_files_json "$HASH" | jq -r '.[0].name // empty')"
  root=""
  if [ -n "$first_file" ]; then
    case "$first_file" in
      */*) root="$savep/$(echo "$first_file" | cut -d/ -f1)";;
       *)  root="$savep";;
    esac
  else
    root="$savep"
  fi
  SRC_ROOT="$root"

  # Sidecars
  case "$SIDECARS_MODE" in
    copy)      copy_sidecars_simple "$HASH" "$SRC_ROOT" "$DEST_DIR"; set_sidecars_prio "$HASH" 1 ;;
    ignore)    set_sidecars_prio "$HASH" 0 ;;
    redownload)set_sidecars_prio "$HASH" 1 ;;
    *)         set_sidecars_prio "$HASH" 1 ;;
  esac

  # Bind (si /data/* et si ROOT est un dossier)
  USED_BIND=0
  if [ "$WRITE" -eq 1 ]; then
    case "$savep" in
      /data/*)
        if [ $USE_BIND -eq 1 ] && [ -d "$SRC_ROOT" ]; then
          if mountpoint -q "$SRC_ROOT"; then
            echo "bind: already $SRC_ROOT"
          else
            if mount --bind "$DEST_DIR" "$SRC_ROOT"; then
              echo "bind: $SRC_ROOT -> $DEST_DIR"
              USED_BIND=1
            else
              echo "[WARN] bind failed (continue without)"
            fi
          fi
        fi
        ;;
    esac

    qb_set_location "$HASH" "$DEST_DIR"

    # Pause stricte avant recheck
    qb_pause "$HASH"

    # Tenter d'entrer en checking (relance recheck si besoin)
    if ! enter_checking_or_timeout "$HASH" 10; then
      qb_recheck "$HASH"
      enter_checking_or_timeout "$HASH" 20 >/dev/null || echo "[WARN] never entered checking"
    fi

    wait_check_done "$HASH" "$RECHECK_TIMEOUT" || echo "[WARN] recheck not confirmed"
    qb_resume "$HASH"
    qb_add_tags "$HASH" "SYNO"
    echo "done: $HASH"

    if [ $USED_BIND -eq 1 ]; then
      umount "$SRC_ROOT" || true
      echo "bind: umount $SRC_ROOT"
    fi
  else
    echo "[PREVIEW] would setLocation -> $DEST_DIR ; pause→recheck→resume/tag"
  fi

  sleep "$SLEEP_SECS"
done < "$ITEMS"

echo "Done (apply sequential strict v1.6.9)."
