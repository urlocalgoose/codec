# Codec static site

The project site is published at [codec.codie.sh](https://codec.codie.sh).
This folder contains its source and build tools. Publishing the website is
separate from App Review submission and public app release, which remain on hold.

The page is plain HTML and CSS: no runtime JavaScript, framework,
remote fonts, analytics, or music-server connection. Edit copy in `index.html`.
The exact Graphite app colors are declared at the top of `style.css`.

Preview from the repository root:

```sh
python3 site/build.py
python3 -m http.server 9086 --bind 127.0.0.1 --directory site/dist
```

`build.py` copies an explicit allowlist into `site/dist`. Scripts, this README,
the provenance ledger and raw captures are excluded. Publish only `site/dist`
when deployment is explicitly authorized. GitHub links point to the project’s
source and versioned Linux server releases. Listening clients shown here are
the iPhone/iPad app and web player.

## Screenshot assets

Screenshots are actual native iPhone/iPad captures of the separately verified
`open-license-test-100` collection. No private collection screenshots or audio
are included. Images are scaled and encoded to WebP; their UI is not recreated,
retouched or recolored. The page labels the collection as demonstration content.
`credits.html` contains its source credits; the artists and museum do not endorse
Codec. The mark uses the current native `AppIcon1024.png`, scaled for the web.

To replace the captures, keep these names under `iphone-6.9/`: `01-home.png`,
`02-library.png`, `03-downloaded.png`, `04-now-playing.png`, `05-visualizer.png`,
`06-palettes.png`, and `07-search.png`. Also include `ipad-13/01-home.png`.
Then run the following with the authorized capture folder:

```sh
python3 site/prepare-assets.py --screenshots /path/to/screenshots \
  --credits /path/to/open-license-test-100/CREDITS.md
```

Requires `cwebp`. Output filenames remain stable. `assets/sources.json` records
the relative input names and SHA-256 hashes, not local paths or credentials.
Review the page at wide browser widths, 390 px and 320 px after replacing images. The
horizontal screenshot gallery is intentionally scrollable on narrow screens.

## Cloudflare deployment

`wrangler.jsonc` configures Cloudflare Workers Static Assets as `codec-site`,
with the exact custom domain `codec.codie.sh`. It has no Worker script,
database, secret, API or music-server dependency. The `workers.dev` address
and deployment-preview URLs are disabled. Deployments are manual.

Use an authorized Cloudflare login and select the account that owns the domain.
An account ID can be supplied through `CLOUDFLARE_ACCOUNT_ID`; credentials do
not belong in this repository. From the repository root:

```sh
python3 site/build.py
bunx wrangler@4.136.3 deploy --config site/wrangler.jsonc
```

The custom-domain route attaches only the project hostname. Keep music servers
separate from this static site. Validate the homepage, guide and example links,
HTTPS, 404 responses, and security/cache headers after publishing.
`auto-trailing-slash` makes the homepage resolve and redirects existing `.html`
links to their canonical pages. The local Python preview does not reproduce
Cloudflare routing, so include a Wrangler runtime check when changing routing.

Configuration follows [Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/)
and the [assets configuration reference](https://developers.cloudflare.com/workers/static-assets/binding/).
HTML and CSS use Cloudflare's default revalidation headers; screenshot assets
use a one-hour browser cache. Header behavior follows the
[static assets headers reference](https://developers.cloudflare.com/workers/static-assets/headers/).
The local preview server does not apply Cloudflare's `_headers` file.

## Documentation

`docs.html` puts the Loud format and hosting guides first. The separate codebase
reference explains the application pieces, source layout and build/test commands.
The project is not accepting contributions or pull requests at this time.

Edit guide text in `docs-content/loud.html`, `docs-content/hosting.html`, and
`docs-content/code.html`. These are reviewed HTML fragments, not full pages.
`render_docs.py` supplies the shared navigation and an optional contents list;
each `h2` needs a unique, stable `id`. `build.py` renders them into
`dist/docs/` and copies the three canonical JSON schemas into `dist/schemas/`.
The explicit allowlist also includes the sample import manifest, two artwork
sidecars, their shared CC0 image and credits in `dist/examples/`.
The site remains static and uses no runtime JavaScript or third-party assets.

`privacy.html`, `support.html` and `legal.css` are the project’s public legal/help
pages. Navigation uses relative links so the private preview and
`codec.codie.sh` serve the same files. These pages distinguish the documentation
website, self-hosted music servers and developer-operated demonstration servers.

The hosting guide targets v0.1.6 Linux AMD64/ARM64 server archives and their
individual checksums, with the bundled Ubuntu installer. Verify those assets
when updating downloads. Match future guide updates to actual package
filenames and runtime scripts.

Keep host-specific operations, tokens, private source paths and dated deployment
receipts out of the public guides. Check release availability before claiming a
new server installer or import capability is in the downloadable release.
