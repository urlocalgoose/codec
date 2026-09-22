// Upload/download real MP3s and artwork between a local library and a sync server.

use super::*;

#[derive(Clone, Debug, Default, Serialize)]
pub struct SyncTransferReport {
    pub tracks_matched: usize,
    pub tracks_added: usize,
    pub tracks_uploaded: usize,
    pub tracks_downloaded: usize,
    pub tracks_skipped: usize,
    pub artwork_uploaded: usize,
    pub artwork_downloaded: usize,
    pub artwork_already_present: usize,
    pub artwork_missing: usize,
    pub artwork_failed: usize,
    pub track_artwork_uploaded: usize,
    pub playlist_artwork_uploaded: usize,
    pub track_artwork_downloaded: usize,
    pub playlist_artwork_downloaded: usize,
    pub track_artwork_already_present: usize,
    pub playlist_artwork_already_present: usize,
    pub track_artwork_missing: usize,
    pub playlist_artwork_missing: usize,
    pub track_artwork_failed: usize,
    pub playlist_artwork_failed: usize,
    pub playlists_added: usize,
    pub playlists_updated: usize,
    pub playlist_tracks_added: usize,
    pub playlist_updates: usize,
    pub liked_updates: usize,
    pub failures: Vec<SyncFailure>,
    pub playlist_mappings: Vec<SyncPlaylistMapping>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SyncPlaylistMapping {
    pub source_id: String,
    pub source_name: String,
    pub destination_id: String,
    pub destination_name: String,
    pub created: bool,
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
    pub(crate) disc_number: Option<u32>,
    #[serde(default)]
    pub(crate) explicit: Option<bool>,
    #[serde(default)]
    pub(crate) identifiers: BTreeMap<String, String>,
    #[serde(default)]
    pub(crate) source_urls: BTreeMap<String, String>,
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

    let candidate = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("http://{trimmed}")
    };
    let parsed =
        reqwest::Url::parse(&candidate).map_err(|_| "Invalid sync server URL.".to_string())?;
    if parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err("Use a server URL without credentials, query parameters, or fragments; pass credentials with --token-file.".to_string());
    }
    Ok(candidate)
}

pub(crate) fn sync_http_client(auth_token: &str) -> Result<reqwest::blocking::Client, String> {
    let mut builder = reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(180));

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
    // A reverse proxy may echo credentials in its response. Never print that
    // body in CLI logs/reports; status and the operation identify the failure.
    Err(format!("Could not {action}: server returned {status}."))
}

/// Only a 404 means absent. A failed/auth-blocked HEAD must never authorize an
/// overwrite, including when importing against older servers without ETags.
pub(crate) fn checked_remote_exists(
    client: &reqwest::blocking::Client,
    url: &str,
) -> Result<bool, String> {
    let response = client
        .head(url)
        .send()
        .map_err(|err| format!("Could not check remote media: {}", err.without_url()))?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(false);
    }
    ensure_success(response, "check remote media").map(|_| true)
}

pub(crate) fn fetch_remote_snapshot(
    client: &reqwest::blocking::Client,
    server: &str,
) -> Result<RemoteSyncSnapshot, String> {
    let response = client
        .get(format!("{server}/api/v1/sync/snapshot"))
        .send()
        .map_err(|err| format!("Could not load sync snapshot: {}", err.without_url()))?;
    ensure_success(response, "load sync snapshot")?
        .json()
        .map_err(|_| "Could not parse sync snapshot.".to_string())
}

#[derive(Clone, Copy)]
pub(crate) enum ArtworkKind {
    Track,
    Playlist,
}

impl SyncTransferReport {
    pub(crate) fn artwork_present(&mut self, kind: ArtworkKind) {
        self.artwork_already_present += 1;
        match kind {
            ArtworkKind::Track => self.track_artwork_already_present += 1,
            ArtworkKind::Playlist => self.playlist_artwork_already_present += 1,
        }
    }
    pub(crate) fn artwork_missing(&mut self, kind: ArtworkKind) {
        self.artwork_missing += 1;
        match kind {
            ArtworkKind::Track => self.track_artwork_missing += 1,
            ArtworkKind::Playlist => self.playlist_artwork_missing += 1,
        }
    }
    pub(crate) fn artwork_failure(&mut self, kind: ArtworkKind, name: &str, reason: String) {
        self.artwork_failed += 1;
        match kind {
            ArtworkKind::Track => self.track_artwork_failed += 1,
            ArtworkKind::Playlist => self.playlist_artwork_failed += 1,
        }
        self.failures.push(SyncFailure {
            track: name.to_string(),
            reason,
        });
    }
}

pub(crate) fn sync_playlist_artwork_url(server: &str, id: &str) -> String {
    format!(
        "{server}/api/v1/playlists/{}/artwork",
        percent_encode_path_segment(id)
    )
}

/// Original validated sidecars bypass thumbnail generation completely. JPEG
/// bytes remain identical; PNG and other supported images keep their MIME.
fn artwork_upload_source(artwork: &CachedArtwork) -> Result<(PathBuf, String), String> {
    if let Some(mime) = artwork.original_mime_type.as_ref() {
        Ok((artwork.source_path.clone(), mime.clone()))
    } else {
        ensure_cached_artwork_thumbnail(artwork).map(|path| (path, "image/jpeg".to_string()))
    }
}

pub(crate) fn upload_artwork_if_missing(
    client: &reqwest::blocking::Client,
    url: &str,
    artwork: Option<&CachedArtwork>,
    kind: ArtworkKind,
    name: &str,
    report: &mut SyncTransferReport,
) {
    let result = (|| -> Result<Option<bool>, String> {
        if checked_remote_exists(client, url)? {
            return Ok(Some(false));
        }
        let Some(artwork) = artwork else {
            return Ok(None);
        };
        let (path, mime) = artwork_upload_source(artwork)?;
        let file = File::open(&path).map_err(|err| format!("Could not open artwork: {err}"))?;
        let size = file
            .metadata()
            .map_err(|err| format!("Could not read artwork size: {err}"))?
            .len();
        let response = client
            .put(url)
            .header(reqwest::header::CONTENT_TYPE, mime)
            .header(reqwest::header::CONTENT_LENGTH, size)
            .header(reqwest::header::IF_NONE_MATCH, "*")
            .body(reqwest::blocking::Body::new(file))
            .send()
            .map_err(|err| format!("Could not upload artwork: {}", err.without_url()))?;
        if response.status() == reqwest::StatusCode::PRECONDITION_FAILED {
            return Ok(Some(false));
        }
        ensure_success(response, "upload artwork")?;
        Ok(Some(true))
    })();
    match result {
        Ok(Some(true)) => {
            report.artwork_uploaded += 1;
            match kind {
                ArtworkKind::Track => report.track_artwork_uploaded += 1,
                ArtworkKind::Playlist => report.playlist_artwork_uploaded += 1,
            }
        }
        Ok(Some(false)) => report.artwork_present(kind),
        Ok(None) => report.artwork_missing(kind),
        Err(reason) => report.artwork_failure(kind, name, reason),
    }
}

/// Track totals cannot detect one lost identity replaced by a fallback identity.
/// Require every successful import target to survive the exact upload scan.
pub(crate) fn validate_import_fingerprints(
    library: &Library,
    expected_fingerprints: &[String],
) -> Result<(), String> {
    let actual = library
        .tracks
        .iter()
        .map(|track| track.fingerprint.as_str())
        .collect::<BTreeSet<_>>();
    let missing = expected_fingerprints
        .iter()
        .filter(|fingerprint| !actual.contains(fingerprint.as_str()))
        .collect::<BTreeSet<_>>();
    if missing.is_empty() {
        return Ok(());
    }
    let examples = missing
        .iter()
        .take(3)
        .map(|fingerprint| fingerprint.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    Err(format!(
        "Import rescan lost {} successful exact track fingerprint(s): {examples}. No server changes were made; resolve the local library identity mismatch before retrying.",
        missing.len()
    ))
}

/// Additive import deliberately does not use /sync/push or replacement playlist
/// PUTs. Existing metadata and ordered memberships remain server-owned.
pub(crate) fn merge_library_to_server(
    library: &Library,
    client: &reqwest::blocking::Client,
    server: &str,
) -> Result<SyncTransferReport, String> {
    let snapshot = fetch_remote_snapshot(client, server)?;
    let mut remote_tracks = BTreeMap::new();
    for track in &snapshot.library.tracks {
        if remote_tracks
            .insert(track.fingerprint.clone(), track.clone())
            .is_some()
        {
            return Err("Server snapshot contains duplicate exact track fingerprints; no import changes were made.".to_string());
        }
    }
    let mut remote_playlists = BTreeMap::new();
    for playlist in snapshot.library.playlists.iter().filter(|p| !p.is_liked) {
        remote_playlists
            .entry(playlist.name.trim().to_string())
            .or_insert_with(Vec::new)
            .push(playlist.clone());
    }
    let mut source_names = BTreeSet::new();
    for playlist in library.playlists.iter().filter(|p| !p.is_liked) {
        let name = playlist.name.trim();
        if name.is_empty()
            || !source_names.insert(name)
            || remote_playlists
                .get(name)
                .is_some_and(|matches| matches.len() != 1)
        {
            return Err(format!("Playlist name '{name}' is empty or ambiguous. Rename duplicate playlists before merging; no import changes were made."));
        }
    }
    let tracks_by_id = library
        .tracks
        .iter()
        .map(|track| (track.id.as_str(), track))
        .collect::<BTreeMap<_, _>>();
    let mut report = SyncTransferReport::default();
    let mut available = BTreeSet::new();
    for track in &library.tracks {
        let fingerprint = &track.fingerprint;
        let metadata_url = format!(
            "{server}/api/v1/tracks/{}",
            percent_encode_path_segment(fingerprint)
        );
        if let Some(remote) = remote_tracks.get(fingerprint) {
            report.tracks_matched += 1;
            if track.is_liked && !remote.is_liked {
                let result = client
                    .put(format!("{metadata_url}/liked"))
                    .json(&json!({"liked":true}))
                    .send()
                    .map_err(|err| format!("Could not add liked song: {}", err.without_url()))
                    .and_then(|response| ensure_success(response, "add liked song"));
                match result {
                    Ok(_) => report.liked_updates += 1,
                    Err(reason) => report.failures.push(SyncFailure {
                        track: track.title.clone(),
                        reason,
                    }),
                }
            }
        } else {
            let mut metadata = serde_json::to_value(track)
                .map_err(|_| "Could not encode track metadata.".to_string())?;
            metadata["id"] = json!(format!("track_{fingerprint}"));
            // Memberships are added only after destination playlist IDs exist.
            metadata["playlist_ids"] = json!([]);
            metadata["artwork_url"] = serde_json::Value::Null;
            let result = client
                .put(&metadata_url)
                .json(&metadata)
                .send()
                .map_err(|err| format!("Could not add track metadata: {}", err.without_url()))
                .and_then(|response| ensure_success(response, "add track metadata"));
            if let Err(reason) = result {
                report.failures.push(SyncFailure {
                    track: track.title.clone(),
                    reason,
                });
                continue;
            }
            report.tracks_added += 1;
            if track.is_liked {
                report.liked_updates += 1;
            }
        }
        let audio_url = sync_track_media_url(server, fingerprint, "audio");
        let audio_result = checked_remote_exists(client, &audio_url).and_then(|present| {
            if present {
                Ok(false)
            } else {
                upload_file(
                    client,
                    &audio_url,
                    &track.path,
                    audio_content_type(Path::new(&track.path)),
                )
                .map(|_| true)
            }
        });
        match audio_result {
            Ok(uploaded) => {
                if uploaded {
                    report.tracks_uploaded += 1;
                } else {
                    report.tracks_skipped += 1;
                }
                available.insert(fingerprint.clone());
            }
            Err(reason) => report.failures.push(SyncFailure {
                track: track.title.clone(),
                reason,
            }),
        }
        upload_artwork_if_missing(
            client,
            &sync_track_media_url(server, fingerprint, "artwork"),
            track.artwork.as_ref(),
            ArtworkKind::Track,
            &track.title,
            &mut report,
        );
    }
    for playlist in library.playlists.iter().filter(|p| !p.is_liked) {
        let name = playlist.name.trim();
        let (mut destination, created) = if let Some(matches) = remote_playlists.get(name) {
            (matches[0].clone(), false)
        } else {
            let result = client
                .post(format!("{server}/api/v1/playlists"))
                .json(&json!({"name":name}))
                .send()
                .map_err(|err| format!("Could not create playlist: {}", err.without_url()))
                .and_then(|response| ensure_success(response, "create playlist"))
                .and_then(|response| {
                    response
                        .json::<RemotePlaylist>()
                        .map_err(|_| "Could not parse created playlist.".to_string())
                });
            match result {
                Ok(destination) if !destination.id.is_empty() && !destination.is_liked => {
                    report.playlists_added += 1;
                    (destination, true)
                }
                Ok(_) => {
                    report.failures.push(SyncFailure {
                        track: name.to_string(),
                        reason: "Server returned an invalid destination playlist.".to_string(),
                    });
                    continue;
                }
                Err(reason) => {
                    report.failures.push(SyncFailure {
                        track: name.to_string(),
                        reason,
                    });
                    continue;
                }
            }
        };
        report.playlist_mappings.push(SyncPlaylistMapping {
            source_id: playlist.id.clone(),
            source_name: playlist.name.clone(),
            destination_id: destination.id.clone(),
            destination_name: destination.name.clone(),
            created,
        });
        let mut changed = false;
        for source_id in &playlist.track_ids {
            let Some(track) = tracks_by_id.get(source_id.as_str()) else {
                report.failures.push(SyncFailure {
                    track: name.to_string(),
                    reason: format!("Playlist references unknown source track ID '{source_id}'."),
                });
                continue;
            };
            let canonical_id = format!("track_{}", track.fingerprint);
            let destination_track_id = remote_tracks
                .get(&track.fingerprint)
                .map(|track| track.id.as_str())
                .unwrap_or(&canonical_id);
            if destination
                .track_ids
                .iter()
                .any(|id| id == destination_track_id || id == &canonical_id)
            {
                continue;
            }
            if !available.contains(&track.fingerprint) {
                report.failures.push(SyncFailure {
                    track: name.to_string(),
                    reason: format!(
                        "Did not add '{}' because its audio transfer failed.",
                        track.title
                    ),
                });
                continue;
            }
            let result = client
                .post(format!(
                    "{server}/api/v1/playlists/{}/tracks",
                    percent_encode_path_segment(&destination.id)
                ))
                .json(&json!({"fingerprint":track.fingerprint}))
                .send()
                .map_err(|err| format!("Could not append playlist track: {}", err.without_url()))
                .and_then(|response| ensure_success(response, "append playlist track"))
                .and_then(|response| {
                    response
                        .json::<RemotePlaylist>()
                        .map_err(|_| "Could not parse updated playlist.".to_string())
                });
            match result {
                Ok(updated) if updated.id == destination.id => {
                    destination = updated;
                    report.playlist_tracks_added += 1;
                    report.playlist_updates += 1;
                    changed = true;
                }
                Ok(_) => report.failures.push(SyncFailure {
                    track: name.to_string(),
                    reason: "Server returned a different playlist while appending tracks."
                        .to_string(),
                }),
                Err(reason) => report.failures.push(SyncFailure {
                    track: name.to_string(),
                    reason,
                }),
            }
        }
        if changed && !created {
            report.playlists_updated += 1;
        }
        upload_artwork_if_missing(
            client,
            &sync_playlist_artwork_url(server, &destination.id),
            playlist.artwork.as_ref(),
            ArtworkKind::Playlist,
            name,
            &mut report,
        );
    }
    Ok(report)
}

pub(crate) fn upload_file(
    client: &reqwest::blocking::Client,
    url: &str,
    path: impl AsRef<Path>,
    content_type: &str,
) -> Result<(), String> {
    let path = path.as_ref();
    let file = File::open(path).map_err(|err| format!("Could not open upload file: {err}"))?;
    let size = file
        .metadata()
        .map_err(|err| format!("Could not read upload size: {err}"))?
        .len();
    let response = client
        .put(url)
        .header(reqwest::header::CONTENT_TYPE, content_type)
        .header(reqwest::header::CONTENT_LENGTH, size)
        .body(reqwest::blocking::Body::new(file))
        .send()
        .map_err(|err| format!("Could not upload file: {}", err.without_url()))?;
    ensure_success(response, "upload file").map(|_| ())
}

/// Download covers independently of audio. Already-matched tracks participate,
/// and playlist sidecars are applied only after destination playlists exist.
pub(crate) fn download_library_artwork(
    root: &Path,
    import_root: &Path,
    remote: &RemoteLibrary,
    client: &reqwest::blocking::Client,
    server: &str,
    fresh_artwork_fingerprints: &BTreeSet<String>,
    report: &mut SyncTransferReport,
) -> Result<(), String> {
    let local = scan_library_path(root)?;
    let local_tracks = local
        .tracks
        .iter()
        .map(|track| (track.fingerprint.as_str(), track))
        .collect::<BTreeMap<_, _>>();
    let mut tracks = Vec::new();
    let mut playlists = Vec::new();
    let covers = import_root.join("artwork");
    fs::create_dir_all(&covers)
        .map_err(|err| format!("Could not create artwork download folder: {err}"))?;
    for track in &remote.tracks {
        if fresh_artwork_fingerprints.contains(&track.fingerprint) {
            continue;
        }
        let Some(destination) = local_tracks.get(track.fingerprint.as_str()) else {
            continue;
        };
        if destination.artwork.is_some() {
            report.artwork_present(ArtworkKind::Track);
            continue;
        }
        let file = format!("track-{}.image", tracks.len());
        match download_artwork_descriptor(
            client,
            &sync_track_media_url(server, &track.fingerprint, "artwork"),
            &covers.join(&file),
            &format!("artwork/{file}"),
        ) {
            Ok(Some(artwork)) => {
                tracks.push(json!({"fingerprint":track.fingerprint,"artwork":artwork}))
            }
            Ok(None) => report.artwork_missing(ArtworkKind::Track),
            Err(reason) => report.artwork_failure(ArtworkKind::Track, &track.title, reason),
        }
    }
    for playlist in remote
        .playlists
        .iter()
        .filter(|playlist| !playlist.is_liked)
    {
        let matches = local
            .playlists
            .iter()
            .filter(|local| !local.is_liked && local.name.trim() == playlist.name.trim())
            .collect::<Vec<_>>();
        if matches.len() != 1 {
            report.artwork_failure(
                ArtworkKind::Playlist,
                &playlist.name,
                "Downloaded playlist artwork has no unique local destination name.".to_string(),
            );
            continue;
        }
        if matches[0].artwork.is_some() {
            report.artwork_present(ArtworkKind::Playlist);
            continue;
        }
        let file = format!("playlist-{}.image", playlists.len());
        match download_artwork_descriptor(
            client,
            &sync_playlist_artwork_url(server, &playlist.id),
            &covers.join(&file),
            &format!("artwork/{file}"),
        ) {
            Ok(Some(artwork)) => playlists.push(json!({"name":playlist.name,"artwork":artwork})),
            Ok(None) => report.artwork_missing(ArtworkKind::Playlist),
            Err(reason) => report.artwork_failure(ArtworkKind::Playlist, &playlist.name, reason),
        }
    }
    if tracks.is_empty() && playlists.is_empty() {
        return Ok(());
    }
    for (filename, value) in [
        (
            "track-artwork.json",
            json!({"schema":"s2y.track-artwork.v1","base_path":".","tracks":tracks}),
        ),
        (
            "playlist-artwork.json",
            json!({"schema":"s2y.playlist-artwork.v1","base_path":".","playlists":playlists}),
        ),
        (
            "artwork-manifest.json",
            json!({"schema":"loud.import.v1","tracks":[],"playlists":[]}),
        ),
    ] {
        fs::write(
            import_root.join(filename),
            serde_json::to_vec(&value)
                .map_err(|_| "Could not serialize artwork import.".to_string())?,
        )
        .map_err(|err| format!("Could not write artwork import: {err}"))?;
    }
    let imported = import_library_manifest_path(root, import_root.join("artwork-manifest.json"))?;
    report.track_artwork_downloaded += imported.track_artwork_imported;
    report.playlist_artwork_downloaded += imported.playlist_artwork_imported;
    report.artwork_downloaded +=
        imported.track_artwork_imported + imported.playlist_artwork_imported;
    // A concurrent local import may have added a cover after our initial scan.
    report.artwork_already_present += imported.artwork_already_present;
    for failure in imported.artwork_failures {
        let kind = if failure.file.contains("playlist-") {
            ArtworkKind::Playlist
        } else {
            ArtworkKind::Track
        };
        report.artwork_failure(kind, &failure.file, failure.reason);
    }
    Ok(())
}

pub(crate) fn download_artwork_descriptor(
    client: &reqwest::blocking::Client,
    url: &str,
    path: &Path,
    relative: &str,
) -> Result<Option<serde_json::Value>, String> {
    use sha2::{Digest, Sha256};
    let response = client
        .get(url)
        .send()
        .map_err(|err| format!("Could not download artwork: {}", err.without_url()))?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }
    let response = ensure_success(response, "download artwork")?;
    const MAX_BYTES: u64 = 12 * 1024 * 1024;
    if response
        .content_length()
        .is_some_and(|length| length > MAX_BYTES)
    {
        return Err("Artwork exceeds the 12 MiB download limit.".to_string());
    }
    let mut bytes = Vec::new();
    response
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|err| format!("Could not read downloaded artwork: {err}"))?;
    if bytes.is_empty() || bytes.len() as u64 > MAX_BYTES {
        return Err("Artwork is empty or exceeds the 12 MiB download limit.".to_string());
    }
    let format = image::guess_format(&bytes)
        .map_err(|_| "Downloaded artwork is not a supported image.".to_string())?;
    let mime = match format {
        image::ImageFormat::Jpeg => "image/jpeg", image::ImageFormat::Png => "image/png",
        _ => return Err("Downloaded artwork cannot be restored as a sidecar: only JPEG and PNG are supported. Existing local artwork was preserved.".to_string()),
    };
    let (width, height) = image::ImageReader::with_format(io::Cursor::new(&bytes), format)
        .into_dimensions()
        .map_err(|_| "Could not read downloaded artwork dimensions.".to_string())?;
    if width == 0
        || height == 0
        || width > 8192
        || height > 8192
        || u64::from(width) * u64::from(height) > 16 * 1024 * 1024
    {
        return Err("Downloaded artwork dimensions exceed the image limits.".to_string());
    }
    fs::write(path, &bytes).map_err(|err| format!("Could not save downloaded artwork: {err}"))?;
    Ok(Some(
        json!({"file":relative,"mime_type":mime,"width":width,"height":height,"sha256":format!("{:x}",Sha256::digest(&bytes))}),
    ))
}

pub(crate) fn sync_track_media_url(
    server_url: &str,
    fingerprint: &str,
    media_kind: &str,
) -> String {
    format!(
        "{server_url}/api/v1/tracks/{}/{}",
        percent_encode_path_segment(fingerprint),
        media_kind
    )
}

pub(crate) fn percent_encode_path_segment(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.as_bytes() {
        let is_unreserved =
            byte.is_ascii_alphanumeric() || matches!(*byte, b'-' | b'.' | b'_' | b'~');
        if is_unreserved {
            encoded.push(char::from(*byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

pub(crate) fn remote_playlist_names_by_track_id(
    library: &RemoteLibrary,
) -> BTreeMap<String, Vec<String>> {
    let mut names_by_track_id = BTreeMap::<String, Vec<String>>::new();
    for playlist in library
        .playlists
        .iter()
        .filter(|playlist| !playlist.is_liked)
    {
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
