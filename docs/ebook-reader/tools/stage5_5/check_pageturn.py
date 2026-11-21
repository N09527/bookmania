"""Stage 5.5 checks on the emulator (debug APK): the text reader's page turn animation (none / slide /
curl), the image reader's page curl, and the text reader's chapter panel.

Each turn is recorded with `screenrecord` and analysed frame by frame against a screenshot taken before
and one taken after the turn: every cell of a grid is "old" (as before), "new" (as after) or neither (the
flap, the shadow, a moving page). Where the new page shows up first tells the edge the page turns by.

Usage: python3 -I check_pageturn.py <step> [arguments]        (environment: ADB=/path/to/adb)
  text <manga> <chapter> <none|slide|curl> <label> [--columns on] [--back] [--landscape] [--direction rtl|ltr]
  image <manga> <chapter> <l2r|r2l|vertical|webtoon> <label> [--curl on|off] [--double] [--back]
  add_chapter <manga> <file on the device> <new file name>   copies a file into the work's folder and refreshes
                                        the work's chapter list (pull to refresh on its page)
  chapters <manga> <first chapter> <other text chapter> <image chapter, 0: the work's .cbz>
  settings_ui <manga> <chapter>          the new settings in the text reader's panel and in Settings > Reader
Results: out/results.jsonl, recordings and frames: out/rec/<label>/, frame sheets: out/shots/<label>-frames.png.
Needs ../stage5/check_stage5.py (and what it needs), ffmpeg, Pillow and numpy.
"""
import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage5'))
import check_stage5 as c  # noqa: E402

d = c.d
OUT = os.environ['OUT']
os.makedirs(os.path.join(OUT, 'shots'), exist_ok=True)
ADB = os.environ.get('ADB', 'adb')
KEY_PAGE_UP, KEY_PAGE_DOWN = 92, 93
CELL = 20  # grid cell, pixels of the half-size recording


def check(name, ok, detail=None):
    return c.check(name, ok, detail)


def note(text):
    c.note(text)


# region Recording and analysis

def grab(size):
    """A screenshot, scaled to the recording size, in grey."""
    png = d.adb('exec-out', 'screencap', '-p', text=False, timeout=90)
    path = os.path.join(OUT, 'grab.png')
    with open(path, 'wb') as f:
        f.write(png)
    img = Image.open(path).convert('RGB')
    return img.resize(size, Image.BILINEAR) if size else img


def screen_size():
    img = grab(None)
    return img.size  # (width, height) in the current orientation


SLOW = 20  # animator duration scale while recording: more frames of each turn on the slow emulator


def record_turn(label, code, seconds=60, size=None):
    """Records the screen while key [code] turns the page, with animations [SLOW] times slower (the system
    setting "animator duration scale", which the App's animations follow). Sending a key with `input` takes
    seconds on this emulator, hence the long recording. Returns (before, after, frames, after_late)."""
    folder = os.path.join(OUT, 'rec', label)
    os.makedirs(folder, exist_ok=True)
    for f in os.listdir(folder):
        os.remove(os.path.join(folder, f))
    w, h = size
    before = grab(size)
    before.save(os.path.join(folder, 'before.png'))
    d.shell('rm -f /sdcard/turn.mp4')
    d.shell(f'settings put global animator_duration_scale {SLOW}')
    rec = subprocess.Popen([ADB, 'shell', 'screenrecord', '--time-limit', str(seconds), '--size', f'{w}x{h}',
                            '--bit-rate', '8000000', '/sdcard/turn.mp4'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)  # screenrecord has started
    t_key = time.time()
    d.shell(f'input keyevent {code}')
    try:
        rec.wait(timeout=seconds + 60)
    except subprocess.TimeoutExpired:
        rec.kill()
    d.shell('settings put global animator_duration_scale 1')
    time.sleep(2)
    d.adb('pull', '/sdcard/turn.mp4', os.path.join(folder, 'turn.mp4'), timeout=120)
    after = grab(size)
    after.save(os.path.join(folder, 'after.png'))
    time.sleep(3)
    late = grab(size)
    frames = extract(folder, size)
    note(f'{label}: {len(frames)} frames, key sent {t_key:.1f}')
    return before, after, frames, late


def extract(folder, size):
    video = os.path.join(folder, 'turn.mp4')
    if not os.path.exists(video) or os.path.getsize(video) == 0:
        return []
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', video, '-vsync', 'passthrough', os.path.join(folder, 'f%04d.png')], check=False)
    probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time',
                            '-of', 'csv=p=0', video], capture_output=True, text=True)
    times = [float(x) for x in probe.stdout.split() if x.strip() and x.strip() != 'N/A']
    names = sorted(n for n in os.listdir(folder) if n.startswith('f') and n.endswith('.png'))
    frames = []
    for i, n in enumerate(names):
        img = Image.open(os.path.join(folder, n)).convert('RGB')
        if img.size != size:
            img = img.resize(size, Image.BILINEAR)
        frames.append((times[i] if i < len(times) else float(i), img))
    return frames


def grey(img):
    return np.asarray(img.convert('L'), dtype=np.int16)


def cells(diff):
    h, w = diff.shape
    gh, gw = h // CELL, w // CELL
    return np.abs(diff[:gh * CELL, :gw * CELL]).reshape(gh, CELL, gw, CELL).mean(axis=(1, 3))


def classify(frame, before, after):
    """Per cell: informative (the two pages differ there), old (as before) and new (as after)."""
    F, B, A = grey(frame), grey(before), grey(after)
    d_fb, d_fa, d_ab = cells(F - B), cells(F - A), cells(A - B)
    informative = d_ab > 12
    old = informative & (d_fb < 7) & (d_fa > 10)
    new = informative & (d_fa < 7) & (d_fb > 10)
    return informative, old, new


def centroid(mask):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    gh, gw = mask.shape
    return round(float((xs.mean() + 0.5) / gw), 3), round(float((ys.mean() + 0.5) / gh), 3)


def analyse(before, after, frames):
    rows = []
    for t, img in frames:
        inf, old, new = classify(img, before, after)
        n = int(inf.sum()) or 1
        rows.append({
            't': round(t, 3),
            'old': round(int(old.sum()) / n, 3),
            'new': round(int(new.sum()) / n, 3),
            'new_at': centroid(new),
            'old_at': centroid(old),
            'new_right_half': round(float(new[:, new.shape[1] // 2:].sum()) / max(1, int(new.sum())), 3),
            'new_bottom_half': round(float(new[new.shape[0] // 2:, :].sum()) / max(1, int(new.sum())), 3),
        })
    return rows


def mid(rows, share=0.8):
    """Frames during the turn: neither the old page nor the new page is on the screen as it is before or
    after the turn (compared with the frames of the recording that show most of each; the video's own
    compression keeps them below 1). The flap of a curl covers much of the old page, so a frame can show
    little of either page."""
    if not rows:
        return []
    old_most = max(r['old'] for r in rows)
    new_most = max(r['new'] for r in rows)
    return [r for r in rows if r['old'] < share * old_most and r['new'] < share * new_most]


def sheet(label, before, after, frames, rows, picks=6):
    """Before, some frames of the turn and after, side by side, with their times."""
    middle = [i for i, r in enumerate(rows) if 0.03 < r['new'] < 0.97 or 0.03 < r['old'] < 0.97]
    if len(middle) > picks:
        middle = [middle[round(k * (len(middle) - 1) / (picks - 1))] for k in range(picks)]
    images = [('before', before)] + [(f"{rows[i]['t']:.2f}s", frames[i][1]) for i in middle] + [('after', after)]
    w, h = before.size
    scale = 0.5
    tw, th = int(w * scale), int(h * scale)
    out = Image.new('RGB', (tw * len(images), th + 28), 'white')
    draw = ImageDraw.Draw(out)
    for k, (name, img) in enumerate(images):
        out.paste(img.resize((tw, th), Image.BILINEAR), (k * tw, 28))
        draw.text((k * tw + 6, 6), name, fill='black')
    path = os.path.join(OUT, 'shots', f'{label}-frames.png')
    out.save(path)
    return path


def no_overlay_left(after, late):
    """The picture after the turn stays as it is: nothing is left on top of the reader."""
    diff = cells(grey(late) - grey(after))
    return float((diff > 10).mean())

# endregion


# region Text reader

def text_step(manga, chapter, style, label, columns='off', back=False, landscape=False, direction=None):
    c.STEP[0] = f'text:{label}'
    values = {'pref_ebook_page_turn': style, 'pref_ebook_columns': columns}
    if direction:
        values['pref_ebook_pageDirection'] = direction
    c.set_prefs(values, reset_typesetting=True)
    c.rotate(landscape)
    st = c.open_book(manga, chapter)
    if not st or not st.get('ready'):
        return check('the book opened', False, st)
    # a page in the middle of the document: the turn stays in it (a turn into the next document is played
    # only when that one is laid out quickly, which this emulator never does)
    start_page = 4 if back else 2
    d.cdp(f'window.__reader.goPage({start_page})')
    time.sleep(4)
    st = d.status()
    if not st or st.get('pages', 0) < start_page + 2 * st.get('cols', 1):
        return check('the document has pages around page %d' % start_page, False, st)
    size = screen_size()
    size = (size[0] // 2, size[1] // 2)
    before, after, frames, late = record_turn(label, KEY_PAGE_UP if back else KEY_PAGE_DOWN, size=size)
    st2 = d.status()
    rows = analyse(before, after, frames)
    with open(os.path.join(OUT, 'rec', label, 'analysis.json'), 'w') as f:
        json.dump(rows, f, indent=1)
    path = sheet(label, before, after, frames, rows)
    step = st.get('cols', 1)
    expected = st['page'] - step if back else st['page'] + step
    check('the page turned', st2 and st2['page'] == expected, {'before': st, 'after': st2, 'expected page': expected})
    # the page direction: as set, else vertical text turns right to left (the shell's mode 'V')
    rtl = direction == 'rtl' or (direction is None and st.get('mode') == 'V')
    verdicts(label, style, rows, back, columns == 'on', rtl=rtl, edge=None, sheet_path=path,
             leftover=no_overlay_left(after, late))
    c.rotate(False)


def verdicts(label, style, rows, back, spread, rtl, edge, sheet_path, leftover):
    during = mid(rows)
    detail = {'frames': len(rows), 'frames during the turn': len(during), 'sheet': os.path.relpath(sheet_path, OUT)}
    check('nothing is left over the page after the turn', leftover < 0.02, {'changed cells': round(leftover, 4)})
    if not rows:
        return check('recorded', False, detail)
    last = rows[-1]
    check('the recording ends on the new page', last['new'] >= 0.9 and last['old'] <= 0.05, last)
    if style == 'none':
        return check('no animation: no frame shows parts of both pages', len(during) == 0, {**detail, 'during': during[:3]})
    check('the turn is animated (frames show parts of both pages)', len(during) >= 2, detail)
    if not during:
        return False
    first = during[0]
    if style == 'slide':
        # the new page comes in from the side the next page lies on
        side = first['new_at'][0] if first['new_at'] else None
        expect_right = (not back) != bool(rtl)
        return check('the new page slides in from the ' + ('right' if expect_right else 'left'),
                     side is not None and ((side > 0.5) if expect_right else (side < 0.5)), {**detail, 'first': first})
    # curl
    if edge == 'BOTTOM':
        ok = first['new_bottom_half'] >= 0.8 if not back else first['new_bottom_half'] <= 0.2
        return check('vertical pager: the page curls from the bottom edge' + (' (back: comes down over the top edge)' if back else ''),
                     ok, {**detail, 'first': first})
    lifted_on_right = not rtl  # the edge that is lifted going forward
    if back:
        # the turn runs in reverse: the previous page comes back over the hinge side first
        lifted_on_right = not lifted_on_right
    share = first['new_right_half']
    ok = share >= 0.8 if lifted_on_right else share <= 0.2
    what = ('two columns: one page turns about the centre line, ' if spread else '') + \
        ('the new page shows on the right first' if lifted_on_right else 'the new page shows on the left first')
    check(what, ok, {**detail, 'first': first})
    if not back and not spread:
        y = first['new_at'][1] if first['new_at'] else 0
        check('the curl starts at the bottom corner', y > 0.5, {'first': first})
    if spread:
        # at no time does the new page show on the other half as it lies at the end, until the very end
        early = [r for r in during if r['new'] < 0.5]
        other_half = [r['new_right_half'] for r in early]
        ok = all((s >= 0.75) if lifted_on_right else (s <= 0.25) for s in other_half)
        check('two columns: the other half shows the back of the turning page, not the new page in place', ok,
              {'new_right_half during the first half of the turn': other_half})
    return True

# endregion


# region Image reader

MODES = {'l2r': 1, 'r2l': 2, 'vertical': 3, 'webtoon': 4}


def image_step(manga, chapter, mode, label, curl='on', double=False, back=False):
    c.STEP[0] = f'image:{label}'
    c.set_prefs({
        'pref_default_reading_mode_key': MODES[mode],
        'pref_bookmania_pager_curl': curl == 'on',
        'page_layout': 1 if double else 0,
        'pref_enable_transitions_key': True,
    })
    c.rotate(double)
    d.shell(f'am start -n {d.PKG}/{c.IMAGE_READER} --el manga {manga} --el chapter {chapter}')
    t = time.time()
    while c.IMAGE_READER.split('.')[-1] not in d.resumed() and time.time() - t < 120:
        time.sleep(3)
    time.sleep(25)  # pages decoded
    c.clear_dialogs()
    hide_reader_menu()
    if back:
        d.shell(f'input keyevent {KEY_PAGE_DOWN}')
        time.sleep(8)
    size = screen_size()
    size = (size[0] // 2, size[1] // 2)
    page_before = reader_page()
    before, after, frames, late = record_turn(label, KEY_PAGE_UP if back else KEY_PAGE_DOWN, size=size)
    page_after = reader_page()
    rows = analyse(before, after, frames)
    with open(os.path.join(OUT, 'rec', label, 'analysis.json'), 'w') as f:
        json.dump(rows, f, indent=1)
    path = sheet(label, before, after, frames, rows)
    check('the page turned', page_before is not None and page_after is not None and page_after != page_before,
          {'before': page_before, 'after': page_after})
    if mode == 'webtoon' or curl == 'off':
        during = mid(rows)
        layers = d.shell('dumpsys SurfaceFlinger --list')
        check('no curl: the turn is drawn by the reader itself (no curl surface)', 'SurfaceView' not in layers,
              {'frames during the turn': len(during), 'sheet': os.path.relpath(path, OUT)})
    else:
        verdicts(label, 'curl', rows, back, double, rtl=(mode == 'r2l'), edge='BOTTOM' if mode == 'vertical' else None,
                 sheet_path=path, leftover=no_overlay_left(after, late))
    c.rotate(False)


def hide_reader_menu():
    """The image reader may open with its menu shown; the curl is not used while it is."""
    ns = d.nodes()
    if any(n['desc'] in ('向上瀏覽', 'Navigate up') for n in ns):
        w = max((m['b'][2] for m in ns), default=1080)
        h = max((m['b'][3] for m in ns), default=1920)
        d.tap(w // 2, h // 2, 3)


def reader_page():
    """The page number the image reader shows ("2 / 3"), from the page indicator."""
    for n in d.nodes():
        text = n['text'].replace(' ', '')
        if '/' in text and text.replace('/', '').replace('-', '').isdigit():
            return text
    return None

# endregion


# region Chapter panel

def chapters_step(manga, first, other, image):
    c.STEP[0] = 'chapters'
    c.set_prefs({'pref_ebook_page_turn': 'none'}, reset_typesetting=True)
    c.rotate(False)
    rows = {r[0]: r for r in chapter_rows(manga)}
    if image == 0:  # the work's picture chapter (add_chapter)
        image = next(r[0] for r in rows.values() if r[2].lower().endswith('.cbz'))
    st = c.open_book(manga, first)
    if not st or not st.get('ready'):
        return check('the book opened', False, st)
    c.turn(1)
    panel = open_chapters()
    d.shot('s55-chapters-panel')
    names = [n['text'] for n in d.nodes() if n['text']]
    expected = [r[3] for r in rows.values()]
    check('the panel lists the chapters of the work', all(any(e == t for t in names) for e in expected),
          {'shown': names, 'chapters': expected})
    # long press: read / unread, as in the image reader's chapter sheet
    item = d.find(rows[other][3], exact=True)
    d.shell(f"input swipe {item['x']} {item['y']} {item['x']} {item['y']} 1500")
    time.sleep(3)
    # the bookmark button of the same row
    bookmark = [n for n in d.nodes() if n['res'].endswith('bookmark_button') and abs(n['y'] - item['y']) < 60]
    if bookmark:
        d.tap(bookmark[0]['x'], bookmark[0]['y'], 3)
    d.shot('s55-chapters-toggled')
    d.shell('input keyevent 4')  # closes the panel
    time.sleep(2)
    c.stop_app()
    toggled = {r[0]: r for r in chapter_rows(manga)}
    check('a long press marks the chapter read / unread', toggled[other][4] != rows[other][4],
          {'before': rows[other], 'after': toggled[other]})
    check('the bookmark button sets / clears the bookmark', toggled[other][5] != rows[other][5],
          {'before': rows[other], 'after': toggled[other]})
    # put both back
    restore_chapter(other, rows[other][4], rows[other][5], rows[other][6])

    # a tap opens another text chapter in the text reader, after saving this one's position
    pos_before = positions()
    st = c.open_book(manga, first)
    open_chapters()
    item = d.find(rows[other][3], exact=True)
    d.tap(item['x'], item['y'], 5)
    t = time.time()
    while time.time() - t < 120 and not (c.READER.split('.')[-1] in d.resumed() and d.status() and d.status().get('ready')):
        time.sleep(3)
    resumed = d.resumed()
    time.sleep(8)
    d.shot('s55-chapters-opened-text')
    c.stop_app()
    pos_after = positions()
    check('a tap on a text chapter opens it in the text reader', 'EbookReaderActivity' in resumed, resumed)
    check('the position of the chapter left is saved, the one opened gets its own',
          pos_after.get(rows[first][2], 0) > pos_before.get(rows[first][2], 0) and rows[other][2] in pos_after,
          {'before': pos_before, 'after': pos_after})

    # a tap on a picture chapter opens the image reader
    c.open_book(manga, first)
    open_chapters()
    item = d.find(rows[image][3], exact=True)
    d.tap(item['x'], item['y'], 5)
    t = time.time()
    while time.time() - t < 120 and 'ReaderActivity' not in d.resumed().replace('EbookReaderActivity', ''):
        time.sleep(3)
    resumed = d.resumed()
    time.sleep(10)
    d.shot('s55-chapters-opened-image')
    check('a tap on a picture chapter opens the image reader', 'ui.reader.ReaderActivity' in resumed, resumed)
    c.stop_app()


def add_chapter(manga, source, name):
    c.STEP[0] = 'add_chapter'
    db = c.pull_db('tachiyomi.db')
    folder = db.execute('SELECT url FROM mangas WHERE _id = ?', (manga,)).fetchone()[0]
    local = f'/sdcard/Android/data/{d.PKG}/files/local'
    d.shell(f'cp "{source}" "{local}/{folder}/{name}"')
    before = len(chapter_rows(manga))
    d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity -a eu.kanade.tachiyomi.SHOW_MANGA --el manga {manga}')
    time.sleep(8)
    c.wait_app_drawn()
    time.sleep(8)
    c.clear_dialogs()
    d.swipe(540, 500, 540, 1500, ms=700, wait=20)  # pull to refresh
    d.shot('s55-add-chapter')
    c.stop_app()
    rows = chapter_rows(manga)
    check('the new file is a chapter of the work', len(rows) == before + 1 and any(r[2].endswith(name) for r in rows), rows)


def open_chapters():
    for _ in range(4):
        n = d.find('章節', exact=True)
        if n and n['desc'] == '章節':
            d.tap(n['x'], n['y'], 4)
            return True
        d.tap(540, 960, 4)
        d.wait_for('章節', tries=4)
    return False


def chapter_rows(manga):
    db = c.pull_db('tachiyomi.db')
    return db.execute('SELECT _id, manga_id, url, name, read, bookmark, last_page_read FROM chapters WHERE manga_id = ? ORDER BY _id',
                      (manga,)).fetchall()


def restore_chapter(chapter, read, bookmark, last_page):
    db_path = os.path.join(c.DB, 'tachiyomi.db')
    con = c.pull_db('tachiyomi.db')
    con.execute('UPDATE chapters SET read = ?, bookmark = ?, last_page_read = ? WHERE _id = ?', (read, bookmark, last_page, chapter))
    con.commit()
    con.close()
    d.adb('push', db_path, '/data/local/tmp/tachiyomi.db')
    d.shell(f'run-as {d.PKG} rm -f databases/tachiyomi.db-wal databases/tachiyomi.db-shm')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/tachiyomi.db databases/tachiyomi.db')


def positions():
    db = c.pull_db('ebook.db')
    return {r[0]: r[1] for r in db.execute('SELECT chapter_url, updated_at FROM position')}

# endregion


# region Settings

def settings_ui(manga, chapter):
    c.STEP[0] = 'settings_ui'
    c.set_prefs({'pref_ebook_page_turn': None, 'pref_bookmania_pager_curl': None}, reset_typesetting=True)
    c.rotate(False)
    st = c.open_book(manga, chapter)
    if not st or not st.get('ready'):
        return check('the book opened', False, st)
    d.open_panel()
    d.tap_label('版面', wait=3, exact=True)
    n = d.reveal('翻頁動畫')
    d.shot('s55-settings-text-panel')
    check('the text reader panel has 翻頁動畫 (none / slide / curl), slide by default',
          n is not None and all(d.find(x, exact=True) for x in ('無', '滑動', '捲曲')), None)
    d.tap_revealed('捲曲')
    time.sleep(2)
    d.shot('s55-settings-text-panel-curl')
    c.stop_app()
    prefs = d.prefs()
    check('choosing 捲曲 stores pref_ebook_page_turn = curl', 'name="pref_ebook_page_turn">curl<' in prefs, None)

    # Settings > Reader: the new switch next to the existing transition switch
    d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity')
    time.sleep(6)
    c.wait_app_drawn()
    time.sleep(3)
    c.clear_dialogs()
    for label in ('其他', '設定', '閱讀'):
        d.tap_label(label, wait=3, exact=True)
    found = d.reveal('捲曲翻頁')
    d.shot('s55-settings-reader')
    check('Settings > Reader has 捲曲翻頁 after the transition switch', found is not None and d.find('翻頁轉場動畫', exact=True) is not None,
          None)
    if found:
        d.tap(found['x'], found['y'], 3)
    c.stop_app()
    check('the switch stores pref_bookmania_pager_curl = true', 'name="pref_bookmania_pager_curl" value="true"' in d.prefs(), None)

# endregion


def main():
    p = argparse.ArgumentParser()
    p.add_argument('step')
    p.add_argument('args', nargs='*')
    p.add_argument('--columns', default='off')
    p.add_argument('--back', action='store_true')
    p.add_argument('--landscape', action='store_true')
    p.add_argument('--direction')
    p.add_argument('--curl', default='on')
    p.add_argument('--double', action='store_true')
    a = p.parse_args()
    try:
        if a.step == 'text':
            m, ch, style, label = a.args
            text_step(int(m), int(ch), style, label, a.columns, a.back, a.landscape, a.direction)
        elif a.step == 'image':
            m, ch, mode, label = a.args
            image_step(int(m), int(ch), mode, label, a.curl, a.double, a.back)
        elif a.step == 'add_chapter':
            m, source, name = a.args
            add_chapter(int(m), source, name)
        elif a.step == 'chapters':
            m, first, other, image = map(int, a.args)
            chapters_step(m, first, other, image)
        elif a.step == 'settings_ui':
            m, ch = map(int, a.args)
            settings_ui(m, ch)
        else:
            print(__doc__)
            sys.exit(2)
    finally:
        c.rotate(False)


if __name__ == '__main__':
    main()
