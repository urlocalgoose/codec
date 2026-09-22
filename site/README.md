# Codec static site

The project site is published at [codec.codie.sh](https://codec.codie.sh).
This folder contains its source and build tools. Publishing the website is
separate from App Review submission and public app release, which remain on hold.

The site is plain HTML and CSS with a small local script for copying code
examples. It has no framework, remote fonts, analytics, or music-server
connection. Edit landing-page copy in `index.html`.
The exact Graphite app colors are declared at the top of `style.css`.

Preview from the repository root:

```sh
python3 site/build.py
python3 -m http.server 9086 --bind 127.0.0.1 --directory site/dist
```

`build.py` copies an explicit allowlist into `site/dist`. Python build tools, this README,
the provenance ledger and raw captures are excluded. Publish only `site/dist`
when deployment is explicitly authorized. GitHub links point to the project’s
source and versioned Linux server releases. Listening clients shown here are
the iPhone/iPad app and web player.

## Screenshot assets

Screenshots are actual iPhone/iPad app and desktop web captures of the separately verified
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

The desktop web screenshot uses the deployed web player with the same licensed
demo library in Graphite. Capture at 1600×1000 with a 2× display scale, then
resize to 1600×1000 WebP for `assets/desktop-web.webp`. Keep auth tokens and raw
captures private; include only the relative capture name, source hash, and
encoded byte count in `assets/sources.json`. This is the browser player, not a
desktop app distribution. Its full-size image opens from the devices section.
Pass `--desktop-web /path/to/01-home.png` to `prepare-assets.py` when replacing
that capture alongside the native images. Without that option, the existing
desktop image and its provenance entry are preserved.

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
The site remains static with no third-party assets. `code-copy.js` adds Copy
buttons to full code examples on the guide pages, preserving the exact text.
It uses the Clipboard API with a local-preview fallback and announces success
or failure. Without JavaScript, the examples remain selectable. Inline code
keeps its compact styling. The security policy permits only local scripts.

`privacy.html`, `support.html` and `legal.css` are the project’s public legal/help
pages. Navigation uses relative links so the private preview and
`codec.codie.sh` serve the same files. These pages distinguish the documentation
website, self-hosted music servers and developer-operated demonstration servers.

## Updating the release version

`release.json` is the single source for version values shown on the site.
After a server release and its AMD64/ARM64 archives and checksums are published,
change only `release_version` in that file, then run `python3 site/build.py`
and publish `site/dist` with the command above. This updates the release labels,
GitHub release/download links, archive names, and install/update commands together.

Use `{{ release_version }}` in HTML or guide fragments instead of typing a
release tag. The build substitutes the value into static HTML; visitors do not
fetch configuration or need JavaScript for version labels. Preview generated
pages in `site/dist` to see resolved values. Invalid tags and unknown variables
fail the build before replacing the working preview.

`artwork_import_min_version` is a separate compatibility requirement. It does
not increase with ordinary releases; change it only if that requirement changes.
Use `{{ artwork_import_min_version }}` for that minimum. CI runs
`python3 site/test_release_config.py` and builds the site to catch stale literals
or broken substitutions. Site publication stays separate from packaging a release.

Keep host-specific operations, tokens, private source paths and dated deployment
receipts out of the public guides. Check release availability before claiming a
new server installer or import capability is in the downloadable release.
