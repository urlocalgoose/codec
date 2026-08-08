mod library;

use library::{
    copy_track_to_liked_path, ensure_cached_artwork_thumbnail, import_library_manifest_path,
    merge_sync_library_state_path, remove_liked_track_path, rename_playlist_path,
    scan_library_path, set_track_playlist_memberships_path, CachedArtwork, ImportReport, Library,
    SyncLibraryState, SyncPlaylistState, SyncTrackState,
};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{Emitter, Manager, State};

const SYNC_SCHEMA: &str = "loud.sync.v1";

#[derive(Default)]
struct WatchState {
    watcher: Mutex<Option<RecommendedWatcher>>,
}

struct MediaServer {
    files: Arc<Mutex<BTreeMap<String, MediaResource>>>,
    inner: Mutex<MediaServerInner>,
}

#[derive(Default)]
struct MediaServerInner {
    base_url: Option<String>,
    tokens_by_path: BTreeMap<String, String>,
    next_token: u64,
}

#[derive(Clone)]
enum MediaResource {
    File {
        path: PathBuf,
        content_type: &'static str,
        supports_ranges: bool,
    },
    Artwork {
        artwork: CachedArtwork,
    },
}

#[derive(Clone, Debug, Serialize)]
struct LibraryChanged {
    root_path: String,
}

#[derive(Clone, Debug, Serialize)]
struct PlaybackSource {
    url: String,
}

#[derive(Clone, Debug, Default, Serialize)]
struct SyncTransferReport {
    tracks_uploaded: usize,
    tracks_downloaded: usize,
    tracks_skipped: usize,
    artwork_uploaded: usize,
    playlist_updates: usize,
    liked_updates: usize,
    failures: Vec<SyncFailure>,
}

#[derive(Clone, Debug, Serialize)]
struct SyncFailure {
    track: String,
    reason: String,
}

#[derive(Clone, Debug, Deserialize)]
struct RemoteSyncSnapshot {
    library: RemoteLibrary,
}

#[derive(Clone, Debug, Deserialize)]
struct RemoteLibrary {
    #[serde(default)]
    playlists: Vec<RemotePlaylist>,
    #[serde(default)]
    tracks: Vec<RemoteTrack>,
}

#[derive(Clone, Debug, Deserialize)]
struct RemotePlaylist {
    id: String,
    name: String,
    #[serde(default)]
    track_ids: Vec<String>,
    #[serde(default)]
    is_liked: bool,
}

#[derive(Clone, Debug, Deserialize)]
struct RemoteTrack {
    id: String,
    #[serde(default)]
    file_name: String,
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
    duration_seconds: Option<f64>,
    #[serde(default)]
    is_liked: bool,
    fingerprint: String,
}

impl Default for MediaServer {
    fn default() -> Self {
        Self {
            files: Arc::new(Mutex::new(BTreeMap::new())),
            inner: Mutex::new(MediaServerInner::default()),
        }
    }
}

impl MediaServer {
    fn register_audio(&self, track_path: PathBuf) -> Result<PlaybackSource, String> {
        let url = self.register_file_path(track_path, "audio/mpeg", true, "media")?;
        Ok(PlaybackSource { url })
    }

    fn register_artwork(&self, artwork: CachedArtwork) -> Result<String, String> {
        self.register_file(
            format!("artwork:{}", artwork.cache_path.to_string_lossy()),
            MediaResource::Artwork { artwork },
            "artwork",
        )
    }

    fn register_file_path(
        &self,
        file_path: PathBuf,
        content_type: &'static str,
        supports_ranges: bool,
        route: &str,
    ) -> Result<String, String> {
        self.register_file(
            format!("{content_type}:{}", file_path.to_string_lossy()),
            MediaResource::File {
                path: file_path,
                content_type,
                supports_ranges,
            },
            route,
        )
    }

    fn register_file(
        &self,
        resource_key: String,
        resource: MediaResource,
        route: &str,
    ) -> Result<String, String> {
        let (base_url, token) = {
            let mut inner = self
                .inner
                .lock()
                .map_err(|_| "Could not lock media server state.".to_string())?;

            if inner.base_url.is_none() {
                inner.base_url = Some(start_media_server(Arc::clone(&self.files))?);
            }

            let base_url = inner
                .base_url
                .clone()
                .ok_or_else(|| "Media server did not start.".to_string())?;

            let token = if let Some(existing) = inner.tokens_by_path.get(&resource_key) {
                existing.clone()
            } else {
                inner.next_token = inner.next_token.wrapping_add(1);
                let token = format!("{:016x}", inner.next_token);
                inner.tokens_by_path.insert(resource_key, token.clone());
                token
            };

            (base_url, token)
        };

        self.files
            .lock()
            .map_err(|_| "Could not lock media file registry.".to_string())?
            .insert(token.clone(), resource);

        Ok(format!("{base_url}/{route}/{token}"))
    }
}

#[tauri::command(rename_all = "snake_case")]
fn scan_library(
    app: tauri::AppHandle,
    media_server: State<'_, MediaServer>,
    root_path: String,
) -> Result<Library, String> {
    let root = PathBuf::from(&root_path)
        .canonicalize()
        .map_err(|err| format!("Could not resolve folder: {err}"))?;
    allow_asset_directory(&app, &root)?;
    let mut library = scan_library_path(root)?;
    attach_artwork_urls(&media_server, &mut library)?;
    prewarm_artwork_cache(&library);
    Ok(library)
}

#[tauri::command(rename_all = "snake_case")]
fn copy_track_to_liked(root_path: String, track_path: String) -> Result<String, String> {
    copy_track_to_liked_path(root_path, track_path)
}

#[tauri::command(rename_all = "snake_case")]
fn remove_liked_track(root_path: String, track_path: String) -> Result<bool, String> {
    remove_liked_track_path(root_path, track_path)
}

#[tauri::command(rename_all = "snake_case")]
fn set_track_playlist_memberships(
    root_path: String,
    track_path: String,
    playlist_ids: Vec<String>,
) -> Result<(), String> {
    set_track_playlist_memberships_path(root_path, track_path, playlist_ids)
}

#[tauri::command(rename_all = "snake_case")]
fn import_library_manifest(
    root_path: String,
    manifest_path: String,
) -> Result<ImportReport, String> {
    import_library_manifest_path(root_path, manifest_path)
}

#[tauri::command(rename_all = "snake_case")]
fn rename_playlist(root_path: String, playlist_id: String, name: String) -> Result<(), String> {
    rename_playlist_path(root_path, playlist_id, name)
}

#[tauri::command(rename_all = "snake_case")]
fn sync_library_to_server(
    root_path: String,
    server_url: String,
    device_id: String,
) -> Result<SyncTransferReport, String> {
    let root = PathBuf::from(&root_path)
        .canonicalize()
        .map_err(|err| format!("Could not resolve folder: {err}"))?;
    if !root.is_dir() {
        return Err("Music folder must be a directory.".to_string());
    }

    let server_url = normalize_server_url(&server_url)?;
    let device_id = clean_device_id(&device_id);
    let client = sync_http_client()?;
    let library = scan_library_path(&root)?;
    let push_response = client
        .post(format!("{server_url}/api/v1/sync/push"))
        .json(&json!({
            "schema": SYNC_SCHEMA,
            "device_id": device_id,
            "library": library,
        }))
        .send()
        .map_err(|err| format!("Could not push sync metadata: {err}"))?;
    ensure_success(push_response, "push sync metadata")?;

    let mut report = SyncTransferReport::default();
    for track in &library.tracks {
        let audio_url = sync_track_media_url(&server_url, &track.fingerprint, "audio");
        if sync_remote_exists(&client, &audio_url) {
            report.tracks_skipped += 1;
        } else if let Err(err) = upload_file(&client, &audio_url, &track.path, "audio/mpeg") {
            report.failures.push(SyncFailure {
                track: track.title.clone(),
                reason: err,
            });
        } else {
            report.tracks_uploaded += 1;
        }

        if let Some(artwork) = track.artwork.clone() {
            let artwork_url = sync_track_media_url(&server_url, &track.fingerprint, "artwork");
            if sync_remote_exists(&client, &artwork_url) {
                continue;
            }

            match ensure_cached_artwork_thumbnail(&artwork)
                .map_err(|err| err.to_string())
                .and_then(|path| upload_file(&client, &artwork_url, &path, "image/jpeg"))
            {
                Ok(()) => report.artwork_uploaded += 1,
                Err(err) => report.failures.push(SyncFailure {
                    track: track.title.clone(),
                    reason: err,
                }),
            }
        }
    }

    Ok(report)
}

#[tauri::command(rename_all = "snake_case")]
fn sync_library_from_server(
    root_path: String,
    server_url: String,
) -> Result<SyncTransferReport, String> {
    let root = PathBuf::from(&root_path)
        .canonicalize()
        .map_err(|err| format!("Could not resolve folder: {err}"))?;
    if !root.is_dir() {
        return Err("Music folder must be a directory.".to_string());
    }

    let server_url = normalize_server_url(&server_url)?;
    let client = sync_http_client()?;
    let snapshot = client
        .get(format!("{server_url}/api/v1/sync/snapshot"))
        .send()
        .map_err(|err| format!("Could not load sync snapshot: {err}"))?;
    let snapshot: RemoteSyncSnapshot = ensure_success(snapshot, "load sync snapshot")?
        .json()
        .map_err(|err| format!("Could not parse sync snapshot: {err}"))?;

    let existing_library = scan_library_path(&root)?;
    let known_fingerprints = existing_library
        .tracks
        .iter()
        .map(|track| track.fingerprint.clone())
        .collect::<BTreeSet<_>>();
    let playlist_names_by_track_id = remote_playlist_names_by_track_id(&snapshot.library);
    let import_root = root
        .join(".loud")
        .join("cache")
        .join("sync-import")
        .join(format!("{}", unix_millis()));
    let files_root = import_root.join("files");
    fs::create_dir_all(&files_root)
        .map_err(|err| format!("Could not create sync import folder: {err}"))?;

    let mut report = SyncTransferReport::default();
    let mut manifest_tracks = Vec::new();

    for track in &snapshot.library.tracks {
        if known_fingerprints.contains(&track.fingerprint) {
            report.tracks_skipped += 1;
            continue;
        }

        let audio_url = sync_track_media_url(&server_url, &track.fingerprint, "audio");
        let response = match client.get(&audio_url).send() {
            Ok(response) => response,
            Err(err) => {
                report.failures.push(SyncFailure {
                    track: track.title.clone(),
                    reason: format!("Could not download audio: {err}"),
                });
                continue;
            }
        };

        let mut response = match ensure_success(response, "download audio") {
            Ok(response) => response,
            Err(err) => {
                report.failures.push(SyncFailure {
                    track: track.title.clone(),
                    reason: err,
                });
                continue;
            }
        };

        let destination =
            unique_sync_download_path(files_root.join(sync_download_file_name(track)));
        let mut file = File::create(&destination)
            .map_err(|err| format!("Could not create downloaded track: {err}"))?;
        io::copy(&mut response, &mut file)
            .map_err(|err| format!("Could not save downloaded track: {err}"))?;

        let relative_file = destination
            .strip_prefix(&files_root)
            .map(path_to_sync_string)
            .unwrap_or_else(|_| path_to_sync_string(&destination));
        manifest_tracks.push(json!({
            "file": relative_file,
            "title": track.title,
            "artist": track.artist,
            "album": track.album,
            "album_artist": track.album_artist,
            "genre": track.genre,
            "year": track.year,
            "track_number": track.track_number,
            "duration_seconds": track.duration_seconds,
            "fingerprint": track.fingerprint,
            "liked": track.is_liked,
            "playlists": playlist_names_by_track_id.get(&track.id).cloned().unwrap_or_default()
        }));
        report.tracks_downloaded += 1;
    }

    if !manifest_tracks.is_empty() {
        let manifest_path = import_root.join("manifest.json");
        let manifest = json!({
            "schema": "loud.import.v1",
            "source": {
                "name": "loud-sync",
                "base_path": "files"
            },
            "tracks": manifest_tracks
        });
        fs::write(
            &manifest_path,
            serde_json::to_string_pretty(&manifest)
                .map_err(|err| format!("Could not serialize sync import manifest: {err}"))?,
        )
        .map_err(|err| format!("Could not write sync import manifest: {err}"))?;

        let import_report = import_library_manifest_path(&root, &manifest_path)?;
        report.playlist_updates += import_report.playlist_updates;
        report.liked_updates += import_report.liked_updates;
        for failure in import_report.failures {
            report.failures.push(SyncFailure {
                track: failure.file,
                reason: failure.reason,
            });
        }
    }

    merge_sync_library_state_path(&root, sync_state_from_remote(snapshot.library))?;
    Ok(report)
}

#[tauri::command(rename_all = "snake_case")]
fn prepare_track_playback(
    state: State<'_, MediaServer>,
    root_path: String,
    track_path: String,
) -> Result<PlaybackSource, String> {
    let root = PathBuf::from(&root_path)
        .canonicalize()
        .map_err(|err| format!("Could not resolve folder: {err}"))?;
    if !root.is_dir() {
        return Err("Music folder must be a directory.".to_string());
    }

    let track = PathBuf::from(&track_path)
        .canonicalize()
        .map_err(|err| format!("Could not resolve track: {err}"))?;
    if !track.is_file() {
        return Err("Track path must be a file.".to_string());
    }
    if !track.starts_with(&root) {
        return Err("Track is outside the selected music folder.".to_string());
    }
    if !is_mp3_path(&track) {
        return Err("Only MP3 playback is supported right now.".to_string());
    }

    state.register_audio(track)
}

fn attach_artwork_urls(server: &MediaServer, library: &mut Library) -> Result<(), String> {
    for track in &mut library.tracks {
        if let Some(artwork) = track.artwork.clone() {
            track.artwork_url = Some(server.register_artwork(artwork)?);
        }
    }

    for album in &mut library.albums {
        if let Some(artwork) = album.artwork.clone() {
            album.artwork_url = Some(server.register_artwork(artwork)?);
        }
    }

    Ok(())
}

fn prewarm_artwork_cache(library: &Library) {
    let mut seen = BTreeSet::<PathBuf>::new();
    let artworks = library
        .tracks
        .iter()
        .filter_map(|track| track.artwork.clone())
        .filter(|artwork| seen.insert(artwork.cache_path.clone()))
        .collect::<Vec<_>>();

    if artworks.is_empty() {
        return;
    }

    let _ = thread::Builder::new()
        .name("loud-artwork-cache".to_string())
        .spawn(move || {
            for artwork in artworks {
                if let Err(err) = ensure_cached_artwork_thumbnail(&artwork) {
                    eprintln!("artwork cache failed: {err}");
                }
            }
        });
}

fn normalize_server_url(server_url: &str) -> Result<String, String> {
    let trimmed = server_url.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return Err("Sync server URL cannot be empty.".to_string());
    }

    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return Ok(trimmed.to_string());
    }

    Ok(format!("http://{trimmed}"))
}

fn clean_device_id(device_id: &str) -> String {
    let device_id = device_id.trim();
    if device_id.is_empty() {
        format!("desktop-{}", std::process::id())
    } else {
        device_id.to_string()
    }
}

fn sync_http_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(180))
        .build()
        .map_err(|err| format!("Could not create sync HTTP client: {err}"))
}

fn ensure_success(
    response: reqwest::blocking::Response,
    action: &str,
) -> Result<reqwest::blocking::Response, String> {
    if response.status().is_success() {
        return Ok(response);
    }

    let status = response.status();
    let details = response.text().unwrap_or_default();
    if details.trim().is_empty() {
        Err(format!("Could not {action}: server returned {status}."))
    } else {
        Err(format!(
            "Could not {action}: server returned {status}. {details}"
        ))
    }
}

fn sync_remote_exists(client: &reqwest::blocking::Client, url: &str) -> bool {
    client
        .head(url)
        .send()
        .map(|response| response.status().is_success())
        .unwrap_or(false)
}

fn upload_file(
    client: &reqwest::blocking::Client,
    url: &str,
    path: impl AsRef<Path>,
    content_type: &'static str,
) -> Result<(), String> {
    let path = path.as_ref();
    let file = File::open(path).map_err(|err| format!("Could not open upload file: {err}"))?;
    let response = client
        .put(url)
        .header(reqwest::header::CONTENT_TYPE, content_type)
        .body(reqwest::blocking::Body::new(file))
        .send()
        .map_err(|err| format!("Could not upload file: {err}"))?;
    ensure_success(response, "upload file").map(|_| ())
}

fn sync_track_media_url(server_url: &str, fingerprint: &str, media_kind: &str) -> String {
    format!(
        "{server_url}/api/v1/tracks/{}/{}",
        percent_encode_path_segment(fingerprint),
        media_kind
    )
}

fn percent_encode_path_segment(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.as_bytes() {
        let is_unreserved = byte.is_ascii_alphanumeric()
            || matches!(*byte, b'-' | b'.' | b'_' | b'~');
        if is_unreserved {
            encoded.push(char::from(*byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn remote_playlist_names_by_track_id(library: &RemoteLibrary) -> BTreeMap<String, Vec<String>> {
    let mut names_by_track_id = BTreeMap::<String, Vec<String>>::new();
    for playlist in library.playlists.iter().filter(|playlist| !playlist.is_liked) {
        for track_id in &playlist.track_ids {
            names_by_track_id
                .entry(track_id.clone())
                .or_default()
                .push(playlist.name.clone());
        }
    }
    names_by_track_id
}

fn sync_state_from_remote(library: RemoteLibrary) -> SyncLibraryState {
    SyncLibraryState {
        tracks: library
            .tracks
            .into_iter()
            .map(|track| SyncTrackState {
                id: track.id,
                fingerprint: track.fingerprint,
                is_liked: track.is_liked,
            })
            .collect(),
        playlists: library
            .playlists
            .into_iter()
            .map(|playlist| SyncPlaylistState {
                id: playlist.id,
                name: playlist.name,
                track_ids: playlist.track_ids,
                is_liked: playlist.is_liked,
            })
            .collect(),
    }
}

fn sync_download_file_name(track: &RemoteTrack) -> String {
    let mut name = safe_sync_file_component(if track.file_name.trim().is_empty() {
        &track.title
    } else {
        &track.file_name
    });
    if !name.to_lowercase().ends_with(".mp3") {
        name.push_str(".mp3");
    }
    name
}

fn safe_sync_file_component(value: &str) -> String {
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
        "track".to_string()
    } else {
        sanitized
    }
}

fn unique_sync_download_path(destination: PathBuf) -> PathBuf {
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

fn path_to_sync_string(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn unix_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0)
}

#[tauri::command(rename_all = "snake_case")]
fn start_library_watch(
    app: tauri::AppHandle,
    state: State<'_, WatchState>,
    root_path: String,
) -> Result<(), String> {
    let root = PathBuf::from(&root_path)
        .canonicalize()
        .map_err(|err| format!("Could not resolve folder: {err}"))?;
    allow_asset_directory(&app, &root)?;
    let root_label = root.to_string_lossy().to_string();
    let app_for_events = app.clone();
    let event_root = root_label.clone();

    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if event.is_ok() {
            let _ = app_for_events.emit(
                "library-changed",
                LibraryChanged {
                    root_path: event_root.clone(),
                },
            );
        }
    })
    .map_err(|err| format!("Could not start folder watcher: {err}"))?;

    watcher
        .watch(&root, RecursiveMode::Recursive)
        .map_err(|err| format!("Could not watch music folder: {err}"))?;

    let mut current = state
        .watcher
        .lock()
        .map_err(|_| "Could not lock watcher state.".to_string())?;
    *current = Some(watcher);
    Ok(())
}

fn allow_asset_directory(app: &tauri::AppHandle, root: &PathBuf) -> Result<(), String> {
    app.asset_protocol_scope()
        .allow_directory(root, true)
        .map_err(|err| format!("Could not allow media folder for playback: {err}"))
}

#[tauri::command]
fn stop_library_watch(state: State<'_, WatchState>) -> Result<(), String> {
    let mut current = state
        .watcher
        .lock()
        .map_err(|_| "Could not lock watcher state.".to_string())?;
    *current = None;
    Ok(())
}

fn is_mp3_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.eq_ignore_ascii_case("mp3"))
        .unwrap_or(false)
}

fn start_media_server(
    files: Arc<Mutex<BTreeMap<String, MediaResource>>>,
) -> Result<String, String> {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .map_err(|err| format!("Could not start local media server: {err}"))?;
    let address = listener
        .local_addr()
        .map_err(|err| format!("Could not read local media server address: {err}"))?;

    thread::Builder::new()
        .name("loud-media-server".to_string())
        .spawn(move || {
            for stream in listener.incoming() {
                match stream {
                    Ok(stream) => {
                        let files = Arc::clone(&files);
                        let _ = thread::Builder::new()
                            .name("loud-media-request".to_string())
                            .spawn(move || {
                                if let Err(err) = handle_media_request(stream, files) {
                                    eprintln!("media request failed: {err}");
                                }
                            });
                    }
                    Err(err) => {
                        eprintln!("media server connection failed: {err}");
                    }
                }
            }
        })
        .map_err(|err| format!("Could not run local media server: {err}"))?;

    Ok(format!("http://{address}"))
}

fn handle_media_request(
    mut stream: TcpStream,
    files: Arc<Mutex<BTreeMap<String, MediaResource>>>,
) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;

    let request = read_http_request(&mut stream)?;
    let request_text = String::from_utf8_lossy(&request);
    let mut lines = request_text.lines();
    let request_line = lines.next().unwrap_or_default();
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().unwrap_or_default();
    let uri = request_parts.next().unwrap_or_default();

    if method == "OPTIONS" {
        return write_empty_response(&mut stream, "204 No Content");
    }

    if method != "GET" && method != "HEAD" {
        return write_text_response(&mut stream, "405 Method Not Allowed", "Method not allowed");
    }

    let Some((_route, token)) = uri
        .split('?')
        .next()
        .and_then(|path| path.strip_prefix('/'))
        .and_then(|path| path.split_once('/'))
        .filter(|(route, token)| (*route == "media" || *route == "artwork") && !token.is_empty())
    else {
        return write_text_response(&mut stream, "404 Not Found", "Not found");
    };

    let Some(resource) = files
        .lock()
        .map_err(|_| io::Error::new(io::ErrorKind::Other, "media registry lock failed"))?
        .get(token)
        .cloned()
    else {
        return write_text_response(&mut stream, "404 Not Found", "Not found");
    };

    let range_header = lines.find_map(|line| {
        line.split_once(':').and_then(|(name, value)| {
            if name.eq_ignore_ascii_case("range") {
                Some(value.trim().to_string())
            } else {
                None
            }
        })
    });

    serve_file(
        &mut stream,
        &resource,
        method == "HEAD",
        range_header.as_deref(),
    )
}

fn read_http_request(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
    let mut request = Vec::new();
    let mut buffer = [0u8; 4096];

    loop {
        let read = stream.read(&mut buffer)?;
        if read == 0 {
            break;
        }

        request.extend_from_slice(&buffer[..read]);
        if request.windows(4).any(|window| window == b"\r\n\r\n") || request.len() > 16 * 1024 {
            break;
        }
    }

    Ok(request)
}

fn serve_file(
    stream: &mut TcpStream,
    resource: &MediaResource,
    head_only: bool,
    range_header: Option<&str>,
) -> io::Result<()> {
    let (path, content_type, supports_ranges) = match resource {
        MediaResource::File {
            path,
            content_type,
            supports_ranges,
        } => (path.clone(), *content_type, *supports_ranges),
        MediaResource::Artwork { artwork } => (
            ensure_cached_artwork_thumbnail(artwork).map_err(io::Error::other)?,
            "image/jpeg",
            false,
        ),
    };

    let mut file = File::open(&path)?;
    let length = file.metadata()?.len();

    if length == 0 {
        return write_text_response(stream, "416 Range Not Satisfiable", "Empty file");
    }

    let range = match range_header.filter(|_| supports_ranges) {
        Some(header) => match parse_range_header(header, length) {
            Ok(range) => Some(range),
            Err(()) => {
                return write_range_not_satisfiable(stream, length);
            }
        },
        None => None,
    };

    let (status, start, end) = match range {
        Some((start, end)) => ("206 Partial Content", start, end),
        None => ("200 OK", 0, length - 1),
    };
    let content_length = end - start + 1;

    let mut headers = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: {}\r\n\
         Accept-Ranges: {}\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n\
         Access-Control-Allow-Headers: Range\r\n\
         Content-Length: {content_length}\r\n",
        content_type,
        if supports_ranges { "bytes" } else { "none" }
    );

    if range.is_some() {
        headers.push_str(&format!("Content-Range: bytes {start}-{end}/{length}\r\n"));
    }

    headers.push_str("Connection: close\r\n\r\n");
    stream.write_all(headers.as_bytes())?;

    if head_only {
        return Ok(());
    }

    file.seek(SeekFrom::Start(start))?;
    copy_limited(&mut file, stream, content_length)
}

fn copy_limited(file: &mut File, stream: &mut TcpStream, mut remaining: u64) -> io::Result<()> {
    let mut buffer = [0u8; 64 * 1024];

    while remaining > 0 {
        let read_limit = remaining.min(buffer.len() as u64) as usize;
        let read = file.read(&mut buffer[..read_limit])?;
        if read == 0 {
            break;
        }

        stream.write_all(&buffer[..read])?;
        remaining -= read as u64;
    }

    Ok(())
}

fn parse_range_header(header: &str, length: u64) -> Result<(u64, u64), ()> {
    let range = header
        .trim()
        .strip_prefix("bytes=")
        .ok_or(())?
        .split(',')
        .next()
        .ok_or(())?
        .trim();
    let (start, end) = range.split_once('-').ok_or(())?;

    if start.is_empty() {
        let suffix_length = end.parse::<u64>().map_err(|_| ())?;
        if suffix_length == 0 {
            return Err(());
        }
        let start = length.saturating_sub(suffix_length);
        return Ok((start, length - 1));
    }

    let start = start.parse::<u64>().map_err(|_| ())?;
    let end = if end.is_empty() {
        length - 1
    } else {
        end.parse::<u64>().map_err(|_| ())?.min(length - 1)
    };

    if start >= length || end < start {
        return Err(());
    }

    Ok((start, end))
}

fn write_range_not_satisfiable(stream: &mut TcpStream, length: u64) -> io::Result<()> {
    let response = format!(
        "HTTP/1.1 416 Range Not Satisfiable\r\n\
         Content-Range: bytes */{length}\r\n\
         Content-Length: 0\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Connection: close\r\n\r\n"
    );
    stream.write_all(response.as_bytes())
}

fn write_empty_response(stream: &mut TcpStream, status: &str) -> io::Result<()> {
    let response = format!(
        "HTTP/1.1 {status}\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n\
         Access-Control-Allow-Headers: Range\r\n\
         Content-Length: 0\r\n\
         Connection: close\r\n\r\n"
    );
    stream.write_all(response.as_bytes())
}

fn write_text_response(stream: &mut TcpStream, status: &str, body: &str) -> io::Result<()> {
    let response = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: text/plain; charset=utf-8\r\n\
         Content-Length: {}\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Connection: close\r\n\r\n\
         {body}",
        body.len()
    );
    stream.write_all(response.as_bytes())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(WatchState::default())
        .manage(MediaServer::default())
        .invoke_handler(tauri::generate_handler![
            scan_library,
            copy_track_to_liked,
            remove_liked_track,
            set_track_playlist_memberships,
            import_library_manifest,
            rename_playlist,
            sync_library_to_server,
            sync_library_from_server,
            prepare_track_playback,
            start_library_watch,
            stop_library_watch
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::{parse_range_header, MediaServer};
    use crate::library::CachedArtwork;
    use std::io::{Read, Write};
    use std::net::TcpStream;

    #[test]
    fn parses_byte_ranges_for_audio_streaming() {
        assert_eq!(parse_range_header("bytes=0-1023", 10_000), Ok((0, 1023)));
        assert_eq!(parse_range_header("bytes=1024-", 10_000), Ok((1024, 9999)));
        assert_eq!(parse_range_header("bytes=-500", 10_000), Ok((9500, 9999)));
    }

    #[test]
    fn rejects_unsatisfiable_byte_ranges() {
        assert_eq!(parse_range_header("bytes=10000-", 10_000), Err(()));
        assert_eq!(parse_range_header("bytes=500-100", 10_000), Err(()));
        assert_eq!(parse_range_header("items=0-10", 10_000), Err(()));
    }

    #[test]
    fn media_server_serves_registered_byte_ranges() {
        let temp = tempfile::tempdir().unwrap();
        let track_path = temp.path().join("track.mp3");
        std::fs::write(&track_path, b"0123456789").unwrap();

        let server = MediaServer::default();
        let source = server.register_audio(track_path).unwrap();
        let request_target = source.url.strip_prefix("http://").unwrap();
        let (address, path) = request_target.split_once('/').unwrap();

        let mut stream = TcpStream::connect(address).unwrap();
        write!(
            stream,
            "GET /{path} HTTP/1.1\r\nHost: {address}\r\nRange: bytes=2-5\r\n\r\n"
        )
        .unwrap();

        let mut response = Vec::new();
        stream.read_to_end(&mut response).unwrap();

        let response_text = String::from_utf8_lossy(&response);
        assert!(response_text.starts_with("HTTP/1.1 206 Partial Content"));
        assert!(response_text.contains("Content-Range: bytes 2-5/10"));
        assert!(response.ends_with(b"2345"));
    }

    #[test]
    fn media_server_serves_registered_artwork_cache_file() {
        let temp = tempfile::tempdir().unwrap();
        let source_path = temp.path().join("track.mp3");
        let cache_path = temp.path().join("thumb.jpg");
        std::fs::write(&source_path, b"source").unwrap();
        std::fs::write(&cache_path, b"jpeg").unwrap();

        let server = MediaServer::default();
        let url = server
            .register_artwork(CachedArtwork {
                source_path,
                cache_path,
            })
            .unwrap();
        let request_target = url.strip_prefix("http://").unwrap();
        let (address, path) = request_target.split_once('/').unwrap();

        let mut stream = TcpStream::connect(address).unwrap();
        write!(stream, "GET /{path} HTTP/1.1\r\nHost: {address}\r\n\r\n").unwrap();

        let mut response = Vec::new();
        stream.read_to_end(&mut response).unwrap();

        let response_text = String::from_utf8_lossy(&response);
        assert!(response_text.starts_with("HTTP/1.1 200 OK"));
        assert!(response_text.contains("Content-Type: image/jpeg"));
        assert!(response.ends_with(b"jpeg"));
    }
}
