"""End-to-end test of Hermes' browser tool against the image's Chrome.

Runs inside the image (tests/run.sh): serves tests/page*.html on 127.0.0.1,
then drives the tool the agent calls. Two generations of the tool:
  - up to v0.22.5: browser_navigate / snapshot / type / click / ... functions;
  - v0.22.6 on: browser_exec, which runs Python with browser helpers.
Fails on any error, on the wrong Chrome, or on a result that does not match
the page.
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, "/opt/hermes")
from tools import browser_tool as b                      # noqa: E402
try:
    from tools.browser_tool_cloud import browser_backend_name     # <= v0.22.5
except ImportError:
    from tools.browser_session_cloud import browser_backend_name  # v0.22.6+

BASE = "http://127.0.0.1:8765"
fails = []


def call(name, fn, *a, **kw):
    raw = fn(*a, task_id="e2e", **kw)
    try:
        res = json.loads(raw) if isinstance(raw, str) else raw
    except json.JSONDecodeError:
        res = {"success": False, "error": f"not JSON: {raw[:200]}"}
    ok = isinstance(res, dict) and res.get("success", True) and not res.get("error")
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f": {str(res)[:300]}"))
    if not ok:
        fails.append(name)
    return res if isinstance(res, dict) else {}


def check(name, cond, detail=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + ("" if cond else f": {detail[:300]}"))
    if not cond:
        fails.append(name)


def ref(snapshot, role, label):
    m = re.search(rf'{role} "{re.escape(label)}"[^\n]*ref=(e\d+)', snapshot)
    return m.group(1) if m else None


want = "/usr/bin/chromium"   # Debian's; the bundled paths link here



def check_chrome():
    # Which Chrome is running: the browser processes' executable.
    ps = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
    chromes = {line.split()[0] for line in ps.splitlines() if "--remote-debugging" in line or "--type=renderer" in line}
    # want may be a wrapper script (Debian: /usr/bin/chromium execs /usr/lib/chromium/chromium)
    allowed = (os.path.dirname(os.path.realpath(want)), "/usr/lib/chromium/")
    real = {os.path.realpath(c) for c in chromes}
    check("runs the image's Chromium, not a bundled one",
          bool(real) and all(r.startswith(allowed) and not r.startswith("/opt/hermes/tools") for r in real),
          f"running: {sorted(chromes)}, allowed {allowed}")



def legacy_tools():
    """v0.22.5 and older: one function per action."""
    check("backend is local", browser_backend_name() == "local", browser_backend_name())
    nav = call("navigate", b.browser_navigate, f"{BASE}/page.html")
    check("title", nav.get("title") == "patched-e2e", str(nav.get("title")))

    check_chrome()
    snap = call("snapshot", b.browser_snapshot).get("snapshot", "")
    box, btn = ref(snap, "textbox", "Name"), ref(snap, "button", "Greet")
    check("snapshot has refs", bool(box and btn), snap[:300])
    if box and btn:
        call("type", b.browser_type, box, "patched")
        call("click", b.browser_click, btn)
        out = call("read result", b.browser_console, expression="document.getElementById('out').textContent")
        check("click ran the page's JS", "hello patched" in json.dumps(out), json.dumps(out)[:300])

    js = call("console expression", b.browser_console, expression="window.__js_ok")
    check("JS evaluates", "42" in json.dumps(js), json.dumps(js)[:300])

    call("scroll", b.browser_scroll, "down")
    call("press", b.browser_press, "End")
    link = ref(snap, "link", "second page")
    if link:
        call("follow link", b.browser_click, link)
        t = call("page 2 title", b.browser_console, expression="document.title")
        check("second page", "page two" in json.dumps(t), json.dumps(t)[:300])
        call("back", b.browser_back)
        snap = call("snapshot back", b.browser_snapshot).get("snapshot", "")
        check("back to first page", "Hermes browser test" in snap, snap[:300])
    imgs = call("get images", b.browser_get_images)



EXEC_CODE = f"""
# Patched image browser test
new_tab("{BASE}/page.html"); wait_for_load()
print("TITLE=" + str(js("document.title")))
print("UA=" + str(js("navigator.userAgent")))
fill_input("#name", "patched")
x, y = js("(() => {{ const r = document.getElementById('go').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; }})()")
click_at_xy(x, y)
print("OUT=" + str(js("document.getElementById('out').textContent")))
print("JS=" + str(js("window.__js_ok")))
goto_url("{BASE}/page2.html"); wait_for_load()
print("TITLE2=" + str(js("document.title")))
capture_screenshot()
"""


def exec_tool():
    """v0.22.6 on: browser_exec runs Python with the browser helpers."""
    from tools import browser_use_cli as c
    check("backend is local", browser_backend_name(local_engine="local") == "local", browser_backend_name())
    check("browser_exec available", bool(c.browser_exec_available()), "browser-harness not importable")
    raw = c.browser_exec(code=EXEC_CODE, session="e2e", timeout_s=180, task_id="e2e")
    res = json.loads(raw) if isinstance(raw, str) else raw
    out = json.dumps(res)
    ok = not (isinstance(res, dict) and (res.get("error") or res.get("success") is False))
    print(f"{'ok  ' if ok else 'FAIL'} browser_exec" + ("" if ok else f": {out[:400]}"))
    if not ok:
        fails.append("browser_exec")
    out = res.get("output", out) if isinstance(res, dict) else out
    # Browser Use marks its tab titles (e.g. a leading emoji): match the end.
    check("title", re.search(r"^TITLE=.*patched-e2e$", out, re.M) is not None, out[:300])
    m = re.search(r"Chrome/(\d+)\.", out)
    check("Chrome major from the user agent", bool(m) and int(m.group(1)) >= 150, (m and m.group(0)) or out[:200])
    check("typed + clicked, page JS ran", "OUT=hello patched" in out, out[:300])
    check("JS evaluates", "JS=42" in out, out[:300])
    check("navigated to page 2", re.search(r"^TITLE2=.*page two$", out, re.M) is not None, out[:300])
    check_chrome()


if hasattr(b, "browser_navigate"):
    legacy_tools()
else:
    exec_tool()

print("RESULT:", "PASS" if not fails else f"FAIL ({', '.join(fails)})")
os._exit(1 if fails else 0)   # skip Hermes' atexit browser cleanup noise
