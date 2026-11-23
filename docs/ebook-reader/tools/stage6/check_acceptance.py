"""Stage 6: checks for section 8 of the task (acceptance criteria) that the earlier stages and the regression
did not cover, on the emulator with the debug App (Android 8.0, WebView 69).

  fonts      item 5: a font imported through the panel and the system file picker becomes the font of the
             body text in a horizontal and in a vertical book: the text's font-family, the font loaded in
             the book document, Latin text measured with it differs from the system font, and the page on
             the screen changed. After a restart the font is still used.
  glyphs     item 6: vertical pages (Chinese and Japanese) with the book's font and with the imported font,
             kept as screenshots, for looking at punctuation, digits and Latin letters by eye.
  positions  items 4 and 8: a book is opened in the middle of its first document, then every setting of
             task section 2.3 (items 1-9) is changed through the panel, one after another. After each
             change: the reading position is still the character that began the page before the first
             change, and that character is fully on the screen (the page number changes); the setting
             reached the book (CSS, layout mode, columns); the page area of the screen changed. Then the
             reader is left, the App stopped and the book opened again: every setting is kept and the
             character is on the screen; then the screen is turned to landscape and back.
             `positions vertical` (the writing mode goes to horizontal) and `positions horizontal`
             (the writing mode goes to vertical).
  visible    item 4, for the two changes the open panel hid in the horizontal book (bottom margin, paragraph
             spacing at the page's lower edge): the page before the panel opened and after it closed again.
  corrupt    item 3: damaged MOBI and AZW3 files (cut short, and a text file named .mobi), in a work of their
             own opened from Browse, and the two damaged EPUBs of stage 2 must show the App's message in the
             text reader without a crash.
  cleanup    imported fonts and typesetting settings removed, portrait.

Usage: ADB=/path/to/adb python3 -I check_acceptance.py <step> [<argument>] [<step> ...]
Results: out/acceptance/results.jsonl (one JSON line per check); screenshots in out/acceptance/shots/.
The page turn animation is set to "none" here (it has no part in the layout), so that turning to the
middle of a document is quick on this slow emulator.
"""
import io
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out', 'acceptance'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage5'))
import check_stage5 as c  # noqa: E402  (puts ../stage3 and ../stage4 on the path)
from verify_columns import start_at_beginning  # noqa: E402

d = c.d
OUT = os.environ['OUT']
SHOTS = os.path.join(OUT, 'shots')
os.makedirs(SHOTS, exist_ok=True)
VERT, HORZ, JA, DAMAGED = (14, 16), (8, 10), (15, 17), 6
FONT_FILE = 'NotoSerifCJKtc-Bold.otf'  # in the emulator's Download folder since stage 3
FAMILY = 'BookmaniaUserFont'           # the family name the shell gives an imported font
LOCAL = f'/sdcard/Android/data/{d.PKG}/files/local'
FIXTURES = os.path.normpath(os.path.join(HERE, '..', '..', '..', '..', 'core', 'ebook', 'src', 'test', 'resources', 'fixtures'))

MEASURE = """(function (fam) {
  var f = document.querySelector('#stage iframe'), dd = f.contentDocument;
  var ctx = dd.createElement('canvas').getContext('2d'), s = 'WebView 2026 Bookmania';
  ctx.font = '40px ' + fam; var a = ctx.measureText(s).width;
  ctx.font = '40px sans-serif'; var b = ctx.measureText(s).width;
  return JSON.stringify({ imported: a, system: b, loaded: dd.fonts ? dd.fonts.check('40px ' + fam) : null });
})(%s)"""

FRAMES = """JSON.stringify(Array.prototype.map.call(document.querySelectorAll('#stage iframe'), function (f) {
  var r = f.getBoundingClientRect(); return [f.style.visibility !== 'hidden', r.left, r.top, r.right, r.bottom]; }))"""


# region helpers

def capture(name):
    """Screenshot saved as shots/<name>.png; returned in grey for comparisons."""
    from PIL import Image
    png = d.adb('exec-out', 'screencap', '-p', text=False, timeout=60)
    with open(os.path.join(SHOTS, name + '.png'), 'wb') as f:
        f.write(png)
    return Image.open(io.BytesIO(png)).convert('L')


def page_change(a, b, top=0.12, bottom=0.66):
    """Share of the page area (below the toolbar, above the panel in portrait) whose brightness changed."""
    import numpy as np
    w, h = a.size
    box = (0, int(h * top), w, int(h * bottom))
    size = ((box[2] - box[0]) // 4, (box[3] - box[1]) // 4)
    x = np.asarray(a.crop(box).resize(size), dtype=np.int16)
    y = np.asarray(b.crop(box).resize(size), dtype=np.int16)
    return round(float((abs(x - y) > 30).mean()), 4)


def num(v):
    try:
        return float(str(v).replace('px', ''))
    except (TypeError, ValueError):
        return None


def near(a, b, eps=0.6):
    return a is not None and b is not None and abs(a - b) <= eps


def fonts_list():
    return json.loads(d.ebook_prefs().get('__APP_STATE_ebook_fonts') or '[]')


def measure():
    v = d.cdp(MEASURE % json.dumps(FAMILY))
    return json.loads(v) if isinstance(v, str) else None


def frames():
    v = d.cdp(FRAMES)
    return [f for f in (json.loads(v) if isinstance(v, str) else []) if f[0]]


def font_used(s):
    return bool(s) and FAMILY in (s['p']['fontFamily'] or '') and f'{FAMILY}:loaded' in s['faces']


def reset(font_list=True):
    """Default typesetting, no page turn animation; [font_list] False also removes the imported fonts."""
    values = {'pref_ebook_page_turn': 'none'}
    if not font_list:
        values['__APP_STATE_ebook_fonts'] = None
    c.set_prefs(values, reset_typesetting=True)
    if not font_list:
        d.shell(f'run-as {d.PKG} rm -rf files/ebook-fonts')


def open_at_start(book):
    c.stop_app(0)
    start_at_beginning(book[1])
    c.open_book(*book)


def import_font():
    """From the panel's text tab: 匯入字型… → the system file picker → Downloads → the font file. The picker
    lists the newest files first, in a grid; newer test files had pushed the font out of view (stage 6), so
    the list view is chosen and the list scrolled until the file shows."""
    n = None
    for _ in range(4):
        n = d.find('匯入字型', exact=False)
        if n:
            break
        d.scroll_panel(400)
    if n is None:
        raise RuntimeError('import button not found')
    d.tap(n['x'], n['y'], 6)
    t = time.time()
    while 'documentsui' not in d.resumed():
        if time.time() - t > 60:
            raise RuntimeError('picker did not open: ' + d.resumed())
        time.sleep(2)
    time.sleep(4)
    if not d.find('Downloads', exact=True):
        roots = d.find('Show roots', exact=True)
        if roots:
            d.tap(roots['x'], roots['y'], 3)
        if d.find('Downloads', exact=True):
            d.tap_label('Downloads', exact=True, wait=5)
    view = d.find('List view', exact=True)
    if view:
        d.tap(view['x'], view['y'], 3)
    for _ in range(10):
        f = d.find(FONT_FILE, exact=True)
        if f:
            capture('fonts-0-picker')
            d.tap(f['x'], f['y'], 8)
            return True
        d.swipe(540, 1500, 540, 800, 800, 2)
    capture('fonts-0-picker-not-found')
    d.shell('input keyevent 4')
    return False

# endregion

# region item 5: imported font


def step_fonts():
    c.STEP[0] = 'fonts'
    c.rotate(False)
    reset(font_list=False)
    before = {}
    for label, book in (('vertical', VERT), ('horizontal', HORZ)):
        open_at_start(book)
        s = d.style()
        c.check(f'{label} book before the import: the book\'s own font', not font_used(s), s and s['p']['fontFamily'])
        before[label] = capture(f'fonts-{label}-1-book-font')
    d.open_panel()  # the horizontal book is open
    if not c.check('the font file is chosen in the system file picker', import_font()):
        return
    fonts, t = [], time.time()
    while time.time() - t < 180 and not fonts:
        time.sleep(3)
        fonts = fonts_list()
    files = d.shell(f'run-as {d.PKG} ls -l files/ebook-fonts')
    c.check('the font is imported through the picker (font list, file in the App storage)',
            len(fonts) == 1 and '.otf' in files, {'fonts': fonts, 'files': files.strip()})
    if not fonts:
        return
    row = d.reveal(fonts[0]['name'])
    st0 = d.status()
    d.tap(row['x'], row['y'], 2)
    c.wait_new_layout(st0['seq'], 300)
    time.sleep(3)
    d.close_panel()
    c.hide_menu()
    time.sleep(3)
    for label, book in (('horizontal', HORZ), ('vertical', VERT)):
        if label == 'vertical':
            open_at_start(book)
        s = d.style()
        m = measure()
        after = capture(f'fonts-{label}-2-imported-font')
        changed = page_change(before[label], after, 0.05, 0.92)
        c.check(f'{label} book: the body text uses the imported font',
                font_used(s) and bool(m) and m['loaded'] and abs(m['imported'] - m['system']) > 1 and changed > 0.01,
                {'mode': s and s['st']['mode'], 'font-family': s and s['p']['fontFamily'], 'faces': s and s['faces'],
                 'Latin text width (40px): imported / system': m and [round(m['imported'], 1), round(m['system'], 1)],
                 'share of the page that changed': changed, 'text': s and s['vis'][:40]})
    open_at_start(HORZ)
    s = d.style()
    c.check('after a restart: the imported font is still used (horizontal book)', font_used(s), s and s['faces'])
    c.leave_reader()
    c.stop_app()

# endregion

# region item 6: vertical glyphs


def step_glyphs():
    c.STEP[0] = 'glyphs'
    c.rotate(False)
    fonts = fonts_list()
    if not c.check('an imported font is available (run "fonts" first)', bool(fonts), fonts):
        return
    for font_label, font in (('book-font', None), ('imported-font', fonts[0]['id'])):
        reset()
        if font:
            c.set_prefs({'pref_ebook_font': font})
        for label, book, pages in (('zh', VERT, 3), ('ja', JA, 2)):
            open_at_start(book)
            for p in range(pages):
                if p:
                    c.turn(1)
                s = d.style()
                capture(f'glyphs-{label}-{font_label}-p{p + 1}')
                c.check(f'{label} page {p + 1}, {font_label}: vertical page shown',
                        bool(s) and s['st']['mode'] == 'V' and (font_used(s) if font else not font_used(s)),
                        {'font-family': s and s['p']['fontFamily'], 'text': s and s['vis'][:60]})
    reset()

# endregion

# region items 4 and 8: every setting, the reading position, a restart, rotation


def margins_ok(s, prefs):
    """The page frames span the window minus the margins (each frame reaches 8 px into the margin)."""
    w, h = s['win']
    fr = frames()
    m = {k: int(prefs.get('pref_ebook_margin' + k, dflt)) for k, dflt in (('Top', 32), ('Bottom', 32), ('Left', 20), ('Right', 20))}
    if not fr:
        return False, {'frames': fr}
    left, top = min(f[1] for f in fr), min(f[2] for f in fr)
    right, bottom = max(f[3] for f in fr), max(f[4] for f in fr)
    ok = (near(left, m['Left'] - 8, 1) and near(top, m['Top'] - 8, 1) and near(right, w - m['Right'] + 8, 1)
          and near(bottom, h - m['Bottom'] + 8, 1))
    return ok, {'margins': m, 'frames': [f[1:] for f in fr], 'window': [w, h]}


def expectations(target_mode):
    """name -> function(style, prefs) returning (setting applied, detail)."""
    def size(s, p):
        return s['html']['fontSize'] == f"{p.get('pref_ebook_fontSize')}px" and p.get('pref_ebook_fontSize') != '20', \
            {'stored': p.get('pref_ebook_fontSize'), 'css': s['html']['fontSize']}

    def scaled(key, css):
        def f(s, p):
            v = p.get('pref_ebook_' + key)
            fs = num(s['html']['fontSize'])
            got = num(css(s))
            want = float(v) * fs if v not in (None, 'book') else None
            return near(got, want, 0.6), {'stored': v, 'css': css(s), 'expected px': want}
        return f

    def block_end(s):
        return s['p']['margin'][3] if s['st']['mode'] == 'V' else s['p']['margin'][2]

    return {
        'font': lambda s, p: (font_used(s), {'stored': p.get('pref_ebook_font'), 'font-family': s['p']['fontFamily']}),
        'font size': size,
        'line height': scaled('lineHeight', lambda s: s['body']['lineHeight']),
        'letter spacing': scaled('letterSpacing', lambda s: s['p']['letterSpacing']),
        'first-line indent': scaled('indent', lambda s: s['p']['textIndent']),
        'paragraph spacing': scaled('paragraphSpacing', block_end),
        'margins': margins_ok,
        'writing mode': lambda s, p: (s['st']['mode'] == target_mode, {'stored': p.get('pref_ebook_writingMode'), 'mode': s['st']['mode'],
                                                                         'css': s['html']['writingMode']}),
        'two columns': lambda s, p: (s['st']['cols'] == 2 and p.get('pref_ebook_columns') == 'on',
                                     {'stored': p.get('pref_ebook_columns'), 'columns': s['st']['cols']}),
    }


def tap_switch(label):
    """The switch on the row of [label]; the row is brought well above the panel's lower edge first (right
    after the panel opens, the switch of the last rows can be below what uiautomator reports)."""
    sw = None
    for _ in range(3):
        d.reveal(label, max_bottom=1650)
        sw = d.switch_for(label)
        if sw is not None:
            break
        d.scroll_panel(200)
    if sw is None:
        raise RuntimeError('no switch for ' + label)
    d.tap(sw['x'], sw['y'], 3)


def step_positions(which):
    c.STEP[0] = 'positions:' + which
    book = VERT if which == 'vertical' else HORZ
    target = 'H' if which == 'vertical' else 'V'
    exp = expectations(target)
    fonts = fonts_list()
    c.rotate(False)
    reset()
    c.ensure_unread(*book)
    open_at_start(book)
    c.turn(4)
    a = c.pos()
    st = d.status()
    c.note(f"start: page {st['page'] + 1}/{st['pages']}, position {a}")
    capture(f'pos-{which}-00-start')
    d.open_panel()
    prev = capture(f'pos-{which}-01-panel')
    pages = [st['page'] + 1]
    state = {'st': st, 'prev': prev}

    def after(n, name):
        st1 = c.wait_new_layout(state['st']['seq'], 300)
        time.sleep(3)
        b = c.pos()
        vis = c.visible(a['location'])
        s = d.style()
        img = capture(f'pos-{which}-{n:02d}-{name.replace(" ", "-")}')
        changed = page_change(state['prev'], img)
        prefs = d.ebook_prefs()
        applied, detail = exp[name](s, prefs)
        pages.append(st1 and st1['page'] + 1)
        c.check(f'{name}: the reading position is the same character, on the screen',
                bool(b) and b['location'] == a['location'] and any(vis),
                {'page before → after': [state['st']['page'] + 1, st1 and st1['page'] + 1], 'pages': st1 and st1['pages'],
                 'columns': st1 and st1['cols'], 'visible in frame': vis, 'position': b and b['location'],
                 'text': s and s['vis'][:24]})
        c.check(f'{name}: the setting reached the book', applied, detail)
        c.check(f'{name}: the page on the screen changed', changed > 0.01, {'share of the page area': changed})
        state['st'], state['prev'] = st1 or state['st'], img

    # Text tab
    if fonts:
        row = d.reveal(fonts[0]['name'])
        d.tap(row['x'], row['y'], 2)
    else:
        d.tap_revealed('系統無襯線')
    after(2, 'font')
    d.set_slider('字級', (26 - 12) / 36)
    after(3, 'font size')
    d.set_slider('行距', (2.2 - 1.0) / 2.0)
    after(4, 'line height')
    d.set_slider('字距', 0.1 / 0.5)
    after(5, 'letter spacing')
    tap_switch('首行縮排')  # "follow the book" off: 2 characters
    after(6, 'first-line indent')
    tap_switch('段落間距')  # "follow the book" off: 0.5 em
    after(7, 'paragraph spacing')
    # Layout tab
    d.tap_label('版面', exact=True)
    for n, (label, value) in enumerate((('上', 60), ('下', 60), ('左', 40), ('右', 40))):
        d.set_slider(label, value / 120)
        after(8 + n, 'margins')
    for _ in range(5):  # back to the top of the layout tab (writing mode, page direction, columns, margins)
        d.scroll_panel(-500)
    d.tap_revealed('橫書' if target == 'H' else '直書')
    after(12, 'writing mode')
    d.tap_revealed('開啟')
    after(13, 'two columns')
    d.close_panel()
    c.hide_menu()
    time.sleep(3)
    vis = c.visible(a['location'])
    capture(f'pos-{which}-14-panel-closed')
    c.check('panel closed: the character is on the screen', any(vis), vis)
    c.note(f'pages (1-based) after each change: {pages}')

    # Close and open again: every setting kept, same passage.
    c.leave_reader()
    c.stop_app()
    c.open_book(*book)
    time.sleep(3)
    s = d.style()
    prefs = d.ebook_prefs()
    b = c.pos()
    vis = c.visible(a['location'])
    capture(f'pos-{which}-15-reopened')
    kept = {name: f(s, prefs) for name, f in exp.items()}
    c.check('after a restart: every setting is kept and applied', all(v[0] for v in kept.values()),
            {k: v for k, v in kept.items()})
    c.check('after a restart: the reading position is the same character, on the screen',
            bool(b) and b['location'] == a['location'] and any(vis), {'position': b and b['location'], 'visible': vis,
                                                                        'page': s['st']['page'] + 1, 'pages': s['st']['pages']})
    # Rotation and back.
    for n, landscape in ((16, True), (17, False)):
        st0 = d.status()
        c.rotate(landscape)
        st1 = c.wait_new_layout(st0['seq'], 300)
        time.sleep(5)
        b = c.pos()
        vis = c.visible(a['location'])
        capture(f'pos-{which}-{n}-{"landscape" if landscape else "portrait"}')
        c.check(f'turned to {"landscape" if landscape else "portrait"}: the same character, on the screen',
                bool(b) and b['location'] == a['location'] and any(vis),
                {'page': st1 and st1['page'] + 1, 'pages': st1 and st1['pages'], 'columns': st1 and st1['cols'], 'visible': vis})
    c.leave_reader()
    c.stop_app()
    reset()

def step_visible():
    """Item 4, for two changes the "positions" step could not see: in the horizontal book the lower part of the
    page is under the open panel, where the bottom margin and (on that page) the paragraph spacing act. The page
    is compared before the panel opens and after it is closed again (the menu hidden both times)."""
    c.STEP[0] = 'visible'
    c.rotate(False)

    def bottom_margin():
        d.tap_label('版面', exact=True)
        d.set_slider('下', 60 / 120)

    for slug, name, action in (('paragraph-spacing', 'paragraph spacing', lambda: tap_switch('段落間距')),
                               ('bottom-margin', 'bottom margin', bottom_margin)):
        reset()
        open_at_start(HORZ)
        c.turn(4)
        time.sleep(3)
        before = capture(f'visible-{slug}-1-before')
        st = d.status()
        d.open_panel()
        action()
        st1 = c.wait_new_layout(st['seq'], 300)
        time.sleep(3)
        d.close_panel()
        time.sleep(2)
        c.hide_menu()
        time.sleep(3)
        after = capture(f'visible-{slug}-2-after')
        changed = page_change(before, after, 0.0, 1.0)
        c.check(f'{name}: with the panel closed again, the page on the screen changed', changed > 0.01,
                {'share of the screen': changed, 'page before → after': [st['page'] + 1, st1 and st1['page'] + 1],
                 'stored': {k: v for k, v in d.ebook_prefs().items() if k in ('pref_ebook_paragraphSpacing', 'pref_ebook_marginBottom')}})
        c.leave_reader()
        c.stop_app()
    reset()

# endregion

# region item 3: damaged files


def screen_texts():
    return [n['text'] or n['desc'] for n in d.nodes() if n['text'] or n['desc']]


def crashes():
    log = d.shell('logcat -d -b crash')
    return [ln for ln in log.splitlines() if 'FATAL EXCEPTION' in ln or 'Fatal signal' in ln]


def start_reader(manga, chapter):
    d.shell(f'am force-stop {d.PKG}')
    d.shell('logcat -c; logcat -b crash -c')
    time.sleep(2)
    d.shell(f'am start -n {d.PKG}/{c.IMAGE_READER} --el manga {manga} --el chapter {chapter}')


DAMAGED_WORK = '損毀檔 MOBI'  # a work folder of its own: an existing work only lists new files after a pull to
                              # refresh, which `input swipe` did not trigger on this emulator


def open_new_work(title):
    """Browse > 本機來源 > the work: a work opened for the first time lists its files as chapters."""
    c.stop_app(0)
    d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity')
    time.sleep(6)
    c.wait_app_drawn()
    time.sleep(4)
    c.clear_dialogs()
    for labels, wait in ((('探索',), 5), (('本機來源', 'Local source'), 10)):  # the source's name is not translated
        n = next((m for m in (d.find(x, exact=True) for x in labels) if m), None)
        if n is None:
            capture('corrupt-0-no-' + labels[0])
            return False
        d.tap(n['x'], n['y'], wait)
    for _ in range(8):
        n = d.find(title, exact=True)
        if n:
            d.tap(n['x'], n['y'], 30)
            capture('corrupt-0-work-page')
            return True
        d.swipe(540, 1500, 540, 700, 800, 3)
    capture('corrupt-0-work-not-found')
    return False


def step_corrupt():
    c.STEP[0] = 'corrupt'
    c.rotate(False)
    made = {}
    folder = f'{LOCAL}/{DAMAGED_WORK}'
    d.shell(f"mkdir -p '{folder}'")
    for name, src, cut in (('corrupt-truncated.mobi', 'zh-horizontal-mobi6.mobi', 0.45),
                           ('corrupt-truncated.azw3', 'zh-horizontal.azw3', 0.45),
                           ('not-an-ebook.mobi', None, None)):
        if src:
            with open(os.path.join(FIXTURES, src), 'rb') as f:
                data = f.read()
            data = data[:int(len(data) * cut)]
        else:
            data = ('這不是電子書。This is not an e-book.\n' * 200).encode('utf-8')
        path = os.path.join(OUT, name)
        with open(path, 'wb') as f:
            f.write(data)
        d.adb('push', path, f'{folder}/{name}')
        made[name] = len(data)
    c.note(f'damaged files: {made}')
    opened = open_new_work(DAMAGED_WORK)
    c.stop_app(3)
    con = c.pull_db('tachiyomi.db')
    row = con.execute('SELECT _id FROM mangas WHERE title = ?', (DAMAGED_WORK,)).fetchone()
    manga = row[0] if row else None
    ids = {url.split('/')[-1]: cid for cid, url in con.execute('SELECT _id, url FROM chapters WHERE manga_id = ?', (manga,))} if manga else {}
    con.close()
    c.check('Local Source lists the damaged files as chapters of a new work', opened and all(n in ids for n in made),
            {'work': manga, 'chapters': ids})
    for name in made:
        if name not in ids:
            continue
        start_reader(manga, ids[name])
        t = time.time()
        while c.READER not in d.resumed() and time.time() - t < 150:
            time.sleep(3)
        time.sleep(12)
        c.clear_dialogs()
        texts = screen_texts()
        capture('corrupt-' + name.replace('.', '-'))
        c.check(f'{name}: the text reader shows the App\'s message, no crash',
                c.READER in d.resumed() and '無法開啟這本書' in texts and any('檔案已損毀' in x for x in texts) and not crashes(),
                {'front': d.resumed().split()[-2:], 'screen': texts[:6], 'crashes': crashes()[:3]})
    # The two damaged EPUBs of stage 2 (work 損毀檔): since the stage 6 fix the text reader explains them; before,
    # the image reader closed without a message (cut short) or with its library's English error (not a ZIP).
    for chapter, name in ((7, 'not-an-ebook.epub'), (8, 'corrupt-truncated.epub')):
        start_reader(DAMAGED, chapter)
        t = time.time()
        while c.READER not in d.resumed() and time.time() - t < 150:
            time.sleep(3)
        time.sleep(12)
        c.clear_dialogs()
        texts = screen_texts()
        capture('corrupt-' + name.replace('.', '-'))
        c.check(f'{name}: the text reader shows the App\'s message, no crash',
                c.READER in d.resumed() and '無法開啟這本書' in texts and any('檔案已損毀' in x for x in texts) and not crashes(),
                {'front': d.resumed().split()[-2:], 'screen': texts[:6], 'crashes': crashes()[:3]})
    c.stop_app(0)

# endregion


def step_cleanup():
    c.STEP[0] = 'cleanup'
    reset(font_list=False)
    c.set_prefs({'pref_ebook_page_turn': None})
    c.rotate(False)
    c.check('typesetting settings and imported fonts removed', not d.ebook_prefs(), d.ebook_prefs())


def main():
    args, i = sys.argv[1:], 0
    while i < len(args):
        step = args[i]
        i += 1
        if step == 'positions':
            step_positions(args[i])
            i += 1
        else:
            {'fonts': step_fonts, 'glyphs': step_glyphs, 'visible': step_visible, 'corrupt': step_corrupt,
             'cleanup': step_cleanup}[step]()
        c.save_system_logs(c.STEP[0])


if __name__ == '__main__':
    main()
