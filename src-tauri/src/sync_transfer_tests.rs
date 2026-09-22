use super::*;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use tempfile::tempdir;

#[derive(Clone, Debug)]
struct Request {
    method: String,
    path: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}
#[derive(Default)]
struct FixtureState {
    tracks: Vec<Value>,
    playlists: Vec<Value>,
    media: BTreeMap<String, (Vec<u8>, String)>,
    requests: Vec<Request>,
    head_status: BTreeMap<String, u16>,
    conditional_conflicts: BTreeSet<String>,
}
struct Fixture {
    url: String,
    state: Arc<Mutex<FixtureState>>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Fixture {
    fn new(state: FixtureState) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let state = Arc::new(Mutex::new(state));
        let stop = Arc::new(AtomicBool::new(false));
        let shared = state.clone();
        let stopping = stop.clone();
        let worker = thread::spawn(move || {
            while !stopping.load(Ordering::SeqCst) {
                let (mut stream, _) = match listener.accept() {
                    Ok(stream) => stream,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                        continue;
                    }
                    Err(error) => panic!("{error}"),
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(15)))
                    .unwrap();
                let request = read_request(&mut stream);
                let head = request.method == "HEAD";
                let (status, body, mime) = respond(&mut shared.lock().unwrap(), request);
                write!(stream, "HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nContent-Type: {mime}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
                if !head {
                    stream.write_all(&body).unwrap();
                }
            }
        });
        Self {
            url,
            state,
            stop,
            worker: Some(worker),
        }
    }
    fn client(&self) -> reqwest::blocking::Client {
        sync_http_client("fixture-secret").unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let joined = self.worker.take().unwrap().join();
        if !thread::panicking() {
            joined.unwrap();
        }
    }
}
fn read_request(stream: &mut TcpStream) -> Request {
    let mut bytes = Vec::new();
    let end = loop {
        let mut chunk = [0; 4096];
        let count = stream.read(&mut chunk).unwrap();
        assert!(count > 0);
        bytes.extend_from_slice(&chunk[..count]);
        if let Some(index) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
            break index + 4;
        }
        assert!(bytes.len() < 65536);
    };
    let header = String::from_utf8(bytes[..end].to_vec()).unwrap();
    let mut lines = header.split("\r\n");
    let mut first = lines.next().unwrap().split(' ');
    let method = first.next().unwrap().to_string();
    let path = first.next().unwrap().to_string();
    let headers = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(key, value)| (key.to_lowercase(), value.trim().to_string()))
        .collect::<BTreeMap<_, _>>();
    let length: usize = headers
        .get("content-length")
        .map(|value| value.parse().unwrap())
        .unwrap_or(0);
    let mut body = bytes[end..].to_vec();
    if body.len() < length {
        let old = body.len();
        body.resize(length, 0);
        stream.read_exact(&mut body[old..]).unwrap();
    }
    Request {
        method,
        path,
        headers,
        body,
    }
}
fn response(status: u16, value: Value) -> (u16, Vec<u8>, String) {
    (
        status,
        serde_json::to_vec(&value).unwrap(),
        "application/json".into(),
    )
}
fn respond(state: &mut FixtureState, request: Request) -> (u16, Vec<u8>, String) {
    assert_eq!(
        request.headers.get("authorization").map(String::as_str),
        Some("Bearer fixture-secret")
    );
    state.requests.push(request.clone());
    if request.path == "/api/v1/sync/snapshot" && request.method == "GET" {
        return response(
            200,
            json!({"library":{"tracks":state.tracks,"playlists":state.playlists}}),
        );
    }
    if request.method == "HEAD" {
        if let Some(status) = state.head_status.get(&request.path) {
            return response(*status, json!({}));
        }
        return match state.media.get(&request.path) {
            Some((bytes, mime)) => (200, bytes.clone(), mime.clone()),
            None => response(404, json!({})),
        };
    }
    if request.path.ends_with("/artwork") || request.path.ends_with("/audio") {
        if request.method == "GET" {
            return match state.media.get(&request.path) {
                Some((bytes, mime)) => (200, bytes.clone(), mime.clone()),
                None => response(404, json!({})),
            };
        }
        if request.method == "PUT" {
            if state.conditional_conflicts.contains(&request.path) {
                return response(412, json!({}));
            }
            let mime = request.headers.get("content-type").unwrap().clone();
            state.media.insert(request.path, (request.body, mime));
            return response(204, Value::Null);
        }
    }
    if request.method == "PUT" && request.path.starts_with("/api/v1/tracks/") {
        let value: Value = serde_json::from_slice(&request.body).unwrap();
        if request.path.ends_with("/liked") {
            let fp = request
                .path
                .trim_start_matches("/api/v1/tracks/")
                .trim_end_matches("/liked");
            state
                .tracks
                .iter_mut()
                .find(|track| track["fingerprint"] == fp)
                .unwrap()["is_liked"] = value["liked"].clone();
        } else {
            assert!(
                !state
                    .tracks
                    .iter()
                    .any(|track| track["fingerprint"] == value["fingerprint"]),
                "existing metadata overwritten"
            );
            state.tracks.push(value);
        }
        return response(204, Value::Null);
    }
    if request.method == "POST" && request.path == "/api/v1/playlists" {
        let value: Value = serde_json::from_slice(&request.body).unwrap();
        let playlist = json!({"id":format!("destination-{}",state.playlists.len()),"name":value["name"],"track_ids":[],"is_liked":false});
        state.playlists.push(playlist.clone());
        return response(201, playlist);
    }
    if request.method == "POST"
        && request.path.starts_with("/api/v1/playlists/")
        && request.path.ends_with("/tracks")
    {
        let id = request
            .path
            .trim_start_matches("/api/v1/playlists/")
            .trim_end_matches("/tracks");
        let value: Value = serde_json::from_slice(&request.body).unwrap();
        let playlist = state
            .playlists
            .iter_mut()
            .find(|playlist| playlist["id"] == id)
            .unwrap();
        let id = json!(format!("track_{}", value["fingerprint"].as_str().unwrap()));
        let ids = playlist["track_ids"].as_array_mut().unwrap();
        if !ids.contains(&id) {
            ids.push(id);
        }
        return response(200, playlist.clone());
    }
    panic!("Unexpected request: {} {}", request.method, request.path);
}
fn original(temp: &Path, name: &str, format: image::ImageFormat) -> CachedArtwork {
    let path = temp.join(name);
    let mut bytes = io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(8, 5, image::Rgb([10, 120, 40])))
        .write_to(&mut bytes, format)
        .unwrap();
    fs::write(&path, bytes.into_inner()).unwrap();
    CachedArtwork {
        source_path: path,
        cache_path: temp.join(format!("{name}.thumb.jpg")),
        original_mime_type: Some(format.to_mime_type().to_string()),
    }
}
fn track(root: &Path, fp: &str, liked: bool, artwork: Option<CachedArtwork>) -> library::Track {
    let path = root.join(format!("{fp}.mp3"));
    fs::write(&path, b"audio-fixture").unwrap();
    library::Track {
        id: format!("local-{fp}"),
        path: path_to_sync_string(&path),
        file_name: format!("{fp}.mp3"),
        title: format!("Local {fp}"),
        artist: "Artist".into(),
        album: "Album".into(),
        album_artist: None,
        genre: None,
        year: None,
        track_number: None,
        disc_number: None,
        explicit: None,
        identifiers: BTreeMap::new(),
        source_urls: BTreeMap::new(),
        duration_seconds: Some(60.),
        artwork_url: None,
        artwork,
        playlist_ids: vec![],
        added_at: None,
        size_bytes: 13,
        is_liked: liked,
        fingerprint: fp.into(),
    }
}
fn playlist(
    id: &str,
    name: &str,
    ids: &[&str],
    artwork: Option<CachedArtwork>,
) -> library::Playlist {
    library::Playlist {
        id: id.into(),
        name: name.into(),
        path: String::new(),
        track_ids: ids.iter().map(|id| id.to_string()).collect(),
        is_liked: false,
        artwork_url: None,
        artwork,
    }
}
fn old_track() -> Value {
    json!({"id":"track_old","fingerprint":"old","title":"Preserved title","artist":"Server Artist","album":"Server Album","file_name":"old.mp3","is_liked":true,"custom":"untouched"})
}

#[test]
fn additive_merge_preserves_metadata_order_likes_and_covers_and_is_idempotent() {
    let temp = tempdir().unwrap();
    let jpeg = original(temp.path(), "original.jpg", image::ImageFormat::Jpeg);
    let png = original(temp.path(), "original.png", image::ImageFormat::Png);
    let jpeg_bytes = fs::read(&jpeg.source_path).unwrap();
    let png_bytes = fs::read(&png.source_path).unwrap();
    let mut local = scan_library_path(temp.path()).unwrap();
    local.tracks = vec![
        track(temp.path(), "old", false, Some(jpeg.clone())),
        track(temp.path(), "new", true, Some(png)),
    ];
    local.playlists = vec![
        playlist(
            "local-mix",
            "Mix",
            &["local-new", "local-old"],
            Some(jpeg.clone()),
        ),
        playlist(
            "local-fresh",
            "Fresh",
            &["local-new", "local-old"],
            Some(jpeg),
        ),
    ];
    let mut state = FixtureState::default();
    state.tracks.push(old_track());
    state.playlists.push(
        json!({"id":"actual-server-mix","name":"Mix","track_ids":["track_old"],"is_liked":false}),
    );
    state.media.insert(
        "/api/v1/tracks/old/audio".into(),
        (b"existing audio".to_vec(), "audio/mpeg".into()),
    );
    state.media.insert(
        "/api/v1/tracks/old/artwork".into(),
        (b"custom track cover".to_vec(), "image/jpeg".into()),
    );
    state.media.insert(
        "/api/v1/playlists/actual-server-mix/artwork".into(),
        (b"custom playlist cover".to_vec(), "image/jpeg".into()),
    );
    let fixture = Fixture::new(state);
    let report = merge_library_to_server(&local, &fixture.client(), &fixture.url).unwrap();
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    assert_eq!(
        (
            report.tracks_added,
            report.tracks_matched,
            report.tracks_uploaded,
            report.tracks_skipped
        ),
        (1, 1, 1, 1)
    );
    assert_eq!(
        (
            report.playlists_added,
            report.playlists_updated,
            report.playlist_tracks_added,
            report.liked_updates
        ),
        (1, 1, 3, 1)
    );
    assert_eq!(
        (
            report.track_artwork_uploaded,
            report.playlist_artwork_uploaded,
            report.artwork_already_present
        ),
        (1, 1, 2)
    );
    assert_eq!(
        report.playlist_mappings[0].destination_id,
        "actual-server-mix"
    );
    {
        let state = fixture.state.lock().unwrap();
        assert_eq!(state.tracks[0], old_track());
        assert_eq!(
            state.playlists[0]["track_ids"],
            json!(["track_old", "track_new"])
        );
        assert_eq!(
            state.playlists[1]["track_ids"],
            json!(["track_new", "track_old"])
        );
        assert_eq!(
            state.media["/api/v1/tracks/old/artwork"].0,
            b"custom track cover"
        );
        assert_eq!(
            state.media["/api/v1/playlists/actual-server-mix/artwork"].0,
            b"custom playlist cover"
        );
        assert_eq!(
            state.media["/api/v1/tracks/new/artwork"],
            (png_bytes, "image/png".into())
        );
        assert_eq!(
            state.media["/api/v1/playlists/destination-1/artwork"],
            (jpeg_bytes, "image/jpeg".into())
        );
        assert!(state
            .requests
            .iter()
            .filter(|r| r.method == "PUT" && r.path.ends_with("/artwork"))
            .all(|r| r.headers.get("if-none-match").map(String::as_str) == Some("*")));
    }
    let second = merge_library_to_server(&local, &fixture.client(), &fixture.url).unwrap();
    assert!(second.failures.is_empty());
    assert_eq!(
        (
            second.tracks_added,
            second.tracks_uploaded,
            second.playlists_added,
            second.playlist_tracks_added,
            second.artwork_uploaded,
            second.liked_updates
        ),
        (0, 0, 0, 0, 0, 0)
    );
    assert_eq!(
        (second.tracks_matched, second.artwork_already_present),
        (2, 4)
    );
}

#[test]
fn duplicate_destination_names_abort_before_mutations() {
    let temp = tempdir().unwrap();
    let mut local = scan_library_path(temp.path()).unwrap();
    local.playlists = vec![playlist("source", "Mix", &[], None)];
    let mut state = FixtureState::default();
    state.playlists = vec![
        json!({"id":"one","name":"Mix"}),
        json!({"id":"two","name":"Mix"}),
    ];
    let fixture = Fixture::new(state);
    let error = merge_library_to_server(&local, &fixture.client(), &fixture.url).unwrap_err();
    assert!(error.contains("ambiguous"));
    assert_eq!(fixture.state.lock().unwrap().requests.len(), 1);
}

#[test]
fn desktop_upload_uses_additive_import_and_destination_playlist_cover_ids() {
    use sha2::{Digest, Sha256};
    let source = tempdir().unwrap();
    let local = tempdir().unwrap();
    let cover = original(source.path(), "mix.jpg", image::ImageFormat::Jpeg);
    let cover_bytes = fs::read(&cover.source_path).unwrap();
    fs::write(source.path().join("old.mp3"), mp3_with_embedded_cover(&cover_bytes)).unwrap();
    fs::write(source.path().join("new.mp3"), mp3_with_embedded_cover(&cover_bytes)).unwrap();
    let dimensions = image::image_dimensions(&cover.source_path).unwrap();
    let manifest = source.path().join("loud-import.json");
    fs::write(&manifest, serde_json::to_vec(&json!({
        "schema":"loud.import.v1", "source":{"base_path":"."},
        "tracks":[
            {"file":"old.mp3","fingerprint":"old","title":"Incoming old title","liked":false},
            {"file":"new.mp3","fingerprint":"new","title":"New song","liked":true}
        ],
        "playlists":[{"name":"Mix","tracks":[{"fingerprint":"new"},{"fingerprint":"old"}],
            "artwork":{"file":"mix.jpg","sha256":format!("{:x}",Sha256::digest(&cover_bytes)),
                "mime_type":"image/jpeg","width":dimensions.0,"height":dimensions.1}}]
    })).unwrap()).unwrap();
    let imported = import_library_manifest_path(local.path(), &manifest).unwrap();
    assert!(imported.failures.is_empty(), "{:?}", imported.failures);
    assert!(imported.artwork_failures.is_empty(), "{:?}", imported.artwork_failures);
    let mut state = FixtureState::default();
    state.tracks.push(old_track());
    state.playlists.push(json!({"id":"actual-destination", "name":"Mix", "track_ids":["track_old"], "is_liked":false}));
    state.media.insert("/api/v1/tracks/old/audio".into(), (b"original audio".to_vec(), "audio/mpeg".into()));
    state.media.insert("/api/v1/tracks/old/artwork".into(), (b"original cover".to_vec(), "image/jpeg".into()));
    let fixture = Fixture::new(state);
    let upload = || sync_library_to_server(local.path().to_string_lossy().into(), fixture.url.clone(), "desktop-fixture".into(), "fixture-secret".into()).unwrap();
    let report = upload();
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    assert_eq!((report.tracks_added, report.tracks_matched, report.playlists_updated, report.playlists_added), (1, 1, 1, 0));
    assert_eq!(report.playlist_artwork_uploaded, 1);
    let repeat = upload();
    assert_eq!((repeat.tracks_added, repeat.playlist_tracks_added, repeat.artwork_uploaded), (0, 0, 0));
    let state = fixture.state.lock().unwrap();
    assert_eq!(state.tracks[0], old_track());
    assert_eq!(state.playlists[0]["track_ids"], json!(["track_old", "track_new"]));
    assert_eq!(state.media["/api/v1/playlists/actual-destination/artwork"].0, cover_bytes);
    assert!(!state.requests.iter().any(|request| request.path == "/api/v1/sync/push"));
}

#[test]
fn lost_import_fingerprint_aborts_before_contacting_server_even_if_track_count_matches() {
    let temp = tempdir().unwrap();
    fs::write(temp.path().join("song.mp3"), b"audio fixture").unwrap();
    let local = scan_library_path(temp.path()).unwrap();
    assert_eq!(local.tracks.len(), 1);
    let fixture = Fixture::new(FixtureState::default());
    let error = sync_library_to_server_headless_checked(
        path_to_sync_string(temp.path()),
        fixture.url.clone(),
        "fixture-secret".into(),
        &["spotify:track:expected-identity".into()],
    )
    .unwrap_err();
    assert!(error.contains("rescan lost 1"));
    assert!(error.contains("No server changes were made"));
    assert!(fixture.state.lock().unwrap().requests.is_empty());
    assert!(validate_import_fingerprints(&local, &[local.tracks[0].fingerprint.clone()]).is_ok());
}

#[test]
fn cover_auth_failure_does_not_overwrite_and_conditional_conflict_is_present() {
    let temp = tempdir().unwrap();
    let artwork = original(temp.path(), "cover.jpg", image::ImageFormat::Jpeg);
    let mut state = FixtureState::default();
    state.head_status.insert("/blocked/artwork".into(), 401);
    state.conditional_conflicts.insert("/race/artwork".into());
    let fixture = Fixture::new(state);
    let mut report = SyncTransferReport::default();
    upload_artwork_if_missing(
        &fixture.client(),
        &format!("{}/blocked/artwork", fixture.url),
        Some(&artwork),
        ArtworkKind::Track,
        "blocked",
        &mut report,
    );
    upload_artwork_if_missing(
        &fixture.client(),
        &format!("{}/race/artwork", fixture.url),
        Some(&artwork),
        ArtworkKind::Playlist,
        "race",
        &mut report,
    );
    assert_eq!(
        (
            report.artwork_failed,
            report.artwork_already_present,
            report.artwork_uploaded
        ),
        (1, 1, 0)
    );
    assert!(!fixture
        .state
        .lock()
        .unwrap()
        .requests
        .iter()
        .any(|r| r.method == "PUT" && r.path == "/blocked/artwork"));
}

#[test]
fn matched_tracks_and_destination_playlists_download_original_covers_without_audio() {
    let temp = tempdir().unwrap();
    let original_dir = tempdir().unwrap();
    let jpeg = original(original_dir.path(), "track.jpg", image::ImageFormat::Jpeg);
    let png = original(original_dir.path(), "playlist.png", image::ImageFormat::Png);
    let jpg_bytes = fs::read(jpeg.source_path).unwrap();
    let png_bytes = fs::read(png.source_path).unwrap();
    fs::write(temp.path().join("existing.mp3"), b"test audio").unwrap();
    let manifest = temp.path().join("manifest.json");
    fs::write(&manifest, serde_json::to_vec(&json!({"schema":"loud.import.v1","tracks":[{"file":"existing.mp3","fingerprint":"old","title":"Track","artist":"Artist","album":"Album"}]})).unwrap()).unwrap();
    import_library_manifest_path(temp.path(), &manifest).unwrap();
    let mut state = FixtureState::default();
    state.tracks.push(old_track());
    state
        .playlists
        .push(json!({"id":"actual-playlist","name":"Mix","track_ids":["track_old"]}));
    state.media.insert(
        "/api/v1/tracks/old/artwork".into(),
        (jpg_bytes.clone(), "image/jpeg".into()),
    );
    state.media.insert(
        "/api/v1/playlists/actual-playlist/artwork".into(),
        (png_bytes.clone(), "image/png".into()),
    );
    let fixture = Fixture::new(state);
    let report = sync_library_from_server_headless(
        path_to_sync_string(temp.path()),
        fixture.url.clone(),
        "fixture-secret".into(),
    )
    .unwrap();
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    assert_eq!(
        (
            report.tracks_matched,
            report.tracks_downloaded,
            report.track_artwork_downloaded,
            report.playlist_artwork_downloaded
        ),
        (1, 0, 1, 1)
    );
    let library = scan_library_path(temp.path()).unwrap();
    let track = library
        .tracks
        .iter()
        .find(|track| track.fingerprint == "old")
        .unwrap();
    let playlist = library
        .playlists
        .iter()
        .find(|p| p.id == "actual-playlist")
        .unwrap();
    assert_eq!(
        fs::read(&track.artwork.as_ref().unwrap().source_path).unwrap(),
        jpg_bytes
    );
    assert_eq!(
        fs::read(&playlist.artwork.as_ref().unwrap().source_path).unwrap(),
        png_bytes
    );
    assert_eq!(
        playlist
            .artwork
            .as_ref()
            .unwrap()
            .original_mime_type
            .as_deref(),
        Some("image/png")
    );
    let second = sync_library_from_server_headless(
        path_to_sync_string(temp.path()),
        fixture.url.clone(),
        "fixture-secret".into(),
    )
    .unwrap();
    assert!(second.failures.is_empty());
    assert_eq!(
        (second.artwork_downloaded, second.artwork_already_present),
        (0, 2)
    );
    let state = fixture.state.lock().unwrap();
    assert!(state.requests.iter().all(|r| !r.path.ends_with("/audio")));
    assert_eq!(
        state
            .requests
            .iter()
            .filter(|r| r.path.ends_with("/artwork"))
            .count(),
        2
    );
}

#[test]
fn server_urls_reject_inline_secrets_and_remote_errors_do_not_echo_them() {
    assert!(normalize_server_url("https://user:secret@example.com").is_err());
    assert!(normalize_server_url("https://example.com?access_token=secret").is_err());
    assert_eq!(
        normalize_server_url("localhost:8787/").unwrap(),
        "http://localhost:8787"
    );
    assert_eq!(
        percent_encode_path_segment("isrc:ABC/with space"),
        "isrc%3AABC%2Fwith%20space"
    );
}

#[test]
fn legacy_gif_cover_download_is_reported_without_replacing_destination() {
    let temp = tempdir().unwrap();
    let gif = original(temp.path(), "legacy.gif", image::ImageFormat::Gif);
    let destination = temp.path().join("preserved-cover.jpg");
    fs::write(&destination, b"existing cover").unwrap();
    let mut state = FixtureState::default();
    state.media.insert(
        "/legacy/artwork".into(),
        (fs::read(gif.source_path).unwrap(), "image/gif".into()),
    );
    let fixture = Fixture::new(state);
    let error = download_artwork_descriptor(
        &fixture.client(),
        &format!("{}/legacy/artwork", fixture.url),
        &destination,
        "cover.jpg",
    )
    .unwrap_err();
    assert!(error.contains("only JPEG and PNG"));
    assert_eq!(fs::read(destination).unwrap(), b"existing cover");
}

fn mp3_with_embedded_cover(jpeg: &[u8]) -> Vec<u8> {
    fn frame(id: &[u8; 4], payload: Vec<u8>) -> Vec<u8> {
        let mut frame = id.to_vec();
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(&[0, 0]);
        frame.extend(payload);
        frame
    }
    let mut tag = Vec::new();
    for (id, text) in [
        (b"TIT2", "Embedded song"),
        (b"TPE1", "Embedded artist"),
        (b"TALB", "Embedded album"),
    ] {
        let mut payload = vec![0];
        payload.extend_from_slice(text.as_bytes());
        tag.extend(frame(id, payload));
    }
    let mut picture = vec![0];
    picture.extend_from_slice(b"image/jpeg\0");
    picture.extend_from_slice(&[3, 0]); // Front cover, empty description.
    picture.extend_from_slice(jpeg);
    tag.extend(frame(b"APIC", picture));
    let length = tag.len() as u32;
    let mut audio = b"ID3\x03\x00\x00".to_vec();
    audio.extend_from_slice(&[
        ((length >> 21) & 127) as u8,
        ((length >> 14) & 127) as u8,
        ((length >> 7) & 127) as u8,
        (length & 127) as u8,
    ]);
    audio.extend(tag);
    // Four MPEG1 Layer III frames are enough for tag/stream-info inspection.
    // This fixture tests byte transfer and metadata, not audio decoding.
    for _ in 0..4 {
        let mut frame = vec![0; 417];
        frame[..4].copy_from_slice(&[0xff, 0xfb, 0x90, 0x00]);
        audio.extend(frame);
    }
    audio
}

#[test]
fn fresh_download_restores_exact_identities_original_covers_order_and_no_cache_duplicates() {
    let receiving = tempdir().unwrap();
    let source = tempdir().unwrap();
    let embedded = original(source.path(), "embedded.jpg", image::ImageFormat::Jpeg);
    let remote_cover = original(source.path(), "remote.png", image::ImageFormat::Png);
    let jpeg = fs::read(&embedded.source_path).unwrap();
    let png = fs::read(&remote_cover.source_path).unwrap();
    let audio_one = mp3_with_embedded_cover(&jpeg);
    fs::write(source.path().join("one.mp3"), &audio_one).unwrap();
    let probe = scan_library_path(source.path()).unwrap();
    assert!(
        probe.tracks[0].artwork.is_some(),
        "fixture must expose actual embedded artwork"
    );
    let first_fingerprint = probe.tracks[0].fingerprint.clone();
    let first_id = format!("track_{first_fingerprint}");
    let second_id = "track_explicit-second";
    let audio_two = b"second audio fixture".to_vec();
    let mut state = FixtureState::default();
    state.tracks = vec![
        json!({"id":first_id,"fingerprint":first_fingerprint,"title":"Remote first metadata","artist":"Server artist","album":"Server album","file_name":"one.mp3","is_liked":true}),
        json!({"id":second_id,"fingerprint":"explicit-second","title":"Remote second metadata","artist":"Server artist","album":"Server album","file_name":"two.mp3","is_liked":false,
            "disc_number":2,"explicit":true,"identifiers":{"spotify_track_id":"source-provider-id","custom_id":"source-custom-id"},
            "source_urls":{"spotify":"https://example.invalid/metadata-only"}}),
    ];
    state.playlists = vec![
        json!({"id":"remote-ordered-mix","name":"Ordered Mix","track_ids":[second_id,first_id],"is_liked":false}),
    ];
    state.media.insert(
        format!("/api/v1/tracks/{first_fingerprint}/audio"),
        (audio_one.clone(), "audio/mpeg".into()),
    );
    state.media.insert(
        "/api/v1/tracks/explicit-second/audio".into(),
        (audio_two.clone(), "audio/mpeg".into()),
    );
    state.media.insert(
        format!("/api/v1/tracks/{first_fingerprint}/artwork"),
        (png.clone(), "image/png".into()),
    );
    state.media.insert(
        "/api/v1/tracks/explicit-second/artwork".into(),
        (jpeg.clone(), "image/jpeg".into()),
    );
    state.media.insert(
        "/api/v1/playlists/remote-ordered-mix/artwork".into(),
        (png.clone(), "image/png".into()),
    );
    let fixture = Fixture::new(state);
    let first = sync_library_from_server_headless(
        path_to_sync_string(receiving.path()),
        fixture.url.clone(),
        "fixture-secret".into(),
    )
    .unwrap();
    assert!(first.failures.is_empty(), "{:?}", first.failures);
    assert_eq!(
        (
            first.tracks_added,
            first.tracks_downloaded,
            first.tracks_matched
        ),
        (2, 2, 0)
    );
    assert_eq!(
        (
            first.track_artwork_downloaded,
            first.playlist_artwork_downloaded,
            first.artwork_already_present
        ),
        (2, 1, 0)
    );
    let library = scan_library_path(receiving.path()).unwrap();
    let fingerprints = library
        .tracks
        .iter()
        .map(|track| track.fingerprint.clone())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        fingerprints,
        BTreeSet::from([first_fingerprint.clone(), "explicit-second".into()])
    );
    assert_eq!(
        library.tracks.len(),
        2,
        "temporary download files must never become library tracks"
    );
    let metadata_track = library.tracks.iter().find(|track| track.fingerprint == "explicit-second").unwrap();
    assert_eq!(metadata_track.disc_number, Some(2));
    assert_eq!(metadata_track.explicit, Some(true));
    assert_eq!(metadata_track.identifiers.get("spotify_track_id").map(String::as_str), Some("source-provider-id"));
    assert_eq!(metadata_track.identifiers.get("custom_id").map(String::as_str), Some("source-custom-id"));
    assert_eq!(metadata_track.source_urls.get("spotify").map(String::as_str), Some("https://example.invalid/metadata-only"));
    for track in &library.tracks {
        assert!(Path::new(&track.path)
            .starts_with(receiving.path().canonicalize().unwrap().join(".loud/audio")));
        let (audio, cover, mime) = if track.fingerprint == first_fingerprint {
            (&audio_one, &png, "image/png")
        } else {
            (&audio_two, &jpeg, "image/jpeg")
        };
        assert_eq!(&fs::read(&track.path).unwrap(), audio);
        let art = track.artwork.as_ref().unwrap();
        assert_eq!(art.original_mime_type.as_deref(), Some(mime));
        assert_eq!(
            &fs::read(&art.source_path).unwrap(),
            cover,
            "fresh audio embedded fallback must not replace server original"
        );
    }
    let mix = library
        .playlists
        .iter()
        .find(|playlist| playlist.id == "remote-ordered-mix")
        .unwrap();
    assert_eq!(mix.track_ids, vec![second_id.to_string(), first_id]);
    assert_eq!(
        fs::read(&mix.artwork.as_ref().unwrap().source_path).unwrap(),
        png
    );
    assert!(
        library
            .tracks
            .iter()
            .find(|track| track.fingerprint == first_fingerprint)
            .unwrap()
            .is_liked
    );
    // Repeat with the download cache still present; no extra tracks or media requests.
    let before = fixture
        .state
        .lock()
        .unwrap()
        .requests
        .iter()
        .filter(|request| request.path.ends_with("/audio") || request.path.ends_with("/artwork"))
        .count();
    let second = sync_library_from_server_headless(
        path_to_sync_string(receiving.path()),
        fixture.url.clone(),
        "fixture-secret".into(),
    )
    .unwrap();
    assert!(second.failures.is_empty());
    assert_eq!(
        (
            second.tracks_added,
            second.tracks_downloaded,
            second.tracks_matched,
            second.artwork_downloaded,
            second.artwork_already_present
        ),
        (0, 0, 2, 0, 3)
    );
    assert_eq!(scan_library_path(receiving.path()).unwrap().tracks.len(), 2);
    let after = fixture
        .state
        .lock()
        .unwrap()
        .requests
        .iter()
        .filter(|request| request.path.ends_with("/audio") || request.path.ends_with("/artwork"))
        .count();
    assert_eq!(before, after);
}

#[test]
fn download_preserves_cover_embedded_in_preexisting_destination_audio() {
    let receiving = tempdir().unwrap();
    let source = tempdir().unwrap();
    let jpeg = original(source.path(), "original.jpg", image::ImageFormat::Jpeg);
    let audio = mp3_with_embedded_cover(&fs::read(jpeg.source_path).unwrap());
    let path = receiving.path().join("preexisting.mp3");
    fs::write(&path, &audio).unwrap();
    let local = scan_library_path(receiving.path()).unwrap();
    let track = &local.tracks[0];
    assert!(track.artwork.is_some());
    let fingerprint = track.fingerprint.clone();
    let mut state = FixtureState::default();
    state.tracks = vec![
        json!({"id":track.id,"fingerprint":fingerprint,"title":track.title,"artist":track.artist,"album":track.album,"file_name":"preexisting.mp3"}),
    ];
    let fixture = Fixture::new(state);
    let report = sync_library_from_server_headless(
        path_to_sync_string(receiving.path()),
        fixture.url.clone(),
        "fixture-secret".into(),
    )
    .unwrap();
    assert!(report.failures.is_empty());
    assert_eq!(
        (
            report.tracks_matched,
            report.tracks_downloaded,
            report.track_artwork_downloaded,
            report.track_artwork_already_present
        ),
        (1, 0, 0, 1)
    );
    assert_eq!(fs::read(path).unwrap(), audio);
    let rescanned = scan_library_path(receiving.path()).unwrap();
    assert_eq!(
        rescanned.tracks[0]
            .artwork
            .as_ref()
            .unwrap()
            .original_mime_type,
        None
    );
    assert!(fixture
        .state
        .lock()
        .unwrap()
        .requests
        .iter()
        .all(|request| !request.path.ends_with("/audio") && !request.path.ends_with("/artwork")));
}
