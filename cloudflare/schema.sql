CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  owner_email TEXT NOT NULL,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  public_key_jwk TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE TABLE IF NOT EXISTS device_nonces (
  device_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, nonce)
);

CREATE INDEX IF NOT EXISTS idx_device_nonces_expires_at ON device_nonces(expires_at);

CREATE TABLE IF NOT EXISTS tracks (
  fingerprint TEXT PRIMARY KEY,
  metadata_json TEXT NOT NULL,
  audio_key TEXT,
  artwork_key TEXT,
  owner_device_id TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS playlists (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  track_ids_json TEXT NOT NULL,
  owner_device_id TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS playback_commands (
  command_id TEXT PRIMARY KEY,
  response_json TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

