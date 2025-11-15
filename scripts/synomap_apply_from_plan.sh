#!/bin/sh
# synomap_apply_from_plan.sh
# Unifie la logique apply_from_plan "classique" et "sequential".
# - Lecture du plan généré par daily_qbittorrent_update.
# - Traitement strict par torrent (pause -> setLocation/bind -> sidecars -> recheck -> resume/tag).
# - Mode PREVIEW par défaut (aucune écriture) et mode WRITE activé via --write.
# Dépendances: /bin/sh, curl, jq, sed, awk, ln, mkdir, stat, tr, nl, cp, mount, umount, mountpoint.

set -eu

TS() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(TS)" "$*"; }
die() { log "ERR: $*" >&2; exit 1; }

to_int() { printf '%s' "$1" | sed 's/[^0-9]//g'; }

SCRIPT="$0"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SCRIPT")" && pwd)

WRITE=0
SLEEP_SECS=2
MOVE_TIMEOUT=900
RECHECK_TIMEOUT=900
SIDECARS_MODE="copy"
USE_BIND=1
DEBUG=0
PLAN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --write) WRITE=1; shift ;;
    --sleep-seconds) SLEEP_SECS="${2:?}"; shift 2 ;;
    --move-timeout-sec) MOVE_TIMEOUT="$(to_int "${2:?}")"; shift 2 ;;
    --recheck-timeout-sec) RECHECK_TIMEOUT="$(to_int "${2:?}")"; shift 2 ;;
    --sidecars) SIDECARS_MODE="${2:?}"; shift 2 ;;
    --no-bind) USE_BIND=0; shift ;;
    --debug) DEBUG=1; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: synomap_apply_from_plan.sh [options] PLANFILE
  --write                   Applique réellement les modifications.
  --sleep-seconds N         Pause entre torrents (défaut 2).
  --move-timeout-sec N      Timeout pour entrée en checking après setLocation (défaut 900).
  --recheck-timeout-sec N   Timeout pour terminer le recheck (défaut 900).
  --sidecars MODE           copy|ignore|redownload (défaut copy).
  --no-bind                 Désactive mount --bind temporaires.
  --debug                   Trace détaillée (dump des réponses qB non JSON).
USAGE
      exit 0
      ;;
    *) PLAN="$1"; shift ;;
  esac
done

[ -n "$PLAN" ] || die "plan file required"
[ -f "$PLAN" ] || die "plan not found: $PLAN"

# Chargement env (SYNO_ENV prioritaire, sinon synomap.env à côté du script)
if [ -n "${SYNO_ENV:-}" ] && [ -f "$SYNO_ENV" ]; then
  # shellcheck disable=SC1090
  . "$SYNO_ENV"
elif [ -f "$SCRIPT_DIR/synomap.env" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/synomap.env"
fi

: "${QB_URL:?env QB_URL missing}"
: "${QB_USER:?env QB_USER missing}"
: "${QB_PASS:?env QB_PASS missing}"
MAP_FILE="${MAP_FILE:-/data/scripts/mapping_entries.txt}"
[ -f "$MAP_FILE" ] || die "mapping file not found: $MAP_FILE"

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need curl; need jq; need sed; need awk; need ln; need mkdir; need stat; need tr; need nl; need cp; need mount; need umount; need mountpoint

TMPDIR_ROOT=${TMPDIR:-/tmp}
RAW=$(mktemp "$TMPDIR_ROOT/synomap_raw.XXXXXX")
HASHES=$(mktemp "$TMPDIR_ROOT/synomap_hashes.XXXXXX")
PAIRS=$(mktemp "$TMPDIR_ROOT/synomap_pairs.XXXXXX")
ITEMS=$(mktemp "$TMPDIR_ROOT/synomap_items.XXXXXX")
COOKIE=$(mktemp "$TMPDIR_ROOT/synomap_cookie.XXXXXX")
CAT_CACHE_DIR=$(mktemp -d "$TMPDIR_ROOT/synomap_cat_cache.XXXXXX") || die "unable to create category cache"
ACTIVE_BIND=""

cleanup() {
  if [ -n "$ACTIVE_BIND" ] && mountpoint -q "$ACTIVE_BIND" 2>/dev/null; then
    umount "$ACTIVE_BIND" 2>/dev/null || true
  fi
  rm -f "$RAW" "$HASHES" "$PAIRS" "$ITEMS" "$COOKIE"
  [ -d "$CAT_CACHE_DIR" ] && rm -rf "$CAT_CACHE_DIR"
}
trap cleanup EXIT INT TERM

sanitize_json_file() {
  tr -d '\000\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037' < "$1"
}

looks_like_json() {
  grep -q '^[[:space:]]*[\[{]' "$1"
}

qb_login() {
  http=$(curl -sS -w '%{http_code}' -o /dev/null -c "$COOKIE" --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS" \
    "$QB_URL/api/v2/auth/login" || true)
  [ "$http" = "200" ] || die "qB login failed (http $http)"
}

qb_call_form() {
  ep="$1"; shift
  http=$(curl -sS -w '%{http_code}' -o /dev/null -b "$COOKIE" "$QB_URL/api/v2/$ep" "$@" || true)
  if [ "$http" != "200" ]; then
    log "WARN: qB API $ep returned HTTP $http"
    return 1
  fi
  return 0
}

qb_call_json() {
  ep="$1"; shift
  tmp=$(mktemp "$TMPDIR_ROOT/synomap_qbjson.XXXXXX")
  http=$(curl -sS -w '%{http_code}' -o "$tmp" -b "$COOKIE" "$QB_URL/api/v2/$ep" "$@" || true)
  if [ "$http" != "200" ]; then
    log "WARN: qB API $ep returned HTTP $http"
    [ "$DEBUG" -eq 1 ] && { log "DEBUG: body follows"; sed -n '1,40p' "$tmp"; }
    rm -f "$tmp"
    return 1
  fi
  if ! looks_like_json "$tmp"; then
    log "WARN: qB API $ep returned non-JSON (size $(wc -c < "$tmp"))"
    [ "$DEBUG" -eq 1 ] && { log "DEBUG: body follows"; sed -n '1,40p' "$tmp"; }
    rm -f "$tmp"
    return 1
  fi
  sanitize_json_file "$tmp"
  rm -f "$tmp"
}

qb_info_json() { qb_call_json "torrents/info" --data-urlencode "hashes=$1"; }
qb_info_all()  { qb_call_json "torrents/info"; }
qb_info_cat()  { qb_call_json "torrents/info" --data-urlencode "category=$1"; }
qb_files_json(){ qb_call_json "torrents/files" --data-urlencode "hash=$1"; }

qb_pause() { qb_call_form "torrents/pause" --data-urlencode "hashes=$1" >/dev/null || true; }
qb_resume() { qb_call_form "torrents/resume" --data-urlencode "hashes=$1" >/dev/null || true; }
qb_auto_tmm_off() { qb_call_form "torrents/setAutoTMM" --data-urlencode "hashes=$1" --data-urlencode "enable=false" >/dev/null || true; }
qb_set_location() { qb_call_form "torrents/setLocation" --data-urlencode "hashes=$1" --data-urlencode "location=$2"; }
qb_recheck() { qb_call_form "torrents/recheck" --data-urlencode "hashes=$1" >/dev/null || true; }
qb_add_tags() { qb_call_form "torrents/addTags" --data-urlencode "hashes=$1" --data-urlencode "tags=$2" >/dev/null || true; }

get_info_field() {
  data="$1"; filter="$2"
  [ -n "$data" ] || { echo ""; return 1; }
  printf '%s' "$data" | jq -r "$filter // empty" 2>/dev/null || true
}

enter_checking_or_timeout() {
  h="$1"; timeout="$2"; waited=0; entered=0
  while [ "$waited" -le "$timeout" ]; do
    if info=$(qb_info_json "$h"); then
      state=$(get_info_field "$info" '.[0].state')
      prog=$(get_info_field "$info" '.[0].progress')
      log "ck: state=$state progress=$prog"
      case "$state" in
        checking*|QueuedForChecking|queuedForChecking) entered=1; break ;;
      esac
      [ "$prog" = "1" ] && break
    else
      log "WARN: unable to fetch state for $h"
    fi
    sleep 2
    waited=$((waited+2))
  done
  [ $entered -eq 1 ]
}

wait_check_done() {
  h="$1"; timeout="$2"; waited=0
  while [ "$waited" -le "$timeout" ]; do
    if info=$(qb_info_json "$h"); then
      state=$(get_info_field "$info" '.[0].state')
      prog=$(get_info_field "$info" '.[0].progress')
      log "recheck: state=$state progress=$prog"
      [ "$prog" = "1" ] && return 0
      case "$state" in
        checking*|QueuedForChecking|queuedForChecking) : ;; # stay
        *) break ;;
      esac
    else
      log "WARN: unable to fetch recheck status for $h"
      break
    fi
    sleep 2
    waited=$((waited+2))
  done
  log "WARN: recheck timeout reached for $h"
  return 1
}

list_sidecars_indexes_and_names() {
  data=$(qb_files_json "$1" || true)
  [ -n "$data" ] || return 1
  printf '%s' "$data" | jq -r '
    to_entries[]
    | select(.value.name | test("\\.(nfo|jpg|jpeg|png|sfv|txt|srt|ass|ssa)$"; "i"))
    | "\(.key)|\(.value.name)"
  ' 2>/dev/null || true
}

copy_sidecars_simple() {
  h="$1"; src_dir="$2"; dst_dir="$3"
  list=$(list_sidecars_indexes_and_names "$h") || true
  [ -n "$list" ] || { log "sidecars: none"; return 0; }
  printf '%s\n' "$list" | cut -d'|' -f2- | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    base=$(basename -- "$rel")
    s="$src_dir/$base"
    d="$dst_dir/$base"
    if [ -f "$s" ]; then
      cp -a "$s" "$d" && log "sidecars: copied $base" || log "WARN: sidecar copy failed $base"
    else
      log "sidecars: missing source $s"
    fi
  done
}

set_sidecars_prio() {
  h="$1"; prio="$2"
  idxs=$(list_sidecars_indexes_and_names "$h" | cut -d'|' -f1 | paste -sd '|' - 2>/dev/null || true)
  [ -n "$idxs" ] || { log "sidecars: no indexes"; return 0; }
  qb_call_form "torrents/filePrio" \
    --data-urlencode "hashes=$h" \
    --data-urlencode "id=$idxs" \
    --data-urlencode "priority=$prio" >/dev/null || true
  log "sidecars: priority=$prio on $idxs"
}

normalize_dir_path() {
  p="$1"
  [ -n "$p" ] || { echo ""; return 1; }
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do
    p=${p%/}
  done
  [ -n "$p" ] || p="/"
  printf '%s\n' "$p"
}

lower_ascii() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

strip_extension() {
  n="$1"
  case "$n" in
    *.*) printf '%s\n' "${n%.*}" ;;
    *) printf '%s\n' "$n" ;;
  esac
}

detect_category_from_dst() {
  d="$1"
  dir=$(dirname -- "$d")
  parent=$(dirname -- "$dir")
  base=$(basename -- "$dir")
  case "$parent" in
    */torrents/completed|*/torrents/completed) printf '%s\n' "$base" ;;
    *) echo "" ;;
  esac
}

get_cat_json() {
  cname="$1"
  [ -n "$cname" ] || return 1
  safe=$(printf '%s' "$cname" | tr -c 'A-Za-z0-9._-' '_')
  cache_file="$CAT_CACHE_DIR/$safe.json"
  if [ -f "$cache_file" ]; then
    cat "$cache_file"
    return 0
  fi
  data=$(qb_info_cat "$cname" || true)
  [ -n "$data" ] || return 1
  printf '%s' "$data" > "$cache_file"
  printf '%s' "$data"
  return 0
}

resolve_hash_for_plan_entry() {
  hint_hash="$1"
  src="$2"
  dst="$3"

  [ -n "$src" ] || { log "WARN no_hash_for DST=$dst reason=missing_src"; return 1; }

  lookup=$(awk -F'|' -v target="$src" '
    $3==target { c++; if (c==1) line=$0 }
    END {
      if (c==0) { printf "0|" }
      else { printf "%d|%s\n", c, line }
    }
  ' "$MAP_FILE" || true)
  count=$(printf '%s\n' "$lookup" | cut -d'|' -f1 | tr -d '[:space:]')
  line=$(printf '%s\n' "$lookup" | cut -d'|' -f2-)

  case "$count" in
    1) : ;;
    0|"") log "WARN no_hash_for DST=$dst reason=mapping_not_found"; return 1 ;;
    *) log "WARN no_hash_for DST=$dst reason=mapping_ambiguous count=$count"; return 1 ;;
  esac

  data_path=$(printf '%s\n' "$line" | awk -F'|' '{print $2}')
  [ -n "$data_path" ] || { log "WARN no_hash_for DST=$dst reason=mapping_missing_data_path"; return 1; }

  data_dir=$(dirname -- "$data_path")
  data_name=$(basename -- "$data_path")
  data_dir_norm=$(normalize_dir_path "$data_dir")
  data_name_lower=$(lower_ascii "$data_name")
  data_name_noext_lower=$(lower_ascii "$(strip_extension "$data_name")")

  cat=$(detect_category_from_dst "$dst")
  [ -n "$cat" ] || { log "WARN no_hash_for DST=$dst reason=unknown_category"; return 1; }

  if [ -n "$hint_hash" ]; then
    info=$(qb_info_json "$hint_hash" || true)
    if [ -n "$info" ]; then
      hint_name=$(get_info_field "$info" '.[0].name')
      hint_save=$(get_info_field "$info" '.[0].save_path')
      hint_hash_live=$(get_info_field "$info" '.[0].hash')
      if [ -n "$hint_name" ] && [ -n "$hint_save" ] && [ -n "$hint_hash_live" ]; then
        hint_save_norm=$(normalize_dir_path "$hint_save" 2>/dev/null || echo "")
        hint_name_lower=$(lower_ascii "$hint_name")
        if [ "$hint_save_norm" = "$data_dir_norm" ] && [ "$hint_name_lower" = "$data_name_lower" ]; then
          log "hash_resolved hash=$hint_hash via=plan_hint cat=$cat data_path=$data_path save_path=$hint_save name=$hint_name"
          printf '%s\n' "$hint_hash"
          return 0
        else
          log "hash_hint_rejected hash=$hint_hash reason=hint_mismatch expected_dir=$data_dir_norm got_dir=$hint_save_norm expected_name=$data_name got_name=$hint_name"
        fi
      else
        log "hash_hint_rejected hash=$hint_hash reason=hint_info_incomplete"
      fi
    else
      log "hash_hint_rejected hash=$hint_hash reason=hint_not_found"
    fi
  fi

  cat_json=$(get_cat_json "$cat" || true)
  [ -n "$cat_json" ] || { log "WARN no_hash_for DST=$dst reason=category_fetch_failed"; return 1; }

  matches=$(printf '%s' "$cat_json" | jq -r --arg save "$data_dir_norm" --arg name_l "$data_name_lower" --arg name_noext "$data_name_noext_lower" '
    .[]
    | select(.save_path != null and .name != null and .hash != null)
    | (.save_path | gsub("/+$$";"")) as $sp
    | select($sp == $save)
    | (.name | ascii_downcase) as $n
    | (.name | sub("\\.[^.]*$";"") | ascii_downcase) as $n_noext
    | select($n == $name_l or $n_noext == $name_noext)
    | [ .hash, .name, .save_path ]
    | @tsv
  ' 2>/dev/null || true)

  matches_clean=$(printf '%s\n' "$matches" | sed '/^[[:space:]]*$/d')
  if [ -z "$matches_clean" ]; then
    log "WARN no_hash_for DST=$dst reason=no_match_in_category"
    return 1
  fi

  match_count=$(printf '%s\n' "$matches_clean" | wc -l | awk '{print $1}')
  if [ "$match_count" -ne 1 ]; then
    log "WARN hash_ambiguous_for DST=$dst candidates=$match_count"
    return 1
  fi

  first_match=$(printf '%s\n' "$matches_clean" | head -n 1)
  match_hash=$(printf '%s' "$first_match" | cut -f1)
  match_name=$(printf '%s' "$first_match" | cut -f2)
  match_save=$(printf '%s' "$first_match" | cut -f3)
  log "hash_resolved hash=$match_hash via=category_lookup cat=$cat data_path=$data_path save_path=$match_save name=$match_name"
  printf '%s\n' "$match_hash"
  return 0
}

qb_login

tr -d '\r' < "$PLAN" > "$RAW"
grep -nE '^[0-9a-f]{40}\b' "$RAW" | sed 's/:/|/' | awk -F'|' '{print $1 "|" $2}' > "$HASHES" || true
nl -ba "$RAW" | sed -n "s/^[[:space:]]*\([0-9]\+\)[[:space:]]\+.*plan: ln '\([^']*\)' -> '\([^']*\)'.*/\1|\2|\3/p" > "$PAIRS" || true

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

[ "$DEBUG" -eq 1 ] && { log "debug: plan items=$(wc -l < "$ITEMS" | awk '{print $1}')"; head -n 5 "$ITEMS" || true; }

ITEM_COUNT=0

while IFS='|' read -r HASH SRC DST; do
  [ -n "${SRC:-}" ] && [ -n "${DST:-}" ] || continue
  ITEM_COUNT=$((ITEM_COUNT+1))

  resolved=$(resolve_hash_for_plan_entry "${HASH:-}" "$SRC" "$DST" || true)
  if [ -z "$resolved" ]; then
    log "skip: unresolved hash for DST=$DST"
    continue
  fi
  HASH="$resolved"

  DEST_DIR=$(dirname -- "$DST")
  log "=== $HASH ==="
  log "SRC=$SRC"
  log "DST=$DST"
  log "DEST_DIR=$DEST_DIR"

  info=$(qb_info_json "$HASH" || true)
  savep=$(get_info_field "$info" '.[0].save_path')
  files_json=$(qb_files_json "$HASH" || true)
  first_file=$(printf '%s' "$files_json" | jq -r '.[0].name // empty' 2>/dev/null || true)
  SRC_ROOT="$savep"
  if [ -n "$first_file" ]; then
    case "$first_file" in
      */*) SRC_ROOT="$savep/$(printf '%s' "$first_file" | cut -d/ -f1)" ;;
      *) SRC_ROOT="$savep" ;;
    esac
  fi

  if [ "$WRITE" -eq 1 ]; then
    qb_pause "$HASH"
    qb_auto_tmm_off "$HASH"
    umask "${UMASK:-002}"
    mkdir -p "$DEST_DIR" 2>/dev/null || true
    if [ -e "$DST" ]; then
      if [ "$(stat -c '%d:%i' "$SRC" 2>/dev/null || echo x)" = "$(stat -c '%d:%i' "$DST" 2>/dev/null || echo y)" ]; then
        log "link: already exists"
      else
        log "link: dst exists but different inode"
      fi
    else
      if ln "$SRC" "$DST" 2>/dev/null; then
        log "link: created"
      else
        log "WARN: link creation failed"
      fi
    fi

    case "$SIDECARS_MODE" in
      copy)       copy_sidecars_simple "$HASH" "$SRC_ROOT" "$DEST_DIR"; set_sidecars_prio "$HASH" 1 ;;
      ignore)     set_sidecars_prio "$HASH" 0 ;;
      redownload) set_sidecars_prio "$HASH" 1 ;;
      *)          set_sidecars_prio "$HASH" 1 ;;
    esac

    USED_BIND=0
    if [ $USE_BIND -eq 1 ] && [ -n "$savep" ] && printf '%s' "$savep" | grep -q '^/data/'; then
      if [ -d "$SRC_ROOT" ]; then
        if mountpoint -q "$SRC_ROOT" 2>/dev/null; then
          log "bind: already mounted $SRC_ROOT"
        else
          if mount --bind "$DEST_DIR" "$SRC_ROOT" 2>/dev/null; then
            log "bind: $SRC_ROOT -> $DEST_DIR"
            USED_BIND=1
            ACTIVE_BIND="$SRC_ROOT"
          else
            log "WARN: bind failed"
          fi
        fi
      fi
    fi

    qb_set_location "$HASH" "$DEST_DIR" || log "WARN: setLocation failed"
    qb_pause "$HASH"

    if ! enter_checking_or_timeout "$HASH" "$MOVE_TIMEOUT"; then
      log "info: forcing recheck"
      qb_recheck "$HASH"
      enter_checking_or_timeout "$HASH" 20 >/dev/null || log "WARN: never entered checking"
    fi

    wait_check_done "$HASH" "$RECHECK_TIMEOUT" || true
    qb_resume "$HASH"
    qb_add_tags "$HASH" "SYNO"

    if [ $USED_BIND -eq 1 ]; then
      umount "$SRC_ROOT" 2>/dev/null || log "WARN: umount failed $SRC_ROOT"
      ACTIVE_BIND=""
    fi
  else
    log "[PREVIEW] would pause + disable AutoTMM"
    if [ -e "$DST" ]; then
      log "[PREVIEW] dst exists -> recheck would be skipped"
    else
      log "[PREVIEW] would ln '$SRC' '$DST'"
    fi
    log "[PREVIEW] sidecars mode=$SIDECARS_MODE"
    if [ $USE_BIND -eq 1 ] && [ -n "$savep" ] && printf '%s' "$savep" | grep -q '^/data/'; then
      log "[PREVIEW] would bind $SRC_ROOT -> $DEST_DIR"
    fi
    log "[PREVIEW] would setLocation -> $DEST_DIR"
    log "[PREVIEW] would recheck + resume + tag"
  fi

  sleep "$SLEEP_SECS"
done < "$ITEMS"

if [ "$WRITE" -eq 1 ]; then
  log "Done (WRITE mode, items=$ITEM_COUNT)"
else
  log "Done (PREVIEW mode, items=$ITEM_COUNT)"
fi
