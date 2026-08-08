// Small shared helpers and SQL row scanners.
package server

import (
	"database/sql"
	"strings"
)

func cleanFingerprint(value string) string {
	return strings.TrimSpace(value)
}

func remoteTrackPath(track Track) string {
	return "loud://track/" + track.Fingerprint + "/" + safeFileName(track.FileName)
}

func safeFileName(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "track"
	}
	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "_", "*", "_", "?", "_", "\"", "_", "<", "_", ">", "_", "|", "_")
	value = replacer.Replace(value)
	value = strings.Trim(value, ". ")
	if value == "" {
		return "track"
	}
	return value
}

func pathEscape(value string) string {
	return strings.ReplaceAll(value, "/", "%2F")
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func dedupeStrings(values []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}

func scanPlaybackDevice(row rowScanner) (PlaybackDevice, error) {
	var device PlaybackDevice
	var trackID sql.NullString
	var trackFingerprint sql.NullString
	var trackTitle sql.NullString
	var isPlaying int
	err := row.Scan(
		&device.DeviceID,
		&device.Name,
		&trackID,
		&trackFingerprint,
		&trackTitle,
		&isPlaying,
		&device.PositionSeconds,
		&device.Volume,
		&device.UpdatedAt,
	)
	if err != nil {
		return PlaybackDevice{}, err
	}
	device.TrackID = stringFromNull(trackID)
	device.TrackFingerprint = stringFromNull(trackFingerprint)
	device.TrackTitle = stringFromNull(trackTitle)
	device.IsPlaying = isPlaying == 1
	return device, nil
}

func stringFromNull(value sql.NullString) *string {
	if !value.Valid || strings.TrimSpace(value.String) == "" {
		return nil
	}
	cleaned := strings.TrimSpace(value.String)
	return &cleaned
}

func cleanStringPointer(value *string) *string {
	if value == nil {
		return nil
	}
	cleaned := strings.TrimSpace(*value)
	if cleaned == "" {
		return nil
	}
	return &cleaned
}

func nullableString(value *string) any {
	value = cleanStringPointer(value)
	if value == nil {
		return nil
	}
	return *value
}

func cleanPlaybackPosition(value float64) float64 {
	if value < 0 {
		return 0
	}
	if value > 24*60*60 {
		return 24 * 60 * 60
	}
	return value
}

func cleanPlaybackVolume(value float64) float64 {
	if value < 0 {
		return 0
	}
	if value > 1 {
		return 1
	}
	return value
}
