use super::*;
use tempfile::tempdir;

#[test]
fn scans_direct_folders_as_playlists_and_reads_nested_mp3s() {
    let temp = tempdir().unwrap();
    let roadtrip = temp.path().join("Roadtrip");
    let nested = roadtrip.join("Disc 1");
    fs::create_dir_all(&nested).unwrap();
    fs::write(roadtrip.join("01 - Start.mp3"), b"not really an mp3").unwrap();
    fs::write(nested.join("02 - Middle.mp3"), b"not really an mp3").unwrap();
    fs::write(roadtrip.join("cover.jpg"), b"ignore me").unwrap();

    let library = scan_library_path(temp.path()).unwrap();
    let roadtrip_playlist = library
        .playlists
        .iter()
        .find(|playlist| playlist.name == "Roadtrip")
        .unwrap();

    assert_eq!(roadtrip_playlist.track_ids.len(), 2);
    assert!(library
        .playlists
        .iter()
        .any(|playlist| playlist.name == LIKED_FOLDER_NAME && playlist.is_liked));
    assert_eq!(library.tracks.len(), 2);
    assert!(library
        .tracks
        .iter()
        .any(|track| track.title == "01 - Start"));
}

#[test]
fn rename_folder_playlist_persists_display_name_without_renaming_folder() {
    let temp = tempdir().unwrap();
    let playlist = temp.path().join("Mix");
    fs::create_dir_all(&playlist).unwrap();
    fs::write(playlist.join("Song.mp3"), b"not really an mp3").unwrap();

    let library = scan_library_path(temp.path()).unwrap();
    let playlist_id = library
        .playlists
        .iter()
        .find(|playlist| playlist.name == "Mix")
        .unwrap()
        .id
        .clone();

    rename_playlist_path(temp.path(), &playlist_id, "Late Night").unwrap();
    let renamed = scan_library_path(temp.path()).unwrap();
    let renamed_playlist = renamed
        .playlists
        .iter()
        .find(|playlist| playlist.id == playlist_id)
        .unwrap();

    assert!(playlist.exists());
    assert_eq!(renamed_playlist.name, "Late Night");
    assert_eq!(renamed_playlist.track_ids.len(), 1);
    assert!(read_library_state(temp.path())
        .unwrap()
        .playlists
        .iter()
        .any(|playlist| playlist.id == playlist_id && playlist.name == "Late Night"));
}

#[test]
fn rename_state_playlist_keeps_track_membership() {
    let temp = tempdir().unwrap();
    fs::write(temp.path().join("Song.mp3"), b"not really an mp3").unwrap();

    let library = scan_library_path(temp.path()).unwrap();
    let track = library.tracks.first().unwrap();
    let mut state = read_library_state(temp.path()).unwrap();
    state.playlists.push(StatePlaylist {
        artwork: None,
        id: "playlist_state_manual".to_string(),
        name: "Manual".to_string(),
        track_fingerprints: vec![track.fingerprint.clone()],
    });
    write_library_state(temp.path(), &state).unwrap();

    rename_playlist_path(temp.path(), "playlist_state_manual", "Renamed").unwrap();
    let renamed = scan_library_path(temp.path()).unwrap();
    let renamed_playlist = renamed
        .playlists
        .iter()
        .find(|playlist| playlist.id == "playlist_state_manual")
        .unwrap();

    assert_eq!(renamed_playlist.name, "Renamed");
    assert_eq!(renamed_playlist.track_ids, vec![track.id.clone()]);
    assert!(!renamed
        .playlists
        .iter()
        .any(|playlist| playlist.name == "Manual"));
}

#[test]
fn liked_folder_marks_matching_tracks_as_liked() {
    let temp = tempdir().unwrap();
    let playlist = temp.path().join("Mix");
    let liked = temp.path().join(LIKED_FOLDER_NAME);
    fs::create_dir_all(&playlist).unwrap();
    fs::create_dir_all(&liked).unwrap();
    fs::write(playlist.join("Same Song.mp3"), b"not really an mp3").unwrap();
    fs::write(liked.join("Same Song.mp3"), b"not really an mp3").unwrap();

    let library = scan_library_path(temp.path()).unwrap();
    let mix_track = library
        .tracks
        .iter()
        .find(|track| track.path.contains("Mix"))
        .unwrap();
    let liked_playlist = library
        .playlists
        .iter()
        .find(|playlist| playlist.is_liked)
        .unwrap();

    assert!(mix_track.is_liked);
    assert_eq!(library.tracks.len(), 1);
    assert_eq!(liked_playlist.track_ids, vec![mix_track.id.clone()]);
    assert!(read_library_state(temp.path())
        .unwrap()
        .liked_fingerprints
        .contains(&mix_track.fingerprint));
}

#[test]
fn copy_to_liked_records_state_without_copying() {
    let temp = tempdir().unwrap();
    let playlist = temp.path().join("Mix");
    fs::create_dir_all(&playlist).unwrap();
    let source = playlist.join("Song.mp3");
    fs::write(&source, b"audio").unwrap();

    let first = copy_track_to_liked_path(temp.path(), &source).unwrap();
    let second = copy_track_to_liked_path(temp.path(), &source).unwrap();
    let library = scan_library_path(temp.path()).unwrap();

    assert!(source.exists());
    assert_eq!(first, second);
    assert!(!temp.path().join(LIKED_FOLDER_NAME).exists());
    assert_eq!(
        read_library_state(temp.path())
            .unwrap()
            .liked_fingerprints
            .len(),
        1
    );
    assert_eq!(library.tracks.len(), 1);
    assert!(library.tracks[0].is_liked);
}

#[test]
fn remove_liked_track_updates_state_without_deleting_file() {
    let temp = tempdir().unwrap();
    let playlist = temp.path().join("Mix");
    fs::create_dir_all(&playlist).unwrap();
    let source = playlist.join("Song.mp3");
    fs::write(&source, b"audio").unwrap();

    copy_track_to_liked_path(temp.path(), &source).unwrap();

    assert!(remove_liked_track_path(temp.path(), &source).unwrap());
    assert!(source.exists());
    assert!(!remove_liked_track_path(temp.path(), &source).unwrap());
    assert!(!scan_library_path(temp.path()).unwrap().tracks[0].is_liked);
}

#[test]
fn set_track_playlist_memberships_updates_liked_and_state_playlists() {
    let temp = tempdir().unwrap();
    let source = temp.path().join("Song.mp3");
    let playlist = temp.path().join("Mix");
    fs::create_dir_all(&playlist).unwrap();
    fs::write(&source, b"audio").unwrap();
    fs::write(playlist.join("Other.mp3"), b"other audio").unwrap();

    let library = scan_library_path(temp.path()).unwrap();
    let liked_id = library
        .playlists
        .iter()
        .find(|playlist| playlist.is_liked)
        .unwrap()
        .id
        .clone();
    let mix_id = library
        .playlists
        .iter()
        .find(|playlist| playlist.name == "Mix")
        .unwrap()
        .id
        .clone();

    set_track_playlist_memberships_path(temp.path(), &source, vec![liked_id, mix_id.clone()])
        .unwrap();
    let source_path = path_to_string(&source.canonicalize().unwrap());
    let updated = scan_library_path(temp.path()).unwrap();
    let track = updated
        .tracks
        .iter()
        .find(|track| track.path == source_path)
        .unwrap();
    let mix = updated
        .playlists
        .iter()
        .find(|playlist| playlist.id == mix_id)
        .unwrap();

    assert!(track.is_liked);
    assert!(mix.track_ids.contains(&track.id));

    set_track_playlist_memberships_path(temp.path(), &source, Vec::new()).unwrap();
    let cleared = scan_library_path(temp.path()).unwrap();
    let track = cleared
        .tracks
        .iter()
        .find(|track| track.path == source_path)
        .unwrap();
    let mix = cleared
        .playlists
        .iter()
        .find(|playlist| playlist.id == mix_id)
        .unwrap();

    assert!(!track.is_liked);
    assert!(!mix.track_ids.contains(&track.id));
}

#[test]
fn set_track_playlist_memberships_can_remove_folder_playlist_membership() {
    let temp = tempdir().unwrap();
    let playlist = temp.path().join("Mix");
    fs::create_dir_all(&playlist).unwrap();
    let source = playlist.join("Song.mp3");
    fs::write(&source, b"audio").unwrap();

    let library = scan_library_path(temp.path()).unwrap();
    let track = library.tracks.first().unwrap();
    let mix_id = library
        .playlists
        .iter()
        .find(|playlist| playlist.name == "Mix")
        .unwrap()
        .id
        .clone();
    assert!(track.playlist_ids.contains(&mix_id));

    set_track_playlist_memberships_path(temp.path(), &source, Vec::new()).unwrap();
    let updated = scan_library_path(temp.path()).unwrap();
    let track = updated.tracks.first().unwrap();
    let mix = updated
        .playlists
        .iter()
        .find(|playlist| playlist.id == mix_id)
        .unwrap();

    assert!(!track.playlist_ids.contains(&mix_id));
    assert!(!mix.track_ids.contains(&track.id));
}

#[test]
fn merge_sync_library_state_updates_likes_and_state_playlists_by_fingerprint() {
    let temp = tempdir().unwrap();
    let source = temp.path().join("Song.mp3");
    fs::write(&source, b"audio").unwrap();

    let library = scan_library_path(temp.path()).unwrap();
    let track = library.tracks.first().unwrap();

    merge_sync_library_state_path(
        temp.path(),
        SyncLibraryState {
            tracks: vec![SyncTrackState {
                id: "remote-track".to_string(),
                fingerprint: track.fingerprint.clone(),
                is_liked: true,
            }],
            playlists: vec![SyncPlaylistState {
                id: "playlist_remote".to_string(),
                name: "Remote Mix".to_string(),
                track_ids: vec!["remote-track".to_string()],
                is_liked: false,
            }],
        },
    )
    .unwrap();

    let updated = scan_library_path(temp.path()).unwrap();
    let updated_track = updated.tracks.first().unwrap();
    let playlist = updated
        .playlists
        .iter()
        .find(|playlist| playlist.id == "playlist_remote")
        .unwrap();

    assert!(updated_track.is_liked);
    assert!(updated_track.playlist_ids.contains(&playlist.id));
    assert_eq!(playlist.track_ids, vec![updated_track.id.clone()]);
}

#[test]
fn import_manifest_links_existing_tracks_without_copying_duplicates() {
    let library_root = tempdir().unwrap();
    let import_root = tempdir().unwrap();
    let mix = library_root.path().join("Mix");
    fs::create_dir_all(&mix).unwrap();
    fs::write(mix.join("Same Song.mp3"), b"audio").unwrap();
    fs::write(import_root.path().join("Same Song.mp3"), b"audio").unwrap();
    let manifest = import_root.path().join("manifest.json");
    fs::write(
        &manifest,
        r#"{
          "schema": "loud.import.v1",
          "tracks": [
            {
              "file": "Same Song.mp3",
              "title": "Same Song",
              "artist": "Unknown Artist",
              "album": "Unknown Album",
              "identifiers": {
                "isrc": "test-existing"
              },
              "liked": true,
              "playlists": ["Imported Mix"]
            }
          ],
          "playlists": [
            {
              "name": "Imported Mix",
              "mode": "append",
              "tracks": [
                {
                  "identifiers": {
                    "isrc": "TEST-EXISTING"
                  }
                }
              ]
            }
          ]
        }"#,
    )
    .unwrap();

    let report = import_library_manifest_path(library_root.path(), &manifest).unwrap();
    let library = scan_library_path(library_root.path()).unwrap();
    let imported_playlist = library
        .playlists
        .iter()
        .find(|playlist| playlist.name == "Imported Mix")
        .unwrap();

    assert_eq!(report.new_tracks, 0);
    assert_eq!(report.existing_tracks, 1);
    assert_eq!(report.liked_updates, 1);
    assert_eq!(library.tracks.len(), 1);
    assert!(library.tracks[0].is_liked);
    assert_eq!(
        imported_playlist.track_ids,
        vec![library.tracks[0].id.clone()]
    );
    assert!(!managed_audio_dir(library_root.path()).exists());
}

#[test]
fn import_manifest_copies_new_tracks_into_managed_audio() {
    let library_root = tempdir().unwrap();
    let import_root = tempdir().unwrap();
    fs::write(import_root.path().join("New Song.mp3"), b"audio").unwrap();
    let manifest = import_root.path().join("manifest.json");
    fs::write(
        &manifest,
        r#"{
          "schema": "loud.import.v1",
          "source": { "base_path": "." },
          "tracks": [
            {
              "file": "New Song.mp3",
              "title": "New Song",
              "artist": "Ada",
              "album": "Compiler Songs",
              "album_artist": "Ada",
              "track_number": 1,
              "disc_number": 1,
              "duration_ms": 172626,
              "explicit": true,
              "identifiers": {
                "isrc": "USRC12100543",
                "spotify_track_id": "spotify-new-track",
                "spotify_album_id": "spotify-new-album",
                "youtube_video_id": "youtube-new-video"
              },
              "source_urls": {
                "spotify": "https://open.spotify.com/track/spotify-new-track",
                "youtube": "https://www.youtube.com/watch?v=youtube-new-video"
              }
            }
          ],
          "playlists": [
            {
              "name": "Inbox",
              "mode": "append",
              "tracks": [
                {
                  "identifiers": {
                    "spotify_track_id": "spotify-new-track"
                  }
                }
              ]
            }
          ]
        }"#,
    )
    .unwrap();

    let report = import_library_manifest_path(library_root.path(), &manifest).unwrap();
    let library = scan_library_path(library_root.path()).unwrap();
    let inbox = library
        .playlists
        .iter()
        .find(|playlist| playlist.name == "Inbox")
        .unwrap();

    assert_eq!(report.new_tracks, 1);
    assert_eq!(report.existing_tracks, 0);
    assert_eq!(report.playlist_updates, 1);
    assert_eq!(report.imported_paths.len(), 1);
    assert!(Path::new(&report.imported_paths[0]).exists());
    assert!(report.imported_paths[0].contains(STATE_DIR_NAME));
    assert_eq!(library.tracks.len(), 1);
    assert_eq!(library.tracks[0].artist, "Ada");
    assert_eq!(library.tracks[0].fingerprint, "isrc:USRC12100543");
    assert_eq!(library.tracks[0].disc_number, Some(1));
    assert_eq!(library.tracks[0].explicit, Some(true));
    assert_eq!(
        library.tracks[0]
            .identifiers
            .get("spotify_track_id")
            .map(String::as_str),
        Some("spotify-new-track")
    );
    assert_eq!(
        library.tracks[0]
            .source_urls
            .get("youtube")
            .map(String::as_str),
        Some("https://www.youtube.com/watch?v=youtube-new-video")
    );
    assert_eq!(inbox.track_ids, vec![library.tracks[0].id.clone()]);

    let state = read_library_state(library_root.path()).unwrap();
    let metadata = state.managed_tracks.values().next().unwrap();
    assert_eq!(metadata.disc_number, Some(1));
    assert_eq!(metadata.explicit, Some(true));
    assert_eq!(
        metadata.identifiers.spotify_track_id.as_deref(),
        Some("spotify-new-track")
    );
    assert_eq!(
        metadata.source_urls.get("youtube").map(String::as_str),
        Some("https://www.youtube.com/watch?v=youtube-new-video")
    );
    assert_eq!(metadata.duration_seconds, Some(172.626));
}

#[test]
fn rescans_reuse_the_tag_cache_and_prune_deleted_files() {
    let temp = tempdir().unwrap();
    let folder = temp.path().join("Mix");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("one.mp3"), b"not really an mp3").unwrap();
    fs::write(folder.join("two.mp3"), b"also not an mp3").unwrap();

    let first = scan_library_path(temp.path()).unwrap();
    assert_eq!(first.tracks.len(), 2);

    // The cache is persisted with mtime+size per file.
    let state = read_library_state(&temp.path().canonicalize().unwrap()).unwrap();
    assert_eq!(state.scan_cache.len(), 2);

    // A second scan (no changes) produces identical tracks from the cache.
    let second = scan_library_path(temp.path()).unwrap();
    assert_eq!(
        first
            .tracks
            .iter()
            .map(|t| &t.fingerprint)
            .collect::<Vec<_>>(),
        second
            .tracks
            .iter()
            .map(|t| &t.fingerprint)
            .collect::<Vec<_>>()
    );

    // Deleting a file prunes its cache entry on the next scan.
    fs::remove_file(folder.join("two.mp3")).unwrap();
    let third = scan_library_path(temp.path()).unwrap();
    assert_eq!(third.tracks.len(), 1);
    let state = read_library_state(&temp.path().canonicalize().unwrap()).unwrap();
    assert_eq!(state.scan_cache.len(), 1);
}

#[test]
fn imported_extended_metadata_survives_rescan_repeat_import_and_serialization() {
    use serde_json::json;
    let root = tempdir().unwrap();
    let source = tempdir().unwrap();
    fs::write(source.path().join("song.mp3"), b"metadata fixture audio").unwrap();
    let identifiers = json!({
        "isrc":"USABC2300001", "spotify_track_id":"track-fixture",
        "spotify_album_id":"album-fixture", "youtube_video_id":"video-fixture",
        "musicbrainz_recording_id":"11111111-1111-4111-8111-111111111111",
        "catalog_id":"custom-identifier"
    });
    let source_urls = json!({
        "spotify":"https://open.spotify.com/track/track-fixture",
        "youtube":"https://www.youtube.com/watch?v=video-fixture",
        "archive":"https://fixture.invalid/original"
    });
    let manifest = source.path().join("manifest.json");
    fs::write(
        &manifest,
        serde_json::to_vec(&json!({
            "schema":"loud.import.v1", "tracks":[{
                "file":"song.mp3", "fingerprint":"metadata-exact", "title":"Metadata Song",
                "artist":"Metadata Artist", "album":"Metadata Album", "disc_number":2,
                "explicit":false, "identifiers":identifiers, "source_urls":source_urls
            }]
        }))
        .unwrap(),
    )
    .unwrap();
    for pass in 0..2 {
        let report = import_library_manifest_path(root.path(), &manifest).unwrap();
        assert_eq!(
            (report.new_tracks, report.existing_tracks),
            if pass == 0 { (1, 0) } else { (0, 1) }
        );
        for _ in 0..2 {
            let library = scan_library_path(root.path()).unwrap();
            assert_eq!(library.tracks.len(), 1);
            let serialized = serde_json::to_value(&library.tracks[0]).unwrap();
            assert_eq!(serialized["disc_number"], 2);
            assert_eq!(serialized["explicit"], false);
            assert_eq!(serialized["identifiers"], identifiers);
            assert_eq!(serialized["source_urls"], source_urls);
        }
    }
}

fn write_extended_metadata_wav(path: &Path, advisory: &str) {
    use lofty::config::WriteOptions;
    use lofty::id3::v2::{Frame, Id3v2Tag, UniqueFileIdentifierFrame};
    use lofty::tag::{Tag, TagExt, TagType};
    let mut wav = b"RIFF".to_vec();
    wav.extend(38_u32.to_le_bytes());
    wav.extend(b"WAVEfmt ");
    wav.extend(16_u32.to_le_bytes());
    wav.extend(1_u16.to_le_bytes());
    wav.extend(1_u16.to_le_bytes());
    wav.extend(8000_u32.to_le_bytes());
    wav.extend(16000_u32.to_le_bytes());
    wav.extend(2_u16.to_le_bytes());
    wav.extend(16_u16.to_le_bytes());
    wav.extend(b"data");
    wav.extend(2_u32.to_le_bytes());
    wav.extend(0_i16.to_le_bytes());
    fs::write(path, wav).unwrap();
    let mut tag = Tag::new(TagType::Id3v2);
    tag.set_title("Tagged Song".to_string());
    tag.set_artist("Tagged Artist".to_string());
    tag.set_album("Tagged Album".to_string());
    tag.set_disk(3);
    assert!(tag.insert_text(ItemKey::ParentalAdvisory, advisory.to_string()));
    assert!(tag.insert_text(ItemKey::Isrc, "USABC2300001".to_string()));
    // MusicBrainz recording IDs use an owner-scoped UFID, not an ordinary
    // ID3 text-frame mapping. Lofty's generic insert_text rejects this key.
    let mut tag = Id3v2Tag::from(tag);
    tag.insert(Frame::UniqueFileIdentifier(UniqueFileIdentifierFrame::new(
        "http://musicbrainz.org",
        b"11111111-1111-4111-8111-111111111111".to_vec(),
    )));
    tag.save_to_path(path, WriteOptions::default()).unwrap();
    let fixture = Probe::open(path).unwrap().read().unwrap();
    assert_eq!(
        fixture
            .first_tag()
            .unwrap()
            .get_string(ItemKey::MusicBrainzRecordingId),
        Some("11111111-1111-4111-8111-111111111111"),
        "Fixture must contain the native ID before the scanner is exercised"
    );
}

#[test]
fn native_disc_advisory_and_identifiers_survive_warm_cache_and_legacy_cache_upgrade() {
    for (advisory, explicit) in [("0", false), ("1", true), ("2", false), ("4", true)] {
        let root = tempdir().unwrap();
        write_extended_metadata_wav(&root.path().join("tagged.wav"), advisory);
        for _ in 0..2 {
            let library = scan_library_path(root.path()).unwrap();
            let track = &library.tracks[0];
            assert_eq!(track.title, "Tagged Song");
            assert_eq!(track.disc_number, Some(3));
            assert_eq!(track.explicit, Some(explicit));
            assert_eq!(
                track.identifiers.get("isrc").map(String::as_str),
                Some("USABC2300001")
            );
            assert_eq!(
                track
                    .identifiers
                    .get("musicbrainz_recording_id")
                    .map(String::as_str),
                Some("11111111-1111-4111-8111-111111111111")
            );
        }
        // Simulate the cache shipped before these fields existed. The audio
        // file's mtime/size remain unchanged, so only the schema upgrade can
        // recover fields missed by the earlier tag reader.
        let state_path = state_file_path(root.path());
        let mut state: serde_json::Value =
            serde_json::from_slice(&fs::read(&state_path).unwrap()).unwrap();
        for cached in state["scan_cache"].as_object_mut().unwrap().values_mut() {
            let cached = cached.as_object_mut().unwrap();
            for field in [
                "metadata_version",
                "disc_number",
                "explicit",
                "identifiers",
                "source_urls",
            ] {
                cached.remove(field);
            }
            cached.insert(
                "title".to_string(),
                serde_json::json!("Outdated cached title"),
            );
        }
        fs::write(&state_path, serde_json::to_vec(&state).unwrap()).unwrap();
        let upgraded = scan_library_path(root.path()).unwrap();
        assert_eq!(upgraded.tracks[0].title, "Tagged Song");
        assert_eq!(upgraded.tracks[0].disc_number, Some(3));
        assert_eq!(upgraded.tracks[0].explicit, Some(explicit));
        let persisted = read_library_state(root.path()).unwrap();
        assert!(persisted
            .scan_cache
            .values()
            .all(|entry| entry.metadata_version == SCAN_TAG_CACHE_VERSION));
    }
}

#[test]
fn native_metadata_defaults_and_new_import_overrides_survive_unchanged_reimport() {
    use serde_json::json;
    for override_native in [false, true] {
        let root = tempdir().unwrap();
        let source = tempdir().unwrap();
        write_extended_metadata_wav(&source.path().join("song.wav"), "1");
        let manifest = source.path().join("manifest.json");
        let mut entry = json!({
            "file":"song.wav", "fingerprint":"tagged-exact",
            "identifiers":{"spotify_track_id":"tagged-spotify"},
            "source_urls":{"spotify":"https://open.spotify.com/track/tagged-spotify"}
        });
        if override_native {
            entry["disc_number"] = json!(2);
            entry["explicit"] = json!(false);
        }
        fs::write(
            &manifest,
            serde_json::to_vec(&json!({
                "schema":"loud.import.v1", "tracks":[entry]
            }))
            .unwrap(),
        )
        .unwrap();
        import_library_manifest_path(root.path(), &manifest).unwrap();
        let first = scan_library_path(root.path()).unwrap();
        assert_eq!(
            first.tracks[0].disc_number,
            Some(if override_native { 2 } else { 3 })
        );
        assert_eq!(first.tracks[0].explicit, Some(!override_native));
        assert_eq!(
            first.tracks[0].identifiers.get("isrc").map(String::as_str),
            Some("USABC2300001")
        );
        assert_eq!(
            first.tracks[0]
                .identifiers
                .get("spotify_track_id")
                .map(String::as_str),
            Some("tagged-spotify")
        );

        // Exact-identity reimports attach membership/artwork as needed but
        // preserve the destination's metadata, even if the source metadata
        // differs and the original download no longer exists.
        fs::remove_file(source.path().join("song.wav")).unwrap();
        fs::write(
            &manifest,
            serde_json::to_vec(&json!({
                "schema":"loud.import.v1", "tracks":[{
                    "file":"song.wav", "fingerprint":"tagged-exact", "disc_number":4,
                    "explicit":override_native, "identifiers":{"catalog_id":"must-not-replace"},
                    "source_urls":{"spotify":"https://fixture.invalid/replacement"}
                }]
            }))
            .unwrap(),
        )
        .unwrap();
        let report = import_library_manifest_path(root.path(), &manifest).unwrap();
        assert_eq!((report.new_tracks, report.existing_tracks), (0, 1));
        let updated = scan_library_path(root.path()).unwrap();
        assert_eq!(
            serde_json::to_value(&updated.tracks[0]).unwrap(),
            serde_json::to_value(&first.tracks[0]).unwrap()
        );
    }
}

#[test]
fn tracks_without_extended_metadata_keep_optional_fields_absent_or_empty() {
    let root = tempdir().unwrap();
    fs::write(root.path().join("untagged.mp3"), b"untagged fixture audio").unwrap();
    for _ in 0..2 {
        let library = scan_library_path(root.path()).unwrap();
        let track = &library.tracks[0];
        assert_eq!(track.disc_number, None);
        assert_eq!(track.explicit, None);
        assert!(track.identifiers.is_empty());
        assert!(track.source_urls.is_empty());
        let serialized = serde_json::to_value(track).unwrap();
        assert!(serialized.get("identifiers").is_none());
        assert!(serialized.get("source_urls").is_none());
    }
}
