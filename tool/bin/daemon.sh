#!/usr/bin/env bash
# Background manager for the stitchpad watcher (per pad). SINGLETON: an atomic
# mkdir lock guarantees at most ONE supervisor per pad — no respawn pileups even
# under concurrent `start` calls or wrong-cwd launches.
# Usage: daemon.sh {start|stop|status|restart}
set -uo pipefail
_src="${BASH_SOURCE[0]}"; while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
BIN_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
source "$BIN_DIR/lib.sh"
sp_init_paths || { echo "no .stitchpad here"; exit 1; }

LOCKDIR="$PAD_STATE/watch.lock.d"     # atomic singleton gate (mkdir = atomic)
PIDFILE="$LOCKDIR/pid"                 # supervisor pid lives INSIDE the lock
LOG="$PAD_STATE/watch.log"

# alive iff the lock exists AND its pid is a live process. A stale lock (process
# gone) is auto-cleared so a crash can't wedge the pad forever.
is_running() {
  [ -d "$LOCKDIR" ] || return 1
  local p; p="$(cat "$PIDFILE" 2>/dev/null)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 0; fi
  rm -rf "$LOCKDIR"; return 1   # stale → clear
}

case "${1:-status}" in
  start)
    if is_running; then echo "running (pid $(cat "$PIDFILE"))"; exit 0; fi
    # ATOMIC acquire: only one caller can create the lockdir. A loser just exits —
    # this is what makes the supervisor a true singleton (no pileup).
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
      # someone else won the race; if it's alive, defer to it
      is_running && { echo "running (pid $(cat "$PIDFILE"))"; exit 0; }
      rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" 2>/dev/null || { echo "could not acquire watcher lock"; exit 1; }
    fi
    # Supervisor: own process group (setsid-ish via subshell), restarts watch.sh if
    # it dies, and CLEARS THE LOCK on exit so stop/crash leaves no stale gate.
    # KEEP-ALIVE: only respawn while at least one agent heartbeat is fresh.
    ( trap 'rm -rf "$LOCKDIR"' EXIT
      echo $$ > "$PIDFILE"            # the supervisor records ITS OWN pid
      while true; do
        date +%s > "$LOCKDIR/heartbeat"
        STITCHPAD_PAD_DIR="$PAD_DIR" bash "$STITCHPAD_HOME/bin/watch.sh" >>"$LOG" 2>&1
        # if the lock was removed (stop requested), exit instead of respawning
        [ -d "$LOCKDIR" ] || exit 0
        # check agent heartbeats before respawning
        if ! sp_any_alive; then
          echo "[stitchpad] no fresh agent heartbeats — supervisor exiting" >>"$LOG"
          exit 0
        fi
        echo "[stitchpad] watcher exited (code $?), restarting in 2s..." >>"$LOG"
        sleep 2
      done
    ) &
    disown
    sleep 0.3
    echo "started stitchpad watcher (pid $(cat "$PIDFILE" 2>/dev/null)); log: $LOG" ;;
  stop)
    if [ -d "$LOCKDIR" ]; then
      p="$(cat "$PIDFILE" 2>/dev/null)"
      rm -rf "$LOCKDIR"            # signal the supervisor loop to exit (it checks)
      # kill the supervisor process group so watch.sh + fswatch children die too
      [ -n "$p" ] && kill -- "-$p" 2>/dev/null; [ -n "$p" ] && kill "$p" 2>/dev/null
      # belt+suspenders: reap any watch.sh/fswatch still bound to THIS pad
      pkill -f "STITCHPAD_PAD_DIR=$PAD_DIR" 2>/dev/null || true
      pkill -f "fswatch.*$PAD_MD" 2>/dev/null || true
      echo "stopped"
    else echo "not running"; fi ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  status)  if is_running; then echo "running (pid $(cat "$PIDFILE"))"; else echo "stopped"; fi ;;
  *) echo "usage: $0 {start|stop|status|restart}"; exit 1 ;;
esac
