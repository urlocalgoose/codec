// Library shaping: liked playlist, stats, artist and album summaries.
package server

import (
	"sort"
	"strings"
)

func ensureLikedPlaylist(playlists []Playlist, tracks []Track) []Playlist {
	var likedTracks []string
	for _, track := range tracks {
		if track.IsLiked {
			likedTracks = append(likedTracks, track.ID)
		}
	}

	for index := range playlists {
		if playlists[index].IsLiked {
			playlists[index].Name = likedName
			playlists[index].TrackIDs = dedupeStrings(append(playlists[index].TrackIDs, likedTracks...))
			if playlists[index].TrackIDs == nil {
				playlists[index].TrackIDs = []string{}
			}
			return playlists
		}
	}

	return append([]Playlist{{
		ID:       likedID,
		Name:     likedName,
		Path:     "loud://playlist/" + likedID,
		TrackIDs: nonNilStrings(dedupeStrings(likedTracks)),
		IsLiked:  true,
	}}, playlists...)
}

func attachPlaylistIDs(tracks []Track, playlists []Playlist) {
	idsByTrack := map[string][]string{}
	for _, playlist := range playlists {
		for _, trackID := range playlist.TrackIDs {
			idsByTrack[trackID] = append(idsByTrack[trackID], playlist.ID)
		}
	}
	for index := range tracks {
		ids := idsByTrack[tracks[index].ID]
		if tracks[index].IsLiked {
			ids = append(ids, likedID)
		}
		tracks[index].PlaylistIDs = dedupeStrings(append(tracks[index].PlaylistIDs, ids...))
	}
}

func summarizeStats(tracks []Track, playlists []Playlist) LibraryStats {
	artists := map[string]bool{}
	albums := map[string]bool{}
	duration := 0.0
	liked := 0
	for _, track := range tracks {
		artists[strings.ToLower(track.Artist)] = true
		albumArtist := track.Artist
		if track.AlbumArtist != nil && *track.AlbumArtist != "" {
			albumArtist = *track.AlbumArtist
		}
		albums[strings.ToLower(albumArtist+"|"+track.Album)] = true
		if track.DurationSeconds != nil {
			duration += *track.DurationSeconds
		}
		if track.IsLiked {
			liked++
		}
	}
	playlistCount := 0
	for _, playlist := range playlists {
		if !playlist.IsLiked {
			playlistCount++
		}
	}
	return LibraryStats{
		TrackCount:      len(tracks),
		PlaylistCount:   playlistCount,
		LikedCount:      liked,
		ArtistCount:     len(artists),
		AlbumCount:      len(albums),
		DurationSeconds: duration,
	}
}

func summarizeArtists(tracks []Track) []ArtistSummary {
	type bucket struct {
		tracks []Track
		albums map[string]bool
	}
	buckets := map[string]*bucket{}
	for _, track := range tracks {
		key := strings.ToLower(track.Artist)
		if buckets[key] == nil {
			buckets[key] = &bucket{albums: map[string]bool{}}
		}
		buckets[key].tracks = append(buckets[key].tracks, track)
		buckets[key].albums[strings.ToLower(track.Album)] = true
	}
	summaries := make([]ArtistSummary, 0, len(buckets))
	for _, bucket := range buckets {
		duration := 0.0
		for _, track := range bucket.tracks {
			if track.DurationSeconds != nil {
				duration += *track.DurationSeconds
			}
		}
		summaries = append(summaries, ArtistSummary{
			Name:            bucket.tracks[0].Artist,
			TrackCount:      len(bucket.tracks),
			AlbumCount:      len(bucket.albums),
			DurationSeconds: duration,
		})
	}
	sort.Slice(summaries, func(i, j int) bool {
		if summaries[i].TrackCount != summaries[j].TrackCount {
			return summaries[i].TrackCount > summaries[j].TrackCount
		}
		return strings.ToLower(summaries[i].Name) < strings.ToLower(summaries[j].Name)
	})
	return nonNilArtists(summaries)
}

func summarizeAlbums(tracks []Track) []AlbumSummary {
	type bucket struct {
		tracks []Track
	}
	buckets := map[string]*bucket{}
	for _, track := range tracks {
		albumArtist := track.Artist
		if track.AlbumArtist != nil && *track.AlbumArtist != "" {
			albumArtist = *track.AlbumArtist
		}
		key := strings.ToLower(albumArtist + "|" + track.Album)
		if buckets[key] == nil {
			buckets[key] = &bucket{}
		}
		buckets[key].tracks = append(buckets[key].tracks, track)
	}
	summaries := make([]AlbumSummary, 0, len(buckets))
	for _, bucket := range buckets {
		duration := 0.0
		var artwork *string
		for _, track := range bucket.tracks {
			if track.DurationSeconds != nil {
				duration += *track.DurationSeconds
			}
			if artwork == nil && track.ArtworkURL != nil {
				artwork = track.ArtworkURL
			}
		}
		first := bucket.tracks[0]
		artist := first.Artist
		if first.AlbumArtist != nil && *first.AlbumArtist != "" {
			artist = *first.AlbumArtist
		}
		summaries = append(summaries, AlbumSummary{
			Name:            first.Album,
			Artist:          artist,
			TrackCount:      len(bucket.tracks),
			DurationSeconds: duration,
			ArtworkURL:      artwork,
		})
	}
	sort.Slice(summaries, func(i, j int) bool {
		return strings.ToLower(summaries[i].Name) < strings.ToLower(summaries[j].Name)
	})
	return nonNilAlbums(summaries)
}

func nonNilTracks(values []Track) []Track {
	if values == nil {
		return []Track{}
	}
	for index := range values {
		values[index].PlaylistIDs = nonNilStrings(values[index].PlaylistIDs)
	}
	return values
}

func nonNilPlaylists(values []Playlist) []Playlist {
	if values == nil {
		return []Playlist{}
	}
	for index := range values {
		values[index].TrackIDs = nonNilStrings(values[index].TrackIDs)
	}
	return values
}

func nonNilArtists(values []ArtistSummary) []ArtistSummary {
	if values == nil {
		return []ArtistSummary{}
	}
	return values
}

func nonNilAlbums(values []AlbumSummary) []AlbumSummary {
	if values == nil {
		return []AlbumSummary{}
	}
	return values
}

func nonNilPlaybackDevices(values []PlaybackDevice) []PlaybackDevice {
	if values == nil {
		return []PlaybackDevice{}
	}
	return values
}

func nonNilStrings(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}

type rowScanner interface {
	Scan(dest ...any) error
}
