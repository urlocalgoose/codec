// Library mutations: liked tracks, playlist membership, renames, sync merges.

use super::*;

pub fn copy_track_to_liked_path(
    root_path: impl AsRef<Path>,
    track_path: impl AsRef<Path>,
) -> Result<String, String> {
    let root = canonical_dir(root_path.as_ref())?;
    let source = canonical_file(track_path.as_ref())?;

    if !is_supported_audio(&source) {
        return Err("Only audio files (mp3, m4a, flac, wav) can be liked.".to_string());
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

    if !is_supported_audio(&track_path) {
        return Err("Only audio files (mp3, m4a, flac, wav) can be removed from liked songs.".to_string());
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

    if !is_supported_audio(&track_path) {
        return Err("Only audio files (mp3, m4a, flac, wav) can be edited.".to_string());
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

