#!/usr/bin/env bash
# Generates a small demo music library of synthesized, fully-tagged MP3s
# with cover art, so Codec can be tried without owning any music.
#
#   scripts/make-demo-library.sh demo-library
#   # then open demo-library/ as the music folder, or import it.
#
# Requires ffmpeg.

set -euo pipefail

OUT="${1:-demo-library}"
command -v ffmpeg >/dev/null || { echo "make-demo-library: ffmpeg is required" >&2; exit 1; }

# name|artist|album|album-color|tracks (title:rootHz,...)
ALBUMS=(
  "Warm Circuits|The Codec Ensemble|Warm Circuits|0xF47B3F|Tape Hiss:220,Motor Start:277,Flywheel:330,Counter Roll:392"
  "Night Panels|The Codec Ensemble|Night Panels|0x73A7FF|VU Glow:196,Standby Lamp:247,Headroom:294"
  "Paper Sleeve|Dot Matrix Choir|Paper Sleeve|0x72C28F|Liner Notes:262,B-Side:311,Runout Groove:349"
)

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

total=0
for entry in "${ALBUMS[@]}"; do
  IFS='|' read -r _ artist album color tracks <<<"$entry"
  album_dir="$OUT/$artist/$album"
  mkdir -p "$album_dir"

  cover="$TMP/${album// /-}.png"
  # Two-tone cover (drawtext is not in every ffmpeg build).
  ffmpeg -loglevel error -y \
    -f lavfi -i "color=c=${color}:s=640x640:d=1" \
    -f lavfi -i "color=c=0x14120E@0.4:s=640x220:d=1" \
    -filter_complex "[0][1]overlay=0:420" \
    -frames:v 1 "$cover"

  n=0
  IFS=',' read -ra TRACKLIST <<<"$tracks"
  for spec in "${TRACKLIST[@]}"; do
    n=$((n + 1)); total=$((total + 1))
    title="${spec%%:*}"
    root="${spec##*:}"
    fifth=$(awk "BEGIN{printf \"%.0f\", $root * 1.5}")
    ffmpeg -loglevel error -y \
      -f lavfi -i "sine=frequency=${root}:duration=24" \
      -f lavfi -i "sine=frequency=${fifth}:duration=24" \
      -i "$cover" \
      -filter_complex "[0][1]amix=inputs=2,tremolo=f=4:d=0.4,afade=t=in:d=1,afade=t=out:st=22:d=2,volume=0.5[a]" \
      -map "[a]" -map 2:v -c:v copy -id3v2_version 3 \
      -metadata title="$title" \
      -metadata artist="$artist" \
      -metadata album="$album" \
      -metadata album_artist="$artist" \
      -metadata track="$n" \
      -metadata genre="Demo" \
      -metadata date="2026" \
      -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
      -b:a 128k "$album_dir/$(printf '%02d' "$n") - ${title}.mp3"
  done
done

echo "wrote $total demo tracks to $OUT/"
