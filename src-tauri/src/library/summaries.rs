// Library stats plus artist and album summaries.

use super::*;

pub(super) fn summarize_library(tracks: &[Track], playlists: &[Playlist]) -> LibraryStats {
    let artists = tracks
        .iter()
        .map(|track| normalize(&track.artist))
        .collect::<BTreeSet<_>>();
    let albums = tracks
        .iter()
        .map(|track| {
            format!(
                "{}|{}",
                normalize(track.album_artist.as_deref().unwrap_or(&track.artist)),
                normalize(&track.album)
            )
        })
        .collect::<BTreeSet<_>>();

    LibraryStats {
        track_count: tracks.len(),
        playlist_count: playlists
            .iter()
            .filter(|playlist| !playlist.is_liked)
            .count(),
        liked_count: tracks.iter().filter(|track| track.is_liked).count(),
        artist_count: artists.len(),
        album_count: albums.len(),
        duration_seconds: tracks
            .iter()
            .map(|track| track.duration_seconds.unwrap_or(0.0))
            .sum(),
    }
}

pub(super) fn summarize_artists(tracks: &[Track]) -> Vec<ArtistSummary> {
    let mut artists = BTreeMap::<String, Vec<&Track>>::new();
    for track in tracks {
        artists
            .entry(normalize(&track.artist))
            .or_default()
            .push(track);
    }

    let mut summaries = artists
        .into_values()
        .map(|tracks| {
            let albums = tracks
                .iter()
                .map(|track| normalize(&track.album))
                .collect::<BTreeSet<_>>();
            ArtistSummary {
                name: tracks
                    .first()
                    .map(|track| track.artist.clone())
                    .unwrap_or_else(|| "Unknown Artist".to_string()),
                track_count: tracks.len(),
                album_count: albums.len(),
                duration_seconds: tracks
                    .iter()
                    .map(|track| track.duration_seconds.unwrap_or(0.0))
                    .sum(),
            }
        })
        .collect::<Vec<_>>();

    summaries.sort_by(|a, b| {
        b.track_count
            .cmp(&a.track_count)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    summaries
}

pub(super) fn summarize_albums(tracks: &[Track]) -> Vec<AlbumSummary> {
    let mut albums = BTreeMap::<String, Vec<&Track>>::new();
    for track in tracks {
        let album_artist = track.album_artist.as_deref().unwrap_or(&track.artist);
        albums
            .entry(format!(
                "{}|{}",
                normalize(album_artist),
                normalize(&track.album)
            ))
            .or_default()
            .push(track);
    }

    let mut summaries = albums
        .into_values()
        .map(|tracks| AlbumSummary {
            name: tracks
                .first()
                .map(|track| track.album.clone())
                .unwrap_or_else(|| "Unknown Album".to_string()),
            artist: tracks
                .first()
                .map(|track| {
                    track
                        .album_artist
                        .clone()
                        .unwrap_or_else(|| track.artist.clone())
                })
                .unwrap_or_else(|| "Unknown Artist".to_string()),
            track_count: tracks.len(),
            duration_seconds: tracks
                .iter()
                .map(|track| track.duration_seconds.unwrap_or(0.0))
                .sum(),
            artwork_url: None,
            artwork: tracks.iter().find_map(|track| track.artwork.clone()),
        })
        .collect::<Vec<_>>();

    summaries.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    summaries
}

