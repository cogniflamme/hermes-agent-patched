#!/usr/bin/env python3
"""Newest stable upstream Hermes image, as a BASE= line for upstream.env.

  ci/upstream.py            print BASE=docker.io/nousresearch/hermes-agent:vX.Y.Z@sha256:...
  ci/upstream.py --check    exit 0 = a newer stable is due, 10 = nothing to do

Stable = the vX.Y.Z tag whose digest equals the `stable` tag's (the same rule
Agent Li's `agntctl outdated` uses). A release is due once it is
COOLDOWN_DAYS old (default 2): a hijacked or broken release is usually
pulled within that time. Standard library only.
"""
import datetime as dt
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

REPO = "nousresearch/hermes-agent"
API = f"https://hub.docker.com/v2/repositories/{REPO}/tags"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "hermes-agent-hardened"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def newest():
    stable = get(f"{API}/stable")["digest"]
    for t in get(f"{API}?page_size=100&ordering=last_updated")["results"]:
        if t.get("digest") == stable and re.fullmatch(r"v\d+\.\d+\.\d+", t["name"]):
            pushed = dt.datetime.fromisoformat(t["last_updated"].replace("Z", "+00:00"))
            return f"docker.io/{REPO}:{t['name']}@{stable}", pushed
    sys.exit("no vX.Y.Z tag matches the 'stable' digest")


def main():
    want, pushed = newest()
    if "--check" in sys.argv:
        have = re.search(r"^BASE=(\S+)", Path("upstream.env").read_text(), re.M).group(1)
        age = dt.datetime.now(dt.timezone.utc) - pushed
        cool = dt.timedelta(days=float(os.environ.get("COOLDOWN_DAYS", "2")))
        print(f"pinned  {have}\nnewest  {want}  ({age.days}d {age.seconds // 3600}h old)")
        if have == want:
            return 10
        if age < cool:
            print(f"inside the {cool.days}-day cooldown: not yet")
            return 10
        return 0
    print(f"BASE={want}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
