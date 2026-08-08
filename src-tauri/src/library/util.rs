// Small shared helpers: text cleanup, ids, fingerprints, paths.

use super::*;

pub(super) fn relative_path_key(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .map(path_to_string)
        .unwrap_or_else(|_| path_to_string(path))
}


pub(super) fn safe_path_component(value: &str) -> String {
    let sanitized = value
        .chars()
        .map(|character| match character {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            character if character.is_control() => '_',
            character => character,
        })
        .collect::<String>()
        .trim()
        .trim_matches('.')
        .to_string();

    if sanitized.is_empty() {
        "Unknown".to_string()
    } else {
        sanitized
    }
}


pub(super) fn clean_text(value: Option<std::borrow::Cow<'_, str>>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

pub(super) fn clean_plain_text(value: Option<&str>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

pub(super) fn fingerprint_for(title: &str, artist: &str, album: &str) -> String {
    stable_id(&format!(
        "{}|{}|{}",
        normalize(title),
        normalize(artist),
        normalize(album)
    ))
}

pub(super) fn normalize(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

pub(super) fn canonical_dir(path: &Path) -> Result<PathBuf, String> {
    let path = path
        .canonicalize()
        .map_err(|err| format!("Could not resolve folder: {err}"))?;
    if !path.is_dir() {
        return Err("Music folder must be a directory.".to_string());
    }
    Ok(path)
}

pub(super) fn canonical_file(path: &Path) -> Result<PathBuf, String> {
    let path = path
        .canonicalize()
        .map_err(|err| format!("Could not resolve file: {err}"))?;
    if !path.is_file() {
        return Err("Track path must be a file.".to_string());
    }
    Ok(path)
}

pub(super) fn is_mp3(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.eq_ignore_ascii_case("mp3"))
        .unwrap_or(false)
}

pub(super) fn unique_destination(destination: PathBuf) -> PathBuf {
    if !destination.exists() {
        return destination;
    }

    let parent = destination
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(PathBuf::new);
    let stem = destination
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("track");
    let extension = destination
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("mp3");

    for index in 2.. {
        let candidate = parent.join(format!("{stem} ({index}).{extension}"));
        if !candidate.exists() {
            return candidate;
        }
    }

    unreachable!("unique destination loop is unbounded")
}

pub(super) fn track_id_for_fingerprint(fingerprint: &str) -> String {
    format!("track_{fingerprint}")
}

pub(super) fn playlist_id_for_path(path: &Path) -> String {
    format!("playlist_{}", stable_id(&path_to_string(path)))
}

pub(super) fn stable_id(value: &str) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

pub(super) fn file_stem_or_name(path: &Path) -> String {
    path.file_stem()
        .or_else(|| path.file_name())
        .and_then(|name| name.to_str())
        .unwrap_or("Untitled")
        .to_string()
}

pub(super) fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

pub(super) fn unix_now() -> u64 {
    system_time_to_unix(SystemTime::now()).unwrap_or(0)
}

pub(super) fn system_time_to_unix(time: SystemTime) -> Option<u64> {
    time.duration_since(UNIX_EPOCH)
        .ok()
        .map(|time| time.as_secs())
}

