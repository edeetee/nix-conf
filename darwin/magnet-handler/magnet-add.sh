#!/bin/sh
# Add a magnet/torrent link to the homeserver's Transmission daemon.
#
# Invoked by "Add to Transmission.app" (see ../magnet-handler.nix), which is the
# default handler for magnet: URLs on this Mac, so a click in any browser lands
# here instead of on a web page.
#
# Deliberately in ~/.local/bin and not in the nix store: the logic can then be
# edited without rebuilding the app bundle (only the AppleScript's own hash
# triggers a rebuild).
set -u

# Same daemon the `torrents` alias drives (darwin/configuration.nix).
HOST="${TRANSMISSION_HOST:-homeserver-edt.local:9091}"
REMOTE=/run/current-system/sw/bin/transmission-remote

notify() {
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

if [ $# -lt 1 ]; then
  notify "Add to Transmission" "no URL given"
  exit 1
fi

# A click has no other trace than this: the app bundle fires, notifies and
# exits, so keep a log to answer "did it even run?".
LOG="$HOME/Library/Logs/transmission-magnet.log"
printf '%s %s %s\n' "$(/bin/date -u +%FT%TZ)" "$1" "$HOST" >> "$LOG" 2>/dev/null || true

if out=$("$REMOTE" "$HOST" -a "$1" 2>&1); then
  printf '%s ok\n' "$(/bin/date -u +%FT%TZ)" >> "$LOG" 2>/dev/null || true
  notify "Torrent added" "$HOST"
  # A refused connection is the *normal* failure here: the homeserver sleeps
  # aggressively to save power. Say so explicitly, because otherwise the
  # torrent silently never appears and the click looks like a no-op.
  printf '%s failed: %s\n' "$(/bin/date -u +%FT%TZ)" "$out" >> "$LOG" 2>/dev/null || true
  notify "Transmission unavailable" "${out:-no response from $HOST} - is the homeserver asleep?"
  exit 1
fi
