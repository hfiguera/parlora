#!/usr/bin/env python3
"""Build a static publication using only the Python standard library."""

import argparse
from datetime import date, datetime, timezone
from email.utils import format_datetime
from html import escape
from html.parser import HTMLParser
import json
import math
from pathlib import Path
import re
import shutil
import tempfile
import xml.etree.ElementTree as ET

SOURCE = Path(__file__).resolve().parent
BUILD_MARKER = ".parlora-blog-build"
BEACON = "https://static.cloudflareinsights.com/beacon.min.js"


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.ids = set()
        self.links = []
        self.headings = []
        self.canonicals = []
        self.beacons = []
        self.text = []
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            if attrs["id"] in self.ids:
                raise ValueError(f"Duplicate HTML id: {attrs['id']}")
            self.ids.add(attrs["id"])
        for key in ("href", "src"):
            if key in attrs:
                self.links.append(attrs[key])
        if tag == "h1":
            self.headings.append(tag)
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonicals.append(attrs["href"])
        if tag == "script" and attrs.get("src") == BEACON:
            self.beacons.append(json.loads(attrs.get("data-cf-beacon", "{}")))

    def handle_data(self, text):
        self.text.append(text)


def base_path(value):
    if not re.fullmatch(r"/(?:[A-Za-z0-9_-]+/)*", value):
        raise argparse.ArgumentTypeError("Base path must be / or a path such as /parlora/")
    return value


def render(template, values):
    # Insert the content last, so its own placeholders are expanded as well.
    for key in ("CONTENT", *[k for k in values if k != "CONTENT"]):
        if key in values:
            template = template.replace("{{" + key + "}}", values[key])
    unresolved = re.findall(r"\{\{[A-Z_]+\}\}", template)
    if unresolved:
        raise ValueError(f"Unresolved template values: {unresolved}")
    return template


def date_label(value):
    day = date.fromisoformat(value)
    return f"{day.strftime('%B')} {day.day}, {day.year}"


def build(output, prefix="/", analytics=False):
    prefix = base_path(prefix)
    output = Path(output).resolve()
    if SOURCE.is_relative_to(output):
        raise ValueError("Build output must not contain the website sources")
    if output.exists() and any(output.iterdir()) and not (output / BUILD_MARKER).is_file():
        raise ValueError("Refusing to replace a directory without a Parlora build marker")
    site = json.loads((SOURCE / "site.json").read_text())
    url = site["url"].rstrip("/")
    template = (SOURCE / "templates/layout.html").read_text()
    articles = sorted(site["articles"], key=lambda item: item["date"], reverse=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".parlora-build-", dir=output.parent) as scratch:
        stage = Path(scratch) / "site"
        stage.mkdir()
        shutil.copytree(SOURCE / "assets", stage / "assets")

        def write_page(path, content, title, description, **extra):
            values = {
                "CONTENT": content,
                "BASE": prefix,
                "TITLE": escape(title, quote=True),
                "DESCRIPTION": escape(description, quote=True),
                "CANONICAL": url + "/" + ("" if path == "index.html" else path.removesuffix("index.html")),
                "TYPE": "website",
                "BLOG_CURRENT": ' aria-current="page"' if path == "index.html" else "",
                "STRUCTURED_DATA": "",
                "SYNTAX_SCRIPTS": (
                    f'<script defer data-manual src="{prefix}assets/vendor/prism-core.min.js"></script>\n'
                    f'  <script defer src="{prefix}assets/vendor/prism-elixir.min.js"></script>'
                    if "language-elixir" in content else ""
                ),
                "ANALYTICS": (
                    f'<script defer src="{BEACON}" data-cf-beacon=\'{json.dumps({"token": site["cloudflare_token"]}, separators=(",", ":"))}\'></script>'
                    if analytics else ""
                ),
            }
            values.update(extra)
            target = stage / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(render(template, values))

        entries = []
        for article in articles:
            slug = article["slug"]
            if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
                raise ValueError(f"Invalid article slug: {slug}")
            content = (SOURCE / "content" / f"{slug}.html").read_text()
            read_time = str(max(1, math.ceil(len(" ".join(Page(content).text).split()) / 200)))
            path = f"blog/{slug}/index.html"
            structured = {
                "@context": "https://schema.org", "@type": "BlogPosting",
                "headline": article["title"], "description": article["description"],
                "datePublished": article["date"],
                "author": {"@type": "Person", "name": site["author"], "url": "https://github.com/hfiguera"},
                "mainEntityOfPage": url + f"/blog/{slug}/",
            }
            write_page(
                path, content, article["title"] + " | Parlora", article["description"],
                TYPE="article", ARTICLE_DESCRIPTION=escape(article["description"]),
                ARTICLE_DATE=article["date"], ARTICLE_DATE_LABEL=date_label(article["date"]),
                READ_TIME=read_time, ARTICLE_VERSION=escape(article["version"]),
                STRUCTURED_DATA='<script type="application/ld+json">' + json.dumps(structured).replace("<", "\\u003c") + "</script>",
            )
            entries.append(
                '<article class="post-entry">'
                f'<div class="post-meta"><time datetime="{article["date"]}">{date_label(article["date"])}</time>'
                f'<span>{escape(article["category"])}</span><span>{read_time} min read</span></div>'
                '<div class="post-summary">'
                f'<h3><a href="{prefix}blog/{slug}/">{escape(article["title"])}</a></h3>'
                f'<p>{escape(article["description"])}</p>'
                f'<a class="article-link" href="{prefix}blog/{slug}/">Read the introduction '
                '<svg class="icon" viewBox="0 0 20 20" aria-hidden="true"><path d="M3 10h14m-6-6 6 6-6 6"/></svg></a></div></article>'
            )
        write_page("index.html", (SOURCE / "content/index.html").read_text(), "Parlora | Voice AI agents with Elixir", site["description"], ARTICLES="\n".join(entries))
        write_page("privacy/index.html", (SOURCE / "content/privacy.html").read_text(), "Analytics privacy | Parlora", "How the Parlora blog uses Cloudflare Web Analytics.")
        write_page("404.html", (SOURCE / "content/404.html").read_text(), "Page not found | Parlora", "Find your way back to the Parlora blog.")

        rss = ET.Element("rss", version="2.0")
        channel = ET.SubElement(rss, "channel")
        for key, value in (("title", "Parlora blog"), ("link", url + "/"), ("description", site["description"]), ("language", "en")):
            ET.SubElement(channel, key).text = value
        for article in articles:
            item = ET.SubElement(channel, "item")
            permalink = url + "/blog/" + article["slug"] + "/"
            for key, value in (("title", article["title"]), ("link", permalink), ("description", article["description"]), ("guid", permalink)):
                ET.SubElement(item, key).text = value
            # The authored date has no claimed publication time; use midnight UTC for RSS.
            published = datetime.combine(date.fromisoformat(article["date"]), datetime.min.time(), timezone.utc)
            ET.SubElement(item, "pubDate").text = format_datetime(published, usegmt=True)
        ET.ElementTree(rss).write(stage / "feed.xml", encoding="utf-8", xml_declaration=True)

        namespace = "http://www.sitemaps.org/schemas/sitemap/0.9"
        ET.register_namespace("", namespace)
        sitemap = ET.Element(f"{{{namespace}}}urlset")
        for path in ("", "privacy/", *["blog/" + a["slug"] + "/" for a in articles]):
            node = ET.SubElement(sitemap, f"{{{namespace}}}url")
            ET.SubElement(node, f"{{{namespace}}}loc").text = url + "/" + path
        ET.ElementTree(sitemap).write(stage / "sitemap.xml", encoding="utf-8", xml_declaration=True)
        (stage / ".nojekyll").touch()
        (stage / BUILD_MARKER).write_text("Generated by website/build.py\n")
        verify(stage, prefix, analytics)
        if output.exists():
            shutil.rmtree(output)
        shutil.move(str(stage), output)
    return output


def verify(output, prefix="/", analytics=False):
    from urllib.parse import unquote, urlsplit

    output = Path(output).resolve()
    config = json.loads((SOURCE / "site.json").read_text())
    html_pages = {path: Page(path.read_text()) for path in output.rglob("*.html")}
    for path, page in html_pages.items():
        if len(page.headings) != 1 or len(page.canonicals) != 1:
            raise ValueError(f"Expected one title heading and canonical URL in {path}")
        if len(page.beacons) != int(analytics):
            raise ValueError(f"Incorrect analytics beacon count in {path}")
        if analytics and page.beacons[0] != {"token": config["cloudflare_token"]}:
            raise ValueError(f"Incorrect analytics property in {path}")
        for link in page.links:
            parts = urlsplit(link)
            if parts.scheme or parts.netloc:
                continue
            if parts.path.startswith("/"):
                if not parts.path.startswith(prefix):
                    raise ValueError(f"Link escapes the site base path: {link}")
                target = output / unquote(parts.path[len(prefix):])
            else:
                target = path.parent / unquote(parts.path)
            if not parts.path:
                target = path
            if target.is_dir():
                target /= "index.html"
            target = target.resolve()
            if not target.is_relative_to(output) or not target.is_file():
                raise ValueError(f"Missing local target: {link} in {path}")
            if parts.fragment and target in html_pages and unquote(parts.fragment) not in html_pages[target].ids:
                raise ValueError(f"Missing fragment: {link} in {path}")
    for name in ("feed.xml", "sitemap.xml"):
        ET.parse(output / name)
    for css in output.rglob("*.css"):
        for asset in re.findall(r'url\(["\']?([^"\')]+)', css.read_text()):
            if not (css.parent / asset).is_file():
                raise ValueError(f"Missing CSS asset: {asset}")
    return len(html_pages)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=SOURCE / "_site")
    parser.add_argument("--base-path", type=base_path, default="/")
    parser.add_argument("--analytics", action="store_true", help="Include the shared public Cloudflare Web Analytics beacon")
    args = parser.parse_args()
    result = build(args.output, args.base_path, args.analytics)
    print(f"Built and verified {verify(result, args.base_path, args.analytics)} pages in {result}; analytics {'enabled' if args.analytics else 'disabled'}")
