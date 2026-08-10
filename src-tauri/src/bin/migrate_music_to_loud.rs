use lofty::file::{AudioFile, TaggedFileExt};
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

#[derive(Clone, Debug)]
struct TrackCandidate {
    source_path: PathBuf,
    direct_folder: String,
    is_liked_source: bool,
    metadata: TrackMetadata,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct LibraryState {
    schema_version: u32,
    #[serde(default)]
    liked_fingerprints: BTreeSet<String>,
    #[serde(default)]
    playlists: Vec<StatePlaylist>,
    #[serde(default)]
    managed_tracks: BTreeMap<String, StateTrackMetadata>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct StatePlaylist {
    id: String,
    name: String,
    #[serde(default)]
    track_fingerprints: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
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

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
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

#[derive(Clone, Debug)]
struct TrackMetadata {
    fingerprint: String,
    title: String,
    artist: String,
    album: String,
    album_artist: Option<String>,
    genre: Option<String>,
    year: Option<u16>,
    track_number: Option<u32>,
    duration_seconds: Option<f64>,
}

fn main() -> Result<(), String> {
    let root_arg = std::env::args()
        .nth(1)
        .ok_or("usage: migrate_music_to_loud <music-folder>")?;
    let root = canonical_dir(Path::new(&root_arg))?;
    let backup_root = root.with_file_name(format!(
        "{}-legacy-{}",
        root.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("Music"),
        unix_now()
    ));

    if backup_root.exists() {
        return Err(format!(
            "Backup folder already exists: {}",
            path_to_string(&backup_root)
        ));
    }

    let mut state = read_library_state(&root)?;
    let playlist_dirs = direct_playlist_dirs(&root)?;
    let mut candidates = Vec::<TrackCandidate>::new();

    for playlist_dir in &playlist_dirs {
        let direct_folder = playlist_dir
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| "Playlist folder has no name.".to_string())?
            .to_string();
        let is_liked_source = direct_folder.eq_ignore_ascii_case(LIKED_FOLDER_NAME);

        for entry in WalkDir::new(playlist_dir)
            .follow_links(false)
            .into_iter()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().is_file())
        {
            let path = entry.path();
            if !is_mp3(path) {
                continue;
            }

            candidates.push(TrackCandidate {
                source_path: path.to_path_buf(),
                direct_folder: direct_folder.clone(),
                is_liked_source,
                metadata: read_track_metadata(path)?,
            });
        }
    }

    let mut by_fingerprint = BTreeMap::<String, TrackCandidate>::new();
    let mut playlist_refs = BTreeMap::<String, Vec<String>>::new();

    for candidate in candidates {
        let fingerprint = candidate.metadata.fingerprint.clone();

        if candidate.is_liked_source {
            state.liked_fingerprints.insert(fingerprint.clone());
        } else {
            let refs = playlist_refs
                .entry(candidate.direct_folder.clone())
                .or_default();
            if !refs.iter().any(|existing| existing == &fingerprint) {
                refs.push(fingerprint.clone());
            }
        }

        match by_fingerprint.get(&fingerprint) {
            Some(existing) if source_priority(&candidate) <= source_priority(existing) => {}
            _ => {
                by_fingerprint.insert(fingerprint, candidate);
            }
        }
    }

    let audio_root = root.join(STATE_DIR_NAME).join(MANAGED_AUDIO_DIR_NAME);
    let mut copied = 0usize;
    let mut existing_managed = 0usize;

    for candidate in by_fingerprint.values() {
        let destination = unique_destination(managed_destination(&audio_root, candidate));
        let relative_key = relative_path_key(&root, &destination);

        if !destination.exists() {
            if let Some(parent) = destination.parent() {
                fs::create_dir_all(parent)
                    .map_err(|err| format!("Could not create managed audio folder: {err}"))?;
            }
            fs::copy(&candidate.source_path, &destination)
                .map_err(|err| format!("Could not copy managed track: {err}"))?;
            copied += 1;
        } else {
            existing_managed += 1;
        }

        state.managed_tracks.insert(
            relative_key,
            StateTrackMetadata {
                fingerprint: candidate.metadata.fingerprint.clone(),
                title: candidate.metadata.title.clone(),
                artist: candidate.metadata.artist.clone(),
                album: candidate.metadata.album.clone(),
                album_artist: candidate.metadata.album_artist.clone(),
                genre: candidate.metadata.genre.clone(),
                year: candidate.metadata.year,
                track_number: candidate.metadata.track_number,
                disc_number: None,
                duration_seconds: candidate.metadata.duration_seconds,
                explicit: None,
                identifiers: TrackIdentifiers::default(),
                source_urls: BTreeMap::new(),
            },
        );
    }

    for (playlist_name, fingerprints) in playlist_refs {
        let playlist = state_playlist_mut(&mut state, &playlist_name);
        playlist.track_fingerprints = fingerprints;
    }

    write_library_state(&root, &state)?;

    fs::create_dir_all(&backup_root)
        .map_err(|err| format!("Could not create legacy backup folder: {err}"))?;
    let mut moved_dirs = 0usize;
    for playlist_dir in playlist_dirs {
        let name = playlist_dir
            .file_name()
            .ok_or_else(|| "Playlist folder has no name.".to_string())?;
        let destination = backup_root.join(name);
        fs::rename(&playlist_dir, &destination)
            .map_err(|err| format!("Could not move legacy playlist folder: {err}"))?;
        moved_dirs += 1;
    }

    println!("Migrated root: {}", path_to_string(&root));
    println!("Canonical tracks: {}", by_fingerprint.len());
    println!("Copied into .loud/audio: {copied}");
    println!("Already existed in managed audio: {existing_managed}");
    println!("Liked fingerprints: {}", state.liked_fingerprints.len());
    println!("State playlists: {}", state.playlists.len());
    println!("Moved legacy folders: {moved_dirs}");
    println!("Legacy backup: {}", path_to_string(&backup_root));

    Ok(())
}

fn direct_playlist_dirs(root: &Path) -> Result<Vec<PathBuf>, String> {
    let mut dirs = Vec::new();
    for entry in fs::read_dir(root).map_err(|err| format!("Could not read music folder: {err}"))? {
        let entry = entry.map_err(|err| format!("Could not read folder entry: {err}"))?;
        let file_type = entry
            .file_type()
            .map_err(|err| format!("Could not read folder entry type: {err}"))?;
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

        dirs.push(path);
    }
    dirs.sort();
    Ok(dirs)
}

fn read_track_metadata(path: &Path) -> Result<TrackMetadata, String> {
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

    if let Ok(tagged_file) = Probe::open(path).and_then(|probe| probe.read()) {
        let duration = tagged_file.properties().duration();
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
        }
    }

    let fingerprint = fingerprint_for(&title, &artist, &album);
    Ok(TrackMetadata {
        fingerprint,
        title,
        artist,
        album,
        album_artist,
        genre,
        year,
        track_number,
        duration_seconds,
    })
}

fn source_priority(candidate: &TrackCandidate) -> u8 {
    if candidate.is_liked_source {
        0
    } else {
        1
    }
}

fn managed_destination(audio_root: &Path, candidate: &TrackCandidate) -> PathBuf {
    let file_name = candidate
        .source_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("track.mp3");

    audio_root
        .join(safe_path_component(&candidate.metadata.artist))
        .join(safe_path_component(&candidate.metadata.album))
        .join(safe_path_component(file_name))
}

fn read_library_state(root: &Path) -> Result<LibraryState, String> {
    let path = root.join(STATE_DIR_NAME).join(STATE_FILE_NAME);
    if !path.exists() {
        return Ok(LibraryState {
            schema_version: 1,
            liked_fingerprints: BTreeSet::new(),
            playlists: Vec::new(),
            managed_tracks: BTreeMap::new(),
        });
    }

    let text =
        fs::read_to_string(&path).map_err(|err| format!("Could not read Loud state: {err}"))?;
    serde_json::from_str(&text).map_err(|err| format!("Could not parse Loud state: {err}"))
}

fn write_library_state(root: &Path, state: &LibraryState) -> Result<(), String> {
    let path = root.join(STATE_DIR_NAME).join(STATE_FILE_NAME);
    let parent = path
        .parent()
        .ok_or_else(|| "Could not resolve Loud state directory.".to_string())?;
    fs::create_dir_all(parent).map_err(|err| format!("Could not create Loud state: {err}"))?;
    let text = serde_json::to_string_pretty(state)
        .map_err(|err| format!("Could not serialize Loud state: {err}"))?;
    fs::write(&path, text).map_err(|err| format!("Could not write Loud state: {err}"))
}

fn state_playlist_mut<'a>(state: &'a mut LibraryState, name: &str) -> &'a mut StatePlaylist {
    let clean_name = name.trim();
    let clean_name = if clean_name.is_empty() {
        "Imported"
    } else {
        clean_name
    };
    let id = format!("playlist_state_{}", stable_id(&normalize(clean_name)));
    if let Some(index) = state
        .playlists
        .iter()
        .position(|playlist| playlist.id == id)
    {
        return &mut state.playlists[index];
    }

    state.playlists.push(StatePlaylist {
        id,
        name: clean_name.to_string(),
        track_fingerprints: Vec::new(),
    });
    state.playlists.last_mut().unwrap()
}

fn clean_text(value: Option<std::borrow::Cow<'_, str>>) -> Option<String> {
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

fn stable_id(value: &str) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
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

fn unique_destination(destination: PathBuf) -> PathBuf {
    if !destination.exists() {
        return destination;
    }

    let parent = destination
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default();
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

fn relative_path_key(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .map(path_to_string)
        .unwrap_or_else(|_| path_to_string(path))
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

fn is_mp3(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.eq_ignore_ascii_case("mp3"))
        .unwrap_or(false)
}

fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|time| time.as_secs())
        .unwrap_or(0)
}
