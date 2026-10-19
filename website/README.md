# Parlora blog

A static publication with HTML content, shared templates, CSS and a small
JavaScript enhancement for code copying and the session walkthrough. Python
3.10+ builds the site using its standard library. No npm install, Mix compilation
or voice provider credentials are needed.

## Preview locally

From the repository root:

```sh
python3 website/build.py
python3 -m http.server 4990 --bind 127.0.0.1 --directory website/_site
```

Open http://localhost:4990/. Rebuild after editing content or assets, then refresh
the browser. Local previews have analytics disabled.

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
