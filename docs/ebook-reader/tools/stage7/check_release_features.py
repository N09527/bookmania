"""Stage 7: the two new features on the signed release APK (R8, not debuggable), after
tools/stage6/release_smoke.py has installed it and given it the debug App's library and books (adb as root).

WebView debugging is off in the release App, so everything is measured on screenshots, with the measures of
check_stage7.py:
  - text reader, horizontal EPUB, portrait, two columns: the fold's shadow on the centre of the gap, which is the
    centre of the screen with the default margins (20 / 20 dp): (412 + 20 - 20) / 2 = 206 CSS px, 540.75 px at
    this emulator's density 2.625. Then the shadow switch off: no shadow.
  - bold, one column: the same page with bold on has more ink than with bold off.
  - image reader, the test comic of check_stage7.py (in the copied library), left to right, double pages, fit
    screen: the shadow on the seam; with the switch off: none.
The release App cannot be reached with run-as: its preferences and database are read and written as root.

Usage: ADB=/path/to/adb python3 -I check_release_features.py
Results: out/release-features/results.jsonl, screenshots in out/release-features/shots/.
"""
import os
import sqlite3
import sys
import time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out', 'release-features'))
REL = 'io.github.n09527.bookmania'
os.environ['PKG'] = REL  # the drivers' package: the release App
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import check_stage7 as s7  # noqa: E402

c, d = s7.c, s7.d
OUT = os.environ['OUT']
PREFS = f'/data/data/{REL}/shared_prefs/{REL}_preferences.xml'
TEXT = f'{REL}/yokai.ebook.EbookReaderActivity'  # as dumpsys names the release App's activities
IMAGE = f'{REL}/{c.IMAGE_READER}'
HORZ = (8, 10)  # 橫排測試書 EPUB / zh-horizontal.epub, ids of the copied library
CENTRE = (412 + 20 - 20) / 2 * 2.625
COMIC_PREFS = {'pref_default_reading_mode_key': 1, 'page_layout': 1, 'pref_reader_theme_key': 0, 'pref_bookmania_pager_curl': False,
               'pref_bookmania_pager_gutter_shadow': None, 'pref_image_scale_type_key': 1, 'pref_zoom_start_key': 1}


def set_prefs(values):
    """As check_stage5.set_prefs, as root, for the release App (stopped first). None removes a key."""
    d.shell(f'am force-stop {REL}')
    time.sleep(1)
    root = ET.fromstring(d.shell(f'cat {PREFS}'))
    for e in list(root):
        if e.get('name', '') in values:
            root.remove(e)
    for k, v in values.items():
        if v is None:
            continue
        if isinstance(v, bool):
            ET.SubElement(root, 'boolean', name=k, value='true' if v else 'false')
        elif isinstance(v, int):
            ET.SubElement(root, 'int', name=k, value=str(v))
        else:
            ET.SubElement(root, 'string', name=k).text = str(v)
    tmp = os.path.join(OUT, 'prefs.xml')
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n" + ET.tostring(root, encoding='unicode'))
    uid = d.shell(f'stat -c %u /data/data/{REL}').strip()
    d.adb('push', tmp, '/data/local/tmp/rel-prefs.xml')
    d.shell(f'cp /data/local/tmp/rel-prefs.xml {PREFS} && chown {uid}:{uid} {PREFS} && chmod 660 {PREFS} && restorecon {PREFS}')


def open_book(manga, chapter, want):
    """Starts the reader on a chapter, as release_smoke.py does, and waits until [want] is in front and laid out."""
    d.shell(f'am force-stop {REL}')
    time.sleep(2)
    d.shell(f'am start -n {REL}/{c.IMAGE_READER} --el manga {manga} --el chapter {chapter}')
    t = time.time()
    while time.time() - t < 150 and not (want in d.resumed() and REL + '/' in s7.focused()):
        time.sleep(3)
    time.sleep(20)  # laid out (the release App cannot be asked)
    c.clear_dialogs()
    return want in d.resumed()


def ink(img):
    """Share of dark pixels between 10 % and 90 % of the height (the page's text)."""
    a = s7.lum(img)
    h = a.shape[0]
    return float((a[int(h * 0.1):int(h * 0.9)] < 128).mean())


def comic_ids():
    """Manga and chapter ids of the test comic in the release App's database (copied as root)."""
    db = os.path.join(OUT, 'db')
    os.makedirs(db, exist_ok=True)
    for f in os.listdir(db):
        os.remove(os.path.join(db, f))
    d.shell(f'am force-stop {REL}')
    for n in d.shell(f'ls /data/data/{REL}/databases/').split():
        if n.startswith('tachiyomi.db'):
            d.shell(f'cp /data/data/{REL}/databases/{n} /data/local/tmp/{n} && chmod 644 /data/local/tmp/{n}')
            d.adb('pull', f'/data/local/tmp/{n}', os.path.join(db, n))
    con = sqlite3.connect(os.path.join(db, 'tachiyomi.db'))
    try:
        row = con.execute('SELECT _id FROM mangas WHERE title = ?', (s7.COMIC_WORK,)).fetchone()
        r = con.execute('SELECT _id FROM chapters WHERE manga_id = ? AND url LIKE ?', (row[0], '%' + s7.COMIC_FILE)).fetchone() if row else None
    finally:
        con.close()
    return (row[0], r[0]) if row and r else None


def step_text():
    c.STEP[0] = 'release-features:two-columns'
    c.rotate(False)
    set_prefs({'pref_ebook_columns': 'on', 'pref_ebook_bold': None, 'pref_ebook_gutter_shadow': None})
    ok = open_book(*HORZ, TEXT)
    img = s7.shot('rel-01-two-columns')
    m = s7.measure_gutter(img, CENTRE, 'rel-01-two-columns')
    c.check("release, two columns: the fold's shadow on the centre of the gap", ok and s7.shadow_ok(m, CENTRE), m)
    set_prefs({'pref_ebook_gutter_shadow': False})
    ok = open_book(*HORZ, TEXT)
    img = s7.shot('rel-02-two-columns-shadow-off')
    m = s7.measure_gutter(img, CENTRE, 'rel-02-two-columns-shadow-off')
    c.check('release, two columns, shadow switch off: no shadow', ok and s7.no_shadow(m), m)


def step_bold():
    c.STEP[0] = 'release-features:bold'
    set_prefs({'pref_ebook_columns': None, 'pref_ebook_gutter_shadow': None, 'pref_ebook_bold': None})
    ok1 = open_book(*HORZ, TEXT)
    a = s7.shot('rel-03-bold-off')
    set_prefs({'pref_ebook_bold': 'true'})
    ok2 = open_book(*HORZ, TEXT)
    b = s7.shot('rel-04-bold-on')
    ia, ib = ink(a), ink(b)
    c.check('release, bold on: the page has more ink than with bold off', ok1 and ok2 and ib > ia * 1.15,
            {'dark share, bold off': round(ia, 4), 'dark share, bold on': round(ib, 4), 'ratio': round(ib / max(ia, 1e-6), 3)})
    set_prefs({'pref_ebook_bold': None})


def step_comic():
    c.STEP[0] = 'release-features:comic'
    ids = comic_ids()
    if not c.check('the test comic is in the release App\'s library', ids is not None, {'ids': ids}):
        return
    for shadow, name in ((None, 'rel-05-comic-double-pages'), (False, 'rel-06-comic-shadow-off')):
        set_prefs(dict(COMIC_PREFS, pref_bookmania_pager_gutter_shadow=shadow))
        ok = open_book(*ids, IMAGE)
        img, seam, xs = s7.spread_shot(name, timeout=90)
        if seam is None:  # the reader opens on the page read last: back to the first two pages
            c.key(21, 8)
            img, seam, xs = s7.spread_shot(name)
        m = s7.comic_measure(img, name, seam) if seam is not None else {'seam': None, 'boundaries': xs, 'shot': name}
        if shadow is None:
            c.check('release, double pages: the shadow is on the seam', ok and seam is not None and s7.shadowed(m), m)
        else:
            c.check('release, double pages, shadow switch off: none on the seam', ok and seam is not None and s7.unshadowed(m), m)
    set_prefs({k: None for k in COMIC_PREFS})


def main():
    steps = {'text': step_text, 'bold': step_bold, 'comic': step_comic}
    for name in sys.argv[1:] or list(steps):
        try:
            steps[name]()
        except Exception as e:  # noqa: BLE001  (record it and go on with the next step)
            c.check(f'{name}: the step ran to its end', False, repr(e))
    d.shell(f'am force-stop {REL}')


if __name__ == '__main__':
    main()
