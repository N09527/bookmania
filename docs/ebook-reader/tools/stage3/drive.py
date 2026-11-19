"""Helpers for the stage 3 checks: uiautomator nodes, taps, sliders and the reader's DevTools.

Used as a module by check_settings.py, or from the command line:
  python3 -I drive.py dump            -> every on-screen node with class, text/desc and bounds
  python3 -I drive.py style           -> computed styles of the open book (style.js)
Environment: ADB (path to adb), PKG (package, default io.github.n09527.bookmania.debug).
"""
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = os.environ.get('ADB', 'adb')
PKG = os.environ.get('PKG', 'io.github.n09527.bookmania.debug')
HERE = os.path.dirname(os.path.abspath(__file__))
S2 = os.path.join(HERE, '..', 'stage2')
OUT = os.environ.get('OUT', os.path.join(HERE, 'out'))
os.makedirs(os.path.join(OUT, 'shots'), exist_ok=True)


def adb(*args, timeout=120, text=True):
    r = subprocess.run([ADB, *args], capture_output=True, timeout=timeout)
    return r.stdout.decode('utf-8', 'replace') if text else r.stdout


def shell(cmd, timeout=120):
    return adb('shell', cmd, timeout=timeout)


def nodes():
    """Visible nodes (zero-size nodes, e.g. WebView text on other pages, are left out)."""
    for _ in range(3):
        shell('uiautomator dump /sdcard/ui.xml', timeout=180)
        raw = adb('exec-out', 'cat', '/sdcard/ui.xml', text=False)
        try:
            root = ET.fromstring(raw.decode('utf-8', 'replace'))
            break
        except ET.ParseError:
            time.sleep(2)
    else:
        return []
    out = []
    for n in root.iter('node'):
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', n.get('bounds', ''))
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        if x2 <= x1 or y2 <= y1:
            continue
        out.append({
            'text': n.get('text', ''), 'desc': n.get('content-desc', ''), 'cls': n.get('class', ''),
            'res': n.get('resource-id', ''), 'checked': n.get('checked') == 'true',
            'checkable': n.get('checkable') == 'true',
            'selected': n.get('selected') == 'true', 'b': (x1, y1, x2, y2),
            'x': (x1 + x2) // 2, 'y': (y1 + y2) // 2,
        })
    return out


def find(label, ns=None, exact=False):
    for n in ns if ns is not None else nodes():
        hay = (n['text'], n['desc'])
        if (label in hay) if exact else any(label in h for h in hay):
            return n
    return None


def tap(x, y, wait=2.0):
    shell(f'input tap {int(x)} {int(y)}')
    time.sleep(wait)


def tap_label(label, wait=2.5, exact=False):
    n = find(label, exact=exact)
    if not n:
        raise RuntimeError(f'not found: {label}')
    tap(n['x'], n['y'], wait)
    return n


def swipe(x1, y1, x2, y2, ms=800, wait=2.0):
    shell(f'input swipe {x1} {y1} {x2} {y2} {ms}')
    time.sleep(wait)


def shot(name):
    with open(os.path.join(OUT, 'shots', name + '.png'), 'wb') as f:
        f.write(adb('exec-out', 'screencap', '-p', text=False, timeout=60))


def cdp(expr):
    r = subprocess.run(['node', os.path.join(S2, 'cdp.mjs'), '9333', expr], capture_output=True, timeout=60)
    out = r.stdout.decode('utf-8', 'replace').strip()
    try:
        return json.loads(out)
    except ValueError:
        return None


def status():
    v = cdp('JSON.stringify(window.__reader.status())')
    return json.loads(v) if isinstance(v, str) else None


def wait_ready(timeout=120, settle=1.0):
    """Waits until the shell finished laying out (and the native side had time to poll it)."""
    t = time.time()
    while time.time() - t < timeout:
        st = status()
        if st and st.get('ready'):
            time.sleep(settle)
            st2 = status()
            if st2 and st2.get('ready'):
                return st2
        time.sleep(1)
    raise RuntimeError('layout not ready')


def style():
    with open(os.path.join(HERE, 'style.js'), encoding='utf-8') as f:
        v = cdp(f.read())
    return json.loads(v) if isinstance(v, str) else None


def prefs():
    return adb('exec-out', 'run-as', PKG, 'cat', f'shared_prefs/{PKG}_preferences.xml')


def ebook_prefs():
    """pref_ebook_* and the imported-font list, as a dict."""
    out = {}
    try:
        root = ET.fromstring(prefs())
    except ET.ParseError:
        return out
    for e in root:
        name = e.get('name', '')
        if name.startswith('pref_ebook_') or name == '__APP_STATE_ebook_fonts':
            out[name] = e.text if e.text is not None else e.get('value')
    return out


def resumed():
    for line in shell('dumpsys activity activities').splitlines():
        if 'mResumedActivity' in line:
            return line.strip()
    return ''


def open_book(manga, chapter):
    """Cold start through the image reader entry point (exercises the hand-off), then DevTools."""
    shell(f'am force-stop {PKG}')
    time.sleep(2)
    shell(f'am start -n {PKG}/eu.kanade.tachiyomi.ui.reader.ReaderActivity --el manga {manga} --el chapter {chapter}')
    t = time.time()
    while 'EbookReaderActivity' not in resumed():
        if time.time() - t > 180:
            raise RuntimeError('reader did not open: ' + resumed())
        time.sleep(3)
    pid = shell(f'pidof {PKG}').strip()
    adb('forward', '--remove-all')
    adb('forward', 'tcp:9333', f'localabstract:webview_devtools_remote_{pid}')
    return wait_ready(settle=2.0)


def wait_for(label, tries=6, exact=True, pause=2.0):
    for _ in range(tries):
        n = find(label, exact=exact)
        if n:
            return n
        time.sleep(pause)
    return None


def open_panel():
    """Centre tap shows the toolbar (after a hit test in the WebView, so it can take a few seconds);
    then the typesetting button. A second centre tap would hide the toolbar again, so it waits instead.
    The first time, the panel can take more than half a minute to appear on a slow emulator."""
    if find('關閉', exact=True):
        return
    for _ in range(3):
        n = find('排版', exact=True)
        if n is None:
            tap(540, 960, 3)
            n = wait_for('排版', tries=4)
        if n is None:
            continue
        tap(n['x'], n['y'], 4)
        if wait_for('關閉', tries=10, pause=3):
            return
    raise RuntimeError('settings panel did not open')


def close_panel():
    n = find('關閉', exact=True)
    if n:
        tap(n['x'], n['y'], 3)


def sliders(ns=None):
    """Slider nodes (Compose sliders are exposed as SeekBar), top to bottom."""
    ns = ns if ns is not None else nodes()
    return [n for n in ns if n['cls'].endswith('SeekBar')]


def slider_after(label, ns=None):
    """The first slider below the node whose text is exactly [label]."""
    ns = ns if ns is not None else nodes()
    lab = next((n for n in ns if n['text'] == label), None)
    if lab is None:
        return None
    below = [s for s in sliders(ns) if s['b'][1] >= lab['b'][1]]
    return min(below, key=lambda s: s['b'][1]) if below else None


def _content_signature(ns):
    inside = [n for n in ns if n['text'] and 1401 <= n['b'][1] < 1794]
    return tuple((n['text'], n['b'][1]) for n in inside[:4])


def reveal_node(pred, tries=16):
    """Scrolls the panel content until pred(nodes) returns a node: forward until the content stops
    moving twice in a row (an end, or a gesture the slow emulator dropped), then backward."""
    direction, last, still = 1, None, 0
    for _ in range(tries):
        ns = nodes()
        hit = pred(ns)
        if hit is not None:
            return hit
        sig = _content_signature(ns)
        still = still + 1 if sig == last else 0
        if still >= 2:
            direction, still = -direction, 0
        last = sig
        scroll_panel(320 * direction)
    return None


def reveal(label, max_bottom=1790, tries=16):
    """Scrolls the panel until a node whose text is exactly [label] ends above [max_bottom]
    (nodes outside the panel, e.g. the level selector, count as visible)."""
    def pred(ns):
        n = next((m for m in ns if m['text'] == label), None)
        if n is not None and n['b'][3] < max_bottom and (n['b'][1] >= 1401 or n['y'] < 1390):
            return n
        return None
    return reveal_node(pred, tries)


def tap_revealed(label, wait=2.5):
    n = reveal(label)
    if n is None:
        raise RuntimeError(f'not found: {label}')
    tap(n['x'], n['y'], wait)
    return n


def switch_for(label, ns=None):
    """The checkable node (a Compose Switch) on the same row as the text [label]."""
    ns = ns if ns is not None else nodes()
    lab = next((n for n in ns if n['text'] == label), None)
    if lab is None:
        return None
    row = [n for n in ns if n['checkable'] and n['b'][1] <= lab['y'] <= n['b'][3] and n['x'] > lab['b'][0]]
    return min(row, key=lambda n: n['b'][2] - n['b'][0]) if row else None


def reveal_slider(label, tries=16):
    """Scrolls the panel until the slider under [label] is fully on screen. uiautomator reports
    nothing below y = 1794 on this device (navigation bar area), and the content starts at about
    y = 1401, so the slider has to be brought into that window."""
    def pred(ns):
        s = slider_after(label, ns)
        return s if s is not None and s['b'][3] < 1790 and s['b'][3] - s['b'][1] > 60 else None
    return reveal_node(pred, tries)


def set_slider(label, fraction, wait=3.0):
    """Taps the slider under [label] at [fraction] of its track (0 = start, 1 = end)."""
    s = reveal_slider(label)
    if s is None:
        raise RuntimeError(f'no slider under {label}')
    x1, y1, x2, y2 = s['b']
    # The material3 slider track spans the node minus half a thumb on each side (thumb is 4 dp wide).
    pad = 2 * 2.625
    x = x1 + pad + fraction * (x2 - x1 - 2 * pad)
    tap(x, (y1 + y2) / 2, wait)


def scroll_panel(dy, wait=2.0):
    """Scrolls the panel content by about [dy] px (negative = back up). The gesture runs along the
    left edge (x = 12): sliders reach x = 27..1053, so a gesture starting elsewhere could press one."""
    top, bottom = 1430, 1770
    if dy >= 0:
        y1, y2 = bottom, max(top, bottom - dy)
    else:
        y1, y2 = top, min(bottom, top - dy)
    swipe(12, y1, 12, y2, 1500, wait)


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'dump'
    if cmd == 'dump':
        for n in nodes():
            label = n['text'] or n['desc'] or n['res'].split('/')[-1]
            flags = ('C' if n['checked'] else '') + ('S' if n['selected'] else '')
            print(f"{n['b']!s:26} {n['cls'].split('.')[-1]:18} {flags:2} {label[:50]!r}")
    elif cmd == 'style':
        print(json.dumps(style(), ensure_ascii=False, indent=1))
