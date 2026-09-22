# Mobile web gestures

The native iPhone app is the interaction reference. Its views live in
`ios/CodecMobile/App/Views/`; `ios/CodecMobile/Sources/` contains shared client
code rather than the screens. Web gesture changes do not modify the native app.

## Song rows

`PlayableTrackRow` in `Components.swift` supplies the same actions in Search,
Songs, Liked Songs, downloaded collections, and playlist detail.

Directions below describe the English, left-to-right interface:

| Gesture | Native behavior and web parity contract |
| --- | --- |
| Tap a song | Play it from the displayed collection; tapping the current song toggles playback. |
| Swipe right | Reveal **Play Next** and **Play Last**. A full swipe performs Play Next. |
| Swipe left in a normal collection | Reveal **Like/Unlike** and **Download/Remove Download**. A full swipe performs Like/Unlike. |
| Swipe left in an editable playlist | Reveal **Remove from Playlist**. A full swipe removes that membership, preserving the song. |
| Long press | Open Like/Unlike, Play Next, Play Last, Add to Playlist, download actions, and Remove from Playlist when applicable. |

Aux guests retain the queue actions. Song-row swipe and context menus hide
likes, playlist membership, and downloads for guests. The action menu and
swipe buttons must use the same permission and current-state checks.

Native sets `allowsFullSwipe: true` for song rows. SwiftUI performs the first
action for that edge on a full swipe; the second action still needs a tap.
See [Apple's swipe actions documentation](https://developer.apple.com/documentation/swiftui/view/swipeactions(edge:allowsfullswipe:content:)).

Web rows use `MobileSwipeRow.svelte` and the pure gesture model in
`row-swipe.ts`. A gesture locks to its initial direction, follows the finger,
and suppresses the click generated after a swipe or long press. Vertical
scrolling stays with the list. Cancellation must not execute an action, and a
recycled virtual row must not inherit another song's open actions. Buttons
and the action menu keep the same operations available without a gesture.

## Playlists

Native Library playlist rows expose **Delete Playlist** on a leftward swipe
and in their long-press menu. `allowsFullSwipe: false` is deliberate: neither
a short nor a full swipe deletes a playlist. Selecting Delete opens a
confirmation explaining that its songs stay in the library.

Web Library uses the same confirmation through `MobileDeletePlaylist.svelte`.
It disables repeated submission while waiting, leaves the row present until
the operation succeeds, and keeps failures visible. Permission, playlist ID,
and existence are checked again before the callback. Liked Songs cannot be
deleted. The client sends only `DELETE /api/v1/playlists/{id}`; it does not send
track or audio deletion requests.

Both playlist detail views offer Edit, Change Artwork, Delete Playlist,
and Add Songs. Web exposes artwork and deletion through Playlist options,
with the same deletion confirmation as Library. Editing exposes removal and reorder controls. These operations
have different scopes: removing a song changes membership, deleting a playlist
removes the container, and changing its artwork leaves its songs unchanged.

## Now Playing and Queue

Both interfaces expose playback, previous/next, shuffle, repeat, seeking,
device selection, download/remove-download, playlist membership, and Queue.
Queue separates the fixed current song, manually queued songs, and upcoming
source songs. Clear empties only the manual queue. Reorder/remove callbacks
must retain that distinction.

Native Queue uses the default trailing swipe action, including full-swipe
Remove. Web queue rows provide the same behavior without allowing their swipe
or drag to dismiss the surrounding sheet. Edit also offers removal, a drag
handle, and web tap/keyboard move controls.

Web drag capture belongs to the persistent list rather than a virtual row.
Holding a dragged item at an edge continues scrolling even without further
pointer movement. A queue change, pointer cancellation, window blur, leaving
Edit, or closing Queue cancels the drag and its animation frame. A later
pointer release must not commit the cancelled reorder.

## Platform and remaining presentation differences

- Native embeds `MPVolumeView`. Web volume remains under the phone/browser's
  system controls; the web player intentionally has no duplicate volume row.
- Native uses `AVRoutePickerView`. Web offers AirPlay when the media element
  exposes `webkitShowPlaybackTargetPicker`.
- SwiftUI provides system context menus, sheet motion, and sensory feedback.
  Web provides corresponding menus and gestures using DOM controls and CSS;
  it does not promise identical system haptics.
- Native playlist membership toggles save immediately and show song counts.
  The existing web membership sheet stages selections until dismissal. This
  remains a separate parity task from song-row and playlist-delete gestures.

## Verification

Pure tests cover direction locking, full-swipe intent, cancellation, stable
identities, and drag edge scrolling. Client tests verify that deletion targets
the selected playlist ID, accepts the server's empty success response, and
does not issue track deletion requests.

The mobile browser regression fixture exercises the actual rendered controls,
including scrolling beyond the virtual window, post-gesture click suppression,
and trusted Chromium touch input. Chromium/WebKit automation does not replace
a physical iPhone Safari/PWA check. Keep that distinction in validation reports.
