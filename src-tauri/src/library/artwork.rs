// Embedded artwork extraction and cached thumbnails.

use super::*;

pub(super) fn cached_artwork_ref(
    root: &Path,
    path: &Path,
    metadata: &fs::Metadata,
    picture: &lofty::picture::Picture,
) -> CachedArtwork {
    let modified = metadata
        .modified()
        .ok()
        .and_then(system_time_to_unix)
        .unwrap_or(0);
    // The size is part of the key so bumping ARTWORK_THUMBNAIL_SIZE
    // regenerates stale small thumbnails instead of reusing them.
    let cache_key = stable_id(&format!(
        "{}|{}|{}|{}|{}",
        relative_path_key(root, path),
        modified,
        metadata.len(),
        picture.data().len(),
        ARTWORK_THUMBNAIL_SIZE
    ));

    CachedArtwork {
        source_path: path.to_path_buf(),
        cache_path: artwork_cache_dir(root).join(format!("{cache_key}.jpg")),
    }
}

pub fn ensure_cached_artwork_thumbnail(artwork: &CachedArtwork) -> Result<PathBuf, String> {
    if artwork.cache_path.exists() {
        return Ok(artwork.cache_path.clone());
    }

    let tagged_file = Probe::open(&artwork.source_path)
        .and_then(|probe| probe.read())
        .map_err(|err| format!("Could not read artwork source: {err}"))?;
    let tag = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
        .ok_or_else(|| "Artwork source has no tags.".to_string())?;
    let picture = tag
        .pictures()
        .iter()
        .find(|picture| picture.pic_type() == PictureType::CoverFront)
        .or_else(|| tag.pictures().first())
        .ok_or_else(|| "Artwork source has no embedded image.".to_string())?;
    let image = image::load_from_memory(picture.data())
        .map_err(|err| format!("Could not decode artwork: {err}"))?;
    // Lanczos for quality; never upscale a source smaller than the target.
    let thumbnail = if image.width() > ARTWORK_THUMBNAIL_SIZE || image.height() > ARTWORK_THUMBNAIL_SIZE {
        image.resize(
            ARTWORK_THUMBNAIL_SIZE,
            ARTWORK_THUMBNAIL_SIZE,
            image::imageops::FilterType::Lanczos3,
        )
    } else {
        image
    };
    let rgb = thumbnail.to_rgb8();
    let mut bytes = Vec::new();
    let mut encoder = JpegEncoder::new_with_quality(&mut bytes, 85);
    encoder
        .encode(&rgb, rgb.width(), rgb.height(), ColorType::Rgb8.into())
        .map_err(|err| format!("Could not encode artwork thumbnail: {err}"))?;

    if let Some(parent) = artwork.cache_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("Could not create artwork cache folder: {err}"))?;
    }

    let unique_write_id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let temp_path = artwork
        .cache_path
        .with_extension(format!("tmp-{}-{unique_write_id}", std::process::id()));
    fs::write(&temp_path, bytes)
        .map_err(|err| format!("Could not write artwork thumbnail: {err}"))?;
    if let Err(err) = fs::rename(&temp_path, &artwork.cache_path) {
        let _ = fs::remove_file(&temp_path);
        if !artwork.cache_path.exists() {
            return Err(format!("Could not write artwork thumbnail: {err}"));
        }
    }
    Ok(artwork.cache_path.clone())
}

