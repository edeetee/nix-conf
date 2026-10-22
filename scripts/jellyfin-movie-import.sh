#!/usr/bin/env bash
# jellyfin-movie-import.sh — give Jellyfin movies it can actually name.
#
# The problem this solves: a Jellyfin library rooted at the torrent download dir
# sees release names (`www.UIndex.org    -    Toy Story 4 2019 REPACK 1080p
# BluRay DDP 7 1 x265-edge2020`) and either fails to match TMDb or matches the
# wrong thing, so items come up with no title and no poster. Jellyfin has no
# rename feature and no way to strip site tags, so the fix has to happen on
# disk: put each movie at `Movies/<Title> (<Year>)/<Title> (<Year>).<ext>`,
# which the parser resolves deterministically.
#
# It does NOT move anything. Each movie is *hardlinked* into the library, so
# Transmission keeps seeding from the original and no space is used twice. If
# the library is on a different filesystem a symlink is made instead (Jellyfin
# follows symlinks; only cifs mounts refuse to stat them).
#
# TV is deliberately skipped: torrent episode names carry SxxExx (or a bare
# episode number, or nothing) and belong in a Shows library with Sonarr-style
# renaming — a different job. Anything under --min-mb that looks like a short
# is skipped too, which is what excludes the Peppa Pig tree.
#
#   ./scripts/jellyfin-movie-import.sh                      # dry run, the default
#   ./scripts/jellyfin-movie-import.sh --apply              # do it
#   ./scripts/jellyfin-movie-import.sh --src /mnt/mac/Movies --dest ... --apply
#
# Runs on the server, where the media is:
#   ssh homeserver-edt.local 'bash -s -- --apply' < scripts/jellyfin-movie-import.sh

set -euo pipefail

SRC="/mnt/hdd/downloads"
DEST="/mnt/hdd/media/library/movies"
MIN_MB=300          # feature-length floor; excludes shorts, samples, extras
APPLY=0

usage() {
  sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --src DIR      where the release-named files are      (default /mnt/hdd/downloads)
  --dest DIR     Jellyfin Movies library root           (default /mnt/hdd/media/library/movies)
  --min-mb N     minimum size in MiB to count a movie   (default 300)
  --apply        actually link files (otherwise dry run)
  -h, --help     this text
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)    SRC="$2"; shift 2 ;;
    --dest)   DEST="$2"; shift 2 ;;
    --min-mb) MIN_MB="$2"; shift 2 ;;
    --apply)  APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Strip the release-site decorations that break the parser: a leading
# "[ www.site.com ] - ", "www.site.com    -    ", and a trailing "[site]" tag.
strip_site() {
  printf '%s' "$1" | sed -E \
    -e 's/^\[[^]]*\][[:space:]]*-[[:space:]]*//' \
    -e 's/^[Ww][Ww][Ww]\.[^[:space:]]*[[:space:]]+-[[:space:]]*//' \
    -e 's/\[[^]]*\]//g' \
    -e 's/[[:space:]]+$//'
}

# Release decorations that end the title when there is no "(Year)" to stop at.
is_quality() {
  case "${1,,}" in
    2160p|1080p|720p|576p|480p|4k|uhd|hdr|dv|webrip|web-dl|webdl|web|bluray|blu-ray|\
    brrip|bdrip|dvdrip|hdtv|remux|x264|x265|h264|h.264|hevc|av1|10bit|8bit|\
    aac|aac2.0|aac5.1|ac3|eac3|ddp|ddp5.1|dd5.1|dts|dts-hd|truehd|atmos|5.1|7.1|\
    repack|proper|extended|remastered|complete|internal|yify|yts|rarbg|\
    nordic|norvine|yts.gg|yts.bz|eztvx.to) return 0 ;;
    *) return 1 ;;
  esac
}

# From a raw name, print "Title<TAB>Year", or nothing if no year is visible.
parse_name() {
  local raw title year
  raw=$(strip_site "$1")

  # The year is the first standalone 19xx/20xx. It is what separates title from
  # the quality tags that follow, and it is what makes TMDb matching reliable.
  # An all-digit title ("1917") would be read as a year — none here; rename such
  # a file by hand.
  year=$(printf '%s' "$raw" | grep -oE '(^|[^0-9])((19|20)[0-9]{2})([^0-9p]|$)' |
         grep -oE '(19|20)[0-9]{2}' | head -1) || true
  [ -n "${year:-}" ] || return 1

  title=$(printf '%s' "$raw" | awk -v y="$year" '{ i = index($0, y); print substr($0, 1, i - 1) }')

  # . and _ were separators in the release name; in a title they are punctuation
  # the parser should not see.
  title=$(printf '%s' "$title" |
          sed -E -e 's/[._]+/ /g' \
                 -e 's/[[:space:]]*[(]?[[:space:]]*$//' \
                 -e 's/[[:space:]]+/ /g' \
                 -e 's/^-+[[:space:]]*//' \
                 -e 's/[[:space:]]+-+$//')
  [ -n "$title" ] || return 1

  # Trim trailing quality words in case the year was in the *folder* and the
  # file name continues with tags we did not cut at.
  local -a words out=()
  read -r -a words <<<"$title"
  local w
  for w in "${words[@]}"; do
    if is_quality "$w"; then break; fi
    out+=("$w")
  done
  title="${out[*]}"
  [ -n "$title" ] || return 1

  printf '%s\t%s' "$title" "$year"
}

is_episode() {
  [[ "$1" =~ [Ss][0-9]{1,2}[Ee][0-9]{1,3} ]] ||
  [[ "$1" =~ [Ss]eason[[:space:]._-]*[0-9] ]] ||
  [[ "${1,,}" == *complete* ]]
}

[ -d "$SRC" ] || { echo "no such source dir: $SRC" >&2; exit 1; }

matched=0 linked=0 skipped_tv=0 skipped_small=0 skipped_noYear=0 already=0 fail=0

echo "source : $SRC"
echo "library: $DEST"
[ "$APPLY" -eq 1 ] && echo "mode   : APPLY" || echo "mode   : dry run (pass --apply to write)"
echo

while IFS= read -r -d '' file; do
  dir=$(dirname "$file")
  base=$(basename "$file")
  ext="${base##*.}"
  size_mb=$(( $(stat -c %s "$file") / 1048576 ))

  [ "$size_mb" -ge "$MIN_MB" ] || { skipped_small=$((skipped_small + 1)); continue; }

  # Prefer the directory name: torrents usually keep "Title (Year) [tags]" on
  # the folder and put the full release name on the file inside it.
  parsed=""
  name=$(basename "$dir")
  if [ "$dir" != "$SRC" ] && ! is_episode "$name"; then
    parsed=$(parse_name "$name" || true)
  fi
  if [ -z "$parsed" ] && ! is_episode "$base"; then
    parsed=$(parse_name "${base%.*}" || true)
  fi

  if [ -z "$parsed" ]; then
    if is_episode "$name" || is_episode "$base"; then
      skipped_tv=$((skipped_tv + 1))
      printf 'TV     %s\n' "$file"
    else
      skipped_noYear=$((skipped_noYear + 1))
      printf 'NOYEAR %s\n' "$file"
    fi
    continue
  fi

  title="${parsed%%$'\t'*}"
  year="${parsed##*$'\t'}"
  target_dir="$DEST/$title ($year)"
  target="$target_dir/$title ($year).$ext"

  if [ -e "$target" ]; then
    already=$((already + 1))
    printf 'HAVE   %s\n' "$target"
    continue
  fi

  matched=$((matched + 1))
  printf '%s (%s)  <-  %s\n' "$title" "$year" "$file"
  if [ "$APPLY" -eq 1 ]; then
    if mkdir -p "$target_dir" 2>/dev/null && ln "$file" "$target" 2>/dev/null; then
      linked=$((linked + 1))
    elif ln -s "$file" "$target" 2>/dev/null; then
      printf '       (symlinked: %s is on a different filesystem)\n' "$DEST"
      linked=$((linked + 1))
    else
      printf '       FAILED to link -> %s\n' "$target" >&2
      fail=$((fail + 1))
    fi
  fi
done < <(find "$SRC" -type f \
           \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' \
              -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.ts' \) -print0)

echo
printf 'matched %d (linked %d), already present %d, failed %d | skipped: tv %d, shorts %d, no year %d\n' \
  "$matched" "$linked" "$already" "$fail" "$skipped_tv" "$skipped_small" "$skipped_noYear"

cat <<'EOF'

Next, in Jellyfin (Dashboard -> Libraries):
  1. Point the Movies library at the DEST path above, and remove the download
     dir from it -- one root cannot be both a Movies and a Shows library.
  2. Library -> ... -> Refresh metadata -> "Replace all metadata", which
     discards the cached misses. Newly named folders are picked up as new
     items, so their watch state starts over.
  3. For a straggler, open the item -> Identify -> search the real title.
     Orphans left as "Folder name" with no poster usually mean the year in the
     name is wrong, which is worth fixing on disk.
EOF
