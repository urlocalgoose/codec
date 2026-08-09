// Upload/download real MP3s and artwork between a local library and a sync server.

use super::*;

#[derive(Clone, Debug, Default, Serialize)]
pub struct SyncTransferReport {
    pub tracks_uploaded: usize,
    pub tracks_downloaded: usize,
    pub tracks_skipped: usize,
    pub artwork_uploaded: usize,
    pub playlist_updates: usize,
    pub liked_updates: usize,
    pub failures: Vec<SyncFailure>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SyncFailure {
    pub track: String,
    pub reason: String,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct RemoteSyncSnapshot {
    pub(crate) library: RemoteLibrary,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct RemoteLibrary {
    #[serde(default)]
    pub(crate) playlists: Vec<RemotePlaylist>,
    #[serde(default)]
    pub(crate) tracks: Vec<RemoteTrack>,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct RemotePlaylist {
    pub(crate) id: String,
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) track_ids: Vec<String>,
    #[serde(default)]
    pub(crate) is_liked: bool,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct RemoteTrack {
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) file_name: String,
    pub(crate) title: String,
    pub(crate) artist: String,
    pub(crate) album: String,
    #[serde(default)]
    pub(crate) album_artist: Option<String>,
    #[serde(default)]
    pub(crate) genre: Option<String>,
    #[serde(default)]
    pub(crate) year: Option<u16>,
    #[serde(default)]
    pub(crate) track_number: Option<u32>,
    #[serde(default)]
    pub(crate) duration_seconds: Option<f64>,
    #[serde(default)]
    pub(crate) is_liked: bool,
    pub(crate) fingerprint: String,
}


pub(crate) fn normalize_server_url(server_url: &str) -> Result<String, String> {
    let trimmed = server_url.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return Err("Sync server URL cannot be empty.".to_string());
    }

    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return Ok(trimmed.to_string());
    }

    Ok(format!("http://{trimmed}"))
}

pub(crate) fn clean_device_id(device_id: &str) -> String {
    let device_id = device_id.trim();
    if device_id.is_empty() {
        format!("desktop-{}", std::process::id())
    } else {
        device_id.to_string()
    }
}

pub(crate) fn sync_http_client(auth_token: &str) -> Result<reqwest::blocking::Client, String> {
    let mut builder = reqwest::blocking::Client::builder().timeout(Duration::from_secs(180));

    let token = auth_token.trim();
    if !token.is_empty() {
        let mut headers = reqwest::header::HeaderMap::new();
        let mut value = reqwest::header::HeaderValue::from_str(&format!("Bearer {token}"))
            .map_err(|err| format!("Auth token is not a valid header value: {err}"))?;
        value.set_sensitive(true);
        headers.insert(reqwest::header::AUTHORIZATION, value);
        builder = builder.default_headers(headers);
    }

    builder
        .build()
        .map_err(|err| format!("Could not create sync HTTP client: {err}"))
}

pub(crate) fn ensure_success(
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

pub(crate) fn sync_remote_exists(client: &reqwest::blocking::Client, url: &str) -> bool {
    client
        .head(url)
        .send()
        .map(|response| response.status().is_success())
        .unwrap_or(false)
}

pub(crate) fn upload_file(
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

pub(crate) fn sync_track_media_url(server_url: &str, fingerprint: &str, media_kind: &str) -> String {
    format!(
        "{server_url}/api/v1/tracks/{}/{}",
        percent_encode_path_segment(fingerprint),
        media_kind
    )
}

pub(crate) fn percent_encode_path_segment(value: &str) -> String {
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

pub(crate) fn remote_playlist_names_by_track_id(library: &RemoteLibrary) -> BTreeMap<String, Vec<String>> {
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

pub(crate) fn sync_state_from_remote(library: RemoteLibrary) -> SyncLibraryState {
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

pub(crate) fn sync_download_file_name(track: &RemoteTrack) -> String {
    let mut name = safe_sync_file_component(if track.file_name.trim().is_empty() {
        &track.title
    } else {
        &track.file_name
    });
    let has_supported_extension = ["mp3", "m4a", "flac", "wav"]
        .iter()
        .any(|extension| name.to_lowercase().ends_with(&format!(".{extension}")));
    if !has_supported_extension {
        name.push_str(".mp3");
    }
    name
}

/// Content type for an audio file, by extension. MP3 is the default so
/// unknown extensions still stream (players sniff the payload anyway).
pub(crate) fn audio_content_type(path: &std::path::Path) -> &'static str {
    match path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .as_deref()
    {
        Some("m4a") => "audio/mp4",
        Some("flac") => "audio/flac",
        Some("wav") => "audio/wav",
        _ => "audio/mpeg",
    }
}

pub(crate) fn safe_sync_file_component(value: &str) -> String {
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

pub(crate) fn unique_sync_download_path(destination: PathBuf) -> PathBuf {
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

pub(crate) fn path_to_sync_string(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

pub(crate) fn unix_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0)
}
