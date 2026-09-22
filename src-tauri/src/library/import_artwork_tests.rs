//! End-to-end importer tests use isolated disk fixtures, never the user's library.
use super::*;
use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::Cursor;
use tempfile::{tempdir, TempDir};

struct ArtworkImportFixture {
    library: TempDir,
    input: TempDir,
}

impl ArtworkImportFixture {
    fn new() -> Self {
        let fixture = Self {
            library: tempdir().unwrap(),
            input: tempdir().unwrap(),
        };
        fixture.write("song.mp3", b"isolated fake audio fixture");
        fixture
    }

    fn write(&self, relative: &str, bytes: &[u8]) {
        let path = self.input.path().join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    fn json(&self, relative: &str, value: &Value) {
        self.write(relative, &serde_json::to_vec_pretty(value).unwrap());
    }

    fn import(&self, manifest: Value) -> ImportReport {
        self.json("manifest.json", &manifest);
        import_library_manifest_path(self.library.path(), self.input.path().join("manifest.json"))
            .unwrap()
    }

    fn scan(&self) -> Library {
        scan_library_path(self.library.path()).unwrap()
    }

    fn image(&self, file: &str, format: ImageFormat, color: [u8; 3]) -> Value {
        let bytes = image_bytes(format, 12, 8, color);
        self.write(file, &bytes);
        artwork_descriptor(file, &bytes, format.to_mime_type(), 12, 8)
    }

    fn initial_manifest(&self) -> Value {
        json!({
            "schema": "loud.import.v1",
            "tracks": [{
                "file": "song.mp3", "title": "Fixture Song", "artist": "Fixture Artist",
                "album": "Fixture Album", "fingerprint": "isrc:ARTWORK-EXACT",
                "identifiers": {"spotify_track_id": "alternate-identity"}
            }],
            "playlists": [{"name": "Fixture Mix", "tracks": ["song.mp3"]}]
        })
    }

    fn playlist_only(&self, artwork: Value) -> Value {
        json!({"schema": "loud.import.v1", "tracks": [],
            "playlists": [{"name": "Fixture Mix", "artwork": artwork}]})
    }
}

fn image_bytes(format: ImageFormat, width: u32, height: u32, color: [u8; 3]) -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    DynamicImage::ImageRgb8(RgbImage::from_pixel(width, height, Rgb(color)))
        .write_to(&mut bytes, format)
        .unwrap();
    bytes.into_inner()
}

#[test]
fn scanner_prunes_internal_staging_and_metadata_but_keeps_managed_and_folder_audio() {
    let fixture = ArtworkImportFixture::new();
    for relative in [
        "Mix/normal.mp3",
        ".loud/audio/managed.mp3",
        ".loud/cache/sync-import/files/normal.mp3",
        ".loud/cache/sync-import/files/staged-different.mp3",
        ".loud/artwork/art-image-with-audio-extension.mp3",
        ".loud/state-backups/old.mp3",
        ".loud/unclassified.mp3",
    ] {
        let path = fixture.library.path().join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, b"isolated scan fixture").unwrap();
    }
    let library = fixture.scan();
    let names = library
        .tracks
        .iter()
        .map(|track| track.file_name.as_str())
        .collect::<BTreeSet<_>>();
    assert_eq!(names, BTreeSet::from(["normal.mp3", "managed.mp3"]));
    let normal = library
        .tracks
        .iter()
        .find(|track| track.file_name == "normal.mp3")
        .unwrap();
    assert!(Path::new(&normal.path).ends_with("Mix/normal.mp3"));
    assert_eq!(fixture.scan().tracks.len(), 2);
    let state = read_library_state(fixture.library.path()).unwrap();
    assert_eq!(state.scan_cache.len(), 2);
    assert!(!state
        .scan_cache
        .keys()
        .any(|key| key.starts_with(".loud/cache")));
}

#[test]
fn staged_download_cannot_count_as_an_existing_track_or_replace_managed_audio() {
    let fixture = ArtworkImportFixture::new();
    let staged = fixture
        .library
        .path()
        .join(".loud/cache/sync-import/files/song.mp3");
    fs::create_dir_all(staged.parent().unwrap()).unwrap();
    fs::write(&staged, b"transient staged audio").unwrap();
    let fingerprint = fingerprint_for("song", "Unknown Artist", "Unknown Album");
    let mut manifest = fixture.initial_manifest();
    manifest["tracks"][0]["fingerprint"] = json!(fingerprint);
    let report = fixture.import(manifest.clone());
    assert_eq!((report.new_tracks, report.existing_tracks), (1, 0));
    let library = fixture.scan();
    assert_eq!(library.tracks.len(), 1);
    assert_eq!(library.tracks[0].fingerprint, fingerprint);
    assert!(Path::new(&library.tracks[0].path).starts_with(
        fixture
            .library
            .path()
            .canonicalize()
            .unwrap()
            .join(".loud/audio")
    ));
    fs::remove_file(staged).unwrap();
    assert_eq!(fixture.scan().tracks.len(), 1);
    let repeated = fixture.import(manifest);
    assert_eq!((repeated.new_tracks, repeated.existing_tracks), (0, 1));
}

fn artwork_descriptor(file: &str, bytes: &[u8], mime: &str, width: u32, height: u32) -> Value {
    json!({
        "file": file, "sha256": format!("{:x}", Sha256::digest(bytes)),
        "mime_type": mime, "width": width, "height": height,
        "source_url": "https://fixture.invalid/original",
        "spotify_url": "https://open.spotify.com/playlist/fixture",
        "license_url": "https://fixture.invalid/license",
        "attribution_url": "https://fixture.invalid/attribution",
        "provenance": {"source": "s2y-test", "revision": 1}
    })
}

fn mix(library: &Library) -> &Playlist {
    library
        .playlists
        .iter()
        .find(|p| p.name == "Fixture Mix")
        .unwrap()
}

fn assert_original_and_thumbnail(root: &Path, artwork: &CachedArtwork, bytes: &[u8], mime: &str) {
    assert!(artwork
        .source_path
        .starts_with(root.canonicalize().unwrap()));
    assert_eq!(artwork.original_mime_type.as_deref(), Some(mime));
    assert_eq!(fs::read(&artwork.source_path).unwrap(), bytes);
    let thumbnail = ensure_cached_artwork_thumbnail(artwork).unwrap();
    assert_eq!(thumbnail, artwork.cache_path);
    assert_ne!(thumbnail, artwork.source_path);
    let thumbnail_bytes = fs::read(thumbnail).unwrap();
    assert_eq!(
        image::guess_format(&thumbnail_bytes).unwrap(),
        ImageFormat::Jpeg
    );
    let decoded = image::load_from_memory(&thumbnail_bytes).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (12, 8));
    assert_eq!(
        fs::read(&artwork.source_path).unwrap(),
        bytes,
        "thumbnail generation rewrote original"
    );
}

#[test]
fn inline_artwork_is_idempotent_and_survives_rescan_rename_and_source_removal() {
    let fixture = ArtworkImportFixture::new();
    let artwork = fixture.image("cover.png", ImageFormat::Png, [220, 35, 60]);
    let original = fs::read(fixture.input.path().join("cover.png")).unwrap();
    let mut manifest = fixture.initial_manifest();
    manifest["tracks"][0]["artwork"] = artwork.clone();
    manifest["playlists"][0]["artwork"] = artwork;

    let first = fixture.import(manifest.clone());
    assert_eq!((first.new_tracks, first.existing_tracks), (1, 0));
    assert_eq!(
        (
            first.playlist_artwork_imported,
            first.track_artwork_imported
        ),
        (1, 1)
    );
    assert_eq!(first.track_fingerprints, ["isrc:ARTWORK-EXACT"]);
    assert!(
        first.artwork_failures.is_empty(),
        "{:?}",
        first.artwork_failures
    );
    let initial = fixture.scan();
    let playlist_id = mix(&initial).id.clone();
    let playlist_art = mix(&initial).artwork.clone().unwrap();
    let track_art = initial.tracks[0].artwork.clone().unwrap();
    assert_original_and_thumbnail(
        fixture.library.path(),
        &playlist_art,
        &original,
        "image/png",
    );
    assert_original_and_thumbnail(fixture.library.path(), &track_art, &original, "image/png");
    let source_mtime = fs::metadata(&playlist_art.source_path)
        .unwrap()
        .modified()
        .unwrap();
    let thumbnail_mtime = fs::metadata(&playlist_art.cache_path)
        .unwrap()
        .modified()
        .unwrap();

    let repeated = fixture.import(manifest);
    assert_eq!((repeated.new_tracks, repeated.existing_tracks), (0, 1));
    assert_eq!(
        (
            repeated.playlist_artwork_imported,
            repeated.track_artwork_imported
        ),
        (0, 0)
    );
    assert_eq!(repeated.artwork_already_present, 2);
    assert_eq!(repeated.track_fingerprints, ["isrc:ARTWORK-EXACT"]);
    assert!(repeated.artwork_failures.is_empty());
    assert_eq!(
        fs::metadata(&playlist_art.source_path)
            .unwrap()
            .modified()
            .unwrap(),
        source_mtime
    );
    assert_eq!(
        fs::metadata(&playlist_art.cache_path)
            .unwrap()
            .modified()
            .unwrap(),
        thumbnail_mtime
    );

    rename_playlist_path(fixture.library.path(), &playlist_id, "Renamed Mix").unwrap();
    fs::remove_file(fixture.input.path().join("cover.png")).unwrap();
    fs::remove_file(&playlist_art.cache_path).unwrap();
    let restarted = fixture.scan();
    let renamed = restarted
        .playlists
        .iter()
        .find(|p| p.id == playlist_id)
        .unwrap();
    assert_eq!(renamed.name, "Renamed Mix");
    assert_eq!(renamed.track_ids, mix(&initial).track_ids);
    assert_eq!(
        renamed.artwork.as_ref().unwrap().source_path,
        playlist_art.source_path
    );
    assert_original_and_thumbnail(
        fixture.library.path(),
        renamed.artwork.as_ref().unwrap(),
        &original,
        "image/png",
    );
    assert_original_and_thumbnail(
        fixture.library.path(),
        restarted.tracks[0].artwork.as_ref().unwrap(),
        &original,
        "image/png",
    );
    assert_eq!(fixture.scan().tracks.len(), 1);
    let persisted = read_library_state(fixture.library.path()).unwrap();
    let playlist_metadata = persisted
        .playlists
        .iter()
        .find(|playlist| playlist.id == playlist_id)
        .unwrap()
        .artwork
        .as_ref()
        .unwrap();
    let track_metadata = persisted.track_artwork.get("isrc:ARTWORK-EXACT").unwrap();
    for artwork in [playlist_metadata, track_metadata] {
        assert_eq!(
            artwork.license_url.as_deref(),
            Some("https://fixture.invalid/license")
        );
        assert_eq!(
            artwork.attribution_url.as_deref(),
            Some("https://fixture.invalid/attribution")
        );
        assert_eq!(artwork.provenance.as_ref().unwrap()["source"], "s2y-test");
    }
}

#[test]
fn imported_originals_support_jpeg_and_png() {
    for (extension, format) in [("jpg", ImageFormat::Jpeg), ("png", ImageFormat::Png)] {
        let fixture = ArtworkImportFixture::new();
        fixture.import(fixture.initial_manifest());
        let file = format!("cover.{extension}");
        let descriptor = fixture.image(&file, format, [30, 170, 80]);
        let bytes = fs::read(fixture.input.path().join(file)).unwrap();
        let report = fixture.import(fixture.playlist_only(descriptor));
        assert_eq!(
            report.playlist_artwork_imported, 1,
            "{extension}: {:?}",
            report.artwork_failures
        );
        assert!(report.artwork_failures.is_empty());
        assert_original_and_thumbnail(
            fixture.library.path(),
            mix(&fixture.scan()).artwork.as_ref().unwrap(),
            &bytes,
            format.to_mime_type(),
        );
    }
}

#[test]
fn sibling_sidecars_resolve_their_own_base_paths_and_existing_exact_targets() {
    let fixture = ArtworkImportFixture::new();
    fixture.write("audio/song.mp3", b"fixture audio");
    let mut manifest = fixture.initial_manifest();
    manifest["source"] = json!({"base_path": "audio"});
    fixture.import(manifest);
    let playlist = fixture.image("playlist-covers/cover.png", ImageFormat::Png, [220, 35, 60]);
    let track = fixture.image("track-covers/cover.png", ImageFormat::Png, [30, 170, 80]);
    let mut playlist_local = playlist;
    playlist_local["file"] = json!("cover.png");
    let mut track_local = track;
    track_local["file"] = json!("cover.png");
    fixture.json("playlist-artwork.json", &json!({"schema":"s2y.playlist-artwork.v1",
        "base_path":"playlist-covers", "playlists":[{"name":"Fixture Mix", "artwork":playlist_local}]}));
    fixture.json("track-artwork.json", &json!({"schema":"s2y.track-artwork.v1",
        "base_path":"track-covers", "tracks":[{"fingerprint":"isrc:ARTWORK-EXACT", "artwork":track_local}]}));

    let report = fixture
        .import(json!({"schema":"loud.import.v1", "source":{"base_path":"audio"}, "tracks":[]}));
    assert_eq!((report.new_tracks, report.existing_tracks), (0, 0));
    assert_eq!(
        (
            report.playlist_artwork_imported,
            report.track_artwork_imported
        ),
        (1, 1)
    );
    assert!(
        report.artwork_failures.is_empty(),
        "{:?}",
        report.artwork_failures
    );
    let library = fixture.scan();
    assert_eq!(library.tracks.len(), 1);
    assert_eq!(
        mix(&library)
            .artwork
            .as_ref()
            .unwrap()
            .original_mime_type
            .as_deref(),
        Some("image/png")
    );
    assert_eq!(
        library.tracks[0]
            .artwork
            .as_ref()
            .unwrap()
            .original_mime_type
            .as_deref(),
        Some("image/png")
    );
    let repeated = fixture.import(json!({"schema":"loud.import.v1", "tracks":[]}));
    assert_eq!(repeated.artwork_already_present, 2);
    assert_eq!(
        (
            repeated.playlist_artwork_imported,
            repeated.track_artwork_imported
        ),
        (0, 0)
    );
}

#[test]
fn s2y_sidecar_origin_is_informational_and_malformed_base_paths_are_reported() {
    for base_path in [json!(null), json!(42), json!({"folder":"."}), json!([])] {
        for (filename, schema, rows, target) in [
            (
                "playlist-artwork.json",
                "s2y.playlist-artwork.v1",
                "playlists",
                json!({"name":"Fixture Mix", "origin":"avb727"}),
            ),
            (
                "track-artwork.json",
                "s2y.track-artwork.v1",
                "tracks",
                json!({"fingerprint":"isrc:ARTWORK-EXACT"}),
            ),
        ] {
            let fixture = ArtworkImportFixture::new();
            let mut row = target;
            row["artwork"] = fixture.image("cover.png", ImageFormat::Png, [30, 170, 80]);
            let mut sidecar = json!({"schema":schema, "base_path":base_path});
            sidecar[rows] = json!([row]);
            fixture.json(filename, &sidecar);
            let report = fixture.import(fixture.initial_manifest());
            assert_eq!(report.new_tracks, 1);
            assert_eq!(
                (
                    report.playlist_artwork_imported,
                    report.track_artwork_imported
                ),
                (0, 0)
            );
            assert_eq!(report.artwork_failed, 1);
            assert_eq!(report.artwork_missing, 0);
            assert!(report.artwork_failures[0]
                .reason
                .contains("base_path must be a string"));
            assert!(fixture.scan().tracks[0].artwork.is_none());
            assert!(mix(&fixture.scan()).artwork.is_none());

            // Omitted base_path retains the documented default; origin never
            // changes the destination name or artwork identity.
            sidecar.as_object_mut().unwrap().remove("base_path");
            fixture.json(filename, &sidecar);
            let retry = fixture.import(fixture.initial_manifest());
            assert_eq!(retry.artwork_failed, 0);
            assert_eq!(
                retry.playlist_artwork_imported + retry.track_artwork_imported,
                1
            );
        }
    }
}

#[test]
fn nullable_optional_manifest_metadata_preserves_legacy_audio_import() {
    let fixture = ArtworkImportFixture::new();
    let mut manifest = fixture.initial_manifest();
    manifest["source"] = json!(null);
    for key in [
        "title",
        "artist",
        "album",
        "album_artist",
        "genre",
        "year",
        "track_number",
        "disc_number",
        "duration_seconds",
        "duration_ms",
        "explicit",
        "artwork",
    ] {
        manifest["tracks"][0][key] = json!(null);
    }
    manifest["tracks"][0]["identifiers"] = json!({"isrc":null, "spotify_track_id":null});
    manifest["playlists"][0]["artwork"] = json!(null);
    let report = fixture.import(manifest);
    assert_eq!(report.new_tracks, 1);
    assert_eq!(report.artwork_failed, 0);
    assert!(report.failures.is_empty());
    let library = fixture.scan();
    assert_eq!(library.tracks[0].fingerprint, "isrc:ARTWORK-EXACT");
    assert_eq!(library.tracks[0].title, "song");
    assert_eq!(mix(&library).track_ids, [library.tracks[0].id.clone()]);
}

#[test]
fn inline_artwork_wins_over_different_and_invalid_sidecar_duplicates() {
    let fixture = ArtworkImportFixture::new();
    let inline = fixture.image("inline.png", ImageFormat::Png, [220, 35, 60]);
    let sidecar = fixture.image("sidecar.png", ImageFormat::Png, [30, 170, 80]);
    let mut manifest = fixture.initial_manifest();
    manifest["tracks"][0]["artwork"] = inline.clone();
    manifest["playlists"][0]["artwork"] = inline.clone();
    fixture.json(
        "playlist-artwork.json",
        &json!({"schema":"s2y.playlist-artwork.v1", "base_path":".",
        "playlists":[{"name":"Fixture Mix", "artwork":sidecar}]}),
    );
    let mut invalid = inline;
    invalid["file"] = json!("missing-sidecar-cover.png");
    fixture.json(
        "track-artwork.json",
        &json!({"schema":"s2y.track-artwork.v1", "base_path":".",
        "tracks":[{"fingerprint":"isrc:ARTWORK-EXACT", "artwork":invalid}]}),
    );
    let report = fixture.import(manifest);
    assert_eq!(
        (
            report.playlist_artwork_imported,
            report.track_artwork_imported
        ),
        (1, 1)
    );
    assert!(
        report.artwork_failures.is_empty(),
        "duplicate sidecar should not replace inline: {:?}",
        report.artwork_failures
    );
    let library = fixture.scan();
    let expected = fs::read(fixture.input.path().join("inline.png")).unwrap();
    assert_eq!(
        fs::read(&mix(&library).artwork.as_ref().unwrap().source_path).unwrap(),
        expected
    );
    assert_eq!(
        fs::read(&library.tracks[0].artwork.as_ref().unwrap().source_path).unwrap(),
        expected
    );
}

#[test]
fn existing_artwork_is_preserved_but_invalid_replacements_are_still_reported() {
    let fixture = ArtworkImportFixture::new();
    fixture.import(fixture.initial_manifest());
    let original = fixture.image("original.png", ImageFormat::Png, [220, 35, 60]);
    fixture.import(fixture.playlist_only(original));
    let initial = fixture.scan();
    let art = mix(&initial).artwork.clone().unwrap();
    let bytes = fs::read(&art.source_path).unwrap();
    let replacement = fixture.image("replacement.png", ImageFormat::Png, [30, 170, 80]);
    let report = fixture.import(fixture.playlist_only(replacement.clone()));
    assert_eq!(report.artwork_already_present, 1);
    assert_eq!(report.playlist_artwork_imported, 0);
    assert!(report.artwork_failures.is_empty());
    let mut invalid = replacement;
    invalid["sha256"] = json!("0".repeat(64));
    let rejected = fixture.import(fixture.playlist_only(invalid));
    assert_eq!(rejected.artwork_already_present, 0);
    assert_eq!(rejected.artwork_failures.len(), 1);
    assert_eq!(rejected.playlist_artwork_imported, 0);
    assert_eq!(
        mix(&fixture.scan()).artwork.as_ref().unwrap().source_path,
        art.source_path
    );
    assert_eq!(fs::read(art.source_path).unwrap(), bytes);
}

#[test]
fn track_sidecars_match_exact_fingerprints_without_alias_or_title_fallback() {
    let fixture = ArtworkImportFixture::new();
    fixture.import(fixture.initial_manifest());
    let art = fixture.image("cover.png", ImageFormat::Png, [30, 170, 80]);
    fixture.json(
        "track-artwork.json",
        &json!({"schema":"s2y.track-artwork.v1", "base_path":".",
        "tracks":[
            {"fingerprint":"spotify:track:alternate-identity", "artwork":art},
            {"fingerprint":"isrc:artwork-exact", "artwork":art},
            {"fingerprint":"Fixture Song", "artwork":art},
            {"fingerprint":"isrc:ARTWORK-EXACT", "artwork":art}
        ]}),
    );
    let report = fixture.import(json!({"schema":"loud.import.v1", "tracks":[]}));
    assert_eq!(report.track_artwork_imported, 1);
    assert_eq!(report.artwork_missing, 3);
    assert_eq!(report.artwork_failures.len(), 3);
    assert!(fixture.scan().tracks[0].artwork.is_some());
}

#[test]
fn artwork_only_playlist_identity_refs_report_existing_track_once() {
    let fixture = ArtworkImportFixture::new();
    fixture.import(fixture.initial_manifest());
    let art = fixture.image("cover.png", ImageFormat::Png, [30, 170, 80]);
    let report = fixture.import(json!({"schema":"loud.import.v1", "tracks":[],
    "playlists":[{"name":"Fixture Mix", "artwork":art, "tracks":[
        {"fingerprint":"isrc:ARTWORK-EXACT"}, {"fingerprint":"isrc:ARTWORK-EXACT"}
    ]}]}));
    assert_eq!(report.track_fingerprints, ["isrc:ARTWORK-EXACT"]);
    assert_eq!(report.playlist_artwork_imported, 1);
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let library = fixture.scan();
    assert_eq!(library.tracks.len(), 1);
    assert_eq!(mix(&library).track_ids.len(), 1);
}

#[test]
fn rejected_artwork_is_reported_without_losing_audio_or_membership() {
    for case in [
        "hash",
        "short-hash",
        "mime",
        "decode",
        "width",
        "height",
        "missing",
        "absolute",
        "traversal",
    ] {
        let fixture = ArtworkImportFixture::new();
        let mut art = fixture.image("cover.png", ImageFormat::Png, [220, 35, 60]);
        match case {
            "hash" => art["sha256"] = json!("0".repeat(64)),
            "short-hash" => art["sha256"] = json!("abcd"),
            "mime" => art["mime_type"] = json!("image/jpeg"),
            "decode" => {
                let bytes = b"not an image";
                fixture.write("cover.png", bytes);
                art["sha256"] = json!(format!("{:x}", Sha256::digest(bytes)));
            }
            "width" => art["width"] = json!(13),
            "height" => art["height"] = json!(9),
            "missing" => art["file"] = json!("missing.png"),
            "absolute" => art["file"] = json!(fixture.input.path().join("cover.png")),
            "traversal" => {
                fs::create_dir_all(fixture.input.path().join("child")).unwrap();
                art["file"] = json!("child/../cover.png");
            }
            _ => unreachable!(),
        }
        let mut manifest = fixture.initial_manifest();
        manifest["playlists"][0]["artwork"] = art.clone();
        manifest["tracks"][0]["artwork"] = art;
        let report = fixture.import(manifest);
        assert_eq!(report.new_tracks, 1, "{case}");
        assert_eq!(
            report.artwork_failures.len(),
            2,
            "{case}: {:?}",
            report.artwork_failures
        );
        assert!(
            report
                .artwork_failures
                .iter()
                .all(|failure| !failure.reason.is_empty()),
            "{case}"
        );
        assert_eq!(
            (
                report.playlist_artwork_imported,
                report.track_artwork_imported
            ),
            (0, 0),
            "{case}"
        );
        if case == "missing" {
            assert_eq!(report.artwork_missing, 2);
        }
        let library = fixture.scan();
        assert_eq!(library.tracks.len(), 1, "{case}");
        assert_eq!(
            mix(&library).track_ids,
            [library.tracks[0].id.clone()],
            "{case}"
        );
        assert!(mix(&library).artwork.is_none(), "{case}");
        assert!(library.tracks[0].artwork.is_none(), "{case}");
    }
}

#[cfg(unix)]
#[test]
fn artwork_symlink_escape_is_rejected_while_in_root_symlink_is_allowed() {
    use std::os::unix::fs::symlink;
    let fixture = ArtworkImportFixture::new();
    let outside = tempdir().unwrap();
    let bytes = image_bytes(ImageFormat::Png, 12, 8, [30, 170, 80]);
    fs::write(outside.path().join("cover.png"), &bytes).unwrap();
    symlink(
        outside.path().join("cover.png"),
        fixture.input.path().join("escape.png"),
    )
    .unwrap();
    let mut manifest = fixture.initial_manifest();
    manifest["playlists"][0]["artwork"] =
        artwork_descriptor("escape.png", &bytes, "image/png", 12, 8);
    let rejected = fixture.import(manifest);
    assert_eq!(rejected.playlist_artwork_imported, 0);
    assert_eq!(rejected.artwork_failures.len(), 1);
    assert!(mix(&fixture.scan()).artwork.is_none());

    fixture.write("inside.png", &bytes);
    symlink("inside.png", fixture.input.path().join("safe-link.png")).unwrap();
    let accepted = fixture.import(fixture.playlist_only(artwork_descriptor(
        "safe-link.png",
        &bytes,
        "image/png",
        12,
        8,
    )));
    assert_eq!(
        accepted.playlist_artwork_imported, 1,
        "{:?}",
        accepted.artwork_failures
    );
}

#[test]
fn artwork_file_size_and_declared_dimension_limits_are_enforced() {
    for case in ["bytes", "edge", "pixels", "zero"] {
        let fixture = ArtworkImportFixture::new();
        let mut bytes = image_bytes(ImageFormat::Png, 12, 8, [30, 170, 80]);
        let (width, height) = match case {
            "bytes" => {
                bytes.resize(12 * 1024 * 1024 + 1, 0);
                (12, 8)
            }
            "edge" => (8_193, 1),
            "pixels" => (4_096, 4_097),
            "zero" => (0, 8),
            _ => unreachable!(),
        };
        fixture.write("cover.png", &bytes);
        let mut manifest = fixture.initial_manifest();
        manifest["playlists"][0]["artwork"] =
            artwork_descriptor("cover.png", &bytes, "image/png", width, height);
        let report = fixture.import(manifest);
        assert_eq!(report.playlist_artwork_imported, 0, "{case}");
        assert_eq!(report.artwork_failures.len(), 1, "{case}");
        assert!(mix(&fixture.scan()).artwork.is_none());
    }
}

#[test]
fn oversized_decoded_dimensions_are_rejected_even_when_metadata_claims_small_image() {
    // A valid oversized edge is inexpensive to encode; a huge pixel declaration
    // needs only a valid PNG IHDR so validation must reject before allocating it.
    for (width, height, valid_image) in [(8_193, 1, true), (4_096, 4_097, false)] {
        let fixture = ArtworkImportFixture::new();
        let bytes = if valid_image {
            image_bytes(ImageFormat::Png, width, height, [30, 170, 80])
        } else {
            png_header(width, height)
        };
        fixture.write("cover.png", &bytes);
        let mut manifest = fixture.initial_manifest();
        manifest["playlists"][0]["artwork"] =
            artwork_descriptor("cover.png", &bytes, "image/png", 12, 8);
        let report = fixture.import(manifest);
        assert_eq!(report.playlist_artwork_imported, 0);
        assert_eq!(report.artwork_failures.len(), 1);
        let reason = report.artwork_failures[0].reason.to_lowercase();
        assert!(
            reason.contains("dimension")
                || reason.contains("pixel")
                || reason.contains("limit")
                || reason.contains("large"),
            "unexpected allocation/decode failure: {reason}"
        );
        assert!(mix(&fixture.scan()).artwork.is_none());
    }
}

fn png_header(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = b"IHDR".to_vec();
    ihdr.extend(width.to_be_bytes());
    ihdr.extend(height.to_be_bytes());
    ihdr.extend([8, 2, 0, 0, 0]);
    bytes.extend(13_u32.to_be_bytes());
    bytes.extend(&ihdr);
    bytes.extend(crc32(&ihdr).to_be_bytes());
    bytes.extend(0_u32.to_be_bytes());
    bytes.extend(b"IDAT");
    bytes.extend(crc32(b"IDAT").to_be_bytes());
    bytes.extend(0_u32.to_be_bytes());
    bytes.extend(b"IEND");
    bytes.extend(crc32(b"IEND").to_be_bytes());
    bytes
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & 0_u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

#[cfg(unix)]
#[test]
fn manifest_and_sidecar_base_paths_cannot_escape_the_import_folder() {
    use std::os::unix::fs::symlink;
    for source in ["manifest", "playlist-sidecar", "track-sidecar"] {
        for escape in ["parent", "absolute", "symlink"] {
            let fixture = ArtworkImportFixture::new();
            fixture.import(fixture.initial_manifest());
            let outside = tempdir().unwrap();
            let bytes = image_bytes(ImageFormat::Png, 12, 8, [30, 170, 80]);
            fs::write(outside.path().join("cover.png"), &bytes).unwrap();
            let base_path = match escape {
                "parent" => format!(
                    "../{}",
                    outside.path().file_name().unwrap().to_str().unwrap()
                ),
                "absolute" => outside.path().to_string_lossy().into_owned(),
                "symlink" => {
                    symlink(outside.path(), fixture.input.path().join("linked-root")).unwrap();
                    "linked-root".to_string()
                }
                _ => unreachable!(),
            };
            let art = artwork_descriptor("cover.png", &bytes, "image/png", 12, 8);
            let manifest = match source {
                "manifest" => {
                    let mut manifest = fixture.playlist_only(art);
                    manifest["source"] = json!({"base_path":base_path});
                    manifest
                }
                "playlist-sidecar" => {
                    fixture.json(
                        "playlist-artwork.json",
                        &json!({
                            "schema":"s2y.playlist-artwork.v1", "base_path":base_path,
                            "playlists":[{"name":"Fixture Mix", "artwork":art}]
                        }),
                    );
                    json!({"schema":"loud.import.v1", "tracks":[]})
                }
                "track-sidecar" => {
                    fixture.json(
                        "track-artwork.json",
                        &json!({
                            "schema":"s2y.track-artwork.v1", "base_path":base_path,
                            "tracks":[{"fingerprint":"isrc:ARTWORK-EXACT", "artwork":art}]
                        }),
                    );
                    json!({"schema":"loud.import.v1", "tracks":[]})
                }
                _ => unreachable!(),
            };
            let report = fixture.import(manifest);
            assert_eq!(
                (
                    report.playlist_artwork_imported,
                    report.track_artwork_imported
                ),
                (0, 0),
                "{source}/{escape}"
            );
            assert!(
                !report.artwork_failures.is_empty(),
                "{source}/{escape} silently accepted an escaped base"
            );
            assert!(
                report.artwork_failed > 0,
                "{source}/{escape} must count as a validation failure"
            );
            let library = fixture.scan();
            assert!(mix(&library).artwork.is_none(), "{source}/{escape}");
            assert!(library.tracks[0].artwork.is_none(), "{source}/{escape}");
        }
    }
}

#[test]
fn imported_webp_and_gif_are_rejected_including_mislabeled_pngs() {
    for (extension, format) in [("webp", ImageFormat::WebP), ("gif", ImageFormat::Gif)] {
        for mislabeled in [false, true] {
            let fixture = ArtworkImportFixture::new();
            let file = format!("cover.{extension}");
            let mut art = fixture.image(&file, format, [30, 170, 80]);
            if mislabeled {
                art["mime_type"] = json!("image/png");
            }
            let mut manifest = fixture.initial_manifest();
            manifest["playlists"][0]["artwork"] = art;
            let report = fixture.import(manifest);
            assert_eq!(
                report.playlist_artwork_imported, 0,
                "{extension}/{mislabeled}"
            );
            assert_eq!(report.artwork_failed, 1, "{extension}/{mislabeled}");
            assert_eq!(report.artwork_failures.len(), 1, "{extension}/{mislabeled}");
            assert!(mix(&fixture.scan()).artwork.is_none());
        }
    }
}

#[test]
fn explicit_fingerprints_keep_identical_metadata_tracks_and_covers_distinct() {
    let fixture = ArtworkImportFixture::new();
    fixture.write("other.mp3", b"different isolated audio fixture");
    let red = fixture.image("red.png", ImageFormat::Png, [220, 35, 60]);
    let green = fixture.image("green.png", ImageFormat::Png, [30, 170, 80]);
    let manifest = json!({"schema":"loud.import.v1", "tracks":[
        {"file":"song.mp3", "fingerprint":"isrc:EXACT-FIRST", "title":"Same Title",
         "artist":"Same Artist", "album":"Same Album", "artwork":red},
        {"file":"other.mp3", "fingerprint":"isrc:EXACT-SECOND", "title":"Same Title",
         "artist":"Same Artist", "album":"Same Album", "artwork":green}
    ], "playlists":[{"name":"Fixture Mix", "tracks":["song.mp3", "other.mp3"]}]});
    let report = fixture.import(manifest.clone());
    assert_eq!((report.new_tracks, report.existing_tracks), (2, 0));
    assert_eq!(
        report.track_artwork_imported, 2,
        "{:?}",
        report.artwork_failures
    );
    let expected = BTreeSet::from([
        "isrc:EXACT-FIRST".to_string(),
        "isrc:EXACT-SECOND".to_string(),
    ]);
    assert_eq!(
        report
            .track_fingerprints
            .into_iter()
            .collect::<BTreeSet<_>>(),
        expected
    );
    let library = fixture.scan();
    assert_eq!(library.tracks.len(), 2);
    assert_eq!(mix(&library).track_ids.len(), 2);
    for (fingerprint, file) in [
        ("isrc:EXACT-FIRST", "red.png"),
        ("isrc:EXACT-SECOND", "green.png"),
    ] {
        let track = library
            .tracks
            .iter()
            .find(|track| track.fingerprint == fingerprint)
            .unwrap();
        assert_eq!(
            fs::read(&track.artwork.as_ref().unwrap().source_path).unwrap(),
            fs::read(fixture.input.path().join(file)).unwrap()
        );
    }
    let repeated = fixture.import(manifest);
    assert_eq!((repeated.new_tracks, repeated.existing_tracks), (0, 2));
    assert_eq!(repeated.artwork_already_present, 2);
    assert_eq!(fixture.scan().tracks.len(), 2);
}

#[test]
fn exact_existing_fingerprint_can_import_artwork_after_source_audio_disappears() {
    let fixture = ArtworkImportFixture::new();
    fixture.import(fixture.initial_manifest());
    let art = fixture.image("cover.png", ImageFormat::Png, [30, 170, 80]);
    fs::remove_file(fixture.input.path().join("song.mp3")).unwrap();
    let mut manifest = fixture.initial_manifest();
    manifest["tracks"][0]["artwork"] = art;
    let report = fixture.import(manifest);
    assert_eq!(
        (
            report.new_tracks,
            report.existing_tracks,
            report.skipped_tracks
        ),
        (0, 1, 0)
    );
    assert_eq!(report.track_fingerprints, ["isrc:ARTWORK-EXACT"]);
    assert_eq!(
        report.track_artwork_imported, 1,
        "{:?}",
        report.artwork_failures
    );
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let library = fixture.scan();
    assert_eq!(library.tracks.len(), 1);
    assert!(Path::new(&library.tracks[0].path).is_file());
    assert!(library.tracks[0].artwork.is_some());
    assert_eq!(mix(&library).track_ids, [library.tracks[0].id.clone()]);
}

fn playlist_fingerprints(library: &Library, playlist: &Playlist) -> Vec<String> {
    playlist
        .track_ids
        .iter()
        .map(|id| {
            library
                .tracks
                .iter()
                .find(|track| &track.id == id)
                .unwrap()
                .fingerprint
                .clone()
        })
        .collect()
}

#[test]
fn imported_playlist_order_survives_repeat_import_rescan_and_rename() {
    let fixture = ArtworkImportFixture::new();
    fixture.write("alpha.mp3", b"alpha audio");
    fixture.write("beta.mp3", b"beta audio");
    fixture.write("gamma.mp3", b"gamma audio");
    let manifest = json!({"schema":"loud.import.v1", "tracks":[
        {"file":"alpha.mp3", "fingerprint":"isrc:ORDER-A", "title":"Alpha", "artist":"Alpha"},
        {"file":"beta.mp3", "fingerprint":"isrc:ORDER-B", "title":"Beta", "artist":"Beta"},
        {"file":"gamma.mp3", "fingerprint":"isrc:ORDER-C", "title":"Gamma", "artist":"Gamma"}
    ], "playlists":[{"name":"Fixture Mix", "tracks":["gamma.mp3", "alpha.mp3", "beta.mp3"]}]});
    fixture.import(manifest.clone());
    let first = fixture.scan();
    let playlist_id = mix(&first).id.clone();
    let expected = ["isrc:ORDER-C", "isrc:ORDER-A", "isrc:ORDER-B"];
    assert_eq!(playlist_fingerprints(&first, mix(&first)), expected);
    let repeated = fixture.import(manifest);
    assert_eq!((repeated.new_tracks, repeated.existing_tracks), (0, 3));
    let rescanned = fixture.scan();
    assert_eq!(playlist_fingerprints(&rescanned, mix(&rescanned)), expected);
    rename_playlist_path(fixture.library.path(), &playlist_id, "Ordered Renamed Mix").unwrap();
    let renamed = fixture.scan();
    let playlist = renamed
        .playlists
        .iter()
        .find(|playlist| playlist.id == playlist_id)
        .unwrap();
    assert_eq!(playlist.name, "Ordered Renamed Mix");
    assert_eq!(playlist_fingerprints(&renamed, playlist), expected);
}

#[test]
fn folder_playlist_keeps_ordered_manifest_refs_before_deterministic_remainder() {
    let fixture = ArtworkImportFixture::new();
    let folder = fixture.library.path().join("Fixture Mix");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("Zebra Folder Song.mp3"), b"zebra folder audio").unwrap();
    fs::write(folder.join("Alpha Folder Song.mp3"), b"alpha folder audio").unwrap();
    fixture.write("first.mp3", b"first managed audio");
    fixture.write("second.mp3", b"second managed audio");
    let manifest = json!({"schema":"loud.import.v1", "tracks":[
        {"file":"first.mp3", "fingerprint":"isrc:MANAGED-FIRST", "title":"First Managed", "artist":"Zebra"},
        {"file":"second.mp3", "fingerprint":"isrc:MANAGED-SECOND", "title":"Second Managed", "artist":"Alpha"}
    ], "playlists":[{"name":"Fixture Mix", "tracks":["first.mp3", "second.mp3"]}]});
    fixture.import(manifest.clone());
    for pass in 0..2 {
        let library = fixture.scan();
        let playlist = mix(&library);
        let titles = playlist
            .track_ids
            .iter()
            .map(|id| {
                library
                    .tracks
                    .iter()
                    .find(|track| &track.id == id)
                    .unwrap()
                    .title
                    .as_str()
            })
            .collect::<Vec<_>>();
        assert_eq!(
            titles,
            [
                "First Managed",
                "Second Managed",
                "Alpha Folder Song",
                "Zebra Folder Song"
            ],
            "pass {pass}"
        );
        assert!(Path::new(&playlist.path).is_dir());
        if pass == 0 {
            fixture.import(manifest.clone());
        }
    }
}

#[test]
fn provider_playlist_refs_remain_supported_but_ambiguous_or_inexact_refs_cannot_merge_tracks() {
    let fixture = ArtworkImportFixture::new();
    let mut manifest = fixture.initial_manifest();
    manifest["playlists"][0]["tracks"] =
        json!([{"identifiers":{"spotify_track_id":"alternate-identity"}}]);
    let first = fixture.import(manifest.clone());
    assert!(first.failures.is_empty(), "{:?}", first.failures);
    assert_eq!(mix(&fixture.scan()).track_ids.len(), 1);
    let existing_ref = fixture.import(json!({"schema":"loud.import.v1", "tracks":[],
        "playlists":[{"name":"Alias Mix", "tracks":[{"identifiers":{"spotify_track_id":"alternate-identity"}}]}]}));
    assert!(
        existing_ref.failures.is_empty(),
        "{:?}",
        existing_ref.failures
    );
    assert_eq!(existing_ref.track_fingerprints, ["isrc:ARTWORK-EXACT"]);

    fixture.write("second.mp3", b"different audio fixture");
    let mut second = manifest["tracks"][0].clone();
    second["file"] = json!("second.mp3");
    second["fingerprint"] = json!("different-explicit-fingerprint");
    manifest["tracks"].as_array_mut().unwrap().push(second);
    manifest["playlists"] = json!([{"name":"Ambiguous Mix", "tracks":[
        {"identifiers":{"spotify_track_id":"alternate-identity"}},
        {"fingerprint":"spotify:track:alternate-identity"},
        {"fingerprint":"isrc:ARTWORK-EXACT"},
        {"fingerprint":"different-explicit-fingerprint"}
    ]}]);
    let ambiguous = fixture.import(manifest);
    assert_eq!((ambiguous.new_tracks, ambiguous.existing_tracks), (1, 1));
    assert_eq!(ambiguous.failures.len(), 2);
    let library = fixture.scan();
    assert_eq!(library.tracks.len(), 2);
    assert_eq!(
        library
            .playlists
            .iter()
            .find(|playlist| playlist.name == "Ambiguous Mix")
            .unwrap()
            .track_ids
            .len(),
        2
    );
}

#[test]
fn case_insensitive_album_directories_preserve_every_explicit_identity_on_rescan() {
    let fixture = ArtworkImportFixture::new();
    fs::create_dir(fixture.library.path().join("CaseProbe")).unwrap();
    let case_insensitive = fixture.library.path().join("caseprobe").is_dir();
    fs::remove_dir(fixture.library.path().join("CaseProbe")).unwrap();
    if !case_insensitive {
        return;
    }
    fixture.write("a.mp3", b"first fixture audio");
    fixture.write("b.mp3", b"second fixture audio");
    let manifest = json!({"schema":"loud.import.v1", "tracks":[
        {"file":"a.mp3", "fingerprint":"spotify:track:distinct-first", "title":"Breakable", "artist":"Fixture Artist", "album":"Girls And Boys"},
        {"file":"b.mp3", "fingerprint":"isrc:DISTINCT-SECOND", "title":"Breakable", "artist":"Fixture Artist", "album":"Girls and Boys"}
    ], "playlists":[{"name":"Case Mix", "tracks":[{"fingerprint":"spotify:track:distinct-first"},{"fingerprint":"isrc:DISTINCT-SECOND"}]}]});
    let imported = fixture.import(manifest.clone());
    assert_eq!(imported.new_tracks, 2);
    for _ in 0..2 {
        let scanned = fixture.scan();
        let fingerprints = scanned
            .tracks
            .iter()
            .map(|track| track.fingerprint.as_str())
            .collect::<BTreeSet<_>>();
        assert_eq!(
            fingerprints,
            BTreeSet::from(["spotify:track:distinct-first", "isrc:DISTINCT-SECOND"])
        );
        assert_eq!(
            scanned
                .playlists
                .iter()
                .find(|playlist| playlist.name == "Case Mix")
                .unwrap()
                .track_ids
                .len(),
            2
        );
    }
    let repeated = fixture.import(manifest);
    assert_eq!((repeated.new_tracks, repeated.existing_tracks), (0, 2));
    assert!(repeated.failures.is_empty());
}

#[cfg(unix)]
#[test]
fn legacy_managed_path_alias_uses_file_identity_without_metadata_fuzzy_matching() {
    use std::os::unix::fs::symlink;
    let fixture = ArtworkImportFixture::new();
    fixture.import(fixture.initial_manifest());
    let state_path = fixture.library.path().join(".loud/state.json");
    let mut state: Value = serde_json::from_slice(&fs::read(&state_path).unwrap()).unwrap();
    let original_key = state["managed_tracks"]
        .as_object()
        .unwrap()
        .keys()
        .next()
        .unwrap()
        .clone();
    let metadata = state["managed_tracks"]
        .as_object_mut()
        .unwrap()
        .remove(&original_key)
        .unwrap();
    symlink("audio", fixture.library.path().join(".loud/audio-alias")).unwrap();
    state["managed_tracks"][original_key.replace(".loud/audio/", ".loud/audio-alias/")] = metadata;
    fs::write(state_path, serde_json::to_vec(&state).unwrap()).unwrap();
    let scanned = fixture.scan();
    assert_eq!(scanned.tracks.len(), 1);
    assert_eq!(scanned.tracks[0].fingerprint, "isrc:ARTWORK-EXACT");
    assert_eq!(mix(&scanned).track_ids, [scanned.tracks[0].id.clone()]);
}
