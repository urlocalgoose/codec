// loud.import.v1 manifest import: copy supported audio, match existing identities.

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

    // Validate names before even warming the scan cache: normalized state IDs
    // must not silently combine differently named source/destination playlists.
    validate_import_playlist_names(&root, &manifest_dir, &manifest)?;

    let mut report = ImportReport {
        playlist_artwork_imported: 0,
        track_artwork_imported: 0,
        artwork_already_present: 0,
        artwork_missing: 0,
        artwork_failed: 0,
        artwork_failures: Vec::new(),
        track_fingerprints: Vec::new(),
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
    let mut fingerprints_by_identity = known_fingerprints
        .iter()
        .map(|fingerprint| (fingerprint.clone(), fingerprint.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut ambiguous_identities = BTreeSet::new();
    for metadata in state
        .managed_tracks
        .values()
        .filter(|track| known_fingerprints.contains(&track.fingerprint))
    {
        for identity in identifier_identity_candidates(&metadata.identifiers) {
            register_import_identity(
                identity,
                &metadata.fingerprint,
                &known_fingerprints,
                &mut fingerprints_by_identity,
                &mut ambiguous_identities,
            );
        }
    }
    let mut known_tracks = existing_library
        .tracks
        .iter()
        .map(|track| (track.fingerprint.clone(), track.clone()))
        .collect::<BTreeMap<_, _>>();
    // Keep destination playlist IDs when names already exist, including folder playlists.
    for playlist in &manifest.playlists {
        if let Some(existing) = existing_library.playlists.iter().find(|existing| {
            !existing.is_liked && normalize(&existing.name) == normalize(&playlist.name)
        }) {
            state_playlist_mut_by_id(&mut state, &existing.id, &existing.name);
        } else {
            state_playlist_mut(&mut state, &playlist.name);
        }
    }

    let mut manifest_tracks_by_file = BTreeMap::<String, ImportTrack>::new();

    for track in manifest.tracks {
        if let Some(previous) = manifest_tracks_by_file.get(&track.file) {
            if clean_plain_text(previous.fingerprint.as_deref())
                != clean_plain_text(track.fingerprint.as_deref())
            {
                report.skipped_tracks += 1;
                report.failures.push(ImportFailure {
                    file: track.file.clone(),
                    reason: "The same source file declares conflicting track fingerprints."
                        .to_string(),
                });
                continue;
            }
        }
        manifest_tracks_by_file.insert(track.file.clone(), track);
    }

    for playlist in &manifest.playlists {
        for track_ref in &playlist.tracks {
            let Some(file) = track_ref.file() else {
                continue;
            };

            let (reference_fingerprint, reference_identifiers) = match track_ref {
                PlaylistTrackRef::Identity {
                    fingerprint,
                    identifiers,
                    ..
                } => (fingerprint.clone(), identifiers.clone()),
                PlaylistTrackRef::Value(_) => (None, TrackIdentifiers::default()),
            };
            if !manifest_tracks_by_file.contains_key(file)
                && (fingerprints_by_identity.contains_key(file)
                    || reference_fingerprint
                        .as_ref()
                        .map(|value| known_fingerprints.contains(value))
                        .unwrap_or(false))
            {
                continue;
            }
            manifest_tracks_by_file
                .entry(file.to_string())
                .or_insert_with(|| ImportTrack {
                    artwork: None,
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
                    fingerprint: reference_fingerprint,
                    identifiers: reference_identifiers,
                    source_urls: BTreeMap::new(),
                    liked: false,
                    playlists: Vec::new(),
                });
        }
    }

    for import_track in manifest_tracks_by_file.values() {
        let explicit = clean_plain_text(import_track.fingerprint.as_deref());
        let existing_exact = explicit
            .as_ref()
            .and_then(|identity| known_tracks.get(identity));
        let source = if existing_exact.is_some() {
            None
        } else {
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
            if !is_supported_audio(&source) {
                report.skipped_tracks += 1;
                report.failures.push(ImportFailure {
                    file: import_track.file.clone(),
                    reason: "Only audio files (mp3, m4a, flac, wav) can be imported.".to_string(),
                });
                continue;
            }
            Some(source)
        };
        let mut track = if let Some(existing) = existing_exact {
            existing.clone()
        } else {
            match read_track(
                &root,
                source.as_ref().expect("unmatched track has source"),
                Vec::new(),
                false,
                false,
            ) {
                Ok(track) => track,
                Err(err) => {
                    report.skipped_tracks += 1;
                    report.failures.push(ImportFailure {
                        file: import_track.file.clone(),
                        reason: err,
                    });
                    continue;
                }
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
            let source = source.as_ref().expect("new track has source");
            let destination = managed_import_destination(&root, &track, source)?;
            fs::copy(source, &destination)
                .map_err(|err| format!("Could not copy imported track: {err}"))?;
            state.managed_tracks.insert(
                relative_path_key(&root, &destination),
                state_track_metadata_from_import(&track, import_track),
            );
            known_fingerprints.insert(track.fingerprint.clone());
            report.new_tracks += 1;
            report.imported_paths.push(path_to_string(&destination));
            track.path = path_to_string(&destination);
        }

        if import_track.liked {
            let changed = state.unliked_fingerprints.remove(&track.fingerprint);
            if state.liked_fingerprints.insert(track.fingerprint.clone()) || changed {
                report.liked_updates += 1;
            }
        }
        push_unique(&mut report.track_fingerprints, track.fingerprint.clone());
        known_tracks.insert(track.fingerprint.clone(), track.clone());

        for playlist_name in &import_track.playlists {
            if add_state_playlist_track(&mut state, playlist_name, &track.fingerprint, false) {
                report.playlist_updates += 1;
            }
        }

        fingerprints_by_file.insert(import_track.file.clone(), track.fingerprint.clone());
        for identity in import_track_identity_aliases(import_track, &track) {
            register_import_identity(
                identity,
                &track.fingerprint,
                &known_fingerprints,
                &mut fingerprints_by_identity,
                &mut ambiguous_identities,
            );
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

            push_unique(&mut report.track_fingerprints, fingerprint.clone());
            if add_state_playlist_track(&mut state, &playlist.name, fingerprint, false) {
                report.playlist_updates += 1;
            }
        }
    }

    import_manifest_artwork(
        &root,
        &manifest_dir,
        base_path,
        &manifest.playlists,
        &manifest_tracks_by_file,
        &fingerprints_by_file,
        &known_fingerprints,
        &existing_library,
        &mut state,
        &mut report,
    );
    write_library_state(&root, &state)?;
    Ok(report)
}

fn validate_import_playlist_names(
    root: &Path,
    manifest_dir: &Path,
    manifest: &ImportManifest,
) -> Result<(), String> {
    let mut incoming = BTreeMap::<String, String>::new();
    let sidecar_names = sidecar_playlist_names(manifest_dir);
    for name in manifest
        .playlists
        .iter()
        .map(|playlist| playlist.name.as_str())
        .chain(
            manifest
                .tracks
                .iter()
                .flat_map(|track| track.playlists.iter().map(String::as_str)),
        )
        .chain(sidecar_names.iter().map(String::as_str))
    {
        let name = name.trim();
        if name.is_empty() {
            return Err("Imported playlist names must not be empty.".to_string());
        }
        let key = normalize(name);
        if let Some(previous) = incoming.get(&key) {
            if previous != name {
                return Err(format!("Playlist name collision: '{previous}' and '{name}' normalize to the same name. Rename one explicitly before importing."));
            }
        } else {
            incoming.insert(key, name.to_string());
        }
    }

    let state = read_library_state(root)?;
    let mut existing = BTreeMap::<String, BTreeSet<(String, String)>>::new();
    for playlist in &state.playlists {
        existing
            .entry(normalize(&playlist.name))
            .or_default()
            .insert((playlist.id.clone(), playlist.name.trim().to_string()));
    }
    for (path, is_liked) in discover_playlist_dirs(root)? {
        if !is_liked {
            let name = file_stem_or_name(&path);
            existing
                .entry(normalize(&name))
                .or_default()
                .insert((playlist_id_for_path(&path), name.trim().to_string()));
        }
    }
    for (key, name) in incoming {
        if let Some(matches) = existing.get(&key) {
            if matches.len() > 1 {
                return Err(format!("Playlist name collision: '{name}' matches multiple existing playlists. Resolve their names before importing."));
            }
            let (_, existing_name) = matches.iter().next().expect("nonempty existing names");
            if existing_name != &name {
                return Err(format!("Playlist name collision: imported '{name}' conflicts with existing '{existing_name}'. Use its exact name or rename one explicitly before importing."));
            }
        } else if let Some(playlist) = state
            .playlists
            .iter()
            .find(|playlist| playlist.id == state_playlist_id_for_name(&name))
        {
            return Err(format!("Playlist identity collision: '{name}' would reuse the ID of renamed playlist '{}'. Rename the imported playlist explicitly.", playlist.name));
        }
    }
    Ok(())
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
        } => {
            if let Some(fingerprint) = clean_plain_text(fingerprint.as_deref()) {
                return fingerprints_by_identity
                    .get(&fingerprint)
                    .filter(|resolved| *resolved == &fingerprint);
            }
            file.as_ref()
                .and_then(|file| fingerprints_by_file.get(file))
                .or_else(|| {
                    identifier_identity_candidates(identifiers)
                        .into_iter()
                        .find_map(|identity| fingerprints_by_identity.get(&identity))
                })
        }
    }
}

pub(super) fn resolve_manifest_file(
    manifest_dir: &Path,
    base_path: Option<&str>,
    file: &str,
) -> PathBuf {
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
    if let Some(disc_number) = import_track.disc_number {
        track.disc_number = Some(disc_number);
    }
    if let Some(explicit) = import_track.explicit {
        track.explicit = Some(explicit);
    }
    track.identifiers.extend(import_track.identifiers.to_map());
    track.source_urls.extend(import_track.source_urls.clone());
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
    if let Some(explicit) = clean_plain_text(import_track.fingerprint.as_deref()) {
        return known_fingerprints.contains(&explicit).then_some(explicit);
    }
    let loud_metadata_fingerprint = fingerprint_for(&track.title, &track.artist, &track.album);
    import_track_identity_aliases(import_track, track)
        .into_iter()
        .chain([loud_metadata_fingerprint])
        .find(|fingerprint| known_fingerprints.contains(fingerprint))
}

pub(super) fn import_track_identity_aliases(
    import_track: &ImportTrack,
    track: &Track,
) -> Vec<String> {
    let mut aliases = Vec::new();

    if let Some(fingerprint) = import_track
        .fingerprint
        .as_deref()
        .and_then(|fingerprint| clean_plain_text(Some(fingerprint)))
    {
        // Keep provider aliases for playlist references; matching an explicit
        // track still uses only its exact fingerprint, never these aliases.
        aliases.push(fingerprint);
    }

    for identity in identifier_identity_candidates(&import_track.identifiers) {
        push_unique(&mut aliases, identity);
    }

    push_unique(&mut aliases, track.fingerprint.clone());
    if clean_plain_text(import_track.fingerprint.as_deref()).is_none() {
        push_unique(
            &mut aliases,
            fingerprint_for(&track.title, &track.artist, &track.album),
        );
    }
    aliases
}

fn register_import_identity(
    identity: String,
    fingerprint: &str,
    known: &BTreeSet<String>,
    identities: &mut BTreeMap<String, String>,
    ambiguous: &mut BTreeSet<String>,
) {
    // An actual fingerprint always wins over a provider alias of the same text.
    if known.contains(&identity) {
        identities.insert(identity.clone(), identity);
        return;
    }
    if ambiguous.contains(&identity) {
        return;
    }
    if identities
        .get(&identity)
        .is_some_and(|existing| existing != fingerprint)
    {
        identities.remove(&identity);
        ambiguous.insert(identity);
    } else {
        identities.insert(identity, fingerprint.to_string());
    }
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

pub(super) fn prefixed_identifier(
    prefix: &str,
    value: Option<&str>,
    uppercase: bool,
) -> Option<String> {
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
    _import_track: &ImportTrack,
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
        disc_number: track.disc_number,
        duration_seconds: track.duration_seconds,
        explicit: track.explicit,
        identifiers: TrackIdentifiers::from_map(track.identifiers.clone()),
        source_urls: track.source_urls.clone(),
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
