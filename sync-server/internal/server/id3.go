// A small ID3v2 reader for bundle imports: title/artist/album fallbacks and
// the embedded cover (APIC). Stdlib only; anything exotic is simply ignored.
package server

import (
	"encoding/binary"
	"os"
	"strings"
	"unicode/utf16"
)

type id3Tags struct {
	Title   string
	Artist  string
	Album   string
	Artwork []byte
}

func parseID3File(path string) id3Tags {
	file, err := os.Open(path)
	if err != nil {
		return id3Tags{}
	}
	defer file.Close()

	header := make([]byte, 10)
	if _, err := file.Read(header); err != nil || string(header[:3]) != "ID3" {
		return id3Tags{}
	}
	version := header[3]
	size := syncSafe(header[6:10])
	if size <= 0 || size > 64<<20 {
		return id3Tags{}
	}
	body := make([]byte, size)
	read, err := file.Read(body)
	if err != nil && read == 0 {
		return id3Tags{}
	}
	body = body[:read]

	offset := 0
	if header[5]&0x40 != 0 && len(body) >= 4 {
		if version == 4 {
			offset += syncSafe(body[0:4])
		} else {
			offset += int(binary.BigEndian.Uint32(body[0:4])) + 4
		}
	}

	var tags id3Tags
	for offset+10 <= len(body) {
		id := string(body[offset : offset+4])
		if !isFrameID(id) {
			break
		}
		var frameSize int
		if version == 4 {
			frameSize = syncSafe(body[offset+4 : offset+8])
		} else {
			frameSize = int(binary.BigEndian.Uint32(body[offset+4 : offset+8]))
		}
		if frameSize <= 0 || offset+10+frameSize > len(body) {
			break
		}
		frame := body[offset+10 : offset+10+frameSize]
		switch id {
		case "TIT2":
			if tags.Title == "" {
				tags.Title = id3Text(frame)
			}
		case "TPE1":
			if tags.Artist == "" {
				tags.Artist = id3Text(frame)
			}
		case "TALB":
			if tags.Album == "" {
				tags.Album = id3Text(frame)
			}
		case "APIC":
			if tags.Artwork == nil {
				tags.Artwork = id3Picture(frame)
			}
		}
		offset += 10 + frameSize
	}
	return tags
}

func isFrameID(id string) bool {
	for _, c := range id {
		if !((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}

func syncSafe(b []byte) int {
	if len(b) < 4 {
		return 0
	}
	return int(b[0]&0x7f)<<21 | int(b[1]&0x7f)<<14 | int(b[2]&0x7f)<<7 | int(b[3]&0x7f)
}

func id3Text(frame []byte) string {
	if len(frame) < 2 {
		return ""
	}
	text := decodeID3String(frame[0], frame[1:])
	if i := strings.IndexByte(text, 0); i >= 0 {
		text = text[:i]
	}
	return strings.TrimSpace(text)
}

func decodeID3String(encoding byte, b []byte) string {
	switch encoding {
	case 1, 2:
		if len(b) < 2 {
			return ""
		}
		bigEndian := encoding == 2
		if encoding == 1 {
			if b[0] == 0xff && b[1] == 0xfe {
				b = b[2:]
			} else if b[0] == 0xfe && b[1] == 0xff {
				bigEndian = true
				b = b[2:]
			}
		}
		units := make([]uint16, 0, len(b)/2)
		for i := 0; i+1 < len(b); i += 2 {
			if bigEndian {
				units = append(units, uint16(b[i])<<8|uint16(b[i+1]))
			} else {
				units = append(units, uint16(b[i+1])<<8|uint16(b[i]))
			}
		}
		return string(utf16.Decode(units))
	case 3:
		return string(b)
	default:
		runes := make([]rune, len(b))
		for i, c := range b {
			runes[i] = rune(c)
		}
		return string(runes)
	}
}

func id3Picture(frame []byte) []byte {
	if len(frame) < 4 {
		return nil
	}
	encoding := frame[0]
	offset := 1
	for offset < len(frame) && frame[offset] != 0 { // mime type
		offset++
	}
	offset += 2 // terminator + picture type
	if offset >= len(frame) {
		return nil
	}
	if encoding == 1 || encoding == 2 {
		for offset+1 < len(frame) && !(frame[offset] == 0 && frame[offset+1] == 0) {
			offset += 2
		}
		offset += 2
	} else {
		for offset < len(frame) && frame[offset] != 0 {
			offset++
		}
		offset++
	}
	if offset >= len(frame) {
		return nil
	}
	out := make([]byte, len(frame)-offset)
	copy(out, frame[offset:])
	return out
}
