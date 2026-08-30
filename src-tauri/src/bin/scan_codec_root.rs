#[allow(dead_code)]
#[path = "../library/mod.rs"]
#[allow(dead_code, unused_imports)]
mod library;

fn main() -> Result<(), String> {
    let root = std::env::args()
        .nth(1)
        .ok_or("usage: scan_codec_root <music-folder>")?;
    let library = library::scan_library_path(root)?;
    let liked = library.tracks.iter().filter(|track| track.is_liked).count();
    let playlists = library
        .playlists
        .iter()
        .filter(|playlist| !playlist.is_liked)
        .map(|playlist| format!("{}:{}", playlist.name, playlist.track_ids.len()))
        .collect::<Vec<_>>()
        .join(", ");

    println!("root: {}", library.root_path);
    println!("tracks: {}", library.tracks.len());
    println!("liked: {liked}");
    println!("playlists: {playlists}");
    Ok(())
}
