# Parlora blog

A static publication with HTML content, shared templates, CSS and a small
JavaScript enhancement for code copying and the session walkthrough. Python
3.10+ builds the site using its standard library. No npm install, Mix compilation
or voice provider credentials are needed.

## Preview locally

From the repository root:

```sh
python3 website/build.py
python3 website/serve.py 4990 --bind 127.0.0.1 --directory website/_site
```

Open http://localhost:4990/. Rebuild after editing content or assets, then refresh
the browser. Local previews have analytics disabled. The preview server supports
byte ranges so native audio seeking works; Python's basic `http.server` does not
provide that behavior.

## Add or edit an article

Edit the HTML in `content/`. Article metadata lives in `site.json`; add a slug,
title, description, publication date, library version and category. The builder reads the matching
`content/<slug>.html`. Use the introduction as the page structure: one title,
named section IDs, a contents list and ordinary links. Shared page structure is
in `templates/layout.html`.

The index, RSS feed, sitemap, reading time and article metadata are generated
from that list. Only actual published articles belong there. The publication
date is authored metadata; builds do not replace it with today's date.

## Verify

```sh
python3 -m unittest discover -s website -p 'test_*.py'
node --check website/assets/site.js
python3 website/build.py --output /tmp/parlora-blog-production --base-path /parlora/ --analytics
```

Every build checks local links, heading IDs, fonts, XML feeds and analytics mode.
It also checks sharing metadata and the referenced PNG files, including their
dimensions, size, public URLs and agreement between Open Graph and X tags.
The browser checks cover the actual reading layout, walkthrough and code copy.

## GitHub Pages

The `Blog` workflow checks builds on pull requests that change the site. On
`main`, it builds with `/parlora/` as the base path, includes analytics, and
deploys only generated output through GitHub Pages. The repository's Pages
source must be set to **GitHub Actions** before the first deployment.

The site URL is https://hfiguera.github.io/parlora/. The local server and GitHub
Pages both work without rewriting article routes: each route has an `index.html`.
The source templates, design records and build scripts are never deployed.

## Cloudflare Web Analytics

Production builds include exactly one Cloudflare Web Analytics beacon per page.
The browser token in `site.json` is a **public identifier**, taken from the shared
`hfiguera.github.io` property used by the maintainer's Smolbox blog. It is not an
API credential. No new analytics account or property is required.

In that property's dashboard, filter the Path dimension for `/parlora/` and its
article paths. Hostname totals also include the other project blogs. There are
no custom events for code copies or walkthrough controls.

The public privacy page explains the setup. After deployment, verify the beacon
request from a real visit and check its page path in the Cloudflare dashboard.
Passing a build check verifies configuration, not dashboard ingestion. Local
previews omit the beacon unless `--analytics` is explicitly supplied.

Setup reference: https://developers.cloudflare.com/web-analytics/get-started/

## Syntax highlighting

Elixir blocks marked with `class="language-elixir"` and shell blocks marked with
`class="language-shell"` are highlighted by a local copy of Prism 1.30.0 (core,
Elixir and Bash grammars). Scripts load only the grammars needed by each page,
before `site.js`. Bash also accepts `language-bash` and `language-sh`.
No CDN or npm install is needed.
Code remains readable without JavaScript, and copying uses the original text.

The vendored files come from https://github.com/PrismJS/prism/tree/v1.30.0/components;
their MIT license is included in `assets/vendor/Prism-LICENSE.txt`.

## Fonts

Fraunces and DM Sans are self-hosted in `assets/fonts/`, with their SIL Open Font
License notices alongside them. Browsers do not contact a font CDN. The faces
and palette preserve the conversation journal preview selected by the maintainer.

## Link previews

The shared layout includes Open Graph metadata for services such as LinkedIn,
Slack, Discord and forums, plus an X large image card. Titles and descriptions
come from the same page metadata. Images use absolute HTTPS URLs, even in a
local preview, because external crawlers need public assets. Metadata is in the
initial HTML; JavaScript and analytics are not required to read it.

`site.json` sets a default `social_image` with `path` and `alt`. An article can
override it with its own image; otherwise it uses the default. Committed PNGs
are 1200 × 630 pixels and under 5 MB. Article structured data includes the same
image. The optional artwork renderer and its dependencies are not deployed and
are not needed to build or test the site.

To edit the artwork, update `social/render.py`, which uses the existing palette,
voice mark and self-hosted OFL fonts, then regenerate the committed images:

```sh
python3 -m venv /tmp/parlora-social-assets
/tmp/parlora-social-assets/bin/pip install -r website/social/requirements.txt
/tmp/parlora-social-assets/bin/python website/social/render.py
```

After deployment, check the article and image URLs without authentication.
Platform preview caches and workspace or forum settings can delay or disable
previews; passing these checks does not force an existing post to refresh.
LinkedIn's Post Inspector can request a fresh scrape. Do not delete an existing
post just because its preview has not updated.

References: https://ogp.me/ and
https://docs.slack.dev/messaging/unfurling-links-in-messages/.

## Booking conversation replay

`keep-talking-while-we-book-it` uses `assets/booking-replay.js` and its scoped CSS.
The native audio element owns playback time; recorded captions, separate caller
and assistant waveforms, task spans and moment links follow it. Clean and café
players each offer four providers. The backend panel shows only facts available
at the playhead. Playback pauses when a player leaves view or another starts.
Reduced motion hides the moving playhead; audio and transcripts also work without
JavaScript. No API keys or live model calls are used by the page.

`assets/booking/` contains only the eight selected MP3/JSON recording pairs and
two charts used in the article. Preserve the audio hashes and measured timing in
that metadata; do not substitute generated assistant speech or invent execution
spans. The example’s [README](../examples/booking_desk/README.md) explains how to run
a new microphone or scripted call. Raw recordings and databases stay in ignored
local directories.

To refresh a recording, run the BookingDesk replay with a fixed caller clip
directory, then export the captured PCM and events. The exporter uses ElevenLabs
Scribe v2 for audio-timed captions from separate caller/assistant channels;
provider captions remain diagnostic evidence. Exporting a new transcription needs
`ELEVENLABS_API_KEY`. Matching cached transcriptions can be exported offline.

```sh
python3 website/booking_recordings.py examples/booking_desk/runs/YOUR_RUN \
  --clips examples/booking_desk/clips/YOUR_CALLER \
  --output website/assets/booking/openai.json
```

Use `clean/PROVIDER.json` for clean calls and `PROVIDER.json` for café calls.
The exporter rejects dropped capture data, mismatched caller clips, unexpected
foreground samples and clipped café mixing. It aligns output by captured tick
order, subtracts the declared café PCM to verify caller input, and records measured
backend durations. Phonic exports also retain a caller-boundary/noise audit;
workflow completion and noise rejection are separate results.

Both article graphs must use the same café GPT Live-1 report as the player.
With `matplotlib`, `fonttools` and `brotli` installed in a separate tooling
environment, regenerate them with:

```sh
python3 website/booking_charts.py examples/booking_desk/runs/YOUR_CAFE_OPENAI_RUN
```

Update the article’s static transcripts, audio cache hashes, outcome notes and
recording metrics from those same exports. Keep incomplete attempts accurately
labelled. The site build and preview do not need the chart dependencies or keys.

After building and starting the preview, run the browser checks with Playwright
installed in the existing `validation/browser` project:

```sh
BOOKING_PREVIEW_URL=http://127.0.0.1:4990/blog/keep-talking-while-we-book-it/ \
node website/test_booking_replay.cjs
```
