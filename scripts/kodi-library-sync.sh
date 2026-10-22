#!/usr/bin/env bash
# kodi-library-sync — keep Kodi's library in step with Transmission, with no
# manual step beyond downloading a torrent.
#
# Why this exists: Kodi assigns a *content type and scraper to a path*, so one
# root is either Movies or TV shows and never both. /mnt/hdd/downloads is
# inherently mixed (film folders, season folders, loose episodes), so it cannot
# be scanned directly without something sorting it first. This does the sorting
# the only way that costs nothing: symlinks, no renames, no copies, no second
# library tree to keep in step.
#
# What it does NOT do: clean up release names. Kodi's own scraper strips site
# tags and release tokens and finds the year, which is why the links keep the
# raw name. If a particular release scrapes badly, put the year in the name by
# hand — that is the one field the parser cannot invent.
#
# Idempotent: an existing link is left alone, so a re-run after a partial
# download is harmless, and the scan is only triggered when something changed.
#
# Design notes and the measured behaviour: hosts/homeserver-edt/TV-MEDIA.md §1a.
set -euo pipefail

DL="${KODI_SYNC_DOWNLOAD_DIR:-/mnt/hdd/downloads}"
LIB="${KODI_SYNC_LIBRARY:-/mnt/hdd/media/library}"
RPC="${KODI_SYNC_RPC:-http://127.0.0.1:8081/jsonrpc}"
DRY="${KODI_SYNC_DRY:-0}"

changed=0

# Movies stay on the importer: it turns a release name into `Title (Year)`, which
# is what makes the film match unambiguous. It is still hands-off — the timer
# runs it — but it means the movie tree is derived rather than raw. TV is linked
# raw, because Kodi reads the show and season straight out of `SxxEyy`.
MI="${KODI_SYNC_MOVIE_IMPORT:-}"
if [ -n "$MI" ] && [ -x "$MI" ] && [ "$DRY" != 1 ]; then
  out=$("$MI" --min-mb 100 --apply 2>&1 || true)
  printf '%s\n' "$out" | grep -qE 'linked [1-9]' && changed=1
fi

link() {
  local src=$1 target=$2
  [ -e "$target" ] && return 0
  echo "link: ${target#"$LIB"/}  <-  ${src#"$DL"/}"
  changed=1
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$(dirname "$target")"
  ln -sf "$src" "$target"
}

# Show name from a file name: everything before the SxxEyy marker, with the
# release's dots and underscores turned back into spaces.
show_name() {
  printf '%s' "$1" | sed -E 's/[._]+/ /g' |
    sed -E 's/[[:space:]]*[Ss][0-9]{2}[Ee][0-9]{2}.*$//' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# ── TV: loose episode files in the download root ────────────────────────────
# Kodi needs Show[/ (Year)]/Season NN/, not just a folder per show: measured,
# a flat Shows/Silo/*.mkv made the scraper match the *source* folder name.
while IFS= read -r -d '' f; do
  b=$(basename "$f")
  se=$(printf '%s' "$b" | grep -oiE 'S[0-9]{2}E[0-9]{2}' | head -1 | tr '[:lower:]' '[:upper:]')
  [ -n "$se" ] || continue
  show=$(show_name "$b")
  [ -n "$show" ] || continue
  link "$f" "$LIB/shows/$show/Season ${se:1:2}/$b"
done < <(find "$DL" -maxdepth 1 -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' \) -print0)

# ── TV: whole season folders (all episodes inside one directory) ────────────
while IFS= read -r -d '' d; do
  base=$(basename "$d")
  case "$base" in .* | .incomplete) continue ;; esac
  # A folder qualifies as a show when its files carry SxxEyy; the folder name is
  # the show, stripped of the release's season/quality trailer.
  while IFS= read -r -d '' f; do
    b=$(basename "$f")
    se=$(printf '%s' "$b" | grep -oiE 'S[0-9]{2}E[0-9]{2}' | head -1 | tr '[:lower:]' '[:upper:]')
    [ -n "$se" ] || continue
    show=$(show_name "$base")
    [ -n "$show" ] || continue
    link "$f" "$LIB/shows/$show/Season ${se:1:2}/$b"
  done < <(find "$d" -maxdepth 2 -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' \) -print0)
done < <(find "$DL" -mindepth 1 -maxdepth 1 -type d -print0)

# ── Movies: everything else, raw name kept ──────────────────────────────────
# A directory that produced no episodes above is a film; a video file with no
# SxxEyy is a film. Linked as a whole directory so Kodi sees the release folder
# exactly as Transmission left it.
while IFS= read -r -d '' e; do
  base=$(basename "$e")
  case "$base" in .* | .incomplete) continue ;; esac
  if [ -d "$e" ]; then
    find "$e" -maxdepth 2 -type f -iname '*.mkv' -print0 2>/dev/null |
      tr '\0' '\n' | grep -qiE 'S[0-9]{2}E[0-9]{2}' && continue
  else
    printf '%s' "$base" | grep -qiE 'S[0-9]{2}E[0-9]{2}' && continue
  fi
  link "$e" "$LIB/movies/$base"
done < <(find "$DL" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) \
  \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -type d \) -print0)

# ── Scan, only if the library actually changed ──────────────────────────────
# Kodi aborts a running scan when a new one starts, and a full scan costs ~12 s
# of TMDb lookups per new item, so this is deliberately not unconditional.
if [ "$changed" = 1 ] && [ "$DRY" != 1 ]; then
  if curl -sf -m 10 -H 'Content-Type: application/json' -X POST \
    -d '{"jsonrpc":"2.0","id":1,"method":"VideoLibrary.Scan"}' "$RPC" >/dev/null; then
    echo "scan triggered"
  else
    echo "kodi not answering on $RPC; library links left in place, scan skipped" >&2
  fi
elif [ "$changed" = 0 ]; then
  echo "nothing new"
fi
