#!/usr/bin/env python3
"""Newest Chrome for Testing stable, as the content of chrome.env.

  ci/chrome.py            print chrome.env for the newest stable (downloads both
                          zips to hash them: ~400 MB)
  ci/chrome.py --check    exit 0 = a newer stable than chrome.env, 10 = nothing to do

Source: Google's Chrome for Testing version list (googlechromelabs.github.io).
It lists no checksums, so the sha256 is taken here, over HTTPS from Google's
storage, and reviewed in the bump PR; the build then checks every download
against it. No cooldown: Chrome stable releases are security releases, and
the build's tests + gate + a person merging the PR stand between a release
and the published image. Standard library only.
"""
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

LIST = "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
PLATFORMS = {"AMD64": "linux64", "ARM64": "linux-arm64"}


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "hermes-agent-patched"})
    return urllib.request.urlopen(req, timeout=60)


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def newest():
    stable = json.load(get(LIST))["channels"]["Stable"]
    urls = {d["platform"]: d["url"] for d in stable["downloads"]["chrome"]}
    missing = [p for p in PLATFORMS.values() if p not in urls]
    if missing:
        sys.exit(f"Chrome for Testing {stable['version']}: no build for {', '.join(missing)}")
    return stable["version"], {arch: urls[p] for arch, p in PLATFORMS.items()}


def sha256(url):
    h = hashlib.sha256()
    with get(url) as r:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    version, urls = newest()
    if "--check" in sys.argv:
        have = re.search(r"^CFT_VERSION=(\S+)", Path("chrome.env").read_text(), re.M).group(1)
        print(f"pinned  {have}\nnewest  {version}")
        return 0 if vkey(version) > vkey(have) else 10
    head = Path("chrome.env").read_text().split("CFT_VERSION=")[0]
    print(head + f"CFT_VERSION={version}", end="\n")
    for arch, url in urls.items():
        print(f"CFT_SHA256_{arch}={sha256(url)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
