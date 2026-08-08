// Folder scanning: walk the music root, read tags, build the Library.

use super::*;

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


pub(super) fn direct_child_folder_name(root: &Path, path: &Path) -> Option<String> {
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

pub(super) fn should_replace_canonical_track(
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

pub(super) fn canonical_source_score(root: &Path, path: &Path, is_liked_source: bool) -> u8 {
    if is_liked_source {
        return 0;
    }

    if path.starts_with(managed_audio_dir(root)) {
        return 1;
    }

    2
}


pub(super) fn discover_playlist_dirs(root: &Path) -> Result<Vec<(PathBuf, bool)>, String> {
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

pub(super) fn read_track_with_state(
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

pub(super) fn read_track(
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

