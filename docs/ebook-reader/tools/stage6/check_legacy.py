"""Stage 6, acceptance item 2: features the App had before Bookmania, checked again on the final debug App as far
as they work offline on this emulator (Android 8.0). Decided with the user: browsing and installing extensions,
downloads from online sources and tracking services are not checked here (third-party extensions and accounts
would be needed); they are left to a check on a phone.

  library    three works are added to the library from their pages (加入書櫃): the database marks them, the
             library tab lists them, one opens from there
  local      Local Source chapters in two more formats of the image reader, next to the .cbz and the comic EPUBs
             of stage 2: a folder of images and a .zip. Both are listed as chapters, open in the image reader
             and are paged to the end (the chapter is then marked read)
  modes      the comic CBZ in each reading mode of the image reader (left to right, right to left, vertical,
             long strip, continuous vertical; the curl off): two page keys move the reading position and change
             the screen
  screens    the main tabs, Local Source in Browse, the download queue and every settings category open
             without a crash (screenshots)
  backup     a backup made in the App holds the library; a work taken out of the library (in the database) is
             back in it after restoring that backup through the App's screens (../stage5/backup_ui.py)
  cleanup    the chapters added by "local" are removed again
Usage: ADB=/path/to/adb python3 -I check_legacy.py <step> [...]
Results: out/legacy/results.jsonl; screenshots: out/legacy/shots/.
"""
import gzip
import io
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out', 'legacy'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage5'))
import check_stage5 as c  # noqa: E402

d = c.d
OUT = os.environ['OUT']
SHOTS = os.path.join(OUT, 'shots')
os.makedirs(SHOTS, exist_ok=True)
MAIN = 'eu.kanade.tachiyomi.ui.main.MainActivity'
LOCAL = f'/sdcard/Android/data/{d.PKG}/files/local'
COMIC_WORK, COMIC_FOLDER, CBZ_CHAPTER = 10, '漫畫 CBZ', 12
LIBRARY = [(10, '漫畫 CBZ'), (14, '直排測試書 EPUB'), (8, '橫排測試書 EPUB')]
ADDED = ('第2話 圖片資料夾', '第3話 壓縮檔.zip')
MODES = [(1, 'left-to-right'), (2, 'right-to-left'), (3, 'vertical'), (4, 'long-strip'), (5, 'continuous-vertical')]


# region helpers

def capture(name):
    from PIL import Image
    png = d.adb('exec-out', 'screencap', '-p', text=False, timeout=60)
    with open(os.path.join(SHOTS, name + '.png'), 'wb') as f:
        f.write(png)
    return Image.open(io.BytesIO(png)).convert('L')


def changed(a, b):
    import numpy as np
    size = (a.size[0] // 4, a.size[1] // 4)
    x = np.asarray(a.resize(size), dtype=np.int16)
    y = np.asarray(b.resize(size), dtype=np.int16)
    return round(float((abs(x - y) > 30).mean()), 4)


def texts():
    return [n['text'] or n['desc'] for n in d.nodes() if n['text'] or n['desc']]


def crash_lines():
    return [ln for ln in d.shell('logcat -d -b crash').splitlines() if 'FATAL' in ln or 'Fatal signal' in ln]


def push_main_db():
    """Puts the local copy of tachiyomi.db back (App stopped)."""
    d.adb('push', os.path.join(c.DB, 'tachiyomi.db'), '/data/local/tmp/tachiyomi.db')
    d.shell(f'run-as {d.PKG} rm -f databases/tachiyomi.db-wal databases/tachiyomi.db-shm')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/tachiyomi.db databases/tachiyomi.db')


def set_progress(chapter, page=0, read=0):
    c.stop_app(0)
    con = c.pull_db('tachiyomi.db')
    con.execute('UPDATE chapters SET last_page_read = ?, read = ? WHERE _id = ?', (page, read, chapter))
    con.commit()
    con.close()
    push_main_db()


def chapter_row(chapter):
    con = c.pull_db('tachiyomi.db')
    row = con.execute('SELECT last_page_read, read, pages_left FROM chapters WHERE _id = ?', (chapter,)).fetchone()
    con.close()
    return {'last_page_read': row[0], 'read': row[1], 'pages_left': row[2]} if row else None


def start_main():
    c.stop_app(0)
    d.shell(f'am start -n {d.PKG}/{MAIN}')
    time.sleep(6)
    c.wait_app_drawn()
    time.sleep(4)
    c.clear_dialogs()


def tap_text(label, tries=6, wait=4.0):
    for _ in range(tries):
        n = d.find(label, exact=True)
        if n:
            d.tap(n['x'], n['y'], wait)
            return n
        c.clear_dialogs()
        time.sleep(2)
    return None


def open_image_reader(manga, chapter, settle=25):
    d.shell('logcat -b crash -c')
    d.shell(f'am start -n {d.PKG}/{c.IMAGE_READER} --el manga {manga} --el chapter {chapter}')
    t = time.time()
    while 'ui.reader.ReaderActivity' not in d.resumed() and time.time() - t < 120:
        time.sleep(3)
    time.sleep(settle)  # pages decoded
    c.clear_dialogs()

# endregion


def step_library():
    c.STEP[0] = 'library'
    for manga, title in LIBRARY:
        c.stop_app(0)
        c.open_manga(manga)
        time.sleep(6)
        c.wait_app_drawn()
        time.sleep(4)
        c.clear_dialogs()
        n = tap_text('加入書櫃')
        time.sleep(2)
        for label in ('確定', 'OK'):  # a category choice, if the App asks
            if d.find(label, exact=True):
                tap_text(label)
        capture(f'library-add-{manga}')
        c.check(f'{title}: the page shows 加入書櫃 and the tap is taken', n is not None and d.find('在書櫃中', exact=True) is not None,
                {'screen': texts()[:12]})
    c.stop_app(3)
    con = c.pull_db('tachiyomi.db')
    fav = {m: f for m, f in con.execute('SELECT _id, favorite FROM mangas')}
    con.close()
    c.check('the three works are in the library (database)', all(fav.get(m) == 1 for m, _ in LIBRARY), {m: fav.get(m) for m, _ in LIBRARY})
    start_main()
    tap_text('書櫃')
    time.sleep(4)
    shown = texts()
    capture('library-tab')
    c.check('the library tab lists the three works', all(any(t in x for x in shown) for _, t in LIBRARY), shown[:30])
    n = d.find(LIBRARY[1][1], exact=True)
    if n:
        d.tap(n['x'], n['y'], 8)
    now = texts()
    capture('library-open-work')
    c.check('a work opens from the library (its page with the chapter list)', '在書櫃中' in now and any('zh-vertical' in x or '直排' in x for x in now),
            now[:15])
    c.check('no crash', not crash_lines(), crash_lines()[:3])
    c.stop_app(0)


def step_local():
    from PIL import Image, ImageDraw
    import zipfile
    c.STEP[0] = 'local'
    pages = []
    for i, color in enumerate(((235, 140, 120), (130, 200, 140), (120, 150, 230))):
        im = Image.new('RGB', (800, 1200), color)
        dr = ImageDraw.Draw(im)
        dr.rectangle([40, 40, 760, 1160], outline=(20, 20, 20), width=14)
        dr.ellipse([200, 300, 600, 700], outline=(20, 20, 20), width=14)
        dr.text((80, 80), f'page {i + 1}', fill=(0, 0, 0))
        b = io.BytesIO()
        im.save(b, 'PNG')
        pages.append(b.getvalue())
    folder = os.path.join(OUT, 'local')
    os.makedirs(os.path.join(folder, ADDED[0]), exist_ok=True)
    for i, data in enumerate(pages):
        with open(os.path.join(folder, ADDED[0], f'{i + 1:03d}.png'), 'wb') as f:
            f.write(data)
    with zipfile.ZipFile(os.path.join(folder, ADDED[1]), 'w') as z:
        for i, data in enumerate(pages):
            z.writestr(f'{i + 1:03d}.png', data)
    d.shell(f"mkdir -p '{LOCAL}/{COMIC_FOLDER}/{ADDED[0]}'")
    for i in range(len(pages)):
        d.adb('push', os.path.join(folder, ADDED[0], f'{i + 1:03d}.png'), f'{LOCAL}/{COMIC_FOLDER}/{ADDED[0]}/{i + 1:03d}.png')
    d.adb('push', os.path.join(folder, ADDED[1]), f'{LOCAL}/{COMIC_FOLDER}/{ADDED[1]}')
    c.stop_app(0)
    c.open_manga(COMIC_WORK)  # Local Source lists the new chapters
    time.sleep(45)
    capture('local-chapters')
    c.stop_app(3)
    con = c.pull_db('tachiyomi.db')
    rows = con.execute('SELECT _id, url, name FROM chapters WHERE manga_id = ?', (COMIC_WORK,)).fetchall()
    con.close()
    ids = {name: cid for cid, url, _ in rows for name in ADDED if url.endswith(name)}
    c.check('the image folder and the .zip are listed as chapters', len(ids) == 2, [(r[0], r[1], r[2]) for r in rows])
    c.set_prefs({'pref_default_reading_mode_key': 1, 'pref_bookmania_pager_curl': False})
    for name, cid in ids.items():
        set_progress(cid)
        open_image_reader(COMIC_WORK, cid)
        a = capture(f'local-{cid}-page1')
        front = d.resumed()
        for _ in range(3):
            c.key(c.KEY_PAGE_DOWN, 6)
        b = capture(f'local-{cid}-after-keys')
        d.shell('input keyevent 4')
        time.sleep(4)
        c.stop_app(4)
        row = chapter_row(cid)
        c.check(f'{name}: opens in the image reader and is paged to the end (marked read)',
                'ui.reader.ReaderActivity' in front and row and (row['read'] == 1 or row['last_page_read'] == 2) and not crash_lines(),
                {'front': front.split()[-2:], 'chapter': row, 'screen changed': changed(a, b), 'crashes': crash_lines()[:3]})


def step_modes():
    c.STEP[0] = 'modes'
    for value, name in MODES:
        c.set_prefs({'pref_default_reading_mode_key': value, 'pref_bookmania_pager_curl': False})
        set_progress(CBZ_CHAPTER)
        open_image_reader(COMIC_WORK, CBZ_CHAPTER)
        front = d.resumed()
        a = capture(f'mode-{name}-1')
        c.key(c.KEY_PAGE_DOWN, 6)
        c.key(c.KEY_PAGE_DOWN, 6)
        b = capture(f'mode-{name}-2')
        d.shell('input keyevent 4')
        time.sleep(4)
        c.stop_app(4)
        row = chapter_row(CBZ_CHAPTER)
        c.check(f'{name}: two page keys move on (reading position, screen), no crash',
                'ui.reader.ReaderActivity' in front and row and (row['last_page_read'] >= 1 or row['read'] == 1) and changed(a, b) > 0.05 and not crash_lines(),
                {'chapter after': row, 'screen changed': changed(a, b), 'crashes': crash_lines()[:3]})
    c.set_prefs({'pref_default_reading_mode_key': None, 'pref_bookmania_pager_curl': None})


def step_screens():
    c.STEP[0] = 'screens'
    d.shell('logcat -b crash -c')
    start_main()
    for tab in ('書櫃', '最新', '探索', '其他'):
        n = tap_text(tab)
        capture(f'screen-tab-{tab}')
        c.check(f'tab {tab} opens', n is not None and d.find(tab, exact=True) is not None, texts()[:12])
        if tab == '探索':
            src = tap_text('本機來源', tries=2, wait=8) or tap_text('Local source', wait=8)  # the name is not translated
            shown = texts()
            capture('screen-browse-local-source')
            c.check('Browse: Local Source lists the works of the test folder', src is not None and any('測試' in x for x in shown), shown[:20])
            d.shell('input keyevent 4')
            time.sleep(4)
    tap_text('其他')
    q = tap_text('下載佇列')
    capture('screen-download-queue')
    c.check('the download queue opens', q is not None, texts()[:10])
    d.shell('input keyevent 4')
    time.sleep(3)
    tap_text('其他')
    tap_text('設定')
    first = [x for x in texts()]
    capture('screen-settings')
    names = [x for x in ('一般', '外觀', '書櫃', '閱讀', '下載', '探索', '歷程', 'Data and storage', '隱私', '進階', '關於') if x in first]
    opened = {}
    for name in names:
        if not d.find(name, exact=True):
            tap_text('設定')
        n = tap_text(name, wait=5)
        shown = texts()
        capture(f'screen-settings-{name.replace(" ", "-")}')
        opened[name] = n is not None and len(shown) > 3
        d.shell('input keyevent 4')
        time.sleep(4)
    c.check('every settings category on the first screen opens', bool(opened) and all(opened.values()),
            {'categories': opened, 'first screen': first[:20]})
    c.check('no crash while opening the screens', not crash_lines(), crash_lines()[:3])
    c.stop_app(0)


def backup_mangas(path):
    """(source, url, title, favorite) of each BackupManga (Backup field 1; BackupManga fields 1, 2, 3, 100)."""
    with open(path, 'rb') as f:
        raw = gzip.decompress(f.read())
    out = []
    for num, _, v in c.proto_fields(raw):
        if num == 1:
            fm = c.proto_fields(v)
            out.append((next((x for n, _, x in fm if n == 1), 0), next((x.decode() for n, _, x in fm if n == 2), ''),
                        next((x.decode() for n, _, x in fm if n == 3), ''), next((x for n, _, x in fm if n == 100), 1)))
    return out


def step_backup():
    import backup_ui as b
    c.STEP[0] = 'backup'
    path = b.create()
    local = os.path.join(OUT, os.path.basename(path))
    d.adb('pull', path, local)
    mangas = backup_mangas(local)
    titles = [m[2] for m in mangas]
    c.check('the backup holds the library works', all(t in titles for _, t in LIBRARY), {'works in the backup': mangas})
    c.stop_app(0)
    con = c.pull_db('tachiyomi.db')
    con.execute('UPDATE mangas SET favorite = 0 WHERE _id = ?', (LIBRARY[2][0],))
    con.commit()
    con.close()
    push_main_db()
    b.restore(os.path.basename(path))
    c.stop_app(5)
    con = c.pull_db('tachiyomi.db')
    fav = con.execute('SELECT favorite FROM mangas WHERE _id = ?', (LIBRARY[2][0],)).fetchone()
    con.close()
    c.check('after the restore the work taken out is in the library again', fav and fav[0] == 1, {'favorite': fav})


def step_cleanup():
    c.STEP[0] = 'cleanup'
    d.shell(f"rm -rf '{LOCAL}/{COMIC_FOLDER}/{ADDED[0]}' '{LOCAL}/{COMIC_FOLDER}/{ADDED[1]}'")
    c.stop_app(0)
    c.open_manga(COMIC_WORK)
    time.sleep(45)
    c.stop_app(3)
    con = c.pull_db('tachiyomi.db')
    left = con.execute('SELECT _id, url FROM chapters WHERE manga_id = ?', (COMIC_WORK,)).fetchall()
    con.close()
    c.check('the added chapters are gone', not any(u.endswith(ADDED[0]) or u.endswith(ADDED[1]) for _, u in left), left)


def main():
    for step in sys.argv[1:]:
        {'library': step_library, 'local': step_local, 'modes': step_modes, 'screens': step_screens,
         'backup': step_backup, 'cleanup': step_cleanup}[step]()
        c.save_system_logs(c.STEP[0])


if __name__ == '__main__':
    main()
