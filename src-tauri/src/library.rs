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
const ARTWORK_THUMBNAIL_SIZE: u32 = 96;
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

pub fn scan_library_path(root_path: impl AsRef<Path>) -> Result<Library, String> {
    let root = canonical_dir(root_path.as_ref())?;
    let mut state = read_library_state(&root)?;
    let mut state_dirty = false;
    let playlist_dirs = discover_playlist_dirs(&root)?;

    let mut playlists_by_id = BTreeMap::<String, Playlist>::new();
    let mut playlist_ids_by_name = BTreeMap::<String, String>::new();
    let mut liked_playlist_id = playlist_id_for_path(&root.join(LIKED_FOLDER_NAME));

    for (playlist_path, is_liked) in &playlist_dirs {
        let name = if *is_liked {
            LIKED_FOLDER_NAME.to_string()
        } else {
            file_stem_or_name(playlist_path)
        };
        let id = playlist_id_for_path(playlist_path);
        if *is_liked {
            liked_playlist_id = id.clone();
        } else {
            playlist_ids_by_name.insert(normalize(&name), id.clone());
        }

        playlists_by_id.insert(
            id.clone(),
            Playlist {
                id: id.clone(),
                name,
                path: path_to_string(playlist_path),
                track_ids: Vec::new(),
                is_liked: *is_liked,
            },
        );
    }

    playlists_by_id
        .entry(liked_playlist_id.clone())
        .or_insert(Playlist {
            id: liked_playlist_id.clone(),
            name: LIKED_FOLDER_NAME.to_string(),
            path: path_to_string(&root.join(LIKED_FOLDER_NAME)),
            track_ids: Vec::new(),
            is_liked: true,
        });

    for state_playlist in &state.playlists {
        let normalized_name = normalize(&state_playlist.name);
        if playlist_ids_by_name.contains_key(&normalized_name) {
            continue;
        }

        playlists_by_id
            .entry(state_playlist.id.clone())
            .or_insert(Playlist {
                id: state_playlist.id.clone(),
                name: state_playlist.name.clone(),
                path: path_to_string(&state_file_path(&root)),
                track_ids: Vec::new(),
                is_liked: false,
            });
        playlist_ids_by_name.insert(normalized_name, state_playlist.id.clone());
    }

    let mut pending_tracks = Vec::<PendingTrack>::new();

    for entry in WalkDir::new(&root)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_file())
    {
        let path = entry.path();
        if !is_mp3(path) {
            continue;
        }

        let direct_folder = direct_child_folder_name(&root, path);
        let is_liked_source = direct_folder
            .as_deref()
            .map(|name| name.eq_ignore_ascii_case(LIKED_FOLDER_NAME))
            .unwrap_or(false);
        let playlist_ids = direct_folder
            .as_ref()
            .and_then(|name| playlist_ids_by_name.get(&normalize(name)))
            .cloned()
            .into_iter()
            .collect::<Vec<_>>();

        pending_tracks.push(PendingTrack {
            track: read_track_with_state(
                &root,
                path,
                playlist_ids.clone(),
                is_liked_source,
                &state,
            )?,
            playlist_ids,
            playlist_is_liked: is_liked_source,
        });
    }

    for pending in &pending_tracks {
        let is_unliked = state
            .unliked_fingerprints
            .contains(&pending.track.fingerprint);
        if pending.playlist_is_liked
            && !is_unliked
            && state
                .liked_fingerprints
                .insert(pending.track.fingerprint.clone())
        {
            state_dirty = true;
        }
    }

    let mut tracks_by_fingerprint = BTreeMap::<String, Track>::new();
    for mut pending in pending_tracks {
        let is_unliked = state
            .unliked_fingerprints
            .contains(&pending.track.fingerprint);
        pending.track.is_liked = (pending.playlist_is_liked
            || state
                .liked_fingerprints
                .contains(&pending.track.fingerprint))
            && !is_unliked;

        if let Some(existing) = tracks_by_fingerprint.get_mut(&pending.track.fingerprint) {
            let mut merged_playlist_ids = existing.playlist_ids.clone();
            for playlist_id in &pending.playlist_ids {
                push_unique(&mut merged_playlist_ids, playlist_id.clone());
            }

            if should_replace_canonical_track(
                &root,
                existing,
                &pending.track,
                pending.playlist_is_liked,
            ) {
                pending.track.playlist_ids = merged_playlist_ids;
                pending.track.is_liked = pending.track.is_liked || existing.is_liked;
                *existing = pending.track;
            } else {
                existing.playlist_ids = merged_playlist_ids;
                existing.is_liked = existing.is_liked || pending.track.is_liked;
            }
        } else {
            tracks_by_fingerprint.insert(pending.track.fingerprint.clone(), pending.track);
        }
    }

    apply_state_playlists(
        &mut tracks_by_fingerprint,
        &mut playlists_by_id,
        &mut playlist_ids_by_name,
        &state,
        &root,
    );
    apply_removed_playlist_memberships(&mut tracks_by_fingerprint, &state);

    for track in tracks_by_fingerprint.values_mut() {
        if state.unliked_fingerprints.contains(&track.fingerprint) {
            track.is_liked = false;
        }

        if track.is_liked {
            push_unique(&mut track.playlist_ids, liked_playlist_id.clone());
        }

        for playlist_id in &track.playlist_ids {
            if let Some(playlist) = playlists_by_id.get_mut(playlist_id) {
                push_unique(&mut playlist.track_ids, track.id.clone());
            }
        }
    }

    let mut tracks = tracks_by_fingerprint.into_values().collect::<Vec<_>>();
    tracks.sort_by(|a, b| {
        a.artist
            .to_lowercase()
            .cmp(&b.artist.to_lowercase())
            .then(a.album.to_lowercase().cmp(&b.album.to_lowercase()))
            .then(a.track_number.cmp(&b.track_number))
            .then(a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });

    for playlist in playlists_by_id.values_mut() {
        playlist.track_ids.dedup();
        playlist.track_ids.sort_by_key(|id| {
            tracks
                .iter()
                .position(|track| &track.id == id)
                .unwrap_or(usize::MAX)
        });
    }

    let mut playlists = playlists_by_id.into_values().collect::<Vec<_>>();
    playlists.sort_by(|a, b| {
        b.is_liked
            .cmp(&a.is_liked)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    let stats = summarize_library(&tracks, &playlists);
    let artists = summarize_artists(&tracks);
    let albums = summarize_albums(&tracks);

    if state_dirty {
        write_library_state(&root, &state)?;
    }

    Ok(Library {
        root_path: path_to_string(&root),
        scanned_at: unix_now(),
        stats,
        artists,
        albums,
        playlists,
        tracks,
    })
}

pub fn copy_track_to_liked_path(
    root_path: impl AsRef<Path>,
    track_path: impl AsRef<Path>,
) -> Result<String, String> {
    let root = canonical_dir(root_path.as_ref())?;
    let source = canonical_file(track_path.as_ref())?;

    if !is_mp3(&source) {
        return Err("Only .mp3 files can be liked.".to_string());
    }

    let mut state = read_library_state(&root)?;
    let track = read_track_with_state(&root, &source, Vec::new(), false, &state)?;
    state.liked_fingerprints.insert(track.fingerprint);
    write_library_state(&root, &state)?;
    Ok(path_to_string(&source))
}

pub fn remove_liked_track_path(
    root_path: impl AsRef<Path>,
    track_path: impl AsRef<Path>,
) -> Result<bool, String> {
    let root = canonical_dir(root_path.as_ref())?;
    let track_path = canonical_file(track_path.as_ref())?;

    if !is_mp3(&track_path) {
        return Err("Only .mp3 files can be removed from liked songs.".to_string());
    }

    let mut state = read_library_state(&root)?;
    let track = read_track_with_state(&root, &track_path, Vec::new(), false, &state)?;
    let changed = state.liked_fingerprints.remove(&track.fingerprint);
    if changed {
        write_library_state(&root, &state)?;
    }
    Ok(changed)
}

pub fn set_track_playlist_memberships_path(
    root_path: impl AsRef<Path>,
    track_path: impl AsRef<Path>,
    playlist_ids: Vec<String>,
) -> Result<(), String> {
    let root = canonical_dir(root_path.as_ref())?;
    let track_path = canonical_file(track_path.as_ref())?;

    if !is_mp3(&track_path) {
        return Err("Only .mp3 files can be edited.".to_string());
    }

    let library = scan_library_path(&root)?;
    let playlists_by_id = library
        .playlists
        .iter()
        .map(|playlist| (playlist.id.clone(), playlist))
        .collect::<BTreeMap<_, _>>();
    let selected_playlist_ids = playlist_ids
        .into_iter()
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty())
        .collect::<BTreeSet<_>>();

    for playlist_id in &selected_playlist_ids {
        if !playlists_by_id.contains_key(playlist_id) {
            return Err("One of those playlists no longer exists.".to_string());
        }
    }

    let mut state = read_library_state(&root)?;
    let track = read_track_with_state(&root, &track_path, Vec::new(), false, &state)?;
    let current_playlist_ids = library
        .tracks
        .iter()
        .find(|candidate| candidate.fingerprint == track.fingerprint)
        .map(|candidate| {
            candidate
                .playlist_ids
                .iter()
                .cloned()
                .collect::<BTreeSet<_>>()
        })
        .unwrap_or_default();
    let liked_playlist_id = library
        .playlists
        .iter()
        .find(|playlist| playlist.is_liked)
        .map(|playlist| playlist.id.clone())
        .unwrap_or_else(|| playlist_id_for_path(&root.join(LIKED_FOLDER_NAME)));

    if selected_playlist_ids.contains(&liked_playlist_id) {
        state.unliked_fingerprints.remove(&track.fingerprint);
        state.liked_fingerprints.insert(track.fingerprint.clone());
    } else {
        state.liked_fingerprints.remove(&track.fingerprint);
        state.unliked_fingerprints.insert(track.fingerprint.clone());
    }

    for playlist in library
        .playlists
        .iter()
        .filter(|playlist| !playlist.is_liked)
    {
        if selected_playlist_ids.contains(&playlist.id) {
            remove_removed_playlist_membership(&mut state, &playlist.id, &track.fingerprint);
            let state_playlist = state_playlist_mut_by_id(&mut state, &playlist.id, &playlist.name);
            push_unique(
                &mut state_playlist.track_fingerprints,
                track.fingerprint.clone(),
            );
        } else {
            let removed_from_state =
                remove_state_playlist_track_by_id(&mut state, &playlist.id, &track.fingerprint);
            if removed_from_state || current_playlist_ids.contains(&playlist.id) {
                add_removed_playlist_membership(&mut state, &playlist.id, &track.fingerprint);
            }
        }
    }

    write_library_state(&root, &state)
}

pub fn merge_sync_library_state_path(
    root_path: impl AsRef<Path>,
    remote: SyncLibraryState,
) -> Result<(), String> {
    let root = canonical_dir(root_path.as_ref())?;
    let mut state = read_library_state(&root)?;
    let fingerprints_by_remote_id = remote
        .tracks
        .iter()
        .map(|track| (track.id.clone(), track.fingerprint.clone()))
        .collect::<BTreeMap<_, _>>();

    for track in &remote.tracks {
        if track.fingerprint.trim().is_empty() {
            continue;
        }

        if track.is_liked {
            state.unliked_fingerprints.remove(&track.fingerprint);
            state.liked_fingerprints.insert(track.fingerprint.clone());
        } else {
            state.liked_fingerprints.remove(&track.fingerprint);
            state.unliked_fingerprints.insert(track.fingerprint.clone());
        }
    }

    for playlist in &remote.playlists {
        if playlist.is_liked {
            continue;
        }

        let clean_name = clean_plain_text(Some(&playlist.name))
            .unwrap_or_else(|| "Synced Playlist".to_string());
        let playlist_id = if playlist.id.trim().is_empty() {
            state_playlist_id_for_name(&clean_name)
        } else {
            playlist.id.clone()
        };
        let state_playlist = state_playlist_mut_by_id(&mut state, &playlist_id, &clean_name);
        state_playlist.track_fingerprints = playlist
            .track_ids
            .iter()
            .filter_map(|track_id| fingerprints_by_remote_id.get(track_id))
            .fold(Vec::<String>::new(), |mut fingerprints, fingerprint| {
                push_unique(&mut fingerprints, fingerprint.clone());
                fingerprints
            });
    }

    write_library_state(&root, &state)
}

pub fn rename_playlist_path(
    root_path: impl AsRef<Path>,
    playlist_id: impl AsRef<str>,
    name: impl AsRef<str>,
) -> Result<(), String> {
    let root = canonical_dir(root_path.as_ref())?;
    let playlist_id = playlist_id.as_ref().trim();
    if playlist_id.is_empty() {
        return Err("Playlist id cannot be empty.".to_string());
    }

    let clean_name = clean_plain_text(Some(name.as_ref()))
        .ok_or_else(|| "Playlist title cannot be empty.".to_string())?;
    if normalize(&clean_name) == normalize(LIKED_FOLDER_NAME) {
        return Err("Liked Songs is reserved.".to_string());
    }

    let library = scan_library_path(&root)?;
    let playlist = library
        .playlists
        .iter()
        .find(|playlist| playlist.id == playlist_id)
        .ok_or_else(|| "Playlist was not found.".to_string())?;
    if playlist.is_liked {
        return Err("Liked Songs cannot be renamed.".to_string());
    }

    let normalized_name = normalize(&clean_name);
    if library.playlists.iter().any(|playlist| {
        !playlist.is_liked
            && playlist.id != playlist_id
            && normalize(&playlist.name) == normalized_name
    }) {
        return Err("Another playlist already uses that title.".to_string());
    }

    let mut state = read_library_state(&root)?;
    if let Some(existing) = state
        .playlists
        .iter_mut()
        .find(|playlist| playlist.id == playlist_id)
    {
        existing.name = clean_name;
    } else {
        state.playlists.push(StatePlaylist {
            id: playlist_id.to_string(),
            name: clean_name,
            track_fingerprints: Vec::new(),
        });
    }

    write_library_state(&root, &state)
}

pub fn import_library_manifest_path(
    root_path: impl AsRef<Path>,
    manifest_path: impl AsRef<Path>,
) -> Result<ImportReport, String> {
    let root = canonical_dir(root_path.as_ref())?;
    let manifest_path = canonical_file(manifest_path.as_ref())?;
    let manifest_dir = manifest_path
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| "Import manifest must live in a folder.".to_string())?;
    let manifest_text = fs::read_to_string(&manifest_path)
        .map_err(|err| format!("Could not read import manifest: {err}"))?;
    let manifest: ImportManifest = serde_json::from_str(&manifest_text)
        .map_err(|err| format!("Could not parse import manifest JSON: {err}"))?;

    if !manifest.schema.is_empty() && manifest.schema != IMPORT_SCHEMA {
        return Err(format!(
            "Unsupported import schema '{}'. Expected {IMPORT_SCHEMA}.",
            manifest.schema
        ));
    }

    let mut report = ImportReport {
        new_tracks: 0,
        existing_tracks: 0,
        skipped_tracks: 0,
        liked_updates: 0,
        playlist_updates: 0,
        imported_paths: Vec::new(),
        failures: Vec::new(),
    };

    let existing_library = scan_library_path(&root)?;
    let mut known_fingerprints = existing_library
        .tracks
        .iter()
        .map(|track| track.fingerprint.clone())
        .collect::<BTreeSet<_>>();
    let mut state = read_library_state(&root)?;
    let base_path = manifest
        .source
        .as_ref()
        .and_then(|source| source.base_path.as_deref());
    let mut fingerprints_by_file = BTreeMap::<String, String>::new();
    let mut fingerprints_by_identity = BTreeMap::<String, String>::new();
    let mut manifest_tracks_by_file = BTreeMap::<String, ImportTrack>::new();

    for track in manifest.tracks {
        manifest_tracks_by_file.insert(track.file.clone(), track);
    }

    for playlist in &manifest.playlists {
        for track_ref in &playlist.tracks {
            let Some(file) = track_ref.file() else {
                continue;
            };

            manifest_tracks_by_file
                .entry(file.to_string())
                .or_insert_with(|| ImportTrack {
                    file: file.to_string(),
                    title: None,
                    artist: None,
                    album: None,
                    album_artist: None,
                    genre: None,
                    year: None,
                    track_number: None,
                    disc_number: None,
                    duration_seconds: None,
                    duration_ms: None,
                    explicit: None,
                    fingerprint: None,
                    identifiers: TrackIdentifiers::default(),
                    source_urls: BTreeMap::new(),
                    liked: false,
                    playlists: Vec::new(),
                });
        }
    }

    for import_track in manifest_tracks_by_file.values() {
        let source_path = resolve_manifest_file(&manifest_dir, base_path, &import_track.file);
        let source = match canonical_file(&source_path) {
            Ok(source) => source,
            Err(err) => {
                report.skipped_tracks += 1;
                report.failures.push(ImportFailure {
                    file: import_track.file.clone(),
                    reason: err,
                });
                continue;
            }
        };

        if !is_mp3(&source) {
            report.skipped_tracks += 1;
            report.failures.push(ImportFailure {
                file: import_track.file.clone(),
                reason: "Only .mp3 files can be imported.".to_string(),
            });
            continue;
        }

        let mut track = match read_track(&root, &source, Vec::new(), false, false) {
            Ok(track) => track,
            Err(err) => {
                report.skipped_tracks += 1;
                report.failures.push(ImportFailure {
                    file: import_track.file.clone(),
                    reason: err,
                });
                continue;
            }
        };
        apply_import_metadata(&mut track, import_track);

        if let Some(existing_fingerprint) =
            matching_existing_fingerprint(&known_fingerprints, &track, import_track)
        {
            track.fingerprint = existing_fingerprint;
            track.id = track_id_for_fingerprint(&track.fingerprint);
            report.existing_tracks += 1;
        } else {
            let destination = managed_import_destination(&root, &track, &source)?;
            fs::copy(&source, &destination)
                .map_err(|err| format!("Could not copy imported track: {err}"))?;
            state.managed_tracks.insert(
                relative_path_key(&root, &destination),
                state_track_metadata_from_import(&track, import_track),
            );
            known_fingerprints.insert(track.fingerprint.clone());
            report.new_tracks += 1;
            report.imported_paths.push(path_to_string(&destination));
        }

        if import_track.liked && state.liked_fingerprints.insert(track.fingerprint.clone()) {
            report.liked_updates += 1;
        }

        for playlist_name in &import_track.playlists {
            if add_state_playlist_track(&mut state, playlist_name, &track.fingerprint, false) {
                report.playlist_updates += 1;
            }
        }

        fingerprints_by_file.insert(import_track.file.clone(), track.fingerprint.clone());
        for identity in import_track_identity_aliases(import_track, &track) {
            fingerprints_by_identity.insert(identity, track.fingerprint.clone());
        }
    }

    let mut replaced_playlists = BTreeSet::<String>::new();
    for playlist in &manifest.playlists {
        let replace = playlist.mode.eq_ignore_ascii_case("replace");
        let playlist_id = state_playlist_id_for_name(&playlist.name);
        if replace && replaced_playlists.insert(playlist_id) {
            clear_state_playlist_tracks(&mut state, &playlist.name);
        }

        for track_ref in &playlist.tracks {
            let Some(fingerprint) = resolve_playlist_track_ref(
                track_ref,
                &fingerprints_by_file,
                &fingerprints_by_identity,
            ) else {
                report.skipped_tracks += 1;
                report.failures.push(ImportFailure {
                    file: track_ref.label(),
                    reason: format!(
                        "Playlist '{}' references a track that could not be imported.",
                        playlist.name
                    ),
                });
                continue;
            };

            if add_state_playlist_track(&mut state, &playlist.name, fingerprint, false) {
                report.playlist_updates += 1;
            }
        }
    }

    write_library_state(&root, &state)?;
    Ok(report)
}

fn default_playlist_mode() -> String {
    "append".to_string()
}

fn default_library_state() -> LibraryState {
    LibraryState {
        schema_version: 1,
        liked_fingerprints: BTreeSet::new(),
        unliked_fingerprints: BTreeSet::new(),
        playlists: Vec::new(),
        removed_playlist_memberships: Vec::new(),
        managed_tracks: BTreeMap::new(),
    }
}

fn state_file_path(root: &Path) -> PathBuf {
    root.join(STATE_DIR_NAME).join(STATE_FILE_NAME)
}

fn managed_audio_dir(root: &Path) -> PathBuf {
    root.join(STATE_DIR_NAME).join(MANAGED_AUDIO_DIR_NAME)
}

fn artwork_cache_dir(root: &Path) -> PathBuf {
    root.join(STATE_DIR_NAME)
        .join(CACHE_DIR_NAME)
        .join(ARTWORK_DIR_NAME)
}

fn read_library_state(root: &Path) -> Result<LibraryState, String> {
    let path = state_file_path(root);
    if !path.exists() {
        return Ok(default_library_state());
    }

    let text =
        fs::read_to_string(&path).map_err(|err| format!("Could not read Loud state: {err}"))?;
    let mut state: LibraryState =
        serde_json::from_str(&text).map_err(|err| format!("Could not parse Loud state: {err}"))?;

    if state.schema_version == 0 {
        state.schema_version = 1;
    }

    Ok(state)
}

fn write_library_state(root: &Path, state: &LibraryState) -> Result<(), String> {
    let path = state_file_path(root);
    let parent = path
        .parent()
        .ok_or_else(|| "Could not resolve Loud state folder.".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|err| format!("Could not create Loud state folder: {err}"))?;
    let text = serde_json::to_string_pretty(state)
        .map_err(|err| format!("Could not serialize Loud state: {err}"))?;
    fs::write(&path, text).map_err(|err| format!("Could not write Loud state: {err}"))
}

fn direct_child_folder_name(root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    let mut components = relative.components();
    let first = components.next()?;
    if components.next().is_none() {
        return None;
    }

    let folder = PathBuf::from(first.as_os_str());
    folder
        .file_name()
        .and_then(|name| name.to_str())
        .map(str::to_string)
}

fn should_replace_canonical_track(
    root: &Path,
    existing: &Track,
    candidate: &Track,
    candidate_is_liked_source: bool,
) -> bool {
    let existing_score = canonical_source_score(root, Path::new(&existing.path), existing.is_liked);
    let candidate_score =
        canonical_source_score(root, Path::new(&candidate.path), candidate_is_liked_source);
    candidate_score > existing_score
}

fn canonical_source_score(root: &Path, path: &Path, is_liked_source: bool) -> u8 {
    if is_liked_source {
        return 0;
    }

    if path.starts_with(managed_audio_dir(root)) {
        return 1;
    }

    2
}

fn summarize_library(tracks: &[Track], playlists: &[Playlist]) -> LibraryStats {
    let artists = tracks
        .iter()
        .map(|track| normalize(&track.artist))
        .collect::<BTreeSet<_>>();
    let albums = tracks
        .iter()
        .map(|track| {
            format!(
                "{}|{}",
                normalize(track.album_artist.as_deref().unwrap_or(&track.artist)),
                normalize(&track.album)
            )
        })
        .collect::<BTreeSet<_>>();

    LibraryStats {
        track_count: tracks.len(),
        playlist_count: playlists
            .iter()
            .filter(|playlist| !playlist.is_liked)
            .count(),
        liked_count: tracks.iter().filter(|track| track.is_liked).count(),
        artist_count: artists.len(),
        album_count: albums.len(),
        duration_seconds: tracks
            .iter()
            .map(|track| track.duration_seconds.unwrap_or(0.0))
            .sum(),
    }
}

fn summarize_artists(tracks: &[Track]) -> Vec<ArtistSummary> {
    let mut artists = BTreeMap::<String, Vec<&Track>>::new();
    for track in tracks {
        artists
            .entry(normalize(&track.artist))
            .or_default()
            .push(track);
    }

    let mut summaries = artists
        .into_values()
        .map(|tracks| {
            let albums = tracks
                .iter()
                .map(|track| normalize(&track.album))
                .collect::<BTreeSet<_>>();
            ArtistSummary {
                name: tracks
                    .first()
                    .map(|track| track.artist.clone())
                    .unwrap_or_else(|| "Unknown Artist".to_string()),
                track_count: tracks.len(),
                album_count: albums.len(),
                duration_seconds: tracks
                    .iter()
                    .map(|track| track.duration_seconds.unwrap_or(0.0))
                    .sum(),
            }
        })
        .collect::<Vec<_>>();

    summaries.sort_by(|a, b| {
        b.track_count
            .cmp(&a.track_count)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    summaries
}

fn summarize_albums(tracks: &[Track]) -> Vec<AlbumSummary> {
    let mut albums = BTreeMap::<String, Vec<&Track>>::new();
    for track in tracks {
        let album_artist = track.album_artist.as_deref().unwrap_or(&track.artist);
        albums
            .entry(format!(
                "{}|{}",
                normalize(album_artist),
                normalize(&track.album)
            ))
            .or_default()
            .push(track);
    }

    let mut summaries = albums
        .into_values()
        .map(|tracks| AlbumSummary {
            name: tracks
                .first()
                .map(|track| track.album.clone())
                .unwrap_or_else(|| "Unknown Album".to_string()),
            artist: tracks
                .first()
                .map(|track| {
                    track
                        .album_artist
                        .clone()
                        .unwrap_or_else(|| track.artist.clone())
                })
                .unwrap_or_else(|| "Unknown Artist".to_string()),
            track_count: tracks.len(),
            duration_seconds: tracks
                .iter()
                .map(|track| track.duration_seconds.unwrap_or(0.0))
                .sum(),
            artwork_url: None,
            artwork: tracks.iter().find_map(|track| track.artwork.clone()),
        })
        .collect::<Vec<_>>();

    summaries.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    summaries
}

fn apply_state_playlists(
    tracks_by_fingerprint: &mut BTreeMap<String, Track>,
    playlists_by_id: &mut BTreeMap<String, Playlist>,
    playlist_ids_by_name: &mut BTreeMap<String, String>,
    state: &LibraryState,
    root: &Path,
) {
    for state_playlist in &state.playlists {
        let normalized_name = normalize(&state_playlist.name);
        let playlist_id = if playlists_by_id.contains_key(&state_playlist.id) {
            state_playlist.id.clone()
        } else {
            playlist_ids_by_name
                .get(&normalized_name)
                .cloned()
                .unwrap_or_else(|| state_playlist.id.clone())
        };

        if let Some(playlist) = playlists_by_id.get_mut(&playlist_id) {
            if !playlist.is_liked {
                playlist.name = state_playlist.name.clone();
            }
        } else {
            playlists_by_id.insert(
                playlist_id.clone(),
                Playlist {
                    id: playlist_id.clone(),
                    name: state_playlist.name.clone(),
                    path: path_to_string(&state_file_path(root)),
                    track_ids: Vec::new(),
                    is_liked: false,
                },
            );
        }
        playlist_ids_by_name.insert(normalized_name, playlist_id.clone());

        for fingerprint in &state_playlist.track_fingerprints {
            if let Some(track) = tracks_by_fingerprint.get_mut(fingerprint) {
                push_unique(&mut track.playlist_ids, playlist_id.clone());
            }
        }
    }
}

fn apply_removed_playlist_memberships(
    tracks_by_fingerprint: &mut BTreeMap<String, Track>,
    state: &LibraryState,
) {
    for membership in &state.removed_playlist_memberships {
        if let Some(track) = tracks_by_fingerprint.get_mut(&membership.track_fingerprint) {
            track
                .playlist_ids
                .retain(|playlist_id| playlist_id != &membership.playlist_id);
        }
    }
}

fn state_playlist_id_for_name(name: &str) -> String {
    format!("playlist_state_{}", stable_id(&normalize(name)))
}

fn state_playlist_mut_by_id<'a>(
    state: &'a mut LibraryState,
    id: &str,
    name: &str,
) -> &'a mut StatePlaylist {
    let clean_name = clean_plain_text(Some(name)).unwrap_or_else(|| "Playlist".to_string());
    let normalized_name = normalize(&clean_name);

    if let Some(index) = state
        .playlists
        .iter()
        .position(|playlist| playlist.id == id || normalize(&playlist.name) == normalized_name)
    {
        let playlist = &mut state.playlists[index];
        playlist.id = id.to_string();
        playlist.name = clean_name;
        return playlist;
    }

    state.playlists.push(StatePlaylist {
        id: id.to_string(),
        name: clean_name,
        track_fingerprints: Vec::new(),
    });
    state
        .playlists
        .last_mut()
        .expect("state playlist was just pushed")
}

fn state_playlist_mut<'a>(state: &'a mut LibraryState, name: &str) -> &'a mut StatePlaylist {
    let clean_name = clean_plain_text(Some(name)).unwrap_or_else(|| "Imported".to_string());
    let normalized_name = normalize(&clean_name);
    let id = state_playlist_id_for_name(&clean_name);
    if let Some(index) = state
        .playlists
        .iter()
        .position(|playlist| playlist.id == id || normalize(&playlist.name) == normalized_name)
    {
        return &mut state.playlists[index];
    }

    state.playlists.push(StatePlaylist {
        id,
        name: clean_name,
        track_fingerprints: Vec::new(),
    });
    state
        .playlists
        .last_mut()
        .expect("state playlist was just pushed")
}

fn clear_state_playlist_tracks(state: &mut LibraryState, name: &str) {
    state_playlist_mut(state, name).track_fingerprints.clear();
}

fn remove_state_playlist_track_by_id(
    state: &mut LibraryState,
    playlist_id: &str,
    fingerprint: &str,
) -> bool {
    let Some(playlist) = state
        .playlists
        .iter_mut()
        .find(|playlist| playlist.id == playlist_id)
    else {
        return false;
    };

    let original_len = playlist.track_fingerprints.len();
    playlist
        .track_fingerprints
        .retain(|existing| existing != fingerprint);
    playlist.track_fingerprints.len() != original_len
}

fn add_state_playlist_track(
    state: &mut LibraryState,
    name: &str,
    fingerprint: &str,
    replace: bool,
) -> bool {
    let playlist = state_playlist_mut(state, name);
    if replace {
        playlist.track_fingerprints.clear();
    }

    if playlist
        .track_fingerprints
        .iter()
        .any(|existing| existing == fingerprint)
    {
        return false;
    }

    playlist.track_fingerprints.push(fingerprint.to_string());
    true
}

fn add_removed_playlist_membership(state: &mut LibraryState, playlist_id: &str, fingerprint: &str) {
    if state.removed_playlist_memberships.iter().any(|membership| {
        membership.playlist_id == playlist_id && membership.track_fingerprint == fingerprint
    }) {
        return;
    }

    state
        .removed_playlist_memberships
        .push(StatePlaylistMembership {
            playlist_id: playlist_id.to_string(),
            track_fingerprint: fingerprint.to_string(),
        });
}

fn remove_removed_playlist_membership(
    state: &mut LibraryState,
    playlist_id: &str,
    fingerprint: &str,
) -> bool {
    let original_len = state.removed_playlist_memberships.len();
    state.removed_playlist_memberships.retain(|membership| {
        membership.playlist_id != playlist_id || membership.track_fingerprint != fingerprint
    });
    state.removed_playlist_memberships.len() != original_len
}

fn push_unique<T: Eq>(items: &mut Vec<T>, item: T) {
    if !items.iter().any(|existing| existing == &item) {
        items.push(item);
    }
}

impl PlaylistTrackRef {
    fn file(&self) -> Option<&str> {
        match self {
            PlaylistTrackRef::Value(value) => Some(value),
            PlaylistTrackRef::Identity { file, .. } => file.as_deref(),
        }
    }

    fn label(&self) -> String {
        match self {
            PlaylistTrackRef::Value(value) => value.clone(),
            PlaylistTrackRef::Identity {
                file,
                fingerprint,
                identifiers,
            } => file
                .clone()
                .or_else(|| fingerprint.clone())
                .or_else(|| {
                    identifier_identity_candidates(identifiers)
                        .into_iter()
                        .next()
                })
                .unwrap_or_else(|| "unknown playlist ref".to_string()),
        }
    }
}

fn resolve_playlist_track_ref<'a>(
    track_ref: &PlaylistTrackRef,
    fingerprints_by_file: &'a BTreeMap<String, String>,
    fingerprints_by_identity: &'a BTreeMap<String, String>,
) -> Option<&'a String> {
    match track_ref {
        PlaylistTrackRef::Value(value) => fingerprints_by_file
            .get(value)
            .or_else(|| fingerprints_by_identity.get(value)),
        PlaylistTrackRef::Identity {
            file,
            fingerprint,
            identifiers,
        } => file
            .as_ref()
            .and_then(|file| fingerprints_by_file.get(file))
            .or_else(|| {
                fingerprint
                    .as_deref()
                    .and_then(|value| clean_plain_text(Some(value)))
                    .and_then(|value| fingerprints_by_identity.get(&value))
            })
            .or_else(|| {
                identifier_identity_candidates(identifiers)
                    .into_iter()
                    .find_map(|identity| fingerprints_by_identity.get(&identity))
            }),
    }
}

fn resolve_manifest_file(manifest_dir: &Path, base_path: Option<&str>, file: &str) -> PathBuf {
    let file_path = PathBuf::from(file);
    if file_path.is_absolute() {
        return file_path;
    }

    match base_path {
        Some(base_path) if !base_path.trim().is_empty() => {
            manifest_dir.join(base_path).join(file_path)
        }
        _ => manifest_dir.join(file_path),
    }
}

fn apply_import_metadata(track: &mut Track, import_track: &ImportTrack) {
    if let Some(value) = clean_plain_text(import_track.title.as_deref()) {
        track.title = value;
    }
    if let Some(value) = clean_plain_text(import_track.artist.as_deref()) {
        track.artist = value;
    }
    if let Some(value) = clean_plain_text(import_track.album.as_deref()) {
        track.album = value;
    }
    if let Some(value) = clean_plain_text(import_track.album_artist.as_deref()) {
        track.album_artist = Some(value);
    }
    if let Some(value) = clean_plain_text(import_track.genre.as_deref()) {
        track.genre = Some(value);
    }
    if let Some(year) = import_track.year {
        track.year = Some(year);
    }
    if let Some(track_number) = import_track.track_number {
        track.track_number = Some(track_number);
    }
    if let Some(duration_seconds) = import_track.duration_seconds.or_else(|| {
        import_track
            .duration_ms
            .map(|duration| duration as f64 / 1000.0)
    }) {
        track.duration_seconds = Some(duration_seconds);
    }

    track.fingerprint = canonical_import_fingerprint(import_track, track);
    track.id = track_id_for_fingerprint(&track.fingerprint);
}

fn canonical_import_fingerprint(import_track: &ImportTrack, track: &Track) -> String {
    import_track
        .fingerprint
        .as_deref()
        .and_then(|fingerprint| clean_plain_text(Some(fingerprint)))
        .or_else(|| primary_identifier_identity(&import_track.identifiers))
        .unwrap_or_else(|| fingerprint_for(&track.title, &track.artist, &track.album))
}

fn matching_existing_fingerprint(
    known_fingerprints: &BTreeSet<String>,
    track: &Track,
    import_track: &ImportTrack,
) -> Option<String> {
    let loud_metadata_fingerprint = fingerprint_for(&track.title, &track.artist, &track.album);
    import_track_identity_aliases(import_track, track)
        .into_iter()
        .chain([loud_metadata_fingerprint])
        .find(|fingerprint| known_fingerprints.contains(fingerprint))
}

fn import_track_identity_aliases(import_track: &ImportTrack, track: &Track) -> Vec<String> {
    let mut aliases = Vec::new();

    if let Some(fingerprint) = import_track
        .fingerprint
        .as_deref()
        .and_then(|fingerprint| clean_plain_text(Some(fingerprint)))
    {
        push_unique(&mut aliases, fingerprint);
    }

    for identity in identifier_identity_candidates(&import_track.identifiers) {
        push_unique(&mut aliases, identity);
    }

    push_unique(&mut aliases, track.fingerprint.clone());
    push_unique(
        &mut aliases,
        fingerprint_for(&track.title, &track.artist, &track.album),
    );
    aliases
}

fn primary_identifier_identity(identifiers: &TrackIdentifiers) -> Option<String> {
    prefixed_identifier("isrc", identifiers.isrc.as_deref(), true)
        .or_else(|| {
            prefixed_identifier(
                "mbid",
                identifiers.musicbrainz_recording_id.as_deref(),
                false,
            )
        })
        .or_else(|| {
            prefixed_identifier(
                "spotify:track",
                identifiers.spotify_track_id.as_deref(),
                false,
            )
        })
        .or_else(|| prefixed_identifier("youtube", identifiers.youtube_video_id.as_deref(), false))
}

fn identifier_identity_candidates(identifiers: &TrackIdentifiers) -> Vec<String> {
    let mut candidates = Vec::new();

    if let Some(value) = prefixed_identifier("isrc", identifiers.isrc.as_deref(), true) {
        candidates.push(value);
    }
    if let Some(value) = prefixed_identifier(
        "mbid",
        identifiers.musicbrainz_recording_id.as_deref(),
        false,
    ) {
        candidates.push(value);
    }
    if let Some(value) = prefixed_identifier(
        "spotify:track",
        identifiers.spotify_track_id.as_deref(),
        false,
    ) {
        candidates.push(value);
    }
    if let Some(value) =
        prefixed_identifier("youtube", identifiers.youtube_video_id.as_deref(), false)
    {
        candidates.push(value);
    }

    for (key, value) in &identifiers.extra {
        if key == "spotify_album_id" {
            continue;
        }
        if let Some(value) = prefixed_identifier(key, Some(value), false) {
            candidates.push(value);
        }
    }

    candidates
}

fn prefixed_identifier(prefix: &str, value: Option<&str>, uppercase: bool) -> Option<String> {
    let value = clean_plain_text(value)?;
    let value = if uppercase {
        value.to_uppercase()
    } else {
        value
    };
    Some(format!("{prefix}:{value}"))
}

fn apply_state_track_metadata(track: &mut Track, metadata: &StateTrackMetadata) {
    track.fingerprint = metadata.fingerprint.clone();
    track.id = track_id_for_fingerprint(&track.fingerprint);
    track.title = metadata.title.clone();
    track.artist = metadata.artist.clone();
    track.album = metadata.album.clone();
    track.album_artist = metadata.album_artist.clone();
    track.genre = metadata.genre.clone();
    track.year = metadata.year;
    track.track_number = metadata.track_number;
    track.duration_seconds = metadata.duration_seconds;
}

fn state_track_metadata_from_import(
    track: &Track,
    import_track: &ImportTrack,
) -> StateTrackMetadata {
    StateTrackMetadata {
        fingerprint: track.fingerprint.clone(),
        title: track.title.clone(),
        artist: track.artist.clone(),
        album: track.album.clone(),
        album_artist: track.album_artist.clone(),
        genre: track.genre.clone(),
        year: track.year,
        track_number: track.track_number,
        disc_number: import_track.disc_number,
        duration_seconds: track.duration_seconds,
        explicit: import_track.explicit,
        identifiers: import_track.identifiers.clone(),
        source_urls: import_track.source_urls.clone(),
    }
}

fn relative_path_key(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .map(path_to_string)
        .unwrap_or_else(|_| path_to_string(path))
}

fn managed_import_destination(
    root: &Path,
    track: &Track,
    source: &Path,
) -> Result<PathBuf, String> {
    let file_name = source
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "Imported track path does not have a file name.".to_string())?;
    let destination = managed_audio_dir(root)
        .join(safe_path_component(&track.artist))
        .join(safe_path_component(&track.album))
        .join(safe_path_component(file_name));

    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("Could not create import destination: {err}"))?;
    }

    Ok(unique_destination(destination))
}

fn safe_path_component(value: &str) -> String {
    let sanitized = value
        .chars()
        .map(|character| match character {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            character if character.is_control() => '_',
            character => character,
        })
        .collect::<String>()
        .trim()
        .trim_matches('.')
        .to_string();

    if sanitized.is_empty() {
        "Unknown".to_string()
    } else {
        sanitized
    }
}

fn discover_playlist_dirs(root: &Path) -> Result<Vec<(PathBuf, bool)>, String> {
    let mut dirs = Vec::new();
    for entry in fs::read_dir(root).map_err(|err| format!("Could not read music folder: {err}"))? {
        let entry = entry.map_err(|err| format!("Could not read folder entry: {err}"))?;
        let file_type = entry
            .file_type()
            .map_err(|err| format!("Could not read file type: {err}"))?;

        if !file_type.is_dir() {
            continue;
        }

        let path = entry.path();
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .map(|name| name == STATE_DIR_NAME)
            .unwrap_or(false)
        {
            continue;
        }

        let is_liked = path
            .file_name()
            .and_then(|name| name.to_str())
            .map(|name| name.eq_ignore_ascii_case(LIKED_FOLDER_NAME))
            .unwrap_or(false);
        dirs.push((path, is_liked));
    }
    dirs.sort_by(|a, b| {
        b.1.cmp(&a.1).then(
            file_stem_or_name(&a.0)
                .to_lowercase()
                .cmp(&file_stem_or_name(&b.0).to_lowercase()),
        )
    });
    Ok(dirs)
}

fn read_track_with_state(
    root: &Path,
    path: &Path,
    playlist_ids: Vec<String>,
    playlist_is_liked: bool,
    state: &LibraryState,
) -> Result<Track, String> {
    let mut track = read_track(root, path, playlist_ids, playlist_is_liked, true)?;
    if let Some(metadata) = state.managed_tracks.get(&relative_path_key(root, path)) {
        apply_state_track_metadata(&mut track, metadata);
    }
    Ok(track)
}

fn read_track(
    root: &Path,
    path: &Path,
    playlist_ids: Vec<String>,
    playlist_is_liked: bool,
    cache_artwork: bool,
) -> Result<Track, String> {
    let metadata =
        fs::metadata(path).map_err(|err| format!("Could not read track metadata: {err}"))?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("Unknown file")
        .to_string();
    let fallback_title = path
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or(&file_name)
        .to_string();

    let mut title = fallback_title;
    let mut artist = "Unknown Artist".to_string();
    let mut album = "Unknown Album".to_string();
    let mut album_artist = None;
    let mut genre = None;
    let mut year = None;
    let mut track_number = None;
    let mut duration_seconds = None;
    let mut artwork = None;

    if let Ok(tagged_file) = Probe::open(path).and_then(|probe| probe.read()) {
        let properties = tagged_file.properties();
        let duration = properties.duration();
        if duration.as_millis() > 0 {
            duration_seconds = Some(duration.as_secs_f64());
        }

        if let Some(tag) = tagged_file
            .primary_tag()
            .or_else(|| tagged_file.first_tag())
        {
            title = clean_text(tag.title()).unwrap_or(title);
            artist = clean_text(tag.artist()).unwrap_or(artist);
            album = clean_text(tag.album()).unwrap_or(album);
            album_artist = tag.get_string(ItemKey::AlbumArtist).map(str::to_string);
            genre = clean_text(tag.genre());
            year = tag.date().map(|date| date.year);
            track_number = tag.track();
            if cache_artwork {
                artwork = tag
                    .pictures()
                    .iter()
                    .find(|picture| picture.pic_type() == PictureType::CoverFront)
                    .or_else(|| tag.pictures().first())
                    .map(|picture| cached_artwork_ref(root, path, &metadata, picture));
            }
        }
    }

    let fingerprint = fingerprint_for(&title, &artist, &album);
    let id = track_id_for_fingerprint(&fingerprint);

    Ok(Track {
        id,
        path: path_to_string(path),
        file_name,
        title,
        artist,
        album,
        album_artist,
        genre,
        year,
        track_number,
        duration_seconds,
        artwork_url: None,
        artwork,
        playlist_ids,
        added_at: metadata.modified().ok().and_then(system_time_to_unix),
        size_bytes: metadata.len(),
        is_liked: playlist_is_liked,
        fingerprint,
    })
}

fn cached_artwork_ref(
    root: &Path,
    path: &Path,
    metadata: &fs::Metadata,
    picture: &lofty::picture::Picture,
) -> CachedArtwork {
    let modified = metadata
        .modified()
        .ok()
        .and_then(system_time_to_unix)
        .unwrap_or(0);
    let cache_key = stable_id(&format!(
        "{}|{}|{}|{}",
        relative_path_key(root, path),
        modified,
        metadata.len(),
        picture.data().len()
    ));

    CachedArtwork {
        source_path: path.to_path_buf(),
        cache_path: artwork_cache_dir(root).join(format!("{cache_key}.jpg")),
    }
}

pub fn ensure_cached_artwork_thumbnail(artwork: &CachedArtwork) -> Result<PathBuf, String> {
    if artwork.cache_path.exists() {
        return Ok(artwork.cache_path.clone());
    }

    let tagged_file = Probe::open(&artwork.source_path)
        .and_then(|probe| probe.read())
        .map_err(|err| format!("Could not read artwork source: {err}"))?;
    let tag = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
        .ok_or_else(|| "Artwork source has no tags.".to_string())?;
    let picture = tag
        .pictures()
        .iter()
        .find(|picture| picture.pic_type() == PictureType::CoverFront)
        .or_else(|| tag.pictures().first())
        .ok_or_else(|| "Artwork source has no embedded image.".to_string())?;
    let image = image::load_from_memory(picture.data())
        .map_err(|err| format!("Could not decode artwork: {err}"))?;
    let thumbnail = image.thumbnail(ARTWORK_THUMBNAIL_SIZE, ARTWORK_THUMBNAIL_SIZE);
    let rgb = thumbnail.to_rgb8();
    let mut bytes = Vec::new();
    let mut encoder = JpegEncoder::new_with_quality(&mut bytes, 82);
    encoder
        .encode(&rgb, rgb.width(), rgb.height(), ColorType::Rgb8.into())
        .map_err(|err| format!("Could not encode artwork thumbnail: {err}"))?;

    if let Some(parent) = artwork.cache_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("Could not create artwork cache folder: {err}"))?;
    }

    let unique_write_id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let temp_path = artwork
        .cache_path
        .with_extension(format!("tmp-{}-{unique_write_id}", std::process::id()));
    fs::write(&temp_path, bytes)
        .map_err(|err| format!("Could not write artwork thumbnail: {err}"))?;
    if let Err(err) = fs::rename(&temp_path, &artwork.cache_path) {
        let _ = fs::remove_file(&temp_path);
        if !artwork.cache_path.exists() {
            return Err(format!("Could not write artwork thumbnail: {err}"));
        }
    }
    Ok(artwork.cache_path.clone())
}

fn clean_text(value: Option<std::borrow::Cow<'_, str>>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn clean_plain_text(value: Option<&str>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn fingerprint_for(title: &str, artist: &str, album: &str) -> String {
    stable_id(&format!(
        "{}|{}|{}",
        normalize(title),
        normalize(artist),
        normalize(album)
    ))
}

fn normalize(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

fn canonical_dir(path: &Path) -> Result<PathBuf, String> {
    let path = path
        .canonicalize()
        .map_err(|err| format!("Could not resolve folder: {err}"))?;
    if !path.is_dir() {
        return Err("Music folder must be a directory.".to_string());
    }
    Ok(path)
}

fn canonical_file(path: &Path) -> Result<PathBuf, String> {
    let path = path
        .canonicalize()
        .map_err(|err| format!("Could not resolve file: {err}"))?;
    if !path.is_file() {
        return Err("Track path must be a file.".to_string());
    }
    Ok(path)
}

fn is_mp3(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.eq_ignore_ascii_case("mp3"))
        .unwrap_or(false)
}

fn unique_destination(destination: PathBuf) -> PathBuf {
    if !destination.exists() {
        return destination;
    }

    let parent = destination
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(PathBuf::new);
    let stem = destination
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("track");
    let extension = destination
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("mp3");

    for index in 2.. {
        let candidate = parent.join(format!("{stem} ({index}).{extension}"));
        if !candidate.exists() {
            return candidate;
        }
    }

    unreachable!("unique destination loop is unbounded")
}

fn track_id_for_fingerprint(fingerprint: &str) -> String {
    format!("track_{fingerprint}")
}

fn playlist_id_for_path(path: &Path) -> String {
    format!("playlist_{}", stable_id(&path_to_string(path)))
}

fn stable_id(value: &str) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn file_stem_or_name(path: &Path) -> String {
    path.file_stem()
        .or_else(|| path.file_name())
        .and_then(|name| name.to_str())
        .unwrap_or("Untitled")
        .to_string()
}

fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

fn unix_now() -> u64 {
    system_time_to_unix(SystemTime::now()).unwrap_or(0)
}

fn system_time_to_unix(time: SystemTime) -> Option<u64> {
    time.duration_since(UNIX_EPOCH)
        .ok()
        .map(|time| time.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn scans_direct_folders_as_playlists_and_reads_nested_mp3s() {
        let temp = tempdir().unwrap();
        let roadtrip = temp.path().join("Roadtrip");
        let nested = roadtrip.join("Disc 1");
        fs::create_dir_all(&nested).unwrap();
        fs::write(roadtrip.join("01 - Start.mp3"), b"not really an mp3").unwrap();
        fs::write(nested.join("02 - Middle.mp3"), b"not really an mp3").unwrap();
        fs::write(roadtrip.join("cover.jpg"), b"ignore me").unwrap();

        let library = scan_library_path(temp.path()).unwrap();
        let roadtrip_playlist = library
            .playlists
            .iter()
            .find(|playlist| playlist.name == "Roadtrip")
            .unwrap();

        assert_eq!(roadtrip_playlist.track_ids.len(), 2);
        assert!(library
            .playlists
            .iter()
            .any(|playlist| playlist.name == LIKED_FOLDER_NAME && playlist.is_liked));
        assert_eq!(library.tracks.len(), 2);
        assert!(library
            .tracks
            .iter()
            .any(|track| track.title == "01 - Start"));
    }

    #[test]
    fn rename_folder_playlist_persists_display_name_without_renaming_folder() {
        let temp = tempdir().unwrap();
        let playlist = temp.path().join("Mix");
        fs::create_dir_all(&playlist).unwrap();
        fs::write(playlist.join("Song.mp3"), b"not really an mp3").unwrap();

        let library = scan_library_path(temp.path()).unwrap();
        let playlist_id = library
            .playlists
            .iter()
            .find(|playlist| playlist.name == "Mix")
            .unwrap()
            .id
            .clone();

        rename_playlist_path(temp.path(), &playlist_id, "Late Night").unwrap();
        let renamed = scan_library_path(temp.path()).unwrap();
        let renamed_playlist = renamed
            .playlists
            .iter()
            .find(|playlist| playlist.id == playlist_id)
            .unwrap();

        assert!(playlist.exists());
        assert_eq!(renamed_playlist.name, "Late Night");
        assert_eq!(renamed_playlist.track_ids.len(), 1);
        assert!(read_library_state(temp.path())
            .unwrap()
            .playlists
            .iter()
            .any(|playlist| playlist.id == playlist_id && playlist.name == "Late Night"));
    }

    #[test]
    fn rename_state_playlist_keeps_track_membership() {
        let temp = tempdir().unwrap();
        fs::write(temp.path().join("Song.mp3"), b"not really an mp3").unwrap();

        let library = scan_library_path(temp.path()).unwrap();
        let track = library.tracks.first().unwrap();
        let mut state = read_library_state(temp.path()).unwrap();
        state.playlists.push(StatePlaylist {
            id: "playlist_state_manual".to_string(),
            name: "Manual".to_string(),
            track_fingerprints: vec![track.fingerprint.clone()],
        });
        write_library_state(temp.path(), &state).unwrap();

        rename_playlist_path(temp.path(), "playlist_state_manual", "Renamed").unwrap();
        let renamed = scan_library_path(temp.path()).unwrap();
        let renamed_playlist = renamed
            .playlists
            .iter()
            .find(|playlist| playlist.id == "playlist_state_manual")
            .unwrap();

        assert_eq!(renamed_playlist.name, "Renamed");
        assert_eq!(renamed_playlist.track_ids, vec![track.id.clone()]);
        assert!(!renamed
            .playlists
            .iter()
            .any(|playlist| playlist.name == "Manual"));
    }

    #[test]
    fn liked_folder_marks_matching_tracks_as_liked() {
        let temp = tempdir().unwrap();
        let playlist = temp.path().join("Mix");
        let liked = temp.path().join(LIKED_FOLDER_NAME);
        fs::create_dir_all(&playlist).unwrap();
        fs::create_dir_all(&liked).unwrap();
        fs::write(playlist.join("Same Song.mp3"), b"not really an mp3").unwrap();
        fs::write(liked.join("Same Song.mp3"), b"not really an mp3").unwrap();

        let library = scan_library_path(temp.path()).unwrap();
        let mix_track = library
            .tracks
            .iter()
            .find(|track| track.path.contains("Mix"))
            .unwrap();
        let liked_playlist = library
            .playlists
            .iter()
            .find(|playlist| playlist.is_liked)
            .unwrap();

        assert!(mix_track.is_liked);
        assert_eq!(library.tracks.len(), 1);
        assert_eq!(liked_playlist.track_ids, vec![mix_track.id.clone()]);
        assert!(read_library_state(temp.path())
            .unwrap()
            .liked_fingerprints
            .contains(&mix_track.fingerprint));
    }

    #[test]
    fn copy_to_liked_records_state_without_copying() {
        let temp = tempdir().unwrap();
        let playlist = temp.path().join("Mix");
        fs::create_dir_all(&playlist).unwrap();
        let source = playlist.join("Song.mp3");
        fs::write(&source, b"audio").unwrap();

        let first = copy_track_to_liked_path(temp.path(), &source).unwrap();
        let second = copy_track_to_liked_path(temp.path(), &source).unwrap();
        let library = scan_library_path(temp.path()).unwrap();

        assert!(source.exists());
        assert_eq!(first, second);
        assert!(!temp.path().join(LIKED_FOLDER_NAME).exists());
        assert_eq!(
            read_library_state(temp.path())
                .unwrap()
                .liked_fingerprints
                .len(),
            1
        );
        assert_eq!(library.tracks.len(), 1);
        assert!(library.tracks[0].is_liked);
    }

    #[test]
    fn remove_liked_track_updates_state_without_deleting_file() {
        let temp = tempdir().unwrap();
        let playlist = temp.path().join("Mix");
        fs::create_dir_all(&playlist).unwrap();
        let source = playlist.join("Song.mp3");
        fs::write(&source, b"audio").unwrap();

        copy_track_to_liked_path(temp.path(), &source).unwrap();

        assert!(remove_liked_track_path(temp.path(), &source).unwrap());
        assert!(source.exists());
        assert!(!remove_liked_track_path(temp.path(), &source).unwrap());
        assert!(!scan_library_path(temp.path()).unwrap().tracks[0].is_liked);
    }

    #[test]
    fn set_track_playlist_memberships_updates_liked_and_state_playlists() {
        let temp = tempdir().unwrap();
        let source = temp.path().join("Song.mp3");
        let playlist = temp.path().join("Mix");
        fs::create_dir_all(&playlist).unwrap();
        fs::write(&source, b"audio").unwrap();
        fs::write(playlist.join("Other.mp3"), b"other audio").unwrap();

        let library = scan_library_path(temp.path()).unwrap();
        let liked_id = library
            .playlists
            .iter()
            .find(|playlist| playlist.is_liked)
            .unwrap()
            .id
            .clone();
        let mix_id = library
            .playlists
            .iter()
            .find(|playlist| playlist.name == "Mix")
            .unwrap()
            .id
            .clone();

        set_track_playlist_memberships_path(temp.path(), &source, vec![liked_id, mix_id.clone()])
            .unwrap();
        let source_path = path_to_string(&source.canonicalize().unwrap());
        let updated = scan_library_path(temp.path()).unwrap();
        let track = updated
            .tracks
            .iter()
            .find(|track| track.path == source_path)
            .unwrap();
        let mix = updated
            .playlists
            .iter()
            .find(|playlist| playlist.id == mix_id)
            .unwrap();

        assert!(track.is_liked);
        assert!(mix.track_ids.contains(&track.id));

        set_track_playlist_memberships_path(temp.path(), &source, Vec::new()).unwrap();
        let cleared = scan_library_path(temp.path()).unwrap();
        let track = cleared
            .tracks
            .iter()
            .find(|track| track.path == source_path)
            .unwrap();
        let mix = cleared
            .playlists
            .iter()
            .find(|playlist| playlist.id == mix_id)
            .unwrap();

        assert!(!track.is_liked);
        assert!(!mix.track_ids.contains(&track.id));
    }

    #[test]
    fn set_track_playlist_memberships_can_remove_folder_playlist_membership() {
        let temp = tempdir().unwrap();
        let playlist = temp.path().join("Mix");
        fs::create_dir_all(&playlist).unwrap();
        let source = playlist.join("Song.mp3");
        fs::write(&source, b"audio").unwrap();

        let library = scan_library_path(temp.path()).unwrap();
        let track = library.tracks.first().unwrap();
        let mix_id = library
            .playlists
            .iter()
            .find(|playlist| playlist.name == "Mix")
            .unwrap()
            .id
            .clone();
        assert!(track.playlist_ids.contains(&mix_id));

        set_track_playlist_memberships_path(temp.path(), &source, Vec::new()).unwrap();
        let updated = scan_library_path(temp.path()).unwrap();
        let track = updated.tracks.first().unwrap();
        let mix = updated
            .playlists
            .iter()
            .find(|playlist| playlist.id == mix_id)
            .unwrap();

        assert!(!track.playlist_ids.contains(&mix_id));
        assert!(!mix.track_ids.contains(&track.id));
    }

    #[test]
    fn merge_sync_library_state_updates_likes_and_state_playlists_by_fingerprint() {
        let temp = tempdir().unwrap();
        let source = temp.path().join("Song.mp3");
        fs::write(&source, b"audio").unwrap();

        let library = scan_library_path(temp.path()).unwrap();
        let track = library.tracks.first().unwrap();

        merge_sync_library_state_path(
            temp.path(),
            SyncLibraryState {
                tracks: vec![SyncTrackState {
                    id: "remote-track".to_string(),
                    fingerprint: track.fingerprint.clone(),
                    is_liked: true,
                }],
                playlists: vec![SyncPlaylistState {
                    id: "playlist_remote".to_string(),
                    name: "Remote Mix".to_string(),
                    track_ids: vec!["remote-track".to_string()],
                    is_liked: false,
                }],
            },
        )
        .unwrap();

        let updated = scan_library_path(temp.path()).unwrap();
        let updated_track = updated.tracks.first().unwrap();
        let playlist = updated
            .playlists
            .iter()
            .find(|playlist| playlist.id == "playlist_remote")
            .unwrap();

        assert!(updated_track.is_liked);
        assert!(updated_track.playlist_ids.contains(&playlist.id));
        assert_eq!(playlist.track_ids, vec![updated_track.id.clone()]);
    }

    #[test]
    fn import_manifest_links_existing_tracks_without_copying_duplicates() {
        let library_root = tempdir().unwrap();
        let import_root = tempdir().unwrap();
        let mix = library_root.path().join("Mix");
        fs::create_dir_all(&mix).unwrap();
        fs::write(mix.join("Same Song.mp3"), b"audio").unwrap();
        fs::write(import_root.path().join("Same Song.mp3"), b"audio").unwrap();
        let manifest = import_root.path().join("manifest.json");
        fs::write(
            &manifest,
            r#"{
              "schema": "loud.import.v1",
              "tracks": [
                {
                  "file": "Same Song.mp3",
                  "title": "Same Song",
                  "artist": "Unknown Artist",
                  "album": "Unknown Album",
                  "identifiers": {
                    "isrc": "test-existing"
                  },
                  "liked": true,
                  "playlists": ["Imported Mix"]
                }
              ],
              "playlists": [
                {
                  "name": "Imported Mix",
                  "mode": "append",
                  "tracks": [
                    {
                      "identifiers": {
                        "isrc": "TEST-EXISTING"
                      }
                    }
                  ]
                }
              ]
            }"#,
        )
        .unwrap();

        let report = import_library_manifest_path(library_root.path(), &manifest).unwrap();
        let library = scan_library_path(library_root.path()).unwrap();
        let imported_playlist = library
            .playlists
            .iter()
            .find(|playlist| playlist.name == "Imported Mix")
            .unwrap();

        assert_eq!(report.new_tracks, 0);
        assert_eq!(report.existing_tracks, 1);
        assert_eq!(report.liked_updates, 1);
        assert_eq!(library.tracks.len(), 1);
        assert!(library.tracks[0].is_liked);
        assert_eq!(
            imported_playlist.track_ids,
            vec![library.tracks[0].id.clone()]
        );
        assert!(!managed_audio_dir(library_root.path()).exists());
    }

    #[test]
    fn import_manifest_copies_new_tracks_into_managed_audio() {
        let library_root = tempdir().unwrap();
        let import_root = tempdir().unwrap();
        fs::write(import_root.path().join("New Song.mp3"), b"audio").unwrap();
        let manifest = import_root.path().join("manifest.json");
        fs::write(
            &manifest,
            r#"{
              "schema": "loud.import.v1",
              "source": { "base_path": "." },
              "tracks": [
                {
                  "file": "New Song.mp3",
                  "title": "New Song",
                  "artist": "Ada",
                  "album": "Compiler Songs",
                  "album_artist": "Ada",
                  "track_number": 1,
                  "disc_number": 1,
                  "duration_ms": 172626,
                  "explicit": true,
                  "identifiers": {
                    "isrc": "USRC12100543",
                    "spotify_track_id": "spotify-new-track",
                    "spotify_album_id": "spotify-new-album",
                    "youtube_video_id": "youtube-new-video"
                  },
                  "source_urls": {
                    "spotify": "https://open.spotify.com/track/spotify-new-track",
                    "youtube": "https://www.youtube.com/watch?v=youtube-new-video"
                  }
                }
              ],
              "playlists": [
                {
                  "name": "Inbox",
                  "mode": "append",
                  "tracks": [
                    {
                      "identifiers": {
                        "spotify_track_id": "spotify-new-track"
                      }
                    }
                  ]
                }
              ]
            }"#,
        )
        .unwrap();

        let report = import_library_manifest_path(library_root.path(), &manifest).unwrap();
        let library = scan_library_path(library_root.path()).unwrap();
        let inbox = library
            .playlists
            .iter()
            .find(|playlist| playlist.name == "Inbox")
            .unwrap();

        assert_eq!(report.new_tracks, 1);
        assert_eq!(report.existing_tracks, 0);
        assert_eq!(report.playlist_updates, 1);
        assert_eq!(report.imported_paths.len(), 1);
        assert!(Path::new(&report.imported_paths[0]).exists());
        assert!(report.imported_paths[0].contains(STATE_DIR_NAME));
        assert_eq!(library.tracks.len(), 1);
        assert_eq!(library.tracks[0].artist, "Ada");
        assert_eq!(library.tracks[0].fingerprint, "isrc:USRC12100543");
        assert_eq!(inbox.track_ids, vec![library.tracks[0].id.clone()]);

        let state = read_library_state(library_root.path()).unwrap();
        let metadata = state.managed_tracks.values().next().unwrap();
        assert_eq!(metadata.disc_number, Some(1));
        assert_eq!(metadata.explicit, Some(true));
        assert_eq!(
            metadata.identifiers.spotify_track_id.as_deref(),
            Some("spotify-new-track")
        );
        assert_eq!(
            metadata.source_urls.get("youtube").map(String::as_str),
            Some("https://www.youtube.com/watch?v=youtube-new-video")
        );
        assert_eq!(metadata.duration_seconds, Some(172.626));
    }
}
