// In-process pub/sub for playback SSE streams.
package server

import "sync"

type playbackEventHub struct {
	mu          sync.Mutex
	nextID      int
	subscribers map[int]chan PlaybackEvent
}

func newPlaybackEventHub() *playbackEventHub {
	return &playbackEventHub{subscribers: map[int]chan PlaybackEvent{}}
}

func (h *playbackEventHub) subscribe() (<-chan PlaybackEvent, func()) {
	h.mu.Lock()
	defer h.mu.Unlock()

	id := h.nextID
	h.nextID++
	ch := make(chan PlaybackEvent, 32)
	h.subscribers[id] = ch

	return ch, func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		delete(h.subscribers, id)
		close(ch)
	}
}

func (h *playbackEventHub) broadcast(event PlaybackEvent) {
	h.mu.Lock()
	defer h.mu.Unlock()

	for _, ch := range h.subscribers {
		select {
		case ch <- event:
		default:
		}
	}
}
