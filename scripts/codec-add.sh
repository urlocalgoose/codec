#!/usr/bin/env bash
# One command from a Spotify link to songs on every Codec device:
#   codec-add https://open.spotify.com/playlist/...   # a playlist
#   codec-add liked                                   # your Liked Songs
#
# Pipeline: s2y (Spotify -> YouTube -> tagged MP3s + loud.import.v1
# manifest) -> codec_import (library import + server upload).
#
# Configuration comes from the environment, or from an env file at
# $CODEC_ADD_ENV (default ~/.codec/codec-add.env):
#   SPOTIFY_CLIENT_ID       Spotify app client ID (required by s2y)
#   S2Y_DIR                 s2y checkout (contains main.py)
#   CODEC_MUSIC_ROOT        the Codec music folder
#   CODEC_SERVER_URL        sync server (default http://127.0.0.1:8787)
#   CODEC_AUTH_TOKEN_FILE   token file (default ~/.codec/auth-token)
#   CODEC_IMPORT_BIN        codec_import binary (default ~/.codec/bin/codec_import)
#   S2Y_WORKERS             download workers (default 8)

set -euo pipefail

CODEC_ADD_ENV="${CODEC_ADD_ENV:-$HOME/.codec/codec-add.env}"
if [[ -f "$CODEC_ADD_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$CODEC_ADD_ENV"
fi

CODEC_SERVER_URL="${CODEC_SERVER_URL:-http://127.0.0.1:8787}"
CODEC_AUTH_TOKEN_FILE="${CODEC_AUTH_TOKEN_FILE:-$HOME/.codec/auth-token}"
CODEC_IMPORT_BIN="${CODEC_IMPORT_BIN:-$HOME/.codec/bin/codec_import}"
S2Y_WORKERS="${S2Y_WORKERS:-8}"
S2Y_PYTHON="${S2Y_PYTHON:-python3}"

usage() {
  echo "usage: codec-add <spotify-playlist-url | liked>" >&2
  exit 64
}

fail() {
  echo "codec-add: $1" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
LINK="$1"

[[ -n "${S2Y_DIR:-}" ]] || fail "S2Y_DIR is not set (add it to $CODEC_ADD_ENV)"
[[ -n "${CODEC_MUSIC_ROOT:-}" ]] || fail "CODEC_MUSIC_ROOT is not set (add it to $CODEC_ADD_ENV)"
[[ -n "${SPOTIFY_CLIENT_ID:-}" ]] || fail "SPOTIFY_CLIENT_ID is not set (add it to $CODEC_ADD_ENV)"
[[ -f "$S2Y_DIR/main.py" ]] || fail "no main.py in S2Y_DIR ($S2Y_DIR)"
[[ -x "$CODEC_IMPORT_BIN" ]] || fail "codec_import binary missing ($CODEC_IMPORT_BIN) - build with: cargo build --release --bin codec_import"
[[ -f "$CODEC_AUTH_TOKEN_FILE" ]] || fail "auth token file missing ($CODEC_AUTH_TOKEN_FILE)"

if [[ "$LINK" == "liked" ]]; then
  WORKING="liked-songs.json"
  MANIFEST="loud-import-liked.json"
  SOURCE_ARGS=(--source liked)
elif [[ "$LINK" =~ open\.spotify\.com/playlist/([A-Za-z0-9]+) ]]; then
  PLAYLIST_ID="${BASH_REMATCH[1]}"
  WORKING="playlist-${PLAYLIST_ID}.json"
  MANIFEST="loud-import-${PLAYLIST_ID}.json"
  SOURCE_ARGS=(--source playlist --playlist "$LINK")
else
  fail "that does not look like a Spotify playlist link (or 'liked'): $LINK"
fi

echo "==> s2y: downloading via $WORKING"
(
  cd "$S2Y_DIR"
  # Prefer the Rust CLI (S2Y_BIN) when configured: same flags as main.py,
  # plus a public-page fallback for playlists Spotify's API refuses to
  # serve (their own algorithmic/editorial ones 404 since late 2024).
  if [[ -n "${S2Y_BIN:-}" ]]; then
    SPOTIFY_CLIENT_ID="$SPOTIFY_CLIENT_ID" "$S2Y_BIN" "$WORKING" \
      "${SOURCE_ARGS[@]}" \
      --workers "$S2Y_WORKERS" \
      --save-each \
      --loud-manifest "$MANIFEST"
  else
    SPOTIFY_CLIENT_ID="$SPOTIFY_CLIENT_ID" "$S2Y_PYTHON" main.py "$WORKING" \
      "${SOURCE_ARGS[@]}" \
      --workers "$S2Y_WORKERS" \
      --save-each \
      --loud-manifest "$MANIFEST"
  fi
)

echo "==> codec: importing $MANIFEST and syncing to $CODEC_SERVER_URL"
"$CODEC_IMPORT_BIN" "$CODEC_MUSIC_ROOT" "$S2Y_DIR/$MANIFEST" \
  --server "$CODEC_SERVER_URL" \
  --token "$(cat "$CODEC_AUTH_TOKEN_FILE")"

echo "==> done. Pull to refresh on your devices."
