// .loud/state.json persistence: app truth for likes, playlists, metadata.

use super::*;

pub(super) fn default_library_state() -> LibraryState {
    LibraryState {
        schema_version: 1,
        liked_fingerprints: BTreeSet::new(),
        unliked_fingerprints: BTreeSet::new(),
        playlists: Vec::new(),
        removed_playlist_memberships: Vec::new(),
        managed_tracks: BTreeMap::new(),
        scan_cache: BTreeMap::new(),
    }
}

pub(super) fn state_file_path(root: &Path) -> PathBuf {
    root.join(STATE_DIR_NAME).join(STATE_FILE_NAME)
}

pub(super) fn managed_audio_dir(root: &Path) -> PathBuf {
    root.join(STATE_DIR_NAME).join(MANAGED_AUDIO_DIR_NAME)
}

pub(super) fn artwork_cache_dir(root: &Path) -> PathBuf {
    root.join(STATE_DIR_NAME)
        .join(CACHE_DIR_NAME)
        .join(ARTWORK_DIR_NAME)
}

pub(super) fn read_library_state(root: &Path) -> Result<LibraryState, String> {
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

pub(super) fn write_library_state(root: &Path, state: &LibraryState) -> Result<(), String> {
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


pub(super) fn apply_state_playlists(
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

pub(super) fn apply_removed_playlist_memberships(
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

pub(super) fn state_playlist_id_for_name(name: &str) -> String {
    format!("playlist_state_{}", stable_id(&normalize(name)))
}

pub(super) fn state_playlist_mut_by_id<'a>(
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

pub(super) fn state_playlist_mut<'a>(state: &'a mut LibraryState, name: &str) -> &'a mut StatePlaylist {
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

pub(super) fn clear_state_playlist_tracks(state: &mut LibraryState, name: &str) {
    state_playlist_mut(state, name).track_fingerprints.clear();
}

pub(super) fn remove_state_playlist_track_by_id(
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

pub(super) fn add_state_playlist_track(
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

pub(super) fn add_removed_playlist_membership(state: &mut LibraryState, playlist_id: &str, fingerprint: &str) {
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

pub(super) fn remove_removed_playlist_membership(
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

pub(super) fn push_unique<T: Eq>(items: &mut Vec<T>, item: T) {
    if !items.iter().any(|existing| existing == &item) {
        items.push(item);
    }
}


pub(super) fn apply_state_track_metadata(track: &mut Track, metadata: &StateTrackMetadata) {
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

