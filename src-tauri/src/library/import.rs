// loud.import.v1 manifest import: copy new MP3s, match existing identities.

use super::*;

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

pub(super) fn default_playlist_mode() -> String {
    "append".to_string()
}


impl PlaylistTrackRef {
    pub(super) fn file(&self) -> Option<&str> {
        match self {
            PlaylistTrackRef::Value(value) => Some(value),
            PlaylistTrackRef::Identity { file, .. } => file.as_deref(),
        }
    }

    pub(super) fn label(&self) -> String {
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

pub(super) fn resolve_playlist_track_ref<'a>(
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

pub(super) fn resolve_manifest_file(manifest_dir: &Path, base_path: Option<&str>, file: &str) -> PathBuf {
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

pub(super) fn apply_import_metadata(track: &mut Track, import_track: &ImportTrack) {
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

pub(super) fn canonical_import_fingerprint(import_track: &ImportTrack, track: &Track) -> String {
    import_track
        .fingerprint
        .as_deref()
        .and_then(|fingerprint| clean_plain_text(Some(fingerprint)))
        .or_else(|| primary_identifier_identity(&import_track.identifiers))
        .unwrap_or_else(|| fingerprint_for(&track.title, &track.artist, &track.album))
}

pub(super) fn matching_existing_fingerprint(
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

pub(super) fn import_track_identity_aliases(import_track: &ImportTrack, track: &Track) -> Vec<String> {
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

pub(super) fn primary_identifier_identity(identifiers: &TrackIdentifiers) -> Option<String> {
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

pub(super) fn identifier_identity_candidates(identifiers: &TrackIdentifiers) -> Vec<String> {
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

pub(super) fn prefixed_identifier(prefix: &str, value: Option<&str>, uppercase: bool) -> Option<String> {
    let value = clean_plain_text(value)?;
    let value = if uppercase {
        value.to_uppercase()
    } else {
        value
    };
    Some(format!("{prefix}:{value}"))
}


pub(super) fn state_track_metadata_from_import(
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


pub(super) fn managed_import_destination(
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

