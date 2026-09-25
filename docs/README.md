# Codec documentation

Start here to move a music collection with Loud or run your own Codec server.
Code, API, UI, and test references follow the user guides.

We’re not accepting contributions or pull requests right now. The source is
available to read and use under the [MIT license](../LICENSE).

## Loud format and hosting

| Task | Guide |
| --- | --- |
| Understand and use the Loud format | [Format, bundle layout, import options, and examples](codec-import-v1.md) |
| Import audio, likes, playlists, and original covers | [Detailed S2Y artwork and merge workflow](s2y-artwork-import.md) |
| Run your own server | [Hosting and deployment overview](../DEPLOY.md) |
| Install, update, or get your server token on Linux | [Server release guide](server-release.md) |
| Understand what each device needs | [How the apps and server fit together](app-architecture.md) |
| Connect or build the native phone app | [iPhone setup](iphone.md) |
| Validate exporter output | [Main schema](codec-import.schema.json) · [Track artwork](s2y-track-artwork.schema.json) · [Playlist artwork](s2y-playlist-artwork.schema.json) |

The Go server owns the shared library and serves the web interface. The web
player and native iPhone/iPad app connect to the same API; each keeps its own
cache and downloads. An installed native app has a separate build from the
published website. The optional import CLI prepares and transfers music collections.

## Code, API, UI, and test reference

| Read or check | Reference |
| --- | --- |
| Run persistent local servers and test Aux across clients | [Local development environment](local-development.md) |
| Install a separate test app without replacing the listening app | [Codec Test on a phone or simulator](local-test-app.md) |
| Keep already-installed clients working after server updates | [Client compatibility gates](client-compatibility.md) |
| Prepare and coordinate GitHub, server, and site publication | [Release checklist and rollback](release-checklist.md) |
| Source organization and app boundaries | [Architecture](app-architecture.md) · [Modding and source entry points](modding.md) |
| Current operating-system support and gaps | [Platform support and portability work](platform-support.md) |
| Shared server contracts and credentials | [Sync API](codec-sync.md) · [Artwork API](artwork-api.md) · [Security model](secure-sync.md) |
| Aux modes, guest permissions and cross-server saves | [Using Aux](aux.md) · [Session protocol](aux-v2-protocol.md) · [Transfer protocol](aux-transfer-protocol.md) · [Historical review](aux-security-review.md) |
| UI tokens and cross-platform behavior | [UI system](ui-system.md) · [Web/mobile parity](mobile-parity.md) |
| Web, Go, and schema feedback | [Parallel checks and verified build reuse](fast-checks.md) |
| Native models, controllers, and rendering | [Native test commands and scopes](../ios/CodecMobile/Tests/README.md) |
| Browser interaction and rendering | [Browser regression instructions](../scripts/mobile-regression.md) |

### Performance and release reference

- [Native performance](native-performance.md) and [web performance](web-performance.md)
  map current behavior to repeatable checks.
- [Data efficiency](data-efficiency.md) and [measurement plan](performance-plan.md)
  cover request budgets and remaining device-level verification.
- [Ubuntu deployment](ubuntu-deployment.md) and [deployment validation](deployment-validation.md)
  cover installation, rollback and isolated systemd/proxy checks.
- [App Store reference](app-store-submission.md) and [listing copy](app-store-listing.md)
  distinguish submitted build 1.4 (7) from the current native release candidate
  and track the remaining App Review evidence.

### Behavior references

- [Current playlist on Home](current-playlist.md): explicit playback origin,
  pause, queue, handoff, and compatibility.
- [Artwork visualizer](artwork-visualizer.md): artwork colors and retained history.
- [Native playback continuity](native-playback-continuity.md),
  [offline playback](native-offline-playback.md), and
  [playlist editing](native-playlist-editing.md).
- [Web playback continuity](web-playback-continuity.md),
  [mobile continuity and cache](mobile-continuity-and-cache.md),
  [Safari and Home Screen viewport](mobile-web-viewport.md),
  [player gestures](mobile-web-player-gestures.md), and
  [service-worker recovery](service-worker-recovery.md).
