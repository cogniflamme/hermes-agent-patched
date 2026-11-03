#!/usr/bin/env python3
"""Release gate over a grype JSON report.

  ci/gate.py REPORT.json [--accepted ci/accepted.toml] [--summary FILE]

Fails (exit 1) on:
  - any finding on CISA's Known Exploited Vulnerabilities list, fix or not;
  - any Critical or High finding that has a fix, unless ci/accepted.toml
    accepts it (id + package [+ version]) and the acceptance has not expired.
Everything else is reported, not blocking: findings without a fix wait for
Debian or upstream, and the weekly rebuild picks them up when they land.
"""
import argparse
import collections
import datetime as dt
import json
import sys
import tomllib


def is_kev(m):
    v = m["vulnerability"]
    if v.get("knownExploited"):
        return True
    return any(r.get("knownExploited") for r in m.get("relatedVulnerabilities") or [])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--accepted", default="ci/accepted.toml")
    ap.add_argument("--summary", help="append a Markdown summary here (e.g. $GITHUB_STEP_SUMMARY)")
    a = ap.parse_args()

    matches = json.load(open(a.report))["matches"]
    accepted = tomllib.load(open(a.accepted, "rb")).get("accepted", [])
    today = dt.date.today()

    def acceptance(m):
        v, art = m["vulnerability"], m["artifact"]
        ids = {v["id"]} | {r["id"] for r in m.get("relatedVulnerabilities") or []}
        for e in accepted:
            if e["id"] in ids and e["package"] == art["name"] and e.get("version", art["version"]) == art["version"]:
                return e
        return None

    blocking, waived, expired = [], [], []
    sev = collections.Counter()
    fixable = collections.Counter()
    for m in matches:
        v, art = m["vulnerability"], m["artifact"]
        sev[v["severity"]] += 1
        has_fix = (v.get("fix") or {}).get("state") == "fixed"
        if has_fix:
            fixable[v["severity"]] += 1
        kev = is_kev(m)
        if not (kev or (has_fix and v["severity"] in ("Critical", "High"))):
            continue
        row = (f"{'KEV ' if kev else ''}{v['severity']} {v['id']} {art['name']} {art['version']}"
               f" -> {', '.join((v.get('fix') or {}).get('versions') or ['no fix'])}"
               f"  ({(art.get('locations') or [{}])[0].get('path', '')})")
        e = acceptance(m)
        if e and e["expires"] >= today:
            waived.append(f"{row}  [accepted until {e['expires']}]")
        elif e:
            expired.append(f"{row}  [acceptance EXPIRED {e['expires']}]")
        else:
            blocking.append(row)

    order = ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"]
    lines = [f"all findings: " + ", ".join(f"{s} {sev[s]}" for s in order if sev[s]),
             f"with a fix:   " + ", ".join(f"{s} {fixable[s]}" for s in order if fixable[s])]
    for title, rows in (("BLOCKING", blocking + expired), ("accepted", waived)):
        if rows:
            lines.append(f"{title} ({len(rows)}):")
            lines += [f"  {r}" for r in sorted(set(rows))]
    ok = not blocking and not expired
    lines.append("gate: PASS" if ok else "gate: FAIL")
    print("\n".join(lines))
    if a.summary:
        with open(a.summary, "a") as f:
            f.write("### Vulnerability gate\n\n```\n" + "\n".join(lines) + "\n```\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
