# Native playlist editing

The playlist detail list reused `PlayableTrackRow`, whose custom trailing swipe
replaced the list's implicit delete gesture. Its old “Remove” button removed a
local download, leaving playlist membership untouched. The app also lacked a
playlist-delete API method and UI action.

Playlist rows now expose **Remove from Playlist**, both as a trailing swipe and
in the context menu. Edit-mode removal sends the selected track identities as a
batch. Other track lists explicitly call the separate download action **Remove
Download**. Library playlists offer **Delete Playlist** on swipe/long press; the
playlist detail's options menu offers the same action. Confirmation explains
that songs stay in the library. Aux guests cannot access playlist mutations.

The model resolves current membership by playlist ID, applies edits immediately,
and serializes their existing partial-update API requests. It uses one conditional
library refresh after a burst of edits. A response started before an edit cannot
replace the optimistic state. Rejected operations restore only the affected
playlist and replay later pending intentions; they never restore a whole stale
library. Changing server, joining/leaving Aux, or disconnecting cancels that
queue. Playback and download ownership are unchanged.

Deleting a collection uses `DELETE /api/v1/playlists/{id}`. Removing membership
uses `DELETE /api/v1/playlists/{id}/tracks/{fingerprint}`. Neither endpoint deletes
a song or its audio file. No server changes or restarts are needed for this fix.

## Verification

`PlaylistEditingTests` is part of the checked-in `CodecNativeTests` target. It
exercises real AppModel/CodecClient behavior against an isolated transport with
controlled delayed replies and failed mutations. Coverage includes ordered rapid
edits, rollback, stale refreshes, disconnect, guest restrictions, and preservation
of songs, likes, other memberships, and downloaded bytes.

Run app-hosted tests on a dedicated simulator. Some existing suites modify the
host app's connection preferences and cached library; the XCTest launch guard
prevents a production connection but does not isolate that local storage.

```sh
cd ios/CodecMobile
swift test
xcodebuild -project Codec.xcodeproj -scheme Codec \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/codec-playlist-native-review \
  -only-testing:CodecNativeTests/PlaylistEditingTests \
  CODE_SIGNING_ALLOWED=NO test
```

Physical-device installation is separate from these build and simulator checks.
