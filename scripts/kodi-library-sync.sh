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
shows_changed=()
movies_changed=0

# Movies stay on the importer: it turns a release name into `Title (Year)`, which
# is what makes the film match unambiguous. It is still hands-off — the timer
# runs it — but it means the movie tree is derived rather than raw. TV is linked
# raw, because Kodi reads the show and season straight out of `SxxEyy`.
MI="${KODI_SYNC_MOVIE_IMPORT:-}"
if [ -n "$MI" ] && [ -x "$MI" ] && [ "$DRY" != 1 ]; then
  out=$("$MI" --min-mb 100 --apply 2>&1 || true)
  printf '%s\n' "$out" | grep -qE 'linked [1-9]' && { changed=1; movies_changed=1; }
fi

link() {
  local src=$1 target=$2
  [ -e "$target" ] && return 0
  echo "link: ${target#"$LIB"/}  <-  ${src#"$DL"/}"
  changed=1
  # Remember which show folder was touched: scans are per directory, because a
  # whole-source scan mis-matches the show name (see the scan section below).
  case "$target" in
    "$LIB"/shows/*/*) shows_changed+=("$(printf '%s' "${target#"$LIB"/shows/}" | cut -d/ -f1)") ;;
  esac
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$(dirname "$target")"
  ln -sf "$src" "$target"
}

# Show name from a release name: drop a leading site tag, everything from the
# season/episode marker on, and the release tokens that follow. Measured against
# the real download names: 'silo.s03e05.1080p.web.h264-cakes[EZTVx.to].mkv' ->
# Silo, 'Modern.Family.S06.Season.6.COMPLETE.1080p.WEB-DL...' -> Modern Family
# (the marker is a bare S06 there, no episode), '[ www.torrenting.com ] - Peppa
# Pig S01-S04 Complete' -> Peppa Pig.
show_name() {
  printf '%s' "$1" |
    sed -E 's/[._]+/ /g' |
    sed -E 's/^\[[^]]*\][[:space:]]*-?[[:space:]]*//' |
    sed -E 's/^www [^ ]*[[:space:]]*-[[:space:]]*//' |
    sed -E 's/[[:space:]]*[Ss][0-9]{2}([Ee][0-9]{2})?.*$//' |
    sed -E 's/[[:space:]]*(COMPLETE|REPACK|PROPER|EXTENDED|1080p|720p|2160p|WEB ?DL|WEBRip|BluRay|BDRip|HDTV|x264|x265|HEVC|H 264|DDP? ?[0-9] ?[0-9]|DTS|AAC).*$//' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# Folder for a show, reusing an existing one that differs only in case. Measured:
# the loose files are 'silo.s03e05...' and 'Silo.S03E04...', which produced two
# sibling folders (ext4 is case-sensitive) and therefore two library entries for
# one show.
show_dir() {
  local want=$1 ex bn
  for ex in "$LIB"/shows/*/; do
    [ -d "$ex" ] || continue
    bn=$(basename "$ex")
    if [ "${bn,,}" = "${want,,}" ]; then
      printf '%s' "$bn"
      return
    fi
  done
  printf '%s' "$want"
}

# ── TV: loose episode files in the download root ────────────────────────────
# Kodi needs Show[/ (Year)]/Season NN/, not just a folder per show: measured,
# a flat Shows/Silo/*.mkv made the scraper match the *source* folder name.
while IFS= read -r -d '' f; do
  b=$(basename "$f")
  se=$(printf '%s' "$b" | grep -oiE 'S[0-9]{2}E[0-9]{2}' | head -1 | tr '[:lower:]' '[:upper:]' || true)
  [ -n "$se" ] || continue
  show=$(show_dir "$(show_name "$b")")
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
    se=$(printf '%s' "$b" | grep -oiE 'S[0-9]{2}E[0-9]{2}' | head -1 | tr '[:lower:]' '[:upper:]' || true)
    [ -n "$se" ] || continue
    show=$(show_dir "$(show_name "$base")")
    [ -n "$show" ] || continue
    link "$f" "$LIB/shows/$show/Season ${se:1:2}/$b"
  done < <(find "$d" -maxdepth 2 -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' \) -print0)
done < <(find "$DL" -mindepth 1 -maxdepth 1 -type d -print0)

# Movies are the importer's job (see the KODI_SYNC_MOVIE_IMPORT block above):
# it turns a release name into `Title (Year)`, which is what makes the film
# match unambiguous, and it is idempotent. This script deliberately does NOT
# also link the raw release folders — that produced every film twice.

# ── Scan, only if the library actually changed ──────────────────────────────
# Per directory, never a whole-source scan. Measured: a plain
# `VideoLibrary.Scan` (no directory) makes the TV scraper match the *source*
# folder name -- `shows/` became "Your Show of Shows" -- while scanning
# `shows/<Show>/` matches the show. Kodi also aborts a running scan when a new
# one starts, so the calls are serialised with a wait between them.
scan_dir() {
  curl -sf -m 60 -H 'Content-Type: application/json' -X POST \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"VideoLibrary.Scan\",\"params\":{\"directory\":\"$1\"}}" \
    "$RPC" >/dev/null
}

if [ "$DRY" = 1 ]; then
  echo "dry run: nothing triggered"
elif [ "$changed" = 0 ]; then
  echo "nothing new"
else
  if ! curl -sf -m 10 -H 'Content-Type: application/json' -X POST \
    -d '{"jsonrpc":"2.0","id":1,"method":"JSONRPC.Ping"}' "$RPC" >/dev/null; then
    echo "kodi not answering on $RPC; links left in place, scan skipped" >&2
    exit 0
  fi
  if [ "$movies_changed" = 1 ]; then
    scan_dir "$LIB/movies/" && echo "scanned movies"
  fi
  for d in "${shows_changed[@]:-}"; do
    [ -n "$d" ] || continue
    # A scan takes ~12 s per new item and a new scan aborts the running one.
    sleep 45
    scan_dir "$LIB/shows/$d/" && echo "scanned shows/$d"
  done
fi
