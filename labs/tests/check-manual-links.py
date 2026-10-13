#!/usr/bin/env python3
"""Check that every dev.mysql.com documentation link in the repo is a real page.

dev.mysql.com answers a missing documentation page with HTTP 200 and the
title "Page Not Found", so ordinary link checkers report broken manual links
as fine. This script fetches each unique URL and checks the page title.

    labs/tests/check-manual-links.py           # all *.md files

Only a page that is really missing (HTTP 404 or a "Page Not Found" title)
fails the check. dev.mysql.com also rate-limits data-centre clients such as
CI runners with 403; those links are retried slowly and, if still blocked,
reported as UNVERIFIED without failing the run.
Exit code is the number of missing pages.
"""
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
URL = re.compile(r"https://dev\.mysql\.com/doc/[^\s)>\]\"'`]+")
TITLE = re.compile(r"<title>(.*?)</title>", re.S | re.I)


def fetch_title(url: str) -> tuple[int, str]:
    req = urllib.request.Request(url, headers={"User-Agent": "curl/8.7.1"})
    err = ""
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                html = r.read(200_000).decode("utf-8", "replace")
                m = TITLE.search(html)
                return r.status, (m.group(1).strip() if m else "")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return 404, "not found"
            err = str(e)
            if e.code in (403, 429):
                time.sleep(10 * (attempt + 1))
                continue
        except Exception as e:  # noqa: BLE001
            err = str(e)
            time.sleep(2 * (attempt + 1))
    return 0, err


def main() -> int:
    where: dict[str, list[str]] = {}
    for md in sorted(REPO.rglob("*.md")):
        if "node_modules" in md.parts:
            continue
        for n, line in enumerate(md.read_text(encoding="utf-8").splitlines(), 1):
            for url in URL.findall(line):
                url = url.rstrip(".,;:")
                where.setdefault(url.split("#")[0], []).append(f"{md.relative_to(REPO)}:{n}")
    bad = blocked = 0
    urls = sorted(where)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(fetch_title, urls))
    for url, (status, title) in zip(urls, results):
        if status == 200 and title and "not found" not in title.lower():
            print(f"ok   {url}")
        elif status == 0 and ("403" in title or "429" in title):
            blocked += 1
            print(f"UNVERIFIED {url} (blocked: {title})")
        else:
            bad += 1
            print(f"FAIL {url} -> {status} {title!r}\n     used at {', '.join(where[url][:5])}")
    print(f"\n{len(where) - bad - blocked}/{len(where)} dev.mysql.com links verified, "
          f"{bad} missing, {blocked} unverified (rate-limited)")
    return bad


if __name__ == "__main__":
    sys.exit(main())
