#[allow(dead_code)]
#[path = "../library.rs"]
mod library;

fn main() -> Result<(), String> {
    let root = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "/path/to/Documents/Music".to_string());
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
