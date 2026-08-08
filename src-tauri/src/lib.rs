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

mod media_server;
mod sync_transfer;

use media_server::*;
use sync_transfer::*;

#[derive(Clone, Debug, Serialize)]
struct LibraryChanged {
    root_path: String,
}

#[derive(Clone, Debug, Serialize)]
struct PlaybackSource {
    url: String,
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
    auth_token: String,
) -> Result<SyncTransferReport, String> {
    let root = PathBuf::from(&root_path)
        .canonicalize()
        .map_err(|err| format!("Could not resolve folder: {err}"))?;
    if !root.is_dir() {
        return Err("Music folder must be a directory.".to_string());
    }

    let server_url = normalize_server_url(&server_url)?;
    let device_id = clean_device_id(&device_id);
    let client = sync_http_client(&auth_token)?;
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
            // Artwork always re-uploads: it is small, and skipping would
            // leave old low-resolution thumbnails on the server forever.
            let artwork_url = sync_track_media_url(&server_url, &track.fingerprint, "artwork");
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
    auth_token: String,
) -> Result<SyncTransferReport, String> {
    let root = PathBuf::from(&root_path)
        .canonicalize()
        .map_err(|err| format!("Could not resolve folder: {err}"))?;
    if !root.is_dir() {
        return Err("Music folder must be a directory.".to_string());
    }

    let server_url = normalize_server_url(&server_url)?;
    let client = sync_http_client(&auth_token)?;
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
