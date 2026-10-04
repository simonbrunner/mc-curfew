#!/usr/bin/env bash
# mc-curfew – bedtime for selected Minecraft players via RCON.
#
# Run "tick" once a minute from cron. For every configured player it decides,
# based on that player's own curfew window, whether to warn, lock or unlock:
#
#   * * * * *  /usr/local/bin/mc-curfew.sh tick
#
# Locking = remove from the whitelist and kick, so the player cannot reconnect.
# Unlocking = add back to the whitelist. A missed unlock (server down) is
# retried on the next run.
#
# Manual commands:
#   mc-curfew.sh status                  windows, current state, online list, whitelist
#   mc-curfew.sh skip    player ...      no curfew for the current/next night (exception)
#   mc-curfew.sh warn    [player ...]    send the warning now
#   mc-curfew.sh enforce [player ...]    lock now (stays locked until "unlock")
#   mc-curfew.sh unlock  [player ...]    unlock now (re-locked by the next tick if inside the window)
#
# Config file: $MC_CURFEW_CONF, /etc/mc-curfew.conf or mc-curfew.conf next to this script.
# For testing, MC_CURFEW_NOW="2026-10-02 21:45" overrides the current time.

set -u

# ------------------------------------------------------------------ defaults
SERVICE="minecraft"          # docker compose service name of the server
CONTAINER=""                 # set to skip the lookup by service name
RCON_CMD=""                  # custom RCON command, e.g. "mcrcon -H 127.0.0.1 -p secret"
DEFAULT_WINDOW="21:30-06:30" # used when a player has no window of their own
WARN_MINUTES=10              # warning this many minutes before the curfew starts
DEFAULT_LANG="en"            # en | de | fr | it | es
STATE_DIR="/var/lib/mc-curfew"
declare -A PLAYERS=()        # [name]="<lang> [window] [days:window ...]"

# ------------------------------------------------------------------ config
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in "${MC_CURFEW_CONF:-}" /etc/mc-curfew.conf "$script_dir/mc-curfew.conf"; do
  if [ -n "$f" ] && [ -f "$f" ]; then
    # shellcheck source=/dev/null
    source "$f"
    break
  fi
done
mkdir -p "$STATE_DIR"

# ------------------------------------------------------------------ messages
msg() {  # msg <warn|kick> <lang> <until HH:MM>; {min} = WARN_MINUTES, {until} = $3
  local text
  case "$1:$2" in
    warn:de) text="In {min} Minuten ist Schluss für heute – bitte speichern!" ;;
    kick:de) text="Schlafenszeit! Ab {until} Uhr geht es weiter." ;;
    warn:fr) text="Le serveur ferme pour toi dans {min} minutes – pense à sauvegarder !" ;;
    kick:fr) text="C'est l'heure de dormir ! Tu pourras rejouer à partir de {until}." ;;
    warn:it) text="Tra {min} minuti il server chiude per te – salva i tuoi progressi!" ;;
    kick:it) text="È ora di dormire! Potrai giocare di nuovo dalle {until}." ;;
    warn:es) text="El servidor se cierra para ti en {min} minutos – ¡guarda tu progreso!" ;;
    kick:es) text="¡Hora de dormir! Podrás volver a jugar a partir de las {until}." ;;
    warn:*)  text="The server closes for you in {min} minutes – please save your progress!" ;;
    kick:*)  text="Bedtime! You can play again from {until}." ;;
  esac
  text="${text//\{min\}/$WARN_MINUTES}"
  echo "${text//\{until\}/$3}"
}

# ------------------------------------------------------------------ time helpers
NOW="${MC_CURFEW_NOW:-$(date '+%Y-%m-%d %H:%M')}"
TODAY=$(date -d "$NOW" +%F)
YESTERDAY=$(date -d "$TODAY -1 day" +%F)
TOMORROW=$(date -d "$TODAY +1 day" +%F)
NOW_MIN=$((10#$(date -d "$NOW" +%H) * 60 + 10#$(date -d "$NOW" +%M)))

to_min()  { echo $((10#${1%%:*} * 60 + 10#${1##*:})); }
hhmm()    { printf '%02d:%02d' $(($1 / 60)) $(($1 % 60)); }
day_num() {  # two-letter weekday (English or German) -> 1..7 (Mon..Sun)
  case "$1" in
    mo) echo 1 ;; tu|di) echo 2 ;; we|mi) echo 3 ;; th|do) echo 4 ;;
    fr) echo 5 ;; sa) echo 6 ;; su|so) echo 7 ;; *) echo 0 ;;
  esac
}

WIN='([0-9]{1,2}:[0-9]{2}-[0-9]{1,2}:[0-9]{2}|off)'

lang_of() {
  local tok
  for tok in ${PLAYERS[$1]:-}; do
    [[ $tok =~ ^[a-z]{2}$ ]] && { echo "$tok"; return; }
  done
  echo "$DEFAULT_LANG"
}

# window <player> <date> -> "start end" (minutes) for the night starting on <date>, or "off"
window() {
  local d tok w="" over="" day
  d=$(date -d "$2" +%u)
  for tok in ${PLAYERS[$1]:-}; do
    if [[ $tok =~ ^$WIN$ ]]; then
      w=$tok
    elif [[ $tok =~ ^([a-z]{2}(,[a-z]{2})*):$WIN$ ]]; then
      for day in ${BASH_REMATCH[1]//,/ }; do
        [ "$(day_num "$day")" = "$d" ] && over=${BASH_REMATCH[3]}
      done
    fi
  done
  w=${over:-${w:-$DEFAULT_WINDOW}}
  if [ "$w" = off ] || [ "${w%-*}" = "${w#*-}" ]; then
    echo off
  else
    echo "$(to_min "${w%-*}") $(to_min "${w#*-}")"
  fi
}

# in_curfew <player>: true if the player's window covers NOW; sets NIGHT and UNTIL
in_curfew() {
  local w s e
  w=$(window "$1" "$YESTERDAY")              # last night's window reaching past midnight
  if [ "$w" != off ]; then
    read -r s e <<<"$w"
    if ((s > e && NOW_MIN < e)); then NIGHT=$YESTERDAY; UNTIL=$(hhmm "$e"); return 0; fi
  fi
  w=$(window "$1" "$TODAY")
  if [ "$w" != off ]; then
    read -r s e <<<"$w"
    if { ((s > e && NOW_MIN >= s)); } || { ((s < e && NOW_MIN >= s && NOW_MIN < e)); }; then
      NIGHT=$TODAY; UNTIL=$(hhmm "$e"); return 0
    fi
  fi
  return 1
}

# warn_due <player>: true if a curfew starts within WARN_MINUTES; sets NIGHT
warn_due() {
  local w s
  w=$(window "$1" "$TODAY")
  if [ "$w" != off ]; then
    read -r s _ <<<"$w"
    if ((s - NOW_MIN > 0 && s - NOW_MIN <= WARN_MINUTES)); then NIGHT=$TODAY; return 0; fi
  fi
  w=$(window "$1" "$TOMORROW")               # window starting shortly after midnight
  if [ "$w" != off ]; then
    read -r s _ <<<"$w"
    if ((s + 1440 - NOW_MIN <= WARN_MINUTES)); then NIGHT=$TOMORROW; return 0; fi
  fi
  return 1
}

# ------------------------------------------------------------------ rcon
if [ -z "$RCON_CMD" ] && [ -z "$CONTAINER" ]; then
  CONTAINER=$(docker ps --filter "label=com.docker.compose.service=${SERVICE}" \
                        --format '{{.Names}}' 2>/dev/null | head -1)
  if [ -z "$CONTAINER" ]; then
    # log once per outage, not every minute
    [ -f "$STATE_DIR/.server-down" ] || logger -t mc-curfew "no running container for service '${SERVICE}'"
    touch "$STATE_DIR/.server-down"
    echo "mc-curfew: no running container for service '${SERVICE}'" >&2
    exit 1
  fi
fi
rm -f "$STATE_DIR/.server-down"

rcon() {
  if [ -n "$RCON_CMD" ]; then
    $RCON_CMD "$1" 2>&1
  else
    docker exec "$CONTAINER" rcon-cli "$1" 2>&1
  fi
}

lock() {  # lock <player> <until>
  local out
  out=$(rcon "whitelist remove $1")
  [[ "$out" == Removed* ]] && logger -t mc-curfew "$1 removed from whitelist"
  out=$(rcon "kick $1 $(msg kick "$(lang_of "$1")" "$2")")
  [[ "$out" == Kicked* ]] && logger -t mc-curfew "$1 kicked"
  return 0
}

unlock() {  # unlock <player>; fails if RCON is not reachable
  local out
  out=$(rcon "whitelist add $1") || return 1
  [[ "$out" == Added* ]] && logger -t mc-curfew "$1 added back to whitelist"
  return 0
}

warn() { rcon "tell $1 $(msg warn "$(lang_of "$1")" "")" >/dev/null; }

skipped() { [ "$(cat "$STATE_DIR/$1.skip" 2>/dev/null)" = "$2" ]; }

# ------------------------------------------------------------------ main
ACTION="${1:-}"
shift || true
if [ $# -gt 0 ]; then TARGETS=("$@"); else TARGETS=("${!PLAYERS[@]}"); fi
if [ "$ACTION" != "status" ] && [ ${#TARGETS[@]} -eq 0 ]; then
  echo "mc-curfew: no players configured" >&2
  exit 2
fi

case "$ACTION" in
  tick)
    for p in "${TARGETS[@]}"; do
      if in_curfew "$p" && ! skipped "$p" "$NIGHT"; then
        lock "$p" "$UNTIL"                   # every minute: safety net after server restarts
        touch "$STATE_DIR/$p.locked"
      else
        if [ -f "$STATE_DIR/$p.locked" ]; then
          unlock "$p" && rm -f "$STATE_DIR/$p.locked"
        fi
        if warn_due "$p" && ! skipped "$p" "$NIGHT" \
           && [ "$(cat "$STATE_DIR/$p.warned" 2>/dev/null)" != "$NIGHT" ]; then
          warn "$p"
          echo "$NIGHT" >"$STATE_DIR/$p.warned"
        fi
      fi
    done
    ;;
  skip)
    for p in "${TARGETS[@]}"; do
      in_curfew "$p" || NIGHT=$TODAY
      echo "$NIGHT" >"$STATE_DIR/$p.skip"
      logger -t mc-curfew "$p: curfew skipped for the night of $NIGHT"
      if [ -f "$STATE_DIR/$p.locked" ]; then unlock "$p" && rm -f "$STATE_DIR/$p.locked"; fi
      echo "$p: no curfew for the night of $NIGHT"
    done
    ;;
  warn)
    for p in "${TARGETS[@]}"; do warn "$p"; done
    ;;
  enforce)
    for p in "${TARGETS[@]}"; do
      if in_curfew "$p"; then u=$UNTIL; else read -r _ e <<<"$(window "$p" "$TODAY")"; u=$(hhmm "${e:-390}"); fi
      lock "$p" "$u"
    done
    ;;
  unlock)
    for p in "${TARGETS[@]}"; do unlock "$p" && rm -f "$STATE_DIR/$p.locked"; done
    ;;
  status)
    echo "Now:      $NOW"
    echo "Target:   ${RCON_CMD:-docker exec $CONTAINER rcon-cli}"
    for p in "${!PLAYERS[@]}"; do
      w=$(window "$p" "$TODAY")
      [ "$w" = off ] && tonight="off" || { read -r s e <<<"$w"; tonight="$(hhmm "$s")-$(hhmm "$e")"; }
      if in_curfew "$p"; then
        skipped "$p" "$NIGHT" && state="exception (skip)" || state="locked until $UNTIL"
      else
        state="free"
      fi
      printf 'Player:   %-16s %s  tonight %-11s  %s\n' "$p" "$(lang_of "$p")" "$tonight" "$state"
    done
    rcon "list"
    rcon "whitelist list"
    ;;
  *)
    echo "Usage: $0 tick|status|skip|warn|enforce|unlock [player ...]" >&2
    exit 2
    ;;
esac
