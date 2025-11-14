#!/bin/sh
# REGLAGES_CHATGPT - header env (local)
SYNO_ENV="${SYNO_ENV:-/srv/dev-disk-by-uuid-167c3d64-0b12-412d-9453-f941e78f8f6e/data/scripts/synomap/synomap.env}"
[ -f "$SYNO_ENV" ] && . "$SYNO_ENV" || true
# FIN_REGLAGES
# synomap_cleanup_omv_only_v1.0.sh
# Usage: sh synomap_cleanup_omv_only_v1.0.sh [--write] <plan>
set -eu
WRITE=0
case "${1:-}" in --write) WRITE=1; shift;; esac
PLAN="${1:-}"; [ -n "$PLAN" ] || { echo "Usage: $0 [--write] <plan>" >&2; exit 2; }
OMV_DATA="${OMV_DATA:-/srv/dev-disk-by-uuid-}"
QB_URL=""; QB_USER=""; QB_PASS=""
# REGLAGES_CHATGPT - header env (local)
SYNO_ENV="${SYNO_ENV:-/srv/dev-disk-by-uuid-167c3d64-0b12-412d-9453-f941e78f8f6e/data/scripts/synomap/synomap.env}"
[ -f "$SYNO_ENV" ] && . "$SYNO_ENV" || true
# FIN_REGLAGES
login_cookie() {
  C="/tmp/synomap.cookie.$$"; trap 'rm -f "$C"' EXIT INT TERM
  [ -n "$QB_URL" ] && [ -n "$QB_USER" ] && [ -n "$QB_PASS" ] || return 1
  curl -sS -c "$C" --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS"     "$QB_URL/api/v2/auth/login" >/dev/null || return 1
  echo "$C"
}
C=""; C=$(login_cookie) || C=""
pairs() {
  hdr=""; bad=0; h=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
        hdr="$line"; h=$(printf "%s" "$hdr" | cut -c1-40)
        case "$line" in *SKIP:*|*\[NOSTAT\]*) bad=1;; * ) bad=0;; esac ;;
      *plan:\ ln\ *)
        if [ -n "$hdr" ] && [ $bad -eq 0 ]; then
          src=$(printf "%s
" "$line" | sed -n "s/^ *plan: ln '\(.*\)' -> '.*'/\1/p")
          dst=$(printf "%s
" "$line" | sed -n "s/^ *plan: ln '.*' -> '\(.*\)'/\1/p")
          printf "%s	%s	%s
" "$h" "$src" "$dst"
          hdr=""
        fi ;;
    esac
  done < "$PLAN"
}
is_syno_path() { case "$1" in /syno/*) return 0;; *) return 1;; esac; }
is_omv_local() {
  case "$1" in
    "$OMV_DATA"*) return 0;;
    /srv/dev-disk-by-uuid-*/data/*) return 0;;
    *) return 1;;
  esac
}
ok_hardlink() {
  SRC="$1"; DST="$2"
  [ -f "$SRC" ] && [ -f "$DST" ] || return 1
  set -- $(stat -c "%d %i %h" "$SRC") || return 1
  DEV1="$1"; INO1="$2"; NL1="$3"
  set -- $(stat -c "%d %i %h" "$DST") || return 1
  DEV2="$1"; INO2="$2"; NL2="$3"
  [ "$DEV1" = "$DEV2" ] && [ "$INO1" = "$INO2" ] && [ "$NL1" -ge 2 ] && [ "$NL2" -ge 2 ]
}
ok_qb_100_syno() {
  H="$1"; [ -n "$C" ] || return 1
  info=$(curl -sS -b "$C" "$QB_URL/api/v2/torrents/info?hashes=$H" 2>/dev/null || true)
  if command -v jq >/dev/null 2>&1; then
    save=$(printf "%s" "$info" | jq -r '.[0].save_path' 2>/dev/null || echo "")
    prog=$(printf "%s" "$info" | jq -r '.[0].progress' 2>/dev/null || echo "")
  else
    save=""; prog=""
  fi
  [ -n "$save" ] && is_syno_path "$save" || return 1
  case "$prog" in 1|1.0|1.00|1.000*) return 0;; *) return 1;; esac
}
pairs | while IFS="$(printf '	')" read -r H SRC DST; do
  if ok_hardlink "$SRC" "$DST" && ok_qb_100_syno "$H" && is_omv_local "$SRC"; then
    if [ "$WRITE" -eq 1 ]; then
      printf "RM -- %s
" "$SRC"; rm -f -- "$SRC" || echo "[WARN] rm failed: $SRC"
    else
      printf "rm -- '%s'
" "$SRC"
    fi
  else
    echo "[SKIP] $H"
  fi
done
