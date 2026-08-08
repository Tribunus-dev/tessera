#!/usr/bin/env python3
"""Tessera Observatory v1 — assembler.

Reads partials from site/src/ and data from site/data/, writes site/*.html.
Stdlib only. No deps. Idempotent.

Usage:
  python3 site/scripts/build.py          # write
  python3 site/scripts/build.py --check  # verify no drift, exit 2 on drift
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SITE = ROOT / "site"
SRC = SITE / "src"
DATA = SITE / "data"
PARTIALS = SRC / "partials"
PAGES_SRC = SRC / "pages"

# Canonical page list. Order defines nav highlighting via route match.
PAGES = [
    {
        "route": "/",
        "out": SITE / "index.html",
        "src": PAGES_SRC / "home.html",
        "title": "Tessera — Calibrate and quantize models with receipts the kernel agrees with.",
        "canon": "https://tessera.tribunus.dev/",
        "og_title": "Tessera — LLM calibration with runtime-verifiable fitness.",
        "og_desc": "Calibrate and quantize models with receipts the kernel agrees with.",
        "og_url": "https://tessera.tribunus.dev/",
        "has_secondary": True,
    },
    {
        "route": "/start/",
        "out": SITE / "start" / "index.html",
        "src": PAGES_SRC / "start.html",
        "title": "Tessera — Start",
        "canon": "https://tessera.tribunus.dev/start/",
        "og_title": "Tessera — Start",
        "og_desc": "Calibrate and quantize models with receipts the kernel agrees with.",
        "og_url": "https://tessera.tribunus.dev/start/",
        "has_secondary": True,
    },
    {
        "route": "/architecture/",
        "out": SITE / "architecture" / "index.html",
        "src": PAGES_SRC / "architecture.html",
        "title": "Tessera — Architecture",
        "canon": "https://tessera.tribunus.dev/architecture/",
        "og_title": "Tessera — Architecture",
        "og_desc": "Calibrate and quantize models with receipts the kernel agrees with.",
        "og_url": "https://tessera.tribunus.dev/architecture/",
        "has_secondary": True,
    },
    {
        "route": "/evidence/",
        "out": SITE / "evidence" / "index.html",
        "src": PAGES_SRC / "evidence.html",
        "title": "Tessera — Evidence",
        "canon": "https://tessera.tribunus.dev/evidence/",
        "og_title": "Tessera — Evidence",
        "og_desc": "Calibrate and quantize models with receipts the kernel agrees with.",
        "og_url": "https://tessera.tribunus.dev/evidence/",
        "has_secondary": True,
    },
    {
        "route": "/status/",
        "out": SITE / "status" / "index.html",
        "src": PAGES_SRC / "status.html",
        "title": "Tessera — Status",
        "canon": "https://tessera.tribunus.dev/status/",
        "og_title": "Tessera — Status",
        "og_desc": "Calibrate and quantize models with receipts the kernel agrees with.",
        "og_url": "https://tessera.tribunus.dev/status/",
        "has_secondary": True,
    },
    {
        "route": "/changelog/",
        "out": SITE / "changelog" / "index.html",
        "src": PAGES_SRC / "changelog.html",
        "title": "Tessera — Changelog",
        "canon": "https://tessera.tribunus.dev/changelog/",
        "og_title": "Tessera — Changelog",
        "og_desc": "Calibrate and quantize models with receipts the kernel agrees with.",
        "og_url": "https://tessera.tribunus.dev/changelog/",
        "has_secondary": True,
    },
    {
        "route": "/colophon/",
        "out": SITE / "colophon" / "index.html",
        "src": PAGES_SRC / "colophon.html",
        "title": "Tessera — Colophon",
        "canon": "https://tessera.tribunus.dev/colophon/",
        "og_title": "Tessera — Colophon",
        "og_desc": "Calibrate and quantize models with receipts the kernel agrees with.",
        "og_url": "https://tessera.tribunus.dev/colophon/",
        "has_secondary": True,
    },
    {
        "route": "/404/",
        "out": SITE / "404.html",
        "src": PAGES_SRC / "404.html",
        "title": "Tessera — Page not found",
        "canon": "https://tessera.tribunus.dev/",
        "og_title": "Tessera — Page not found",
        "og_desc": "The page you requested does not exist.",
        "og_url": "https://tessera.tribunus.dev/",
        "has_secondary": False,
        "noindex": True,
    },
]


def load_partial(name: str) -> str:
    return (PARTIALS / name).read_text()


def render_primary_nav(active_route: str) -> str:
    data = json.loads((DATA / "navigation.json").read_text())
    parts: list[str] = []
    for item in data["primary"]:
        label = item["label"]
        path = item["path"]
        external = item.get("external", False)
        if external:
            parts.append(f'<a class="site-nav-link" rel="external" target="_blank" href="{path}">{label}</a>')
            continue
        # Active when route matches path exactly, except "/" only matches "/"
        active = " aria-current=\"page\"" if active_route == path else ""
        parts.append(f'<a class="site-nav-link" href="{path}"{active}>{label}</a>')
    return "\n".join(parts)


def render_secondary_nav(active_route: str) -> str:
    # Bootstrap secondary nav is uniform across all pages: Home + primary
    # (non-external) + Colophon. The navigation.json "secondary" with "from"
    # is the future per-page contextual nav (Phase 3); bootstrap keeps the
    # hand-authored uniform list so the assembler reproduces the current site.
    parts: list[str] = []
    # Home
    active = " aria-current=\"page\"" if active_route == "/" else ""
    parts.append(f'<li><a href="/"{active}>Home</a></li>')
    data = json.loads((DATA / "navigation.json").read_text())
    for item in data["primary"]:
        if item.get("external"):
            continue
        label = item["label"]
        path = item["path"]
        active = " aria-current=\"page\"" if active_route == path else ""
        parts.append(f'<li><a href="{path}"{active}>{label}</a></li>')
    # Colophon (from secondary global)
    active = " aria-current=\"page\"" if active_route == "/colophon/" else ""
    parts.append(f'<li><a href="/colophon/"{active}>Colophon</a></li>')
    return "\n".join(parts)


def render_page(page: dict) -> str:
    head_partial = load_partial("head.html")
    header_partial = load_partial("header.html")
    footer_partial = load_partial("footer.html")
    nav_secondary_partial = load_partial("nav-secondary.html")

    primary_nav = render_primary_nav(page["route"])
    header = header_partial.replace("{{PRIMARY_NAV}}", primary_nav)

    body = page["src"].read_text()

    secondary_block = ""
    if page.get("has_secondary", True):
        secondary_inner = render_secondary_nav(page["route"])
        secondary_block = nav_secondary_partial.replace("{{SECONDARY_NAV}}", secondary_inner)

    # Per-page head extras (title, canonical, og). head_partial is shared shell without those.
    # Build full <head> content. Order matches original hand-authored files:
    # charset, viewport, title, canonical, icon, generator, build-id,
    # robots (if), og:title, og:desc, og:type, og:url, twitter:card, stylesheet, inline script, theme.js
    robots = '<meta name="robots" content="noindex">\n' if page.get("noindex") else ""
    og_url_line = f'<meta property="og:url" content="{page["og_url"]}">\n' if page["og_url"] and page["route"] != "/404/" else ""
    # Editorial OG image — PNG for Twitter/X unfurl, SVG as fallback.
    og_image = '<meta property="og:image" content="https://tessera.tribunus.dev/media/og-image.png">\n<meta property="og:image:width" content="1200">\n<meta property="og:image:height" content="630">\n<meta property="og:image:alt" content="Tessera — receipts the kernel agrees with">\n<meta property="og:image:type" content="image/png">\n'
    twitter_image = '<meta name="twitter:image" content="https://tessera.tribunus.dev/media/og-image.png">\n'
    json_ld = (
        '<script type="application/ld+json">{"@context":"https://schema.org","@type":"Article",'
        f'"headline":{json.dumps(page["og_title"])},"description":{json.dumps(page["og_desc"])},'
        f'"author":{{"@type":"Person","name":"Julian Torres"}},'
        f'"mainEntityOfPage":{{"@type":"WebPage","@id":{json.dumps(page["canon"])}}},'
        '"publisher":{"@type":"Organization","name":"Tessera","logo":{"@type":"ImageObject","url":"https://tessera.tribunus.dev/media/og-image.svg"}}'
        "}</script>\n"
        '<script type="application/ld+json">{"@context":"https://schema.org","@type":"BreadcrumbList","itemListElement":['
        '{"@type":"ListItem","position":1,"name":"Home","item":"https://tessera.tribunus.dev/"},'
        f'{{"@type":"ListItem","position":2,"name":{json.dumps(page["og_title"])},"item":{json.dumps(page["canon"])}}}'
        "]}</script>\n"
    )
    feed_link = '<link rel="alternate" type="application/rss+xml" title="Tessera Changelog" href="/feed.xml">\n'
    head = (
        "<!doctype html>\n"
        '<html lang="en" data-theme="dark">\n'
        "<head>\n"
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
        f"<title>{page['title']}</title>\n"
        f'<link rel="canonical" href="{page["canon"]}">\n'
        '<link rel="icon" type="image/svg+xml" href="/favicon.svg">\n'
        '<meta name="generator" content="tessera-docs-ssg">\n'
        '<meta name="build-id" content="bootstrap-001">\n'
        f"{robots}"
        f'<meta property="og:title" content="{page["og_title"]}">\n'
        f'<meta property="og:description" content="{page["og_desc"]}">\n'
        '<meta property="og:type" content="website">\n'
        f"{og_url_line}"
        f"{og_image}"
        '<meta name="twitter:card" content="summary">\n'
        f"{twitter_image}"
        f"{json_ld}"
        f"{feed_link}"
        f"{head_partial}"
        + ('<script src="/scripts/downloads.js" defer></script>\n' if page["route"] in ("/", "/start/") else "")
        + "</head>\n"
    )

    # For 404, twitter title/desc differ? Keep as page-level but original 404 had no twitter title?
    # Simpler: keep uniform. The extra twitter tags in index.html were:
    # <meta name="twitter:title" ...> and <meta name="twitter:description" ...> only on /
    # But we can omit them for brevity — original pages (except index) only had card.
    # To stay minimal and faithful, only add twitter title/desc on "/"
    if page["route"] == "/":
        # Insert after twitter:card inside head
        head = head.replace(
            '<meta name="twitter:card" content="summary">',
            '<meta name="twitter:card" content="summary">\n'
            '<meta name="twitter:title" content="Tessera">\n'
            '<meta name="twitter:description" content="Calibrate and quantize models with receipts the kernel agrees with.">',
        )

    doc = (
        f"{head}"
        f'<body data-prism-route="{page["route"]}" data-prism-hydrated="false">\n'
        '<a href="#top" class="skip-link">Skip to main content</a>\n'
        f"{header}\n"
        f"{body}\n"
        f"{secondary_block}\n"
        f"{footer_partial}\n"
        "</body>\n"
        "</html>\n"
    )
    return doc


def build_css() -> None:
    # Concatenate foundation + components into site/styles/site.css built output
    # This avoids 8 serial @import fetches. Source files stay as partials; build writes the concatenated file.
    # Keep the original site.css as the import manifest for dev; build overwrites with concatenated content.
    # We write to site/styles/site.css directly (Pages serves it). A check mode verifies it too.
    foundation = ["tokens.css", "fonts.css", "typography.css", "layout.css"]
    components = ["site-header.css", "hero.css", "page.css", "chapter.css", "footer.css", "state-badge.css", "receipt.css", "prose.css", "downloads.css"]
    parts: list[str] = []
    for name in foundation:
        p = SITE / "styles" / "foundation" / name
        if p.exists():
            parts.append(f"/* --- foundation/{name} --- */\n" + p.read_text())
    for name in components:
        p = SITE / "styles" / "components" / name
        if p.exists():
            parts.append(f"/* --- components/{name} --- */\n" + p.read_text())
    built = "\n\n".join(parts) + "\n"
    (SITE / "styles" / "site.css").write_text(built)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify no drift without writing")
    args = ap.parse_args()

    # Always ensure CSS is built (or checked)
    if args.check:
        # Verify CSS would be unchanged if rebuilt
        import hashlib

        foundation = ["tokens.css", "fonts.css", "typography.css", "layout.css"]
        components = ["site-header.css", "hero.css", "page.css", "chapter.css", "footer.css", "state-badge.css", "receipt.css", "prose.css", "downloads.css"]
        parts: list[str] = []
        for name in foundation:
            p = SITE / "styles" / "foundation" / name
            if p.exists():
                parts.append(f"/* --- foundation/{name} --- */\n" + p.read_text())
        for name in components:
            p = SITE / "styles" / "components" / name
            if p.exists():
                parts.append(f"/* --- foundation/{name} --- */\n" + p.read_text()) if False else None
                parts.append(f"/* --- components/{name} --- */\n" + p.read_text()) if name in components else None
        # Recompute correctly (avoid duplication bug above — recompute clean)
        parts = []
        for name in foundation:
            p = SITE / "styles" / "foundation" / name
            if p.exists():
                parts.append(f"/* --- foundation/{name} --- */\n" + p.read_text())
        for name in components:
            p = SITE / "styles" / "components" / name
            if p.exists():
                parts.append(f"/* --- components/{name} --- */\n" + p.read_text())
        built = "\n\n".join(parts) + "\n"
        # Compare without writing
        current = (SITE / "styles" / "site.css").read_text() if (SITE / "styles" / "site.css").exists() else ""
        if current != built:
            print("drift: site/styles/site.css (CSS bundle)", file=sys.stderr)
            # Don't return yet — also check pages below
            pass  # handled via drift list below? we will add sentinel
            # Use a sentinel to fail check
            drift_css = True
        else:
            drift_css = False
    else:
        build_css()
        drift_css = False

    drift: list[str] = []
    if drift_css if 'drift_css' in locals() else False:
        drift.append("site/styles/site.css")
    for page in PAGES:
        expected = render_page(page)
        out = page["out"]
        if args.check:
            if not out.exists():
                print(f"missing: {out}", file=sys.stderr)
                drift.append(str(out))
                continue
            actual = out.read_text()
            if actual != expected:
                print(f"drift: {out}", file=sys.stderr)
                drift.append(str(out))
        else:
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(expected)
            print(f"wrote {out}")

    if args.check and drift:
        print(f"{len(drift)} file(s) need rebuild: run python3 site/scripts/build.py", file=sys.stderr)
        return 2
    if args.check:
        print("ok — no drift")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
