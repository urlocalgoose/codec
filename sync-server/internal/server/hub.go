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
		if _, ok := h.subscribers[id]; ok {
			delete(h.subscribers, id)
			close(ch)
		}
	}
}

func (h *playbackEventHub) broadcast(event PlaybackEvent) {
	h.mu.Lock()
	defer h.mu.Unlock()

	for id, ch := range h.subscribers {
		select {
		case ch <- event:
		default:
			// Reconnect for a fresh snapshot instead of silently losing state.
			close(ch)
			delete(h.subscribers, id)
		}
	}
}
