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
The browser checks cover the actual reading layout, walkthrough and code copy.

## GitHub Pages

The `Blog` workflow checks builds on pull requests that change the site. On
`main`, it builds with `/parlora/` as the base path, includes analytics, and
deploys only generated output through GitHub Pages. The repository's Pages
source must be set to **GitHub Actions** before the first deployment. This task
does not enable Pages or publish the branch.

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

Elixir blocks marked with `class="language-elixir"` are highlighted by a local
copy of Prism 1.30.0 (core and Elixir grammar only). Scripts load only on pages
containing Elixir blocks, before `site.js`. No CDN or npm install is needed.
Code remains readable without JavaScript, and copying uses the original text.

The vendored files come from https://github.com/PrismJS/prism/tree/v1.30.0/components;
their MIT license is included in `assets/vendor/Prism-LICENSE.txt`.

## Fonts

Fraunces and DM Sans are self-hosted in `assets/fonts/`, with their SIL Open Font
License notices alongside them. Browsers do not contact a font CDN. The faces
and palette preserve the conversation journal preview selected by the maintainer.
