"""Stage 7: the bold switch and the gutter shadow, on the emulator with the debug App (Android 8.0, WebView 69).

  bold <vertical|horizontal>
             From the panel's text tab, 字體加粗 on: the body text of the book document is bold (computed
             font-weight), the reading position is the same character and on the screen, the page changed, the
             value is stored (pref_ebook_bold). After a restart still bold, same character. Then off again: the
             book's own weight comes back.
  gutter     The text reader with two columns: a shadow centred on the gap between the columns (measured on
             the screenshot: the darkest column of the page, which must be in the text-free gap and at the
             centre the shell reports), darkest in the middle and fading out. Switched off from the panel's
             layout tab: gone, also after a restart; on again: back. Left margin 60 and right margin 20: the
             gap moves and the shadow with it. One column: none. Two columns only in landscape: none in
             portrait, there in landscape. A vertical book with two columns. During a curl, the copies of
             the page carry the shadow (frames taken while the turn plays, best effort).
  comic      The image reader, paged left to right, double pages: a test comic whose pages are pink and blue
             is opened; the two merged pages meet at the colour boundary, and the shadow must be there, only
             as high as the image. Zoomed in by a double tap: the boundary moves and the shadow with it. The
             page shown alone (the third): no shadow. Shadow setting off: none.
  cleanup    typesetting and reader settings back to their defaults, portrait.

Usage: ADB=/path/to/adb python3 -I check_stage7.py <step> [<argument>] [<step> ...]
Results: out/stage7/results.jsonl (one JSON line per check); screenshots in out/stage7/shots/.
"""
import io
import json
import os
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage6'))
sys.dont_write_bytecode = True
import check_acceptance as acc  # noqa: E402  (also puts the stage 3-5 helpers on the path)

c = acc.c
d = acc.d
OUT = os.environ['OUT']
SHOTS = os.path.join(OUT, 'shots')
os.makedirs(SHOTS, exist_ok=True)
acc.SHOTS = SHOTS  # acc.capture() saves into this stage's folder
VERT, HORZ = acc.VERT, acc.HORZ
COMIC_WORK = '中縫測試漫畫'
COMIC_FILE = 'seam-pages.cbz'
PINK, BLUE, GREEN = (255, 214, 222), (206, 222, 255), (210, 245, 210)

WEIGHT = """JSON.stringify(Array.prototype.map.call(document.querySelectorAll('#stage iframe'), function (f) {
  var dd = f.contentDocument, p = dd.querySelector('p'), h = dd.querySelector('h1, h2, h3');
  return { p: p ? getComputedStyle(p).fontWeight : null, h: h ? getComputedStyle(h).fontWeight : null }; }))"""

VIEW = 'JSON.stringify({ w: window.innerWidth, h: window.innerHeight })'


# region helpers

def shot(name):
    """Screenshot in colour (saved as shots/<name>.png)."""
    from PIL import Image
    png = d.adb('exec-out', 'screencap', '-p', text=False, timeout=60)
    with open(os.path.join(SHOTS, name + '.png'), 'wb') as f:
        f.write(png)
    return Image.open(io.BytesIO(png)).convert('RGB')


def lum(img):
    import numpy as np
    return np.asarray(img.convert('L'), dtype=np.float32)


def weights():
    v = d.cdp(WEIGHT)
    return json.loads(v) if isinstance(v, str) else None


def is_bold(w):
    return w in ('700', 'bold', '800', '900')


def column_profile(img, y0, y1):
    """Median brightness of every column of the screenshot between rows y0 and y1 (text is a minority of the
    pixels of a column, so the median is the page background, with the shadow where there is one), and the
    darkest pixel of every column (text shows there)."""
    import numpy as np
    a = lum(img)[int(y0):int(y1)]
    return np.median(a, axis=0), a.min(axis=0)


def webview_box():
    """Left and right edge of the WebView on the screen (a navigation bar can take a side in landscape)."""
    n = next((m for m in d.nodes() if m['cls'].endswith('WebView')), None)
    return (n['b'][0], n['b'][2]) if n else None


DENSITY = [None]


def density():
    """Pixels per dp (a CSS px of the reader's page is a dp)."""
    if DENSITY[0] is None:
        out = d.shell('wm density').strip().split()[-1]
        DENSITY[0] = int(out) / 160
    return DENSITY[0]


def gutter_expected(st, width_px, box=None):
    """The centre of the gap in screen pixels, from the shell's status (CSS px) and where the WebView is."""
    if not st or st.get('gutter') is None:
        return None
    left = box[0] if box else 0
    return left + st['gutter'] * density()


def measure_gutter(img, expected, name):
    """Where the shadow is and how dark, around [expected] (or the screen centre)."""
    import numpy as np
    w, h = img.size
    med, darkest = column_profile(img, h * 0.15, h * 0.85)
    centre = int(round(expected if expected is not None else w / 2))
    lo, hi = max(0, centre - 140), min(w, centre + 140)
    window = med[lo:hi]
    x = lo + int(np.argmin(window))
    background = float(np.median(med[:40])) if w > 80 else float(med.max())
    # The text-free gap: columns around the centre without dark text pixels.
    text = darkest < 110
    left = centre
    while left > 0 and not text[left - 1]:
        left -= 1
    right = centre
    while right < w - 1 and not text[right + 1]:
        right += 1
    return {
        'darkest column x': x, 'expected x': expected and round(expected, 1),
        'brightness at the darkest column': round(float(med[x]), 1), 'page background': round(background, 1),
        'brightness 20 / 40 / 80 px left': [round(float(med[max(0, x - k)]), 1) for k in (20, 40, 80)],
        'brightness 20 / 40 / 80 px right': [round(float(med[min(w - 1, x + k)]), 1) for k in (20, 40, 80)],
        'text-free gap': [left, right], 'gap centre': (left + right) / 2, 'shot': name,
    }


def shadow_ok(m, expected, tolerance=3.0):
    """A shadow on the expected line: darker than the page by a clear amount, fading out to both sides."""
    depth = m['page background'] - m['brightness at the darkest column']
    fades = all(m['brightness 20 / 40 / 80 px left'][i] <= m['brightness 20 / 40 / 80 px left'][i + 1] + 1 for i in range(2)) and \
        all(m['brightness 20 / 40 / 80 px right'][i] <= m['brightness 20 / 40 / 80 px right'][i + 1] + 1 for i in range(2))
    placed = expected is None or abs(m['darkest column x'] - expected) <= tolerance
    in_gap = m['text-free gap'][0] <= m['darkest column x'] <= m['text-free gap'][1]
    return depth >= 40 and fades and placed and in_gap


def no_shadow(m):
    return m['page background'] - m['brightness at the darkest column'] < 6


SLOW = 40  # animator duration scale while recording, as in stage 5.5: enough frames of a turn on this emulator


def record_turn(name, keycode, seconds=60):
    """A screen recording (screenrecord) of a page turn started by [keycode], as frames of the screen's size in
    out/<name>-frames/. The animations run [SLOW] times slower meanwhile (the system's animator duration scale,
    which the page turn follows): at normal speed a turn has 3 to 5 frames here, which neither screenshots nor
    the recording caught (stage 7)."""
    import glob
    import shutil
    import subprocess
    from PIL import Image
    w, h = screen_size()
    rw, rh = w // 16 * 16, h // 16 * 16  # video encoders want multiples of 16; frames are scaled back
    d.shell('rm -f /sdcard/turn.mp4')
    d.shell(f'settings put global animator_duration_scale {SLOW}')
    rec = subprocess.Popen([d.ADB, 'shell', 'screenrecord', '--time-limit', str(seconds), '--size', f'{rw}x{rh}',
                            '--bit-rate', '8000000', '/sdcard/turn.mp4'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)
    d.shell(f'input keyevent {keycode}')
    try:
        rec.wait(timeout=seconds + 60)
    except subprocess.TimeoutExpired:
        rec.kill()
    d.shell('settings put global animator_duration_scale 1')
    time.sleep(2)
    video = os.path.join(OUT, name + '.mp4')
    d.adb('pull', '/sdcard/turn.mp4', video, timeout=120)
    folder = os.path.join(OUT, name + '-frames')
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', video, '-vsync', 'passthrough', os.path.join(folder, '%04d.png')], check=False)
    paths = sorted(glob.glob(os.path.join(folder, '*.png')))
    for p in paths:
        img = Image.open(p).convert('RGB')
        if img.size != (w, h):
            img.resize((w, h), Image.BILINEAR).save(p)
    return paths


def between(paths):
    """The frames of a recording that differ from its first and its last frame (the turn playing), with their
    file names."""
    import numpy as np
    from PIL import Image
    if len(paths) < 3:
        return []
    first, last = lum(Image.open(paths[0])), lum(Image.open(paths[-1]))
    out = []
    for p in paths[1:-1]:
        img = Image.open(p).convert('RGB')
        a = lum(img)
        if a.shape == first.shape and np.abs(a - first).mean() > 1.0 and np.abs(a - last).mean() > 1.0:
            out.append((os.path.basename(p), img))
    return out


def dip(img, x, away=60):
    """How much darker column x is than the columns [away] px to its left and right (median over the page rows)."""
    med, _ = column_profile(img, img.size[1] * 0.15, img.size[1] * 0.85)
    x = int(round(x))
    return round(float(med[x - away] - med[x]), 1), round(float(med[x + away] - med[x]), 1)


def panel_layout_tab():
    d.open_panel()
    d.tap_label('版面', exact=True)
    for _ in range(4):
        d.scroll_panel(-500)


def screen_size():
    """Width and height of the screen in the current orientation."""
    out = d.shell('wm size').strip().split()[-1]
    w, h = (int(v) for v in out.split('x'))
    st = d.shell('dumpsys input | grep -m1 SurfaceOrientation').strip()
    rotated = st.endswith('1') or st.endswith('3')
    return (h, w) if rotated else (w, h)


# endregion


def step_bold(which):
    c.STEP[0] = 'bold:' + which
    book = VERT if which == 'vertical' else HORZ
    c.rotate(False)
    acc.reset()
    c.ensure_unread(*book)
    acc.open_at_start(book)
    c.turn(2)
    a = c.pos()
    st = d.status()
    w0 = weights()
    d.open_panel()
    prev = acc.capture(f'bold-{which}-01-panel')
    acc.tap_switch('字體加粗')
    st1 = c.wait_new_layout(st['seq'], 300)
    time.sleep(3)
    b = c.pos()
    vis = c.visible(a['location'])
    w1 = weights()
    img = acc.capture(f'bold-{which}-02-bold')
    prefs = d.ebook_prefs()
    c.check('bold on: stored for all books (pref_ebook_bold)', prefs.get('pref_ebook_bold') == 'true',
            {'pref_ebook_bold': prefs.get('pref_ebook_bold')})
    c.check('bold on: the body text is bold, it was not before',
            bool(w0) and bool(w1) and not is_bold(w0[0]['p']) and all(is_bold(f['p']) for f in w1),
            {'before': w0, 'after': w1})
    c.check('bold on: the reading position is the same character, on the screen',
            bool(b) and b['location'] == a['location'] and any(vis),
            {'page before → after': [st['page'] + 1, st1 and st1['page'] + 1], 'pages': [st['pages'], st1 and st1['pages']],
             'position': b and b['location'], 'visible': vis})
    changed = acc.page_change(prev, img)
    c.check('bold on: the page on the screen changed', changed > 0.01, {'share of the page area': changed})
    d.close_panel()
    c.hide_menu()
    c.leave_reader()
    c.stop_app()
    c.open_book(*book)
    time.sleep(3)
    w2 = weights()
    b = c.pos()
    vis = c.visible(a['location'])
    acc.capture(f'bold-{which}-03-reopened')
    c.check('after a restart: still bold', bool(w2) and all(is_bold(f['p']) for f in w2), w2)
    c.check('after a restart: the same character, on the screen', bool(b) and b['location'] == a['location'] and any(vis),
            {'position': b and b['location'], 'visible': vis})
    st = d.status()
    d.open_panel()
    acc.tap_switch('字體加粗')
    c.wait_new_layout(st['seq'], 300)
    time.sleep(3)
    w3 = weights()
    b = c.pos()
    vis = c.visible(a['location'])
    acc.capture(f'bold-{which}-04-off')
    c.check('bold off: the book\'s own weight again', bool(w3) and w3[0]['p'] == w0[0]['p'], {'before': w0, 'now': w3})
    c.check('bold off: the same character, on the screen', bool(b) and b['location'] == a['location'] and any(vis),
            {'position': b and b['location'], 'visible': vis})
    d.close_panel()
    c.hide_menu()
    c.leave_reader()
    c.stop_app()
    acc.reset()


def open_two_columns(book, extra=None, columns='on'):
    values = {'pref_ebook_page_turn': 'none', 'pref_ebook_columns': columns}
    values.update(extra or {})
    c.set_prefs(values, reset_typesetting=True)
    acc.open_at_start(book)
    time.sleep(3)
    return d.status()


def gutter_check(name, title, expect_shadow, st=None, tolerance=3.0):
    st = st or d.status()
    img = shot(name)
    w, _ = img.size
    box = webview_box()
    expected = gutter_expected(st, w, box)
    m = measure_gutter(img, expected, name)
    m['columns'] = st and st.get('cols')
    m['WebView left / right'] = box
    if expect_shadow:
        c.check(title, expected is not None and shadow_ok(m, expected, tolerance), m)
    else:
        c.check(title, no_shadow(m), m)
    return m


def step_gutter():
    c.STEP[0] = 'gutter'
    c.rotate(False)
    # Two columns in portrait, default margins (20 / 20): the gap is in the middle of the screen.
    st = open_two_columns(HORZ)
    m = gutter_check('gutter-01-horizontal-two-columns', 'two columns: a shadow on the centre of the gap', True, st)
    c.check('two columns: the shadow is in the middle of the screen (same left and right margins)',
            abs(m['darkest column x'] - 540) <= 3, {'darkest column x': m['darkest column x']})
    # Off from the panel, kept after a restart, on again.
    panel_layout_tab()
    acc.tap_switch('中縫陰影')
    d.close_panel()
    c.hide_menu()
    time.sleep(3)
    prefs = d.ebook_prefs()
    c.check('switched off: stored (pref_ebook_gutter_shadow)', prefs.get('pref_ebook_gutter_shadow') == 'false',
            {'pref_ebook_gutter_shadow': prefs.get('pref_ebook_gutter_shadow')})
    gutter_check('gutter-02-off', 'switched off: no shadow', False)
    c.leave_reader()
    c.stop_app()
    c.open_book(*HORZ)
    time.sleep(3)
    gutter_check('gutter-03-off-reopened', 'switched off, after a restart: no shadow', False)
    panel_layout_tab()
    acc.tap_switch('中縫陰影')
    d.close_panel()
    c.hide_menu()
    time.sleep(3)
    gutter_check('gutter-04-on-again', 'switched on again: the shadow is back', True)
    # Page turn with a curl: a screen recording of the turn; the frames between the two pages show the shadow.
    c.leave_reader()
    c.stop_app()
    c.set_prefs({'pref_ebook_page_turn': 'curl'})
    c.open_book(*HORZ)
    time.sleep(3)
    st = d.status()
    frames = record_turn('gutter-06-curl', 93)  # page down
    time.sleep(3)
    mid = between(frames)
    expected = gutter_expected(st, 1080)
    dips = [(n, dip(f, expected)) for n, f in mid]
    for n, f in mid[:3]:
        f.save(os.path.join(SHOTS, 'gutter-06-curl-' + n))
    dark = [n for n, (a, b) in dips if a >= 10 and b >= 10]
    c.check('curl: in most recorded frames while the turn played (at least 60 %), the centre line is darker than 60 px '
            'to each side (the fold\'s own shading can come near the line)',
            bool(dips) and len(dark) >= 0.6 * len(dips),
            {'frames recorded': len(frames), 'frames between the two pages': len(mid), 'centre x': expected,
             'frames with the darker line': len(dark), 'darker by (left, right)': dips[:40]})
    gutter_check('gutter-07-after-curl', 'curl: after the turn the shadow is there', True)
    # Margins 60 / 20: the gap and the shadow move right by (60 - 20) / 2 dp.
    c.leave_reader()
    c.stop_app()
    st = open_two_columns(HORZ, {'pref_ebook_marginLeft': '60', 'pref_ebook_marginRight': '20'})
    m = gutter_check('gutter-08-margins-60-20', 'left margin 60, right 20: the shadow follows the gap', True, st)
    view = json.loads(d.cdp(VIEW) or '{}')
    formula = (view.get('w', 0) + 60 - 20) / 2
    c.check('left margin 60, right 20: the gap centre the shell reports is (width + 60 - 20) / 2 CSS px',
            st is not None and abs((st.get('gutter') or 0) - formula) <= 0.5, {'shell': st and st.get('gutter'), 'formula': formula})
    # One column: none.
    c.leave_reader()
    c.stop_app()
    st = open_two_columns(HORZ, columns='off')
    gutter_check('gutter-09-one-column', 'one column: no shadow', False, st)
    # Two columns only in landscape.
    c.leave_reader()
    c.stop_app()
    st = open_two_columns(HORZ, columns='landscape')
    gutter_check('gutter-10-landscape-setting-portrait', 'two columns in landscape only, portrait: no shadow', False, st)
    c.rotate(True)
    st = c.wait_new_layout(st['seq'], 300)
    time.sleep(5)
    gutter_check('gutter-11-landscape', 'landscape: two columns and the shadow on the gap', True, st)
    st0 = d.status()
    c.rotate(False)
    st = c.wait_new_layout(st0['seq'], 300)
    time.sleep(5)
    gutter_check('gutter-12-back-to-portrait', 'back to portrait: one column, no shadow', False, st)
    # A vertical book with two columns.
    c.leave_reader()
    c.stop_app()
    st = open_two_columns(VERT)
    gutter_check('gutter-13-vertical-two-columns', 'vertical book, two columns: a shadow on the centre of the gap', True, st)
    c.leave_reader()
    c.stop_app()
    acc.reset()


def make_comic(path):
    """Three 800 x 1200 pages: pink, blue, green, each with a dark frame and its number (drawn here)."""
    from PIL import Image, ImageDraw
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_STORED) as z:
        for i, colour in enumerate((PINK, BLUE, GREEN), start=1):
            img = Image.new('RGB', (800, 1200), colour)
            g = ImageDraw.Draw(img)
            g.rectangle((60, 60, 740, 1140), outline=(60, 60, 60), width=6)
            for k in range(6):
                y = 200 + k * 150
                g.rectangle((120, y, 680, y + 40), fill=tuple(max(0, v - 90) for v in colour))
            g.text((380, 1000), str(i), fill=(0, 0, 0))
            buf = io.BytesIO()
            img.save(buf, 'PNG')
            z.writestr(f'{i:03d}.png', buf.getvalue())


def boundary(img, y):
    """x where the pink page meets the blue one on row y: pink has more red than blue, the blue page more blue
    than red (also where the shadow darkens them)."""
    row = [img.getpixel((x, int(y))) for x in range(img.size[0])]
    sign = [(p[0] - p[2]) for p in row]
    # The merged image is a JPEG: its colours blur over a few pixels at the boundary.
    out = []
    for x in range(1, len(row)):
        if sign[x] < -10 and sign[x - 1] >= -10:
            left = next((k for k in range(x - 1, max(-1, x - 7), -1) if sign[k] > 10), None)
            if left is not None:
                out.append((left + x + 1) // 2)
    return out


def comic_measure(img, name, seam):
    """The shadow on column [seam] of the image: brightness 2 px from the seam against 120 px away on the same
    page, along the image's rows (median of the ratios)."""
    import numpy as np
    a = lum(img)
    w, h = img.size
    rows = [y for y in range(int(h * 0.3), int(h * 0.7), 4)]
    lefts = [a[y, seam - 2] / max(1.0, a[y, seam - 120]) for y in rows]
    rights = [a[y, min(w - 1, seam + 2)] / max(1.0, a[y, min(w - 1, seam + 120)]) for y in rows]
    return {'seam x': seam, 'darkening left of the seam (ratio)': round(float(np.median(lefts)), 3),
            'darkening right of the seam (ratio)': round(float(np.median(rights)), 3), 'shot': name}


def shadowed(m):
    return m['darkening left of the seam (ratio)'] < 0.85 and m['darkening right of the seam (ratio)'] < 0.85


def unshadowed(m):
    return m['darkening left of the seam (ratio)'] > 0.97 and m['darkening right of the seam (ratio)'] > 0.97


def image_rows(img, x):
    """Top and bottom rows of the image on column x (pixels close to pink or blue)."""
    ys = [y for y in range(img.size[1]) if min(sum((a - b) ** 2 for a, b in zip(img.getpixel((x, y)), col)) for col in (PINK, BLUE)) < 900]
    return (ys[0], ys[-1]) if ys else (None, None)


COMIC_IDS = [None, None]


def focused():
    return d.shell('dumpsys window windows | grep -m1 mCurrentFocus')


def open_comic():
    """Starts the image reader on the test comic and waits until its window has the focus: a key sent while the
    reader was still starting up made Android report the App as not responding (stage 7, first run)."""
    manga, chapter = COMIC_IDS
    acc.start_reader(manga, chapter)
    t = time.time()
    while time.time() - t < 150 and not (c.IMAGE_READER in d.resumed() and 'ReaderActivity' in focused()):
        time.sleep(3)
    time.sleep(5)
    c.clear_dialogs()


def spread_shot(name, timeout=150):
    """A screenshot with the two merged pages, and their boundary on the middle row (None when not shown). Merging
    the two pages takes more than half a minute on this emulator, so the screen is taken again until they show."""
    t = time.time()
    while True:
        img = shot(name)
        xs = boundary(img, img.size[1] / 2)
        if xs or time.time() - t > timeout:
            return img, (xs[0] if xs else None), xs
        c.clear_dialogs()
        time.sleep(6)


def single_shot(name, timeout=150):
    """A screenshot once the green third page shows."""
    t = time.time()
    while True:
        img = shot(name)
        w, h = img.size
        if sum((p - q) ** 2 for p, q in zip(img.getpixel((w // 2, h // 2)), GREEN)) < 2500 or time.time() - t > timeout:
            return img
        time.sleep(6)


def step_comic():
    c.STEP[0] = 'comic'
    c.rotate(False)
    path = os.path.join(OUT, COMIC_FILE)
    make_comic(path)
    folder = f'{acc.LOCAL}/{COMIC_WORK}'
    d.shell(f'mkdir -p "{folder}"')
    d.adb('push', path, f'{folder}/{COMIC_FILE}')
    base = {'pref_default_reading_mode_key': 1, 'page_layout': 1, 'pref_reader_theme_key': 0, 'pref_bookmania_pager_curl': False,
            'pref_bookmania_pager_gutter_shadow': None, 'pref_image_scale_type_key': 1, 'pref_zoom_start_key': 1}
    c.set_prefs(base)
    ids = ids_of(COMIC_WORK, COMIC_FILE)  # listed already by an earlier run
    opened = None
    if ids is None:
        opened = acc.open_new_work(COMIC_WORK)
        ids = ids_of(COMIC_WORK, COMIC_FILE)
    c.check('the test comic is listed as a chapter of a new work', ids is not None, {'ids': ids, 'work page shown': opened})
    if ids is None:
        return
    COMIC_IDS[:] = ids

    # Fit screen: the two pages side by side, the seam in the middle of the screen.
    open_comic()
    img, seam, xs = spread_shot('comic-01-double-pages', timeout=90)
    if seam is None:  # the reader opens on the page read last: back to the first two pages
        c.key(21, 8)
        img, seam, xs = spread_shot('comic-01-double-pages')
    w, h = img.size
    c.note(f'pink/blue boundaries on the middle row: {xs}')
    if seam is None:
        c.check('double pages: the two pages are shown side by side', False, {'shot': 'comic-01-double-pages'})
        return
    m = comic_measure(img, 'comic-01-double-pages', seam)
    top, bottom = image_rows(img, seam - 60)
    m['image rows'] = [top, bottom]
    c.check('double pages, fit screen: the shadow is on the seam, in the middle of the screen', shadowed(m) and abs(seam - w / 2) <= 3, m)
    if top is not None and top > 40:
        a = lum(img)
        above = max(abs(float(a[y, seam]) - float(a[y, seam - 120])) for y in range(top - 30, top - 5))
        below = max(abs(float(a[y, seam]) - float(a[y, seam - 120])) for y in range(bottom + 5, min(h, bottom + 30)))
        c.check('double pages: no shadow above or below the image', above < 4 and below < 4,
                {'largest difference above / below': [above, below], 'image rows': [top, bottom]})

    # Curl (if on): frames while the turn to the next page plays carry the shadow; then the third page alone.
    c.stop_app(2)
    c.set_prefs({'pref_bookmania_pager_curl': True})
    open_comic()
    spread_shot('comic-02-before-curl')
    frames = record_turn('comic-03-curl', 22)  # right arrow: the next page in left to right
    time.sleep(4)
    single = single_shot('comic-04-single-page')
    mid = between(frames)
    marks = []
    for n, f in mid:
        xs2 = boundary(f, f.size[1] / 2)
        if xs2 and 130 < xs2[0] < f.size[0] - 130:
            marks.append((n, comic_measure(f, n, xs2[0])))
    for n, f in mid[:3]:
        f.save(os.path.join(SHOTS, 'comic-03-curl-' + n))
    shaded = [n for n, m in marks if shadowed(m)]
    c.check('curl: in most recorded frames while the turn played (at least 60 %) where both pages show, the shadow is '
            'where the pink and blue pages meet',
            bool(marks) and len(shaded) >= 0.6 * len(marks),
            {'frames recorded': len(frames), 'frames between the pages': len(mid), 'frames with both pages': len(marks),
             'frames with the shadow': len(shaded),
             'measurements': [(n, m['seam x'], m['darkening left of the seam (ratio)'], m['darkening right of the seam (ratio)']) for n, m in marks[:40]]})
    a = lum(single)
    x = w // 2
    rows = [y for y in range(int(h * 0.3), int(h * 0.7), 4) if abs(int(a[y, x - 120]) - int(a[y, x + 120])) < 3]
    diff = max((abs(float(a[y, x]) - float(a[y, x - 120])) for y in rows), default=999)
    green = sum((p - q) ** 2 for p, q in zip(single.getpixel((x, h // 2)), GREEN)) < 2500
    c.check('the third page shown alone: no shadow in the middle', green and diff < 6,
            {'green page shown': green, 'largest difference': diff, 'rows compared': len(rows)})

    # Original size, zoom start left: the seam is not in the middle of the screen; then the image is moved.
    c.stop_app(2)
    c.set_prefs({'pref_bookmania_pager_curl': False, 'pref_image_scale_type_key': 5, 'pref_zoom_start_key': 2})
    open_comic()
    c.key(21, 8)  # left arrow: back to the two pages (the reader opens on the page read last)
    img, seam, xs = spread_shot('comic-05-original-size')
    if seam is None:
        c.check('original size: the two pages are shown', False, {'boundaries': xs})
    else:
        m = comic_measure(img, 'comic-05-original-size', seam)
        c.check('original size: the seam is away from the middle of the screen and the shadow is on it',
                shadowed(m) and abs(seam - w / 2) > 100, m)
        d.swipe(900, 1300, 600, 1300, 1500, 5)  # drag the image to the left
        img, seam2, xs2 = spread_shot('comic-06-moved')
        if seam2 is None or seam2 == seam:
            c.check('moved: the seam moved', False, {'before': seam, 'boundaries now': xs2})
        else:
            m2 = comic_measure(img, 'comic-06-moved', seam2)
            m2['seam before'] = seam
            c.check('moved: the seam moved and the shadow went with it', shadowed(m2), m2)

    # Setting off: no shadow.
    c.stop_app(2)
    c.set_prefs({'pref_bookmania_pager_gutter_shadow': False, 'pref_image_scale_type_key': 1, 'pref_zoom_start_key': 1})
    open_comic()
    img, seam, xs = spread_shot('comic-07-setting-off')
    if seam is None:
        c.key(21, 8)
        img, seam, xs = spread_shot('comic-07-setting-off')
    if seam is None:
        c.check('setting off: the two pages are shown', False, {'boundaries': xs})
    else:
        m = comic_measure(img, 'comic-07-setting-off', seam)
        c.check('setting off: no shadow on the seam', unshadowed(m), m)
    c.stop_app(2)
    c.set_prefs(base)


def step_settings_ui():
    """Settings > 閱讀 lists 中縫陰影 after 捲曲翻頁; tapping it stores the new value."""
    c.STEP[0] = 'settings-ui'
    c.rotate(False)
    c.stop_app(0)
    d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity')
    time.sleep(6)
    c.wait_app_drawn()
    time.sleep(3)
    c.clear_dialogs()
    for label in ('其他', '設定'):
        d.tap_label(label, wait=3, exact=True)
    for _ in range(3):
        n = d.find('閱讀', exact=True)
        if n:
            d.tap(n['x'], n['y'], 4)
        if not any(x['text'] in ('下載', '探索') for x in d.nodes()):
            break
    found = curl = None
    for _ in range(6):
        ns = d.nodes()
        found = next((n for n in ns if n['text'] == '中縫陰影'), None)
        curl = next((n for n in ns if n['text'] == '捲曲翻頁'), None)
        if found:
            break
        d.swipe(540, 1500, 540, 900, ms=1200, wait=2)
    acc.capture('settings-reader')
    summary = next((n for n in d.nodes() if n['text'].startswith('雙頁模式中')), None)
    c.check('Settings > 閱讀 has 中縫陰影 right after 捲曲翻頁, with its summary',
            found is not None and curl is not None and 0 < found['y'] - curl['y'] < 400 and summary is not None,
            {'中縫陰影': found and found['b'], '捲曲翻頁': curl and curl['b'], 'summary': summary and summary['text']})
    if found:
        d.tap(found['x'], found['y'], 3)
    c.stop_app()
    c.check('the switch (on by default) stores pref_bookmania_pager_gutter_shadow = false',
            'name="pref_bookmania_pager_gutter_shadow" value="false"' in d.prefs(), None)
    c.set_prefs({'pref_bookmania_pager_gutter_shadow': None})


def ids_of(work, file):
    """Manga and chapter ids of [file] in the Local Source work [work], from the App's database."""
    c.stop_app(3)
    con = c.pull_db('tachiyomi.db')
    try:
        row = con.execute('SELECT _id FROM mangas WHERE title = ?', (work,)).fetchone()
        manga = row[0] if row else None
        r = con.execute('SELECT _id FROM chapters WHERE manga_id = ? AND url LIKE ?', (manga, '%' + file)).fetchone() if manga else None
    finally:
        con.close()
    return [manga, r[0]] if r else None


def step_cleanup():
    c.STEP[0] = 'cleanup'
    c.rotate(False)
    c.set_prefs({'pref_default_reading_mode_key': None, 'page_layout': None, 'pref_reader_theme_key': None,
                 'pref_bookmania_pager_gutter_shadow': None, 'pref_bookmania_pager_curl': None, 'pref_image_scale_type_key': None,
                 'pref_zoom_start_key': None, 'pref_ebook_page_turn': None}, reset_typesetting=True)
    c.note('typesetting and reader settings back to their defaults')


def main():
    args = sys.argv[1:]
    steps = {'bold': step_bold, 'gutter': step_gutter, 'comic': step_comic, 'settings-ui': step_settings_ui,
             'cleanup': step_cleanup}
    i = 0
    while i < len(args):
        name = args[i]
        fn = steps[name]
        call = (lambda: fn(args[i + 1])) if name == 'bold' else fn
        try:
            call()
        except Exception as e:  # recorded, and the next step still runs
            import traceback
            c.check(f'{name}: the step ran to its end', False, {'error': repr(e), 'trace': traceback.format_exc()[-1500:]})
            try:
                acc.capture(f'error-{name}')
            except Exception:
                pass
        i += 2 if name == 'bold' else 1


if __name__ == '__main__':
    main()
