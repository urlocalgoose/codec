use image::{codecs::jpeg::JpegEncoder, ColorType};
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::picture::PictureType;
use lofty::probe::Probe;
use lofty::tag::{Accessor, ItemKey};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::WalkDir;

const LIKED_FOLDER_NAME: &str = "Liked";
const STATE_DIR_NAME: &str = ".loud";
const STATE_FILE_NAME: &str = "state.json";
const MANAGED_AUDIO_DIR_NAME: &str = "audio";
const CACHE_DIR_NAME: &str = "cache";
const ARTWORK_DIR_NAME: &str = "artwork";
const ARTWORK_THUMBNAIL_SIZE: u32 = 640;
const IMPORT_SCHEMA: &str = "loud.import.v1";

#[derive(Clone, Debug, Serialize)]
pub struct Library {
    pub root_path: String,
    pub scanned_at: u64,
    pub stats: LibraryStats,
    pub artists: Vec<ArtistSummary>,
    pub albums: Vec<AlbumSummary>,
    pub playlists: Vec<Playlist>,
    pub tracks: Vec<Track>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub path: String,
    pub track_ids: Vec<String>,
    pub is_liked: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct Track {
    pub id: String,
    pub path: String,
    pub file_name: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub year: Option<u16>,
    pub track_number: Option<u32>,
    pub duration_seconds: Option<f64>,
    pub artwork_url: Option<String>,
    #[serde(skip_serializing)]
    pub artwork: Option<CachedArtwork>,
    pub playlist_ids: Vec<String>,
    pub added_at: Option<u64>,
    pub size_bytes: u64,
    pub is_liked: bool,
    pub fingerprint: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryStats {
    pub track_count: usize,
    pub playlist_count: usize,
    pub liked_count: usize,
    pub artist_count: usize,
    pub album_count: usize,
    pub duration_seconds: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtistSummary {
    pub name: String,
    pub track_count: usize,
    pub album_count: usize,
    pub duration_seconds: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AlbumSummary {
    pub name: String,
    pub artist: String,
    pub track_count: usize,
    pub duration_seconds: f64,
    #[serde(rename = "artwork_url")]
    pub artwork_url: Option<String>,
    #[serde(skip_serializing)]
    pub artwork: Option<CachedArtwork>,
}

#[derive(Clone, Debug)]
pub struct CachedArtwork {
    pub source_path: PathBuf,
    pub cache_path: PathBuf,
}

#[derive(Clone, Debug)]
struct PendingTrack {
    track: Track,
    playlist_ids: Vec<String>,
    playlist_is_liked: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct LibraryState {
    schema_version: u32,
    #[serde(default)]
    liked_fingerprints: BTreeSet<String>,
    #[serde(default)]
    unliked_fingerprints: BTreeSet<String>,
    #[serde(default)]
    playlists: Vec<StatePlaylist>,
    #[serde(default)]
    removed_playlist_memberships: Vec<StatePlaylistMembership>,
    #[serde(default)]
    managed_tracks: BTreeMap<String, StateTrackMetadata>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StatePlaylist {
    id: String,
    name: String,
    #[serde(default)]
    track_fingerprints: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StatePlaylistMembership {
    playlist_id: String,
    track_fingerprint: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StateTrackMetadata {
    fingerprint: String,
    title: String,
    artist: String,
    album: String,
    #[serde(default)]
    album_artist: Option<String>,
    #[serde(default)]
    genre: Option<String>,
    #[serde(default)]
    year: Option<u16>,
    #[serde(default)]
    track_number: Option<u32>,
    #[serde(default)]
    disc_number: Option<u32>,
    #[serde(default)]
    duration_seconds: Option<f64>,
    #[serde(default)]
    explicit: Option<bool>,
    #[serde(default)]
    identifiers: TrackIdentifiers,
    #[serde(default)]
    source_urls: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct TrackIdentifiers {
    #[serde(default)]
    isrc: Option<String>,
    #[serde(default)]
    spotify_track_id: Option<String>,
    #[serde(default)]
    spotify_album_id: Option<String>,
    #[serde(default)]
    youtube_video_id: Option<String>,
    #[serde(default)]
    musicbrainz_recording_id: Option<String>,
    #[serde(flatten)]
    extra: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Deserialize)]
struct ImportManifest {
    #[serde(default)]
    schema: String,
    #[serde(default)]
    source: Option<ImportSource>,
    #[serde(default)]
    tracks: Vec<ImportTrack>,
    #[serde(default)]
    playlists: Vec<ImportPlaylist>,
}

#[derive(Clone, Debug, Deserialize)]
struct ImportSource {
    #[serde(default)]
    base_path: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct ImportTrack {
    file: String,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    artist: Option<String>,
    #[serde(default)]
    album: Option<String>,
    #[serde(default)]
    album_artist: Option<String>,
    #[serde(default)]
    genre: Option<String>,
    #[serde(default)]
    year: Option<u16>,
    #[serde(default)]
    track_number: Option<u32>,
    #[serde(default)]
    disc_number: Option<u32>,
    #[serde(default)]
    duration_seconds: Option<f64>,
    #[serde(default)]
    duration_ms: Option<u64>,
    #[serde(default)]
    explicit: Option<bool>,
    #[serde(default)]
    fingerprint: Option<String>,
    #[serde(default)]
    identifiers: TrackIdentifiers,
    #[serde(default)]
    source_urls: BTreeMap<String, String>,
    #[serde(default)]
    liked: bool,
    #[serde(default)]
    playlists: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct ImportPlaylist {
    name: String,
    #[serde(default)]
    tracks: Vec<PlaylistTrackRef>,
    #[serde(default = "default_playlist_mode")]
    mode: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(untagged)]
enum PlaylistTrackRef {
    Value(String),
    Identity {
        #[serde(default)]
        file: Option<String>,
        #[serde(default)]
        fingerprint: Option<String>,
        #[serde(default)]
        identifiers: TrackIdentifiers,
    },
}

#[derive(Clone, Debug, Serialize)]
pub struct ImportReport {
    pub new_tracks: usize,
    pub existing_tracks: usize,
    pub skipped_tracks: usize,
    pub liked_updates: usize,
    pub playlist_updates: usize,
    pub imported_paths: Vec<String>,
    pub failures: Vec<ImportFailure>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ImportFailure {
    pub file: String,
    pub reason: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SyncLibraryState {
    #[serde(default)]
    pub tracks: Vec<SyncTrackState>,
    #[serde(default)]
    pub playlists: Vec<SyncPlaylistState>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SyncTrackState {
    pub id: String,
    pub fingerprint: String,
    #[serde(default)]
    pub is_liked: bool,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SyncPlaylistState {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub track_ids: Vec<String>,
    #[serde(default)]
    pub is_liked: bool,
}


mod artwork;
mod import;
mod ops;
mod scan;
mod state;
mod summaries;
mod util;

#[cfg(test)]
mod tests;

pub use artwork::ensure_cached_artwork_thumbnail;
pub use import::import_library_manifest_path;
pub use ops::{
    copy_track_to_liked_path, merge_sync_library_state_path, remove_liked_track_path,
    rename_playlist_path, set_track_playlist_memberships_path,
};
pub use scan::scan_library_path;

use artwork::*;
use import::*;
use scan::*;
use state::*;
use summaries::*;
use util::*;
