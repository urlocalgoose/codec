//! Import-side artwork validation and persistent original-image storage.
use super::*;
use image::{ImageFormat, ImageReader};
use sha2::{Digest, Sha256};
use std::io::{Cursor, Read, Write};
use std::path::Component;

pub(super) const MAX_ARTWORK_BYTES: u64 = 12 * 1024 * 1024;
const MAX_ARTWORK_PIXELS: u64 = 16 * 1024 * 1024;
const MAX_ARTWORK_EDGE: u32 = 8_192;

struct ArtworkCandidate {
    target: String,
    artwork: ImportArtwork,
    base: PathBuf,
}

fn failure(report: &mut ImportReport, file: &str, reason: String, missing: bool) {
    if missing {
        report.artwork_missing += 1;
    } else {
        report.artwork_failed += 1;
    }
    report.artwork_failures.push(ImportFailure {
        file: file.to_string(),
        reason,
    });
}

fn relative_artwork_path(path: &Path) -> bool {
    !path.as_os_str().is_empty()
        && !path.is_absolute()
        && path
            .components()
            .all(|part| matches!(part, Component::Normal(_) | Component::CurDir))
}

fn artwork_base(manifest_dir: &Path, base_path: Option<&str>) -> Result<PathBuf, String> {
    let base = Path::new(
        base_path
            .filter(|path| !path.trim().is_empty())
            .unwrap_or("."),
    );
    if !relative_artwork_path(base) {
        return Err(
            "Artwork base_path must stay within the manifest folder without parent traversal."
                .to_string(),
        );
    }
    let canonical = canonical_dir(&manifest_dir.join(base))?;
    if !canonical.starts_with(manifest_dir) {
        return Err("Artwork base folder symlink escapes the manifest folder.".to_string());
    }
    Ok(canonical)
}

pub(super) fn read_bounded(path: &Path, maximum: u64) -> Result<Vec<u8>, String> {
    let file = fs::File::open(path)
        .map_err(|err| format!("Could not read artwork '{}': {err}", path.display()))?;
    let metadata = file
        .metadata()
        .map_err(|err| format!("Could not inspect artwork: {err}"))?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > maximum {
        return Err(format!(
            "Artwork must be a nonempty regular file no larger than {maximum} bytes."
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(|err| format!("Could not read artwork: {err}"))?;
    if bytes.is_empty() || bytes.len() as u64 > maximum {
        return Err("Artwork byte limit exceeded.".to_string());
    }
    Ok(bytes)
}

pub(super) fn decode_artwork_bytes(
    bytes: &[u8],
) -> Result<(image::DynamicImage, &'static str, &'static str), String> {
    if bytes.is_empty() || bytes.len() as u64 > MAX_ARTWORK_BYTES {
        return Err("Artwork byte limit exceeded.".to_string());
    }
    let format =
        image::guess_format(bytes).map_err(|err| format!("Could not identify artwork: {err}"))?;
    let (mime, extension) = match format {
        ImageFormat::Jpeg => ("image/jpeg", "jpg"),
        ImageFormat::Png => ("image/png", "png"),
        ImageFormat::WebP => ("image/webp", "webp"),
        ImageFormat::Gif => ("image/gif", "gif"),
        _ => return Err("Only JPEG, PNG, WebP and GIF artwork is supported.".to_string()),
    };
    let dimensions = ImageReader::with_format(Cursor::new(bytes), format)
        .into_dimensions()
        .map_err(|err| format!("Could not read artwork dimensions: {err}"))?;
    validate_dimensions(dimensions.0, dimensions.1)?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_ARTWORK_EDGE);
    limits.max_image_height = Some(MAX_ARTWORK_EDGE);
    limits.max_alloc = Some(256 * 1024 * 1024);
    let mut reader = ImageReader::with_format(Cursor::new(bytes), format);
    reader.limits(limits);
    let decoded = reader
        .decode()
        .map_err(|err| format!("Could not decode artwork: {err}"))?;
    Ok((decoded, mime, extension))
}

fn validate_dimensions(width: u32, height: u32) -> Result<(), String> {
    if width == 0
        || height == 0
        || width > MAX_ARTWORK_EDGE
        || height > MAX_ARTWORK_EDGE
        || u64::from(width) * u64::from(height) > MAX_ARTWORK_PIXELS
    {
        return Err("Artwork dimensions exceed the 8192-edge / 16777216-pixel limit.".to_string());
    }
    Ok(())
}

fn validate_artwork(
    base: &Path,
    artwork: &ImportArtwork,
) -> Result<(Vec<u8>, &'static str), String> {
    let path = Path::new(&artwork.file);
    if !relative_artwork_path(path) {
        return Err(
            "Artwork file must be relative to its base folder, without parent traversal."
                .to_string(),
        );
    }
    let path = canonical_file(&base.join(path))?;
    if !path.starts_with(base) {
        return Err("Artwork symlink escapes its base folder.".to_string());
    }
    if artwork.sha256.len() != 64 || !artwork.sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("Artwork requires a 64-character SHA-256 digest.".to_string());
    }
    if !matches!(artwork.mime_type.as_str(), "image/jpeg" | "image/png") {
        return Err("Imported original artwork must be JPEG or PNG; other formats are not supported by the sync server.".to_string());
    }
    validate_dimensions(artwork.width, artwork.height)?;
    let bytes = read_bounded(&path, MAX_ARTWORK_BYTES)?;
    let digest = format!("{:x}", Sha256::digest(&bytes));
    if !digest.eq_ignore_ascii_case(&artwork.sha256) {
        return Err("Artwork SHA-256 does not match its source bytes.".to_string());
    }
    let (decoded, mime, extension) = decode_artwork_bytes(&bytes)?;
    if artwork.mime_type != mime {
        return Err(format!("Artwork MIME mismatch: decoded {mime}."));
    }
    if (decoded.width(), decoded.height()) != (artwork.width, artwork.height) {
        return Err("Artwork dimensions do not match the decoded image.".to_string());
    }
    Ok((bytes, extension))
}

fn persist_artwork(
    root: &Path,
    artwork: &ImportArtwork,
    bytes: &[u8],
    extension: &str,
) -> Result<StoredArtwork, String> {
    let parent = root
        .join(STATE_DIR_NAME)
        .join(ARTWORK_DIR_NAME)
        .join("originals");
    fs::create_dir_all(&parent)
        .map_err(|err| format!("Could not create artwork originals folder: {err}"))?;
    let parent = canonical_dir(&parent)?;
    if !parent.starts_with(root) {
        return Err("Artwork storage escapes the library root.".to_string());
    }
    let path = parent.join(format!(
        "{}.{}",
        artwork.sha256.to_ascii_lowercase(),
        extension
    ));
    if fs::symlink_metadata(&path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err("Artwork destination cannot be a symbolic link.".to_string());
    }
    let already_identical = read_bounded(&path, MAX_ARTWORK_BYTES)
        .map(|existing| existing == bytes)
        .unwrap_or(false);
    if !already_identical {
        let temporary = parent.join(format!(
            ".{}-{}-{}.tmp",
            artwork.sha256,
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let result = (|| {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .map_err(|err| format!("Could not create artwork original: {err}"))?;
            file.write_all(bytes)
                .map_err(|err| format!("Could not write artwork original: {err}"))?;
            file.sync_all()
                .map_err(|err| format!("Could not flush artwork original: {err}"))?;
            fs::rename(&temporary, &path)
                .map_err(|err| format!("Could not store artwork original: {err}"))
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result?;
    }
    let mut stored = artwork.clone();
    stored.file = relative_path_key(root, &path);
    stored.sha256 = stored.sha256.to_ascii_lowercase();
    Ok(stored)
}

pub(super) fn stored_artwork_ref(root: &Path, artwork: &StoredArtwork) -> Option<CachedArtwork> {
    let relative = Path::new(&artwork.file);
    if !relative_artwork_path(relative)
        || artwork.sha256.len() != 64
        || !artwork.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return None;
    }
    let source = canonical_file(&root.join(relative)).ok()?;
    if !source.starts_with(root.join(STATE_DIR_NAME).join(ARTWORK_DIR_NAME)) {
        return None;
    }
    Some(CachedArtwork {
        original_mime_type: Some(artwork.mime_type.clone()),
        source_path: source,
        cache_path: artwork_cache_dir(root).join(format!(
            "original-{}-{ARTWORK_THUMBNAIL_SIZE}.jpg",
            artwork.sha256
        )),
    })
}

fn read_artwork_sidecar(
    manifest_dir: &Path,
    filename: &str,
    schema: &str,
    field: &str,
) -> Result<(PathBuf, Vec<serde_json::Value>), String> {
    let path = canonical_file(&manifest_dir.join(filename))?;
    if !path.starts_with(manifest_dir) {
        return Err("Artwork sidecar symlink escapes the manifest folder.".to_string());
    }
    let bytes = read_bounded(&path, 16 * 1024 * 1024)?;
    let value: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|err| format!("Invalid artwork sidecar JSON: {err}"))?;
    if value.get("schema").and_then(|value| value.as_str()) != Some(schema) {
        return Err(format!(
            "Unsupported artwork sidecar schema; expected {schema}."
        ));
    }
    let base_path = match value.get("base_path") {
        None => None,
        Some(serde_json::Value::String(path)) => Some(path.as_str()),
        Some(_) => {
            return Err("Artwork sidecar base_path must be a string when supplied.".to_string())
        }
    };
    let base = artwork_base(manifest_dir, base_path)?;
    let rows = value
        .get(field)
        .and_then(|value| value.as_array())
        .ok_or_else(|| format!("Artwork sidecar needs a {field} array."))?;
    Ok((base, rows.clone()))
}

// Malformed sidecars remain ordinary per-artwork diagnostics. Valid sidecars
// participate in identity preflight even when inline artwork would take priority.
pub(super) fn sidecar_playlist_names(manifest_dir: &Path) -> Vec<String> {
    read_artwork_sidecar(
        manifest_dir,
        "playlist-artwork.json",
        "s2y.playlist-artwork.v1",
        "playlists",
    )
    .map(|(_, rows)| {
        rows.into_iter()
            .filter_map(|row| {
                // Bad optional artwork is reported separately after audio import;
                // it must not turn an unusable sidecar row into a fatal name alias.
                serde_json::from_value::<ImportArtwork>(row.get("artwork")?.clone()).ok()?;
                row.get("name")
                    .and_then(|name| name.as_str())
                    .map(str::to_string)
            })
            .collect()
    })
    .unwrap_or_default()
}

fn sidecar_candidates(
    manifest_dir: &Path,
    filename: &str,
    schema: &str,
    field: &str,
    mut ignored: BTreeSet<String>,
    report: &mut ImportReport,
) -> Vec<ArtworkCandidate> {
    let path = manifest_dir.join(filename);
    if !path.exists() {
        return Vec::new();
    }
    let load = read_artwork_sidecar(manifest_dir, filename, schema, field);
    let (base, rows) = match load {
        Ok(value) => value,
        Err(reason) => {
            failure(report, filename, reason, false);
            return Vec::new();
        }
    };
    let mut candidates = Vec::new();
    for row in rows {
        let identity = if field == "playlists" {
            "name"
        } else {
            "fingerprint"
        };
        let target = row
            .get(identity)
            .and_then(|value| value.as_str())
            .filter(|value| !value.trim().is_empty());
        if let Some(target) = target {
            let key = if field == "playlists" {
                normalize(target)
            } else {
                target.to_string()
            };
            if !ignored.insert(key) {
                continue;
            }
        }
        let artwork = row
            .get("artwork")
            .cloned()
            .ok_or_else(|| "Artwork descriptor is missing.".to_string())
            .and_then(|value| {
                serde_json::from_value::<ImportArtwork>(value)
                    .map_err(|err| format!("Invalid artwork descriptor: {err}"))
            });
        match (target, artwork) {
            (Some(target), Ok(artwork)) => candidates.push(ArtworkCandidate {
                target: target.to_string(),
                artwork,
                base: base.clone(),
            }),
            (_, Err(reason)) => failure(report, filename, reason, false),
            (None, _) => failure(
                report,
                filename,
                format!("Artwork entry is missing {identity}."),
                false,
            ),
        }
    }
    candidates
}

pub(super) fn import_manifest_artwork(
    root: &Path,
    manifest_dir: &Path,
    base_path: Option<&str>,
    playlists: &[ImportPlaylist],
    tracks: &BTreeMap<String, ImportTrack>,
    fingerprints_by_file: &BTreeMap<String, String>,
    known_fingerprints: &BTreeSet<String>,
    existing: &Library,
    state: &mut LibraryState,
    report: &mut ImportReport,
) {
    let base = artwork_base(manifest_dir, base_path);
    let mut playlist_candidates = Vec::new();
    let mut track_candidates = Vec::new();
    for playlist in playlists {
        if let Some(artwork) = &playlist.artwork {
            match &base {
                Ok(base) => playlist_candidates.push(ArtworkCandidate {
                    target: playlist.name.clone(),
                    artwork: artwork.clone(),
                    base: base.clone(),
                }),
                Err(reason) => failure(report, &artwork.file, reason.clone(), false),
            }
        }
    }
    for track in tracks.values() {
        if let Some(artwork) = &track.artwork {
            let target = fingerprints_by_file
                .get(&track.file)
                .cloned()
                .or_else(|| track.fingerprint.clone());
            match (&base, target) {
                (Ok(base), Some(target)) => track_candidates.push(ArtworkCandidate {
                    target,
                    artwork: artwork.clone(),
                    base: base.clone(),
                }),
                (Err(reason), _) => failure(report, &artwork.file, reason.clone(), false),
                (_, None) => failure(
                    report,
                    &artwork.file,
                    "Artwork track could not be resolved.".to_string(),
                    true,
                ),
            }
        }
    }
    let inline_playlists = playlists
        .iter()
        .filter(|playlist| playlist.artwork.is_some())
        .map(|playlist| normalize(&playlist.name))
        .collect();
    let inline_tracks = tracks
        .values()
        .filter(|track| track.artwork.is_some())
        .filter_map(|track| {
            fingerprints_by_file
                .get(&track.file)
                .cloned()
                .or_else(|| track.fingerprint.clone())
        })
        .collect();
    playlist_candidates.extend(sidecar_candidates(
        manifest_dir,
        "playlist-artwork.json",
        "s2y.playlist-artwork.v1",
        "playlists",
        inline_playlists,
        report,
    ));
    track_candidates.extend(sidecar_candidates(
        manifest_dir,
        "track-artwork.json",
        "s2y.track-artwork.v1",
        "tracks",
        inline_tracks,
        report,
    ));
    let mut seen_playlists = BTreeSet::new();
    for candidate in playlist_candidates {
        if !seen_playlists.insert(normalize(&candidate.target)) {
            continue;
        }
        let artwork = &candidate.artwork;
        let (bytes, extension) = match validate_artwork(&candidate.base, artwork) {
            Ok(result) => result,
            Err(reason) => {
                failure(
                    report,
                    &artwork.file,
                    reason,
                    relative_artwork_path(Path::new(&artwork.file))
                        && !candidate.base.join(&artwork.file).exists(),
                );
                continue;
            }
        };
        if !state
            .playlists
            .iter()
            .any(|playlist| normalize(&playlist.name) == normalize(&candidate.target))
        {
            if let Some(playlist) = existing.playlists.iter().find(|playlist| {
                !playlist.is_liked && normalize(&playlist.name) == normalize(&candidate.target)
            }) {
                state_playlist_mut_by_id(state, &playlist.id, &playlist.name);
            }
        }
        let target = state
            .playlists
            .iter()
            .position(|playlist| normalize(&playlist.name) == normalize(&candidate.target));
        let Some(index) = target else {
            failure(
                report,
                &artwork.file,
                format!("Artwork playlist '{}' was not found.", candidate.target),
                true,
            );
            continue;
        };
        if state.playlists[index]
            .artwork
            .as_ref()
            .and_then(|art| stored_artwork_ref(root, art))
            .is_some()
        {
            report.artwork_already_present += 1;
            continue;
        }
        match persist_artwork(root, artwork, &bytes, extension) {
            Ok(stored) => {
                state.playlists[index].artwork = Some(stored);
                report.playlist_artwork_imported += 1;
            }
            Err(reason) => failure(report, &artwork.file, reason, false),
        }
    }
    let mut seen_tracks = BTreeSet::new();
    for candidate in track_candidates {
        if !seen_tracks.insert(candidate.target.clone()) {
            continue;
        }
        let artwork = &candidate.artwork;
        let (bytes, extension) = match validate_artwork(&candidate.base, artwork) {
            Ok(result) => result,
            Err(reason) => {
                failure(
                    report,
                    &artwork.file,
                    reason,
                    relative_artwork_path(Path::new(&artwork.file))
                        && !candidate.base.join(&artwork.file).exists(),
                );
                continue;
            }
        };
        if !known_fingerprints.contains(&candidate.target) {
            failure(
                report,
                &artwork.file,
                format!(
                    "Artwork fingerprint '{}' was not found exactly.",
                    candidate.target
                ),
                true,
            );
            continue;
        }
        let already_present = state
            .track_artwork
            .get(&candidate.target)
            .and_then(|art| stored_artwork_ref(root, art))
            .is_some()
            || existing
                .tracks
                .iter()
                .any(|track| track.fingerprint == candidate.target && track.artwork.is_some());
        if already_present {
            report.artwork_already_present += 1;
            continue;
        }
        match persist_artwork(root, artwork, &bytes, extension) {
            Ok(stored) => {
                state.track_artwork.insert(candidate.target, stored);
                report.track_artwork_imported += 1;
            }
            Err(reason) => failure(report, &artwork.file, reason, false),
        }
    }
}
