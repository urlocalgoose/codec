//! Playlist-name preflight must reject ambiguous imports before writing audio or state.
use super::*;
use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::Cursor;
use tempfile::{tempdir, TempDir};

struct CollisionFixture {
    library: TempDir,
    source: TempDir,
}

impl CollisionFixture {
    fn new() -> Self {
        let fixture = Self {
            library: tempdir().unwrap(),
            source: tempdir().unwrap(),
        };
        fixture.write_source("new.mp3", b"new isolated audio");
        fixture
    }

    fn write_source(&self, name: &str, bytes: &[u8]) {
        fs::write(self.source.path().join(name), bytes).unwrap();
    }

    fn write_json(&self, name: &str, value: &Value) {
        self.write_source(name, &serde_json::to_vec_pretty(value).unwrap());
    }

    fn import(&self, manifest: Value) -> Result<ImportReport, String> {
        self.write_json("manifest.json", &manifest);
        import_library_manifest_path(
            self.library.path(),
            self.source.path().join("manifest.json"),
        )
    }

    fn scan(&self) -> Library {
        scan_library_path(self.library.path()).unwrap()
    }

    fn cover(&self, name: &str, color: [u8; 3]) -> Value {
        let mut encoded = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(RgbImage::from_pixel(4, 3, Rgb(color)))
            .write_to(&mut encoded, ImageFormat::Png)
            .unwrap();
        let bytes = encoded.into_inner();
        self.write_source(name, &bytes);
        json!({"file":name, "sha256":format!("{:x}", Sha256::digest(&bytes)),
            "mime_type":"image/png", "width":4, "height":3})
    }

    fn new_track_manifest(&self) -> Value {
        json!({"schema":"loud.import.v1", "tracks":[{
            "file":"new.mp3", "fingerprint":"isrc:COLLISION-NEW",
            "title":"New Track", "artist":"Beta", "album":"Collision Tests"
        }], "playlists":[]})
    }

    fn seed_playlist(&self, name: &str) {
        self.write_source("old-z.mp3", b"old z audio");
        self.write_source("old-a.mp3", b"old a audio");
        let art = self.cover("old-cover.png", [200, 30, 50]);
        self.import(json!({"schema":"loud.import.v1", "tracks":[
            {"file":"old-a.mp3", "fingerprint":"isrc:COLLISION-OLD-A", "title":"Old A", "artist":"Alpha"},
            {"file":"old-z.mp3", "fingerprint":"isrc:COLLISION-OLD-Z", "title":"Old Z", "artist":"Zulu"}
        ], "playlists":[{"name":name, "tracks":["old-z.mp3", "old-a.mp3"], "artwork":art}]})).unwrap();
    }

    fn sidecar(&self, rows: Value) {
        self.write_json(
            "playlist-artwork.json",
            &json!({
                "schema":"s2y.playlist-artwork.v1", "base_path":".", "playlists":rows
            }),
        );
    }

    fn assert_rejected_without_writes(&self, manifest: Value, label: &str) {
        // Warm the normal scan cache first so a preflight scan does not itself
        // account for unrelated initial cache creation in this comparison.
        self.scan();
        let before = disk_snapshot(self.library.path());
        let error = self.import(manifest).expect_err(label);
        assert!(!error.is_empty(), "{label}: missing collision diagnostic");
        assert_eq!(
            disk_snapshot(self.library.path()),
            before,
            "{label}: rejected import changed the library"
        );
    }
}

fn disk_snapshot(root: &Path) -> BTreeMap<PathBuf, Option<Vec<u8>>> {
    let mut snapshot = BTreeMap::new();
    for entry in WalkDir::new(root).min_depth(1) {
        let entry = entry.unwrap();
        let relative = entry.path().strip_prefix(root).unwrap().to_path_buf();
        let value = if entry.file_type().is_file() {
            Some(fs::read(entry.path()).unwrap())
        } else {
            assert!(
                entry.file_type().is_dir(),
                "fixture contains unexpected symlink"
            );
            None
        };
        snapshot.insert(relative, value);
    }
    snapshot
}

fn named_playlist<'a>(library: &'a Library, name: &str) -> &'a Playlist {
    library
        .playlists
        .iter()
        .find(|playlist| playlist.name == name)
        .unwrap()
}

fn fingerprints(library: &Library, playlist: &Playlist) -> Vec<String> {
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
fn manifest_playlist_case_and_whitespace_collisions_fail_before_any_write() {
    for variant in ["road trip", "Road  Trip", "Road\tTrip"] {
        let fixture = CollisionFixture::new();
        let art = fixture.cover("cover.png", [30, 180, 80]);
        let mut manifest = fixture.new_track_manifest();
        manifest["tracks"][0]["liked"] = json!(true);
        manifest["tracks"][0]["artwork"] = art.clone();
        manifest["playlists"] = json!([
            {"name":"Road Trip", "tracks":["new.mp3"], "artwork":art},
            {"name":variant, "mode":"replace", "tracks":["new.mp3"], "artwork":art}
        ]);
        fixture.assert_rejected_without_writes(manifest, variant);
        assert!(fixture.scan().tracks.is_empty());
    }
}

#[test]
fn incoming_names_cannot_alias_existing_state_or_folder_playlists() {
    for kind in ["state", "folder"] {
        for variant in ["road trip", "Road  Trip", "Road\tTrip"] {
            let fixture = CollisionFixture::new();
            if kind == "state" {
                fixture.seed_playlist("Road Trip");
            } else {
                let folder = fixture.library.path().join("Road Trip");
                fs::create_dir(&folder).unwrap();
                fs::write(folder.join("Existing Song.mp3"), b"existing folder audio").unwrap();
            }
            let art = fixture.cover("incoming-cover.png", [30, 180, 80]);
            let mut manifest = fixture.new_track_manifest();
            manifest["tracks"][0]["liked"] = json!(true);
            manifest["playlists"] =
                json!([{"name":variant, "mode":"replace", "tracks":["new.mp3"], "artwork":art}]);
            fixture.assert_rejected_without_writes(manifest, &format!("{kind}/{variant}"));
        }
    }
}

#[test]
fn track_playlist_references_participate_in_collision_preflight() {
    for origin in [
        "two-references",
        "top-level-and-reference",
        "existing-and-reference",
    ] {
        for variant in ["road trip", "Road  Trip", "Road\tTrip"] {
            let fixture = CollisionFixture::new();
            let mut manifest = fixture.new_track_manifest();
            manifest["tracks"][0]["playlists"] = json!([variant]);
            match origin {
                "two-references" => {
                    manifest["tracks"][0]["playlists"] = json!(["Road Trip", variant])
                }
                "top-level-and-reference" => {
                    manifest["playlists"] = json!([{"name":"Road Trip", "tracks":["new.mp3"]}])
                }
                "existing-and-reference" => fixture.seed_playlist("Road Trip"),
                _ => unreachable!(),
            }
            fixture.assert_rejected_without_writes(manifest, &format!("{origin}/{variant}"));
        }
    }
}

#[test]
fn valid_sidecar_names_cannot_hide_collisions_behind_inline_precedence() {
    for origin in [
        "two-sidecar-rows",
        "inline-and-sidecar",
        "reference-and-sidecar",
        "existing-and-sidecar",
    ] {
        for variant in ["road trip", "Road  Trip", "Road\tTrip"] {
            let fixture = CollisionFixture::new();
            let inline = fixture.cover("inline.png", [200, 30, 50]);
            let sidecar = fixture.cover("sidecar.png", [30, 180, 80]);
            let mut manifest = fixture.new_track_manifest();
            let mut rows = vec![json!({"name":variant, "artwork":sidecar})];
            match origin {
                "two-sidecar-rows" => rows.insert(0, json!({"name":"Road Trip", "artwork":inline})),
                "inline-and-sidecar" => {
                    manifest["playlists"] =
                        json!([{"name":"Road Trip", "tracks":["new.mp3"], "artwork":inline}])
                }
                "reference-and-sidecar" => {
                    manifest["tracks"][0]["playlists"] = json!(["Road Trip"])
                }
                "existing-and-sidecar" => fixture.seed_playlist("Road Trip"),
                _ => unreachable!(),
            }
            fixture.sidecar(json!(rows));
            fixture.assert_rejected_without_writes(manifest, &format!("{origin}/{variant}"));
        }
    }
}

#[test]
fn exact_existing_name_appends_without_changing_playlist_id_order_or_artwork() {
    let fixture = CollisionFixture::new();
    fixture.seed_playlist("Original Name");
    let seeded = fixture.scan();
    let old_id = named_playlist(&seeded, "Original Name").id.clone();
    rename_playlist_path(fixture.library.path(), &old_id, "Road Trip").unwrap();
    let before = fixture.scan();
    let old_playlist = named_playlist(&before, "Road Trip");
    let old_art = old_playlist.artwork.as_ref().unwrap();
    let original_bytes = fs::read(&old_art.source_path).unwrap();
    assert_eq!(
        fingerprints(&before, old_playlist),
        ["isrc:COLLISION-OLD-Z", "isrc:COLLISION-OLD-A"]
    );

    let replacement = fixture.cover("replacement.png", [30, 180, 80]);
    let mut manifest = fixture.new_track_manifest();
    manifest["tracks"][0]["playlists"] = json!(["Road Trip"]);
    manifest["playlists"] = json!([{"name":"Road Trip", "mode":"append", "artwork":replacement,
        "tracks":[{"fingerprint":"isrc:COLLISION-OLD-A"}, "new.mp3"]}]);
    fixture.sidecar(json!([{"name":"Road Trip", "artwork":replacement}]));
    let report = fixture.import(manifest.clone()).unwrap();
    assert_eq!(report.new_tracks, 1);
    assert!(report.artwork_failures.is_empty());
    assert_eq!(report.artwork_already_present, 1);
    let after = fixture.scan();
    let playlist = named_playlist(&after, "Road Trip");
    assert_eq!(playlist.id, old_id);
    assert_eq!(
        fingerprints(&after, playlist),
        [
            "isrc:COLLISION-OLD-Z",
            "isrc:COLLISION-OLD-A",
            "isrc:COLLISION-NEW"
        ]
    );
    assert_eq!(
        playlist.artwork.as_ref().unwrap().source_path,
        old_art.source_path
    );
    assert_eq!(fs::read(&old_art.source_path).unwrap(), original_bytes);
    assert_eq!(
        after
            .playlists
            .iter()
            .filter(|playlist| normalize(&playlist.name) == "road trip")
            .count(),
        1
    );
    let repeated = fixture.import(manifest).unwrap();
    assert_eq!(repeated.new_tracks, 0);
    let rescanned = fixture.scan();
    assert_eq!(
        fingerprints(&rescanned, named_playlist(&rescanned, "Road Trip")),
        fingerprints(&after, playlist)
    );
}

#[test]
fn identical_source_names_are_allowed_across_multiple_references() {
    let fixture = CollisionFixture::new();
    let mut manifest = fixture.new_track_manifest();
    manifest["tracks"][0]["playlists"] = json!(["Road Trip", "Road Trip"]);
    manifest["playlists"] = json!([
        {"name":"Road Trip", "tracks":["new.mp3"]},
        {"name":"Road Trip", "tracks":["new.mp3"]}
    ]);
    let report = fixture.import(manifest).unwrap();
    assert_eq!(report.new_tracks, 1);
    let library = fixture.scan();
    assert_eq!(
        fingerprints(&library, named_playlist(&library, "Road Trip")),
        ["isrc:COLLISION-NEW"]
    );
    assert_eq!(
        library
            .playlists
            .iter()
            .filter(|playlist| playlist.name == "Road Trip")
            .count(),
        1
    );
}

#[test]
fn invalid_artwork_sidecars_keep_normal_diagnostics_without_blocking_audio() {
    for invalid in ["missing-art-file", "malformed-json", "wrong-schema"] {
        let fixture = CollisionFixture::new();
        let mut art = fixture.cover("cover.png", [30, 180, 80]);
        match invalid {
            "missing-art-file" => {
                art["file"] = json!("absent.png");
                fixture.sidecar(json!([{"name":"Road Trip", "artwork":art}]));
            }
            "malformed-json" => fixture.write_source("playlist-artwork.json", b"not json"),
            "wrong-schema" => fixture.write_json(
                "playlist-artwork.json",
                &json!({
                    "schema":"unsupported", "playlists":[{"name":"Road Trip", "artwork":art}]
                }),
            ),
            _ => unreachable!(),
        }
        let mut manifest = fixture.new_track_manifest();
        manifest["playlists"] = json!([{"name":"Road Trip", "tracks":["new.mp3"]}]);
        let report = fixture.import(manifest).unwrap();
        assert_eq!(report.new_tracks, 1, "{invalid}");
        assert_eq!(report.playlist_artwork_imported, 0, "{invalid}");
        assert!(!report.artwork_failures.is_empty(), "{invalid}");
        if invalid == "missing-art-file" {
            assert_eq!(report.artwork_missing, 1);
        }
        let library = fixture.scan();
        assert_eq!(
            fingerprints(&library, named_playlist(&library, "Road Trip")),
            ["isrc:COLLISION-NEW"],
            "{invalid}"
        );
    }
}

#[test]
fn malformed_sidecar_descriptor_does_not_promote_optional_artwork_to_fatal_name_collision() {
    let fixture = CollisionFixture::new();
    fixture
        .sidecar(json!([{"name":"road trip", "origin":"avb727", "artwork":{"file":"cover.png"}}]));
    let mut manifest = fixture.new_track_manifest();
    manifest["playlists"] = json!([{"name":"Road Trip", "tracks":["new.mp3"]}]);
    let report = fixture.import(manifest).unwrap();
    assert_eq!(report.new_tracks, 1);
    assert_eq!(report.artwork_failed, 1);
    assert_eq!(report.artwork_missing, 0);
    assert!(report.artwork_failures[0]
        .reason
        .contains("Invalid artwork descriptor"));
    let library = fixture.scan();
    assert_eq!(
        fingerprints(&library, named_playlist(&library, "Road Trip")),
        ["isrc:COLLISION-NEW"]
    );
    assert!(!library
        .playlists
        .iter()
        .any(|playlist| playlist.name == "road trip"));
}
