#!/usr/bin/env python3
"""Bake stacks.nu screenshots into www/static/shots/.

Captures an SSE patch from a running server, splices it into a static page,
and renders pose screenshots via headless chromium. Each shot has a slugged
filename describing the state ("main-rest", "main-hover-edit-clip", ...) so
the /shots grid view reads as a self-documenting catalog.

Usage:
    HOST=http://localhost:4777 scripts/shoot.py

The bake-then-screenshot route is deliberate: chromium's
--virtual-time-budget only advances when the page is idle, and an SSE
connection keeps a fetch open forever, so a direct hit on the live URL
fires the screenshot before the first patch arrives. Splicing the patch
into a static page sidesteps the whole timing problem.
"""

import os
import re
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

HOST = os.environ.get("HOST", "http://localhost:4777")
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "www" / "static" / "shots"
OUT.mkdir(parents=True, exist_ok=True)


def capture_sse(seconds: int = 6) -> str:
    """Pull from /updates for `seconds` -- enough for the first patch."""
    p = subprocess.Popen(
        ["curl", "-sN", f"{HOST}/updates"],
        stdout=subprocess.PIPE,
    )
    time.sleep(seconds)
    p.terminate()
    out, _ = p.communicate(timeout=2)
    return out.decode()


def bake(sse: str, mutator=None) -> str:
    """Splice the first SSE patch into the bootstrap page; resolve relative
    URLs so chromium can load them via file://. `mutator` runs on the final
    HTML to inject pose-specific tweaks (e.g. .is-hover on a binding)."""
    m = re.search(
        r"event: datastar-patch-elements\ndata: selector main\n"
        r"((?:data: elements [^\n]*\n)+)",
        sse,
    )
    if not m:
        raise SystemExit("no datastar-patch-elements event in SSE stream")
    main_html = "\n".join(
        line[len("data: elements "):] for line in m.group(1).splitlines()
    )
    boot = urllib.request.urlopen(HOST).read().decode()
    page = re.sub(r"<main>loading\.\.\.</main>", main_html, boot)
    page = (
        page
        .replace('"/base.css"', f'"{HOST}/base.css"')
        .replace('"/keys.js"', f'"{HOST}/keys.js"')
        .replace('"/datastar@', f'"{HOST}/datastar@')
    )
    if mutator:
        page = mutator(page)
    return page


def shoot(slug: str, page: str) -> Path:
    out = OUT / f"{slug}.png"
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(page)
        html = f.name
    subprocess.run(
        [
            "chromium", "--headless", "--no-sandbox", "--disable-gpu",
            "--hide-scrollbars", "--window-size=1280,720",
            "--virtual-time-budget=2500",
            f"--screenshot={out}", f"file://{html}",
        ],
        check=True, stderr=subprocess.DEVNULL,
    )
    Path(html).unlink()
    print(f"  -> {out.relative_to(ROOT)}")
    return out


def hover_nth(n: int):
    """Return a mutator that adds .is-hover to the nth `class="binding"`."""
    def m(page: str) -> str:
        matches = list(re.finditer(r'class="binding"', page))
        if n >= len(matches):
            return page
        s, e = matches[n].span()
        return page[:s] + 'class="binding is-hover"' + page[e:]
    return m


def main() -> None:
    print(f"capturing SSE from {HOST}...")
    sse = capture_sse()
    print("baking poses...")

    shoot("main-rest", bake(sse))
    shoot("main-hover-next-clip", bake(sse, hover_nth(0)))
    shoot("main-hover-edit-clip", bake(sse, hover_nth(-1)))

    print(f"\nDone. View at {HOST}/shots")


if __name__ == "__main__":
    main()
