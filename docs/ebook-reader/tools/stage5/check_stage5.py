"""Stage 5 checks on the emulator (debug APK): reading position, chapter progress, history, incognito
mode, table of contents, whole-book slider, tap zones, volume keys and the text / image switch.

Usage: python3 -I check_stage5.py <step> [arguments]        (environment: ADB=/path/to/adb)
  ids                                   test books on the device (manga and chapter ids)
  warmup <manga> <chapter>              opens a book once after the emulator booted (long waits)
  restore <manga> <chapter> <label> [--pages N] [--columns off|on|landscape] [--landscape]
  rotate <manga> <chapter> <label> [--pages N]
  settings <manga> <chapter> <label> [--pages N]
  fallback <manga> <chapter> <label>    (needs a saved position, e.g. from restore)
  parity <manga> <chapter> <first document>   read / unread in the chapter list: the book opens at its start
  incognito <manga> <chapter>
  chapter_list <manga> <chapter>        "Page X of Y" in the chapter list and in Recents
  toc <manga> <chapter> <label> <entry index>
  slider <manga> <chapter> <label> <fraction of the track from the left>
  end <manga> <chapter> <label>
  tapzones <manga> <chapter> <label> <mode 0-5> [NONE|HORIZONTAL|VERTICAL|BOTH]
  volume <manga> <chapter>
  switch <manga> <chapter> <label> images|no-images   text EPUB: to images and back; without pictures the
                                        image reader finds no pages and hands the book back to the text reader
  switch_back <manga> <chapter> <label> <pages>   a text book with fewer pictures than text pages, read for
                                        <pages> pages: to the image reader (no crash) and back to the same position
  switch_comic <manga> <chapter>        comic EPUB: to text and back to images
  classify <manga> <chapter>            an EPUB never opened before: routed directly after the first time
  backup_setting <chapter>              writes a per-file typesetting setting (to go through the backup)
  backup_setting_clear / backup_setting_verify   removes it before the restore / checks it came back
  backup_check <file.tachibk>           the backup holds every position of ebook.db (field 20101)
  backup_prepare <source|manga url|chapter url>   removes the positions, keeps one newer position
  backup_verify                         after restoring the backup in the App: positions back, newer one kept
Results: out/results.jsonl (one JSON line per check), screenshots: out/shots/, database copies: out/db/,
crashes and "not responding" events of the system log after each step: out/system-events.log.
Needs ../stage3/drive.py and ../stage4/verify_columns.py (see ../stage3/README.md); the App language is
Traditional Chinese (the script looks for Chinese labels).
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage3'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage4'))
import drive as d  # noqa: E402
from verify_columns import clear_dialogs  # noqa: E402

OUT = os.environ['OUT']
DB = os.path.join(OUT, 'db')
os.makedirs(DB, exist_ok=True)
STEP = ['?']
KEY_BACK, KEY_PAGE_UP, KEY_PAGE_DOWN, KEY_VOL_UP, KEY_VOL_DOWN = 4, 92, 93, 24, 25
PAGE_INFO = re.compile(r'^(\d+)/(\d+) · (\d+)(?:–(\d+))?/(\d+)$')
READER = 'yokai.ebook.EbookReaderActivity'
IMAGE_READER = 'eu.kanade.tachiyomi.ui.reader.ReaderActivity'


def check(name, ok, detail=None):
    line = {'time': time.strftime('%H:%M:%S'), 'step': STEP[0], 'check': name, 'ok': bool(ok), 'detail': detail}
    with open(os.path.join(OUT, 'results.jsonl'), 'a', encoding='utf-8') as f:
        f.write(json.dumps(line, ensure_ascii=False) + '\n')
    print('PASS' if ok else 'FAIL', name, json.dumps(detail, ensure_ascii=False)[:1500], flush=True)
    return bool(ok)


def note(text):
    print('..', text, flush=True)


# region App, preferences and databases

def stop_app(wait=5.0):
    """Stops the App after [wait] seconds, so that writes started when the reader was paused can finish."""
    time.sleep(wait)
    d.shell(f'am force-stop {d.PKG}')
    time.sleep(1)


def set_prefs(values, reset_typesetting=False):
    """Sets App preferences with the App stopped. Booleans, ints and strings get their own element types;
    None removes the key. reset_typesetting removes every pref_ebook_* key (defaults for all books)."""
    d.shell(f'am force-stop {d.PKG}')
    time.sleep(1)
    root = ET.fromstring(d.prefs())
    for e in list(root):
        name = e.get('name', '')
        if name in values or (reset_typesetting and name.startswith('pref_ebook_')):
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
    d.adb('push', tmp, '/data/local/tmp/p.xml')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/p.xml shared_prefs/{d.PKG}_preferences.xml')


def pull_db(name):
    """A copy of database [name] with its journal / WAL files (call with the App stopped)."""
    for f in os.listdir(DB):
        if f == name or f.startswith(name + '-'):
            os.remove(os.path.join(DB, f))
    for f in d.shell(f'run-as {d.PKG} ls databases').split():
        if f == name or f.startswith(name + '-'):
            with open(os.path.join(DB, f), 'wb') as out:
                out.write(d.adb('exec-out', 'run-as', d.PKG, 'cat', f'databases/{f}', text=False))
    return sqlite3.connect(os.path.join(DB, name))


def push_ebook_db():
    """Puts the local copy of ebook.db back (App stopped)."""
    d.adb('push', os.path.join(DB, 'ebook.db'), '/data/local/tmp/ebook.db')
    d.shell(f'run-as {d.PKG} rm -f databases/ebook.db-journal')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/ebook.db databases/ebook.db')


def main_rows(chapter):
    c = pull_db('tachiyomi.db')
    ch = c.execute('SELECT _id, manga_id, url, name, read, last_page_read, pages_left FROM chapters WHERE _id = ?', (chapter,)).fetchone()
    m = c.execute('SELECT source, url, title FROM mangas WHERE _id = ?', (ch[1],)).fetchone()
    h = c.execute('SELECT history_last_read, history_time_read FROM history WHERE history_chapter_id = ?', (chapter,)).fetchone()
    c.close()
    return {
        'key': (m[0], m[1], ch[2]), 'title': m[2], 'chapter': ch[3], 'read': ch[4], 'last_page_read': ch[5],
        'pages_left': ch[6], 'history_last_read': h[0] if h else None, 'history_time_read': h[1] if h else None,
    }


def ebook_rows(key):
    c = pull_db('ebook.db')
    pos = c.execute('SELECT locator FROM position WHERE source = ? AND manga_url = ? AND chapter_url = ?', key).fetchone()
    book = c.execute(
        'SELECT kind_auto, kind_user, file_size, file_modified, char_counts FROM book WHERE source = ? AND manga_url = ? AND chapter_url = ?',
        key,
    ).fetchone()
    c.close()
    info = None
    if book:
        info = {'kind_auto': book[0], 'kind_user': book[1], 'file_size': book[2], 'file_modified': book[3],
                'char_counts': [int(x) for x in book[4].split(',')] if book[4] else None}
    return (json.loads(pos[0]) if pos else None), info


def edit_position(key, change):
    """Replaces the saved position of [key] in ebook.db with change(locator) (App stopped)."""
    c = pull_db('ebook.db')
    row = c.execute('SELECT locator FROM position WHERE source = ? AND manga_url = ? AND chapter_url = ?', key).fetchone()
    new = change(json.loads(row[0]))
    c.execute(
        'UPDATE position SET locator = ? WHERE source = ? AND manga_url = ? AND chapter_url = ?',
        (json.dumps(new, ensure_ascii=False, separators=(',', ':')), *key),
    )
    c.commit()
    c.close()
    push_ebook_db()
    return new


def forget_book(key):
    """Removes [key]'s rows (classification, character counts, position) from ebook.db (App stopped), as if
    the book had never been opened."""
    c = pull_db('ebook.db')
    c.execute('DELETE FROM book WHERE source = ? AND manga_url = ? AND chapter_url = ?', key)
    c.execute('DELETE FROM position WHERE source = ? AND manga_url = ? AND chapter_url = ?', key)
    c.commit()
    c.close()
    push_ebook_db()


def estimate(counts, spine, page, pages, at_end):
    """The chapter list's page numbers as the App computes them (ReadingProgress.pages), to compare with
    what it wrote: (last_page_read, pages_left)."""
    total = sum(counts)
    per_page = counts[spine] / pages
    before = sum(counts[:spine])
    n_before = int(before / per_page + 0.5)
    n_after = int((total - before - counts[spine]) / per_page + 0.5)
    n = max(1, n_before + pages + n_after)
    current = n - 1 if at_end else min(n - 1, n_before + max(0, page))
    return current, n - current

# endregion

# region Reader


def rotate(landscape):
    d.shell('settings put system accelerometer_rotation 0')
    d.shell(f'settings put system user_rotation {1 if landscape else 0}')
    time.sleep(3)


def open_book(manga, chapter):
    st = d.open_book(manga, chapter)
    clear_dialogs()
    return st


def pos():
    v = d.cdp('JSON.stringify(window.__reader.position())')
    return json.loads(v) if isinstance(v, str) else None


def src():
    v = d.cdp("document.querySelector('#stage iframe').src")
    return v if isinstance(v, str) else None


def doc_path(url):
    return url.split('/book/', 1)[1] if url and '/book/' in url else url


VISIBLE = """(function (ni, off) {
  var frames = document.querySelectorAll('#stage iframe'), res = [];
  Array.prototype.forEach.call(frames, function (f) {
    if (f.style.visibility === 'hidden') { res.push(false); return; }
    var dd = f.contentDocument, tw = dd.createTreeWalker(dd.body, NodeFilter.SHOW_TEXT), i = 0, hit = false;
    for (var n = tw.nextNode(); n; n = tw.nextNode(), i++) if (i === ni) {
      var r = dd.createRange(); r.setStart(n, off); r.setEnd(n, off + 1); var rc = r.getClientRects()[0];
      hit = !!rc && rc.left >= -0.5 && rc.top >= -0.5 && rc.right <= f.clientWidth + 0.5 && rc.bottom <= f.clientHeight + 0.5;
      break;
    }
    res.push(hit);
  });
  return JSON.stringify(res);
})(%d, %d)"""

VISIBLE_TEXT = """(function () {
  var out = [];
  Array.prototype.forEach.call(document.querySelectorAll('#stage iframe'), function (f) {
    if (f.style.visibility === 'hidden') return;
    var dd = f.contentDocument, tw = dd.createTreeWalker(dd.body, NodeFilter.SHOW_TEXT), r = dd.createRange(), s = '';
    for (var n = tw.nextNode(); n; n = tw.nextNode()) for (var j = 0; j < n.data.length; j++) {
      var ch = n.data.charAt(j); if (/\\s/.test(ch)) continue;
      r.setStart(n, j); r.setEnd(n, j + 1); var rc = r.getClientRects()[0];
      if (rc && rc.left >= -0.5 && rc.top >= -0.5 && rc.right <= f.clientWidth + 0.5 && rc.bottom <= f.clientHeight + 0.5) s += ch;
    }
    out.push(s);
  });
  return JSON.stringify(out);
})()"""


def visible(location):
    """For each frame: whether the character at [location] is fully on screen."""
    if not location:
        return []
    v = d.cdp(VISIBLE % (location[0], location[1]))
    return json.loads(v) if isinstance(v, str) else []


def visible_text():
    v = d.cdp(VISIBLE_TEXT)
    return ''.join(json.loads(v)) if isinstance(v, str) else ''


def wait_change(before, timeout=90):
    """Waits until the shell shows another page or finished another layout than [before] (a status)."""
    t = time.time()
    while time.time() - t < timeout:
        st = d.status()
        if st and st.get('ready') and (st['page'] != before['page'] or st['seq'] != before['seq']):
            return st
        time.sleep(1)
    return d.status()


def wait_new_layout(seq_before, timeout=180):
    t = time.time()
    while time.time() - t < timeout:
        st = d.status()
        if st and st['seq'] != seq_before and st['ready']:
            return st
        time.sleep(2)
    return d.status()


def key(code, wait=2.5):
    d.shell(f'input keyevent {code}')
    time.sleep(wait)


def turn(n, code=KEY_PAGE_DOWN):
    """Turns [n] pages with a key and waits for each (a new document takes a layout)."""
    for _ in range(n):
        if READER not in d.resumed():
            raise RuntimeError('the reader is not shown: ' + d.resumed())
        st = d.status()
        key(code, 1.5)
        st2 = wait_change(st)
        if st2 and st2['page'] == st['page'] and st2['seq'] == st['seq']:
            clear_dialogs()
            key(code, 1.5)  # a key lost to a system dialog
            wait_change(st)
    time.sleep(3)  # the position is saved one second after the last page turn


def menu_shown(ns=None):
    ns = ns if ns is not None else d.nodes()
    return next((n for n in ns if n['desc'] == '目錄'), None) is not None


def show_menu():
    """Centre tap shows the toolbar and the bottom bar; a lost tap is retried."""
    for _ in range(4):
        ns = d.nodes()
        if menu_shown(ns):
            return ns
        w = max((m['b'][2] for m in ns), default=1080)
        h = max((m['b'][3] for m in ns), default=1920)
        d.tap(w // 2, h // 2, 3)
        for _ in range(3):
            ns = d.nodes()
            if menu_shown(ns):
                return ns
            time.sleep(2)
    raise RuntimeError('menu did not show')


def hide_menu():
    """Centre tap hides the toolbar and the bottom bar. (Not the back key: if the screen dump still shows
    the menu after it was hidden, a second back key would close the reader.)"""
    for _ in range(3):
        ns = d.nodes()
        if not menu_shown(ns):
            return True
        w = max((m['b'][2] for m in ns), default=1080)
        h = max((m['b'][3] for m in ns), default=1920)
        d.tap(w // 2, h // 2, 4)
    return not menu_shown()


def page_info(ns):
    return next((n['text'] for n in ns if PAGE_INFO.match(n['text'])), None)


def leave_reader():
    """Normal exit with BACK (a shown menu takes one BACK to hide)."""
    for _ in range(4):
        if READER not in d.resumed():
            return True
        key(KEY_BACK, 4)
    return READER not in d.resumed()


def slider_node(ns):
    """The whole-book slider (an enabled Compose Slider is a SeekBar in the accessibility tree; a disabled
    one is a ProgressBar). Its label 全書進度 is on a separate node with the same bounds."""
    bars = [n for n in ns if n['cls'].endswith('SeekBar')]
    label = next((n for n in ns if n['desc'] == '全書進度'), None)
    return next((n for n in bars if n['desc'] == '全書進度' or (label and n['b'] == label['b'])), None)


def slider_x(s, fraction):
    """Screen x at [fraction] of the slider's track from the left (the track is inset by the thumb)."""
    x1, _, x2, _ = s['b']
    pad = 10 * 2.625  # half the 20 dp thumb
    return int(x1 + pad + fraction * (x2 - x1 - 2 * pad))


def percent(ns):
    n = next((m for m in ns if re.fullmatch(r'\d+%', m['text'])), None)
    return int(n['text'][:-1]) if n else None


def page_span():
    """(first, after): index of the first non-whitespace character on the page (or spread) shown and of the
    first one after it in the document (the document's length when nothing follows). The pages after it are
    read through the shell and the page shown is shown again; the App does not see these moves (it saved
    the position shown before)."""
    st = d.status()
    p = pos()
    if not st or not p or p.get('before') is None:
        return None
    after = p['chars']
    k = st['page'] + st['cols']
    while k < st['pages']:
        d.cdp(f'window.__reader.goPage({k})')
        q = pos()
        if q and q.get('before') is not None:
            after = q['before']
            break
        k += st['cols']
    d.cdp(f'window.__reader.goPage({st["page"]})')
    back = pos()
    if not back or back.get('before') != p['before']:
        note(f'page_span: the page shown again is not the same: {back}')
    return p['before'], after

# endregion

# region Backup (.tachibk: gzip of the Backup protobuf message)

def _varint(b, i):
    shift = result = 0
    while True:
        c = b[i]
        i += 1
        result |= (c & 0x7F) << shift
        if c < 0x80:
            return result, i
        shift += 7


def proto_fields(b):
    """(field number, wire type, value) of a protobuf message, without a schema."""
    i, out = 0, []
    while i < len(b):
        tag, i = _varint(b, i)
        num, wt = tag >> 3, tag & 7
        if wt == 0:
            v, i = _varint(b, i)
        elif wt == 1:
            v, i = b[i:i + 8], i + 8
        elif wt == 2:
            n, i = _varint(b, i)
            v, i = b[i:i + n], i + n
        elif wt == 5:
            v, i = b[i:i + 4], i + 4
        else:
            raise ValueError(f'wire type {wt}')
        out.append((num, wt, v))
    return out


def read_backup(path):
    """Positions per (source, manga url, chapter url) from field 20101 of BackupChapter, and the keys of the
    App preferences (Backup field 104) that belong to the text reader."""
    import gzip
    with open(path, 'rb') as f:
        raw = gzip.decompress(f.read())
    positions, ebook_prefs, chapters = {}, [], 0
    for num, _, v in proto_fields(raw):
        if num == 1:  # BackupManga
            fm = proto_fields(v)
            source = next((x for n, _, x in fm if n == 1), 0)
            url = next((x.decode() for n, _, x in fm if n == 2), '')
            for n, _, ch in fm:
                if n != 16:  # chapters
                    continue
                chapters += 1
                fc = proto_fields(ch)
                curl = next((x.decode() for k, _, x in fc if k == 1), '')
                pos = next((x.decode() for k, _, x in fc if k == 20101), None)
                if pos is not None:
                    positions[(source, url, curl)] = json.loads(pos)
        elif num == 104:  # BackupPreference
            k = next((x.decode() for n, _, x in proto_fields(v) if n == 1), '')
            if k.startswith('pref_ebook_') or 'ebook' in k:
                ebook_prefs.append(k)
    return {'positions': positions, 'ebook_prefs': sorted(ebook_prefs), 'chapters': chapters}


def all_positions():
    c = pull_db('ebook.db')
    rows = c.execute('SELECT source, manga_url, chapter_url, locator FROM position').fetchall()
    c.close()
    return {(r[0], r[1], r[2]): json.loads(r[3]) for r in rows}


def override_key(key):
    """Preference key of the per-file typesetting override (EbookSettingsStore.overrideKey, FILE scope)."""
    import hashlib
    identity = f'file\u0000{key[0]}\u0000{key[1]}\u0000{key[2]}'
    return 'pref_ebook_override_' + hashlib.sha1(identity.encode('utf-8')).hexdigest()


def step_backup_setting(chapter):
    """A per-file typesetting setting (font size 26) for the book of [chapter], to see it go through a
    backup (decision 12: per-book settings are backed up too)."""
    STEP[0] = 'backup:setting'
    stop_app(0)
    m = main_rows(chapter)
    k = override_key(m['key'])
    value = json.dumps({'_source': str(m['key'][0]), '_manga': m['key'][1], '_chapter': m['key'][2], 'fontSize': '26'},
                       ensure_ascii=False, separators=(',', ':'))
    set_prefs({k: value})
    root = ET.fromstring(d.prefs())
    got = next((e.text for e in root if e.get('name') == k), None)
    check('per-file setting written', got == value, {'key': k, 'value': got})
    with open(os.path.join(OUT, 'backup-setting.json'), 'w', encoding='utf-8') as f:
        json.dump({'key': k, 'value': value}, f, ensure_ascii=False)


def step_backup_setting_clear():
    STEP[0] = 'backup:setting'
    with open(os.path.join(OUT, 'backup-setting.json'), encoding='utf-8') as f:
        k = json.load(f)['key']
    set_prefs({k: None})
    root = ET.fromstring(d.prefs())
    check('per-file setting removed before the restore', all(e.get('name') != k for e in root), k)


def step_backup_setting_verify():
    STEP[0] = 'backup:setting'
    stop_app(0)
    with open(os.path.join(OUT, 'backup-setting.json'), encoding='utf-8') as f:
        want = json.load(f)
    root = ET.fromstring(d.prefs())
    got = next((e.text for e in root if e.get('name') == want['key']), None)
    check('per-file setting restored from the backup', got == want['value'], {'key': want['key'], 'value': got})


def backed_up_manga():
    """(source, url) of the manga that a backup with the default options holds (BackupCreator): the library
    (favorite = 1) and, with "all read manga" on, the others that have a chapter read or with a page
    (mangas.sq findReadNotFavorites)."""
    c = pull_db('tachiyomi.db')
    rows = c.execute('SELECT source, url FROM mangas WHERE favorite = 1 OR _id IN '
                     '(SELECT manga_id FROM chapters WHERE read = 1 OR last_page_read != 0)').fetchall()
    c.close()
    return {(r[0], r[1]) for r in rows}


def step_backup_check(path):
    """The backup file holds the positions in ebook.db of the manga the backup holds (App stopped)."""
    STEP[0] = 'backup:file'
    stop_app(0)
    b = read_backup(path)
    device = all_positions()
    manga = backed_up_manga()
    expected = {k: v for k, v in device.items() if (k[0], k[1]) in manga}
    outside = sorted(list(k) for k in device if (k[0], k[1]) not in manga)
    note(f"{len(b['positions'])} positions in the backup, {len(device)} in ebook.db ({len(expected)} of manga the backup holds), "
         f"{b['chapters']} chapters")
    check('every position of ebook.db is in the backup (field 20101), unchanged, for the manga the backup holds',
          expected and all(b['positions'].get(k) == v for k, v in expected.items()),
          {'in ebook.db': len(device), 'of manga in the backup': len(expected), 'in backup': len(b['positions']),
           'missing or different': [list(k) for k, v in expected.items() if b['positions'].get(k) != v],
           'not in the backup by the existing rules (not in the library, no page, nothing read)': outside})
    want = None
    if os.path.exists(os.path.join(OUT, 'backup-setting.json')):
        with open(os.path.join(OUT, 'backup-setting.json'), encoding='utf-8') as f:
            want = json.load(f)['key']
    check('typesetting preferences are in the backup, with the per-file setting', want in b['ebook_prefs'] if want else len(b['ebook_prefs']) > 0,
          {'per-file key': want, 'ebook keys in the backup': b['ebook_prefs']})
    with open(os.path.join(OUT, 'backup-positions.json'), 'w', encoding='utf-8') as f:
        json.dump({'|'.join(map(str, k)): v for k, v in b['positions'].items()}, f, ensure_ascii=False, indent=1)


def step_backup_prepare(newer_key):
    """Before restoring: removes every saved position except [newer_key] (source|manga url|chapter url),
    which gets a different position with a later time than the backup's (it must survive the restore)."""
    STEP[0] = 'backup:prepare'
    stop_app(0)
    k = tuple(newer_key.split('|'))
    k = (int(k[0]), k[1], k[2])
    c = pull_db('ebook.db')
    row = c.execute('SELECT locator FROM position WHERE source = ? AND manga_url = ? AND chapter_url = ?', k).fetchone()
    newer = dict(json.loads(row[0]), location=[0, 0], text='', progression=0.0, total=0.0, updatedAt=int(time.time() * 1000) + 86_400_000)
    c.execute('DELETE FROM position')
    c.execute('INSERT INTO position(source, manga_url, chapter_url, locator, updated_at) VALUES (?, ?, ?, ?, ?)',
              (*k, json.dumps(newer, ensure_ascii=False, separators=(',', ':')), newer['updatedAt']))
    c.commit()
    c.close()
    push_ebook_db()
    with open(os.path.join(OUT, 'backup-newer.json'), 'w', encoding='utf-8') as f:
        json.dump({'key': list(k), 'locator': newer}, f, ensure_ascii=False)
    check('positions removed, one newer position kept', len(all_positions()) == 1, newer)


def step_backup_verify():
    STEP[0] = 'backup:restored'
    stop_app(0)
    with open(os.path.join(OUT, 'backup-positions.json'), encoding='utf-8') as f:
        backup = {tuple(int(p) if i == 0 else p for i, p in enumerate(k.split('|', 2))): v for k, v in json.load(f).items()}
    with open(os.path.join(OUT, 'backup-newer.json'), encoding='utf-8') as f:
        newer = json.load(f)
    nk = tuple(newer['key'])
    device = all_positions()
    others = {k: v for k, v in backup.items() if k != nk}
    check('restored: every position from the backup is back', others and all(device.get(k) == v for k, v in others.items()),
          {'restored': sum(device.get(k) == v for k, v in others.items()), 'of': len(others)})
    check('restored: a newer position on the device is kept', device.get(nk) == newer['locator'], {'device': device.get(nk), 'kept': newer['locator']})

# endregion


# region Steps


def step_warmup(manga, chapter):
    """The first book opened after the emulator booted takes minutes (the WebView starts for the first
    time); this opens one with long waits, so that the timed steps that follow do not run into it."""
    STEP[0] = 'warmup'
    d.shell(f'am force-stop {d.PKG}')
    time.sleep(2)
    d.shell(f'am start -n {d.PKG}/{IMAGE_READER} --el manga {manga} --el chapter {chapter}')
    r = wait_resumed(READER, timeout=600)
    pid = d.shell(f'pidof {d.PKG}').strip()
    d.adb('forward', '--remove-all')
    d.adb('forward', 'tcp:9333', f'localabstract:webview_devtools_remote_{pid}')
    st = d.wait_ready(timeout=900, settle=2.0)
    note(f'warm-up: {r} {st}')
    leave_reader()
    stop_app()


def save_system_logs(step):
    """Appends crashes (logcat crash buffer) and "not responding" / crash events of the event log to
    out/system-events.log, then clears both buffers, so that each step's entries can be told apart."""
    crash = d.adb('logcat', '-d', '-b', 'crash')
    events = [ln for ln in d.adb('logcat', '-d', '-b', 'events').splitlines() if 'am_anr' in ln or 'am_crash' in ln]
    if crash.strip() or events:
        with open(os.path.join(OUT, 'system-events.log'), 'a', encoding='utf-8') as f:
            f.write(f'--- {time.strftime("%H:%M:%S")} after {step}\n')
            if crash.strip():
                f.write(crash.rstrip() + '\n')
            for ln in events:
                f.write(ln + '\n')
    d.adb('logcat', '-c', '-b', 'crash')
    d.adb('logcat', '-c', '-b', 'events')


def step_ids():
    c = pull_db('tachiyomi.db')
    rows = c.execute('SELECT m._id, m.title, c._id, c.url, c.read, c.last_page_read, c.pages_left FROM mangas m '
                     'JOIN chapters c ON c.manga_id = m._id ORDER BY m._id, c._id').fetchall()
    for r in rows:
        print(r)
    c.close()


def ensure_unread(manga, chapter):
    """A read chapter opens at the start of the book (like the manga reader), which would hide whether
    the position is restored; such a chapter is marked unread first, in the chapter list (App stopped
    afterwards). Returns the chapter's rows."""
    stop_app(0)
    m = main_rows(chapter)
    if m['read']:
        note(f"chapter {chapter} is read; marking it unread in the chapter list")
        m = set_read(manga, chapter, False)
        if m['read']:
            raise RuntimeError(f'chapter {chapter} is still read')
    return m


def go_to_start():
    """Shows the start of the book: the first table of contents entry, unless the first page of the first
    document is shown already (page information 1/N · 1/M)."""
    ns = show_menu()
    info = page_info(ns)
    mt = PAGE_INFO.match(info or '')
    if mt and mt.group(1) == '1' and mt.group(3) == '1':
        hide_menu()
        return info
    st0 = d.status()
    n = d.find('目錄', exact=True)
    d.tap(n['x'], n['y'], 4)
    items = []
    for _ in range(6):
        items = toc_items(d.nodes())
        if items:
            break
        time.sleep(2)
    if not items:
        raise RuntimeError('table of contents did not open')
    d.tap(items[0]['x'], items[0]['y'], 3)
    wait_change(st0, 120)
    time.sleep(3)
    ns = show_menu()
    info = page_info(ns)
    hide_menu()
    return info


def step_restore(manga, chapter, label, pages, columns, landscape):
    STEP[0] = 'restore:' + label
    set_prefs({'pref_ebook_columns': columns} if columns != 'off' else {}, reset_typesetting=True)
    rotate(landscape)
    before = ensure_unread(manga, chapter)
    t_open = time.time()
    open_book(manga, chapter)
    note('start: ' + str(go_to_start()))
    turn(pages)
    p = pos()
    st = d.status()
    s = doc_path(src())
    d.shot(label + '-1-before-exit')
    if p is None or st is None:
        check('the reader answers after the page turns', False,
              {'resumed': d.resumed(), 'pid': d.shell(f'pidof {d.PKG}').strip(), 'status': st, 'position': p})
        return
    note(f'shown: {s} page {st["page"]}/{st["pages"]} cols {st["cols"]} {p}')
    left = leave_reader()
    t_close = time.time()
    stop_app()
    m = main_rows(chapter)
    saved, book = ebook_rows(m['key'])
    check('normal exit with BACK', left, d.resumed())
    check('saved position = position shown at exit', saved is not None and saved.get('location') == p['location']
          and saved.get('text') == p['text'] and saved.get('href') == s, {'saved': saved, 'shown': p, 'doc': s})
    counts = book['char_counts'] if book else None
    if counts and saved:
        want = estimate(counts, saved['spine'], st['page'], st['pages'], saved.get('atEnd', False))
        check('chapter list page numbers (last_page_read, pages_left) from the page shown',
              (m['last_page_read'], m['pages_left']) == want,
              {'db': (m['last_page_read'], m['pages_left']), 'expected': want, 'page': st['page'], 'pages': st['pages'],
               'char_counts': counts, 'Page X of Y': f"Page {m['last_page_read'] + 1} of {m['pages_left'] + m['last_page_read']}"})
    else:
        check('chapter list page numbers', False, {'book': book, 'saved': saved})
    spent = (t_close - t_open) * 1000
    added = (m['history_time_read'] or 0) - (before['history_time_read'] or 0)
    check('history: reading time added at exit', m['history_time_read'] is not None and 0 < added <= spent + 5000,
          {'before': before['history_time_read'], 'after': m['history_time_read'], 'added ms': added, 'reader open ms (upper bound)': int(spent)})
    check('history: last read is the exit time', m['history_last_read'] is not None and abs(m['history_last_read'] / 1000 - t_close) < 120,
          {'last_read': m['history_last_read'], 'exit': int(t_close * 1000)})
    st2 = open_book(manga, chapter)
    p2 = pos()
    s2 = doc_path(src())
    vis = visible(saved['location'] if saved else None)
    d.shot(label + '-2-reopened')
    check('reopened at the same page and character', s2 == s and st2['page'] == st['page'] and p2 and p2['location'] == p['location'] and any(vis),
          {'doc': (s, s2), 'page': (st['page'], st2['page']), 'location': (p['location'], p2 and p2['location']), 'visible': vis})
    leave_reader()
    stop_app()
    if landscape:
        rotate(False)


def step_rotate(manga, chapter, label, pages):
    STEP[0] = 'rotate:' + label
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    ensure_unread(manga, chapter)
    open_book(manga, chapter)
    note('start: ' + str(go_to_start()))
    turn(pages)
    a = pos()
    st0 = d.status()
    rotate(True)
    st1 = wait_new_layout(st0['seq'])
    time.sleep(5)  # the page indicator and the position are read again after the relayout, then saved
    b = pos()
    vis1 = visible(a['location'])
    d.shot(label + '-1-landscape')
    check('rotated to landscape: the first character stays the reading position and is on screen',
          b and b['location'] == a['location'] and any(vis1), {'before': a, 'after': b, 'status': st1, 'visible': vis1})
    leave_reader()
    stop_app()
    m = main_rows(chapter)
    saved, _ = ebook_rows(m['key'])
    check('landscape exit: saved position is the same character', saved and saved['location'] == a['location'], saved)
    open_book(manga, chapter)
    vis2 = visible(a['location'])
    d.shot(label + '-2-reopened-landscape')
    check('reopened in landscape: the character is on screen', any(vis2), vis2)
    st2 = d.status()
    rotate(False)
    wait_new_layout(st2['seq'])
    time.sleep(5)
    vis3 = visible(a['location'])
    check('rotated back to portrait: the character is on screen', any(vis3), vis3)
    leave_reader()
    stop_app()
    st4 = open_book(manga, chapter)
    vis4 = visible(a['location'])
    p4 = pos()
    d.shot(label + '-3-reopened-portrait')
    check('reopened in portrait: same page as before the rotations', p4 and p4['location'] == a['location'] and st4['page'] == st0['page'] and any(vis4),
          {'page before': st0['page'], 'page now': st4['page'], 'location': p4 and p4['location'], 'visible': vis4})
    leave_reader()
    stop_app()


def step_settings(manga, chapter, label, pages):
    STEP[0] = 'settings:' + label
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    ensure_unread(manga, chapter)
    open_book(manga, chapter)
    note('start: ' + str(go_to_start()))
    turn(pages)
    a = pos()
    st0 = d.status()
    d.open_panel()
    d.set_slider('字級', (30 - 12) / 36)
    st1 = wait_new_layout(st0['seq'])
    time.sleep(3)
    d.close_panel()
    time.sleep(4)
    b = pos()
    vis = visible(a['location'])
    d.shot(label + '-1-font-30')
    check('font size 30: the reading position stays the same character, on screen',
          b and b['location'] == a['location'] and any(vis), {'before': a, 'after': b, 'status': st1, 'visible': vis})
    leave_reader()
    stop_app()
    m = main_rows(chapter)
    saved, _ = ebook_rows(m['key'])
    check('saved after the change: same character', saved and saved['location'] == a['location'], saved)
    open_book(manga, chapter)
    vis2 = visible(a['location'])
    d.shot(label + '-2-reopened')
    check('reopened with font size 30: the character is on screen', any(vis2), vis2)
    leave_reader()
    set_prefs({}, reset_typesetting=True)


def step_fallback(manga, chapter, label):
    STEP[0] = 'fallback:' + label
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    m = main_rows(chapter)
    saved, _ = ebook_rows(m['key'])
    if not saved or not saved.get('location') or m['read'] or m['last_page_read'] == 0:
        check('starting point: unread, a saved position with a location', False, {'saved': saved, 'read': m['read'], 'last_page_read': m['last_page_read']})
        return
    # 1. The location does not match any more (e.g. the file was edited): found again by the saved text.
    edit_position(m['key'], lambda loc: dict(loc, location=[0, 0]))
    st = open_book(manga, chapter)
    p = pos()
    s = doc_path(src())
    d.shot(label + '-1-by-text')
    check('wrong location: restored by the saved text', s == saved['href'] and p and p['location'] == saved['location'] and p['text'] == saved['text'],
          {'saved': saved, 'shown': p, 'page': st['page']})
    leave_reader()
    stop_app()
    # 2. Neither the location nor the text match: the fraction of the document.
    saved2, _ = ebook_rows(m['key'])
    edit_position(m['key'], lambda loc: dict(loc, location=[0, 0], text='這段文字不在書裡甲乙丙丁'))
    open_book(manga, chapter)
    p = pos()
    want = int(saved2['progression'] * p['chars'] + 1e-6) if p else None
    d.shot(label + '-2-by-fraction')
    check('wrong location and text: restored by the fraction', p and p['before'] == want and doc_path(src()) == saved2['href'],
          {'progression': saved2['progression'], 'chars': p and p['chars'], 'expected first character': want, 'shown': p})
    leave_reader()
    stop_app()


def open_manga(manga):
    d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity -a eu.kanade.tachiyomi.SHOW_MANGA --el manga {manga}')


SWIPES = [0]


def wait_app_drawn(timeout=120):
    """Waits until the App's launch screen is gone. It is the system's starting window "Splash Screen
    <package>", kept until the App's window draws (BaseActivity keeps it up to 5 s after the activity is
    created, which itself takes seconds on this emulator); touches made meanwhile are lost."""
    t = time.time()
    while time.time() - t < timeout:
        if f'Splash Screen {d.PKG}' not in d.shell('dumpsys window windows'):
            return True
        time.sleep(2)
    return False


def swipe_chapter_left(manga, name):
    """In the chapter list a swipe to the left toggles read / unread (MangaDetailsAdapter.onItemSwiped);
    "unread" also clears last_page_read and pages_left (MangaDetailsPresenter.markChaptersRead).
    Returns the snackbar text the swipe shows (標示為已讀 / 標示為未讀), or None when none was seen. A
    screenshot after each swipe is kept (swipe-N.png)."""
    open_manga(manga)
    row = None
    for _ in range(20):
        time.sleep(4)
        if not wait_app_drawn():
            note('the launch screen is still shown')
        clear_dialogs()
        row = d.find(name, exact=True)
        if row:
            time.sleep(3)  # the manga screen fades in (a touch during the transition is ignored)
            row = d.find(name, exact=True) or row
            break
    SWIPES[0] += 1
    if row is None:
        note(f'swipe {SWIPES[0]}: chapter row {name} not found')
        d.shot(f'swipe-{SWIPES[0]}-no-row')
        return None
    d.swipe(980, row['y'], 120, row['y'], 1500, 1)  # a 300 ms swipe is often not taken on this emulator
    snack = None
    for _ in range(4):
        ns = d.nodes()
        snack = d.find('標示為已讀', ns, exact=True) or d.find('標示為未讀', ns, exact=True)
        if snack:
            break
        time.sleep(1)
    d.shot(f'swipe-{SWIPES[0]}')
    note(f"swipe {SWIPES[0]} on {name} at y={row['y']}: snackbar {snack and snack['text']}")
    time.sleep(4)
    return snack and snack['text']


def set_read(manga, chapter, want):
    """Marks [chapter] read (want=True) or unread in the chapter list, checking the database after each
    swipe (App stopped) and swiping again only while the state is not [want]: a swipe that was not
    taken is retried, a swipe that was taken is never repeated. Returns the chapter's rows."""
    stop_app(0)
    m = main_rows(chapter)
    for attempt in range(3):
        if bool(m['read']) == want:
            return m
        if attempt:
            note(f'chapter {chapter} is still {"unread" if want else "read"}; swiping again')
        swipe_chapter_left(manga, m['chapter'])
        stop_app(3)
        m = main_rows(chapter)
    return m


def at_start():
    st = d.status()
    return st, doc_path(src())


def step_parity(manga, chapter, first_doc):
    """Like the manga reader: a chapter marked read in the chapter list, and one marked unread there
    (which clears its page), open at the start of the book instead of the saved position."""
    STEP[0] = 'parity'
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    m0 = main_rows(chapter)
    saved0, _ = ebook_rows(m0['key'])
    check('starting point: unread, a saved position past the first page', not m0['read'] and saved0 and (saved0.get('chapterPage') or 0) > 0,
          {'chapter': {k: m0[k] for k in ('read', 'last_page_read', 'pages_left')}, 'saved': saved0})
    # 1. read, then unread again in the chapter list: the page is cleared
    m1 = set_read(manga, chapter, True)
    m2 = set_read(manga, chapter, False)
    check('chapter list: marked read, then unread (page cleared)', m1['read'] == 1 and m2['read'] == 0 and m2['last_page_read'] == 0 and m2['pages_left'] == 0,
          {'after first swipe': {k: m1[k] for k in ('read', 'last_page_read', 'pages_left')},
           'after second swipe': {k: m2[k] for k in ('read', 'last_page_read', 'pages_left')}})
    st = open_book(manga, chapter)
    s = doc_path(src())
    d.shot('parity-1-cleared')
    check('marked unread (page cleared): opens at the start, not at the saved position', st['page'] == 0 and s == first_doc,
          {'doc': s, 'page': st['page'], 'saved position was': saved0 and [saved0['href'], saved0.get('location')]})
    # 2. a saved position in the middle, then marked read in the chapter list
    turn(6)
    mid = pos()
    mid_doc = doc_path(src())
    leave_reader()
    stop_app()
    m3 = set_read(manga, chapter, True)
    saved3, _ = ebook_rows(m3['key'])
    st = open_book(manga, chapter)
    s = doc_path(src())
    d.shot('parity-2-read')
    check('marked read: opens at the start, not at the saved position', m3['read'] == 1 and st['page'] == 0 and s == first_doc,
          {'read': m3['read'], 'doc': s, 'page': st['page'], 'saved position': saved3 and [saved3['href'], saved3.get('location')], 'left at': [mid_doc, mid and mid['location']]})
    leave_reader()
    stop_app()
    # back to unread for the later steps
    set_read(manga, chapter, False)


def step_incognito(manga, chapter, pages=3):
    STEP[0] = 'incognito'
    set_prefs({'incognito_mode': True}, reset_typesetting=True)
    m0 = main_rows(chapter)
    p0, _ = ebook_rows(m0['key'])
    open_book(manga, chapter)
    turn(pages)
    shown = pos()
    leave_reader()
    stop_app()
    m1 = main_rows(chapter)
    p1, _ = ebook_rows(m1['key'])
    check('incognito: the saved position is unchanged', p1 == p0, {'before': p0, 'after': p1, 'shown at exit': shown})
    keys = ('read', 'last_page_read', 'pages_left')
    check('incognito: chapter progress unchanged', all(m1[k] == m0[k] for k in keys), {k: (m0[k], m1[k]) for k in keys})
    hk = ('history_last_read', 'history_time_read')
    check('incognito: history unchanged', all(m1[k] == m0[k] for k in hk), {k: (m0[k], m1[k]) for k in hk})
    set_prefs({'incognito_mode': None})


def step_chapter_list(manga, chapter):
    STEP[0] = 'chapter_list'
    stop_app(0)
    m = main_rows(chapter)
    want = f"Page {m['last_page_read'] + 1} of {m['pages_left'] + m['last_page_read']}"
    d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity -a eu.kanade.tachiyomi.SHOW_MANGA --el manga {manga}')
    hit = None
    for _ in range(20):
        time.sleep(4)
        clear_dialogs()
        hit = d.find(want)
        if hit:
            break
    d.shot('chapter-list')
    check('chapter list shows the page of the text book', hit is not None and not m['read'], {'expected': want, 'node': hit and hit['text'], 'read': m['read']})
    # Recents (the bottom navigation item 最新 in Traditional Chinese). The manga screen opened by the
    # intent above sits on top of the library and hides the bottom navigation: back first (once the
    # launch screen is gone, so that the key is not lost).
    wait_app_drawn()
    time.sleep(3)
    key(KEY_BACK, 4)
    tab = None
    for _ in range(5):
        tab = d.find('最新', exact=True)
        if tab:
            break
        time.sleep(2)
    found = None
    if tab:
        d.tap(tab['x'], tab['y'], 6)
        for _ in range(10):
            found = d.find(want)
            if found:
                break
            time.sleep(3)
    d.shot('recents')
    check('Recents shows the page of the text book', found is not None, {'expected': want, 'node': found and found['text'], 'tab': bool(tab)})
    stop_app(0)


def toc_items(ns):
    return [n for n in ns if n['cls'].endswith('CheckedTextView')]


def open_toc():
    show_menu()
    n = d.find('目錄', exact=True)
    d.tap(n['x'], n['y'], 4)
    for _ in range(6):
        ns = d.nodes()
        items = toc_items(ns)
        if items:
            return items
        time.sleep(2)
    return []


def step_toc(manga, chapter, label, entry):
    STEP[0] = 'toc:' + label
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    open_book(manga, chapter)
    items = open_toc()
    d.shot(label + '-1-toc')
    labels = [n['text'] for n in items]
    check('table of contents listed', len(labels) > entry, labels)
    if len(labels) <= entry:
        leave_reader()
        return
    title = labels[entry].replace('　', '').strip()
    st0 = d.status()
    d.tap(items[entry]['x'], items[entry]['y'], 3)
    st = wait_change(st0, 120)
    time.sleep(3)
    text = visible_text()
    s = doc_path(src())
    d.shot(label + '-2-after-jump')
    # Compared after NFKC normalization: a table of contents may write 第1章 for the heading 第１章.
    import unicodedata
    compact = unicodedata.normalize('NFKC', re.sub(r'\s', '', title))
    check('jumped to the entry: its title is on the page', compact in unicodedata.normalize('NFKC', text),
          {'entry': labels[entry], 'doc': s, 'page': st and st['page'], 'visible text': text[:120]})
    items2 = open_toc()
    checked = [i for i, n in enumerate(items2) if n['checked']]
    d.shot(label + '-3-toc-current')
    check('the current entry is marked when the contents open again', checked == [entry], {'checked': checked, 'expected': entry})
    key(KEY_BACK, 3)  # closes the dialog
    leave_reader()
    stop_app()


# Raw touch events on the emulator's touch screen ("qwerty2": multi-touch protocol B, axes 0..32767 over the
# 1080 x 1920 screen in portrait). A touch needs a pressure above 0: with a pressure axis, Android takes a contact
# without pressure for hovering.
TOUCH_DEV = '/dev/input/event1'


def _ev(type_, code, value):
    return f'sendevent {TOUCH_DEV} {type_} {code} {value}'


def _touch_at(x, y):
    return [_ev(3, 53, round(x * 32767 / 1080)), _ev(3, 54, round(y * 32767 / 1920)), _ev(0, 0, 0)]


def touch_down(x, y):
    return [_ev(3, 47, 0), _ev(3, 57, 7), _ev(3, 48, 5), _ev(3, 58, 512)] + _touch_at(x, y)


def touch_moves(x1, x2, y, steps):
    return [e for i in range(1, steps + 1) for e in _touch_at(x1 + (x2 - x1) * i / steps, y)]


def touch_up():
    return [_ev(3, 47, 0), _ev(3, 57, -1), _ev(0, 0, 0)]


def touch(events):
    d.shell('; '.join(events), timeout=180)


def step_slider(manga, chapter, label, fraction):
    STEP[0] = 'slider:' + label
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    open_book(manga, chapter)
    ns = show_menu()
    s = slider_node(ns)
    if not check('slider shown with the menu', s is not None, page_info(ns)):
        return
    rtl = bool(d.cdp('window.__reader.status().mode') == 'V')
    # Drag, holding the finger down: the label shows the table of contents entry under the thumb. The drag is made
    # of raw touch events and the finger stays still for a moment part of the way (stage 7): uiautomator dumps the
    # screen only once it is idle, and with `input swipe` (which moves the finger without a pause) the dump came
    # after the finger was lifted. The screenshot is taken while the finger is down.
    x_from, x_to = slider_x(s, 0.1), slider_x(s, fraction)
    x_mid = x_from + (x_to - x_from) * 0.55
    y = s['y']
    st0 = d.status()
    touch(touch_down(x_from, y) + touch_moves(x_from, x_mid, y, 12))
    time.sleep(2)
    t_dump = time.time()
    mid = d.nodes()
    dump_s = round(time.time() - t_dump, 1)
    d.shot(label + '-1-dragging')
    touch(touch_moves(x_mid, x_to, y, 12) + touch_up())
    # The bar's texts are TextView nodes (the book's text in the WebView is in View nodes).
    bar_texts = [n['text'] for n in mid if n['text'] and n['y'] > 1500 and n['cls'].endswith('TextView')
                 and not re.fullmatch(r'\d+%', n['text'])]
    check('while dragging, the bar shows a table of contents title instead of the page', bar_texts and not any(PAGE_INFO.match(x) for x in bar_texts),
          {'bar texts while dragging': bar_texts, 'page info before': page_info(ns),
           'finger held at (fraction of the track)': round(0.1 + (fraction - 0.1) * 0.55, 3), 'dump took (s)': dump_s})
    st = wait_change(st0, 120)
    time.sleep(4)
    after = d.nodes()
    pct = percent(after)
    want = (1 - fraction) if rtl else fraction
    span = page_span()
    d.shot(label + '-2-released')
    leave_reader()
    stop_app()
    m = main_rows(chapter)
    saved, book = ebook_rows(m['key'])
    counts = (book or {}).get('char_counts') or []
    total = sum(counts)
    start = end = None
    if saved and span and total:
        before = sum(counts[:saved['spine']])
        start, end = before + span[0], before + span[1]
    # The slider goes to the page that holds the character at its value. The value is behind the finger by
    # the touch slop (8 dp, about 2 % of the track here): a drag starts after that distance and the slider
    # does not add it (seen: released at 25 %, value about 22.9 %). So the page shown must hold a character
    # between the finger's fraction minus 3 % and plus 0.5 % (where the finger was released is known to a
    # few pixels); the progress shown and saved is then checked exactly against that page.
    target = want * total
    # The drag starts at 0.1 of the track: in the book, the value grows along the drag for a left-to-right
    # slider and shrinks for a right-to-left one, and it stays behind the finger.
    grows = (not rtl) == (fraction > 0.1)
    lo, hi = (target - 0.03 * total, target + 0.005 * total) if grows else (target - 0.005 * total, target + 0.03 * total)
    check(f'released at {fraction:.2f} of the track ({"right to left" if rtl else "left to right"}): the page shown holds a character near {want:.2f} of the book',
          start is not None and start <= hi and end > lo,
          {'finger at character': round(target), 'accepted characters': [round(lo), round(hi)], 'page shown, characters': [start, end], 'of': total,
           'status': st, 'page info': page_info(after)})
    # The progress shown and saved is that of the page's first character (the reading position).
    check('percent shown and saved whole-book progress are those of the first character of that page',
          start is not None and pct is not None and abs(pct / 100 - start / total) <= 0.006 and saved.get('total') is not None
          and abs(saved['total'] - start / total) < 0.002,
          {'percent shown': pct, 'saved total': saved and saved.get('total'), 'first character / book': start and round(start / total, 4)})


def step_end(manga, chapter, label):
    STEP[0] = 'end:' + label
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    open_book(manga, chapter)
    ns = show_menu()
    s = slider_node(ns)
    rtl = bool(d.cdp('window.__reader.status().mode') == 'V')
    st0 = d.status()
    # Near the end of the book with the slider (the left end of a right-to-left slider), then page turns
    # to the last page, as a reader would. The slider takes touches on its track only (a tap in the
    # padding at its very end does nothing), and on this emulator the last moves of a drag past the end
    # are not all applied (it stopped at 95-99 %), so the slider alone does not reach the last page.
    x_from = slider_x(s, 0.5)
    x_to = 0 if rtl else 1079
    d.swipe(x_from, s['y'], x_to, s['y'], 1500, 3)
    st = wait_change(st0, 120)
    time.sleep(4)
    hide_menu()
    near = st
    turns = 0
    for _ in range(12):
        before = (doc_path(src()), d.status())
        key(KEY_PAGE_DOWN, 4)
        after = (doc_path(src()), d.status())
        if after[0] == before[0] and after[1] and before[1] and after[1]['page'] == before[1]['page']:
            break  # the last page: Page Down shows 已到本書結尾 and stays
        turns += 1
    st = d.status()
    p = pos()
    last_doc = doc_path(src())
    d.shot(label + '-1-end')
    check('slider near the end, then page turns: the last page of the book', st and st['page'] + st['cols'] > st['pages'] - 1,
          {'after the slider': near, 'page turns': turns, 'status': st, 'doc': last_doc, 'percent': percent(d.nodes())})
    leave_reader()
    stop_app()
    m = main_rows(chapter)
    saved, _ = ebook_rows(m['key'])
    check('the last page marks the chapter read', m['read'] == 1 and saved and saved.get('atEnd') is True and m['pages_left'] == 1,
          {'read': m['read'], 'last_page_read': m['last_page_read'], 'pages_left': m['pages_left'], 'saved': saved})
    st2 = open_book(manga, chapter)
    s2 = doc_path(src())
    d.shot(label + '-2-reopened')
    check('a finished book opens at its start again', st2['page'] == 0 and s2 != last_doc, {'doc': s2, 'status': st2})
    leave_reader()
    stop_app()


# Tap zones of the existing reader settings, as rectangles (left, top, right, bottom) of the screen, from
# app/src/main/java/eu/kanade/tachiyomi/ui/reader/viewer/navigation/*.kt.
REGIONS = {
    'L': [((0, .33, .33, .66), 'PREV'), ((0, 0, 1, .33), 'PREV'), ((.66, .33, 1, .66), 'NEXT'), ((0, .66, 1, 1), 'NEXT')],
    'Kindlish': [((.33, .33, 1, 1), 'NEXT'), ((0, .33, .33, 1), 'PREV')],
    'Edge': [((0, 0, .33, 1), 'NEXT'), ((.33, .66, .66, 1), 'PREV'), ((.66, 0, 1, 1), 'NEXT')],
    'RightAndLeft': [((0, 0, .33, 1), 'LEFT'), ((.66, 0, 1, 1), 'RIGHT')],
    'Disabled': [],
}
MODES = {0: 'RightAndLeft', 1: 'L', 2: 'Kindlish', 3: 'Edge', 4: 'RightAndLeft', 5: 'Disabled'}


def invert(r, mode):
    left, top, right, bottom = r
    h = mode in ('HORIZONTAL', 'BOTH')
    v = mode in ('VERTICAL', 'BOTH')
    if h and v:
        return 1 - right, 1 - bottom, 1 - left, 1 - top
    if v:
        return left, 1 - bottom, right, 1 - top
    if h:
        return 1 - right, top, 1 - left, bottom
    return r


def expected_action(mode, inv, x, y, rtl):
    for r, kind in REGIONS[MODES[mode]]:
        left, top, right, bottom = invert(r, inv)
        if left <= x < right and top <= y < bottom:  # RectF.contains
            if kind == 'LEFT':
                return 'NEXT' if rtl else 'PREV'
            if kind == 'RIGHT':
                return 'PREV' if rtl else 'NEXT'
            return kind
    return 'MENU'


def observe(before, timeout=10):
    """NEXT / PREV from the page that the shell shows, MENU when the toolbar appeared, else NONE."""
    t = time.time()
    while time.time() - t < timeout:
        st = d.status()
        if st and st.get('ready') and (st['page'] != before['page'] or st['seq'] != before['seq']):
            if st['seq'] != before['seq']:
                return 'NEXT?' , st  # another document opened (not expected in the middle of a document)
            return ('NEXT' if st['page'] > before['page'] else 'PREV'), st
        time.sleep(1.5)
    ns = d.nodes()
    if menu_shown(ns):
        hide_menu()
        return 'MENU', d.status()
    return 'NONE', d.status()


def middle_page():
    st = d.status()
    want = (st['pages'] // 2) - ((st['pages'] // 2) % max(1, st['cols']))
    if st['page'] != want:
        d.cdp('window.__reader.goPage(%d); "ok"' % want)
        time.sleep(2)
    return d.status()


def step_tapzones(manga, chapter, label, mode, inv):
    STEP[0] = f'tapzones:{label}:{mode}:{inv}'
    set_prefs({'reader_navigation_mode_pager': mode, 'reader_tapping_inverted': inv}, reset_typesetting=True)
    rotate(False)
    st = open_book(manga, chapter)
    rtl = st['mode'] == 'V'
    w, h = 1080, 1920
    points = [(1 / 6, 1 / 2), (5 / 6, 1 / 2), (1 / 2, 1 / 2), (1 / 2, 1 / 6), (1 / 2, 5 / 6), (1 / 6, 5 / 6), (5 / 6, 1 / 6)]
    if MODES[mode] == 'L':
        points += [(1 / 6, 1 / 6), (5 / 6, 5 / 6)]
    rows = []
    for fx, fy in points:
        before = middle_page()
        d.tap(int(fx * w), int(fy * h), 1.5)
        got, _ = observe(before)
        want = expected_action(mode, inv, fx, fy, rtl)
        rows.append({'point': (round(fx, 2), round(fy, 2)), 'expected': want, 'got': got})
        note(rows[-1])
    check(f'tap zones mode {mode} ({MODES[mode]}), inverted {inv}, {"right-to-left" if rtl else "left-to-right"} book',
          all(r['expected'] == r['got'] for r in rows), rows)
    leave_reader()
    set_prefs({'reader_navigation_mode_pager': None, 'reader_tapping_inverted': None})


def step_volume(manga, chapter):
    for on, inverted in ((True, False), (True, True), (False, False)):
        STEP[0] = f'volume:on={on}:inverted={inverted}'
        set_prefs({'reader_volume_keys': on, 'reader_volume_keys_inverted': inverted}, reset_typesetting=True)
        rotate(False)
        open_book(manga, chapter)
        rows = []
        for code, name in ((KEY_VOL_DOWN, 'VOLUME_DOWN'), (KEY_VOL_UP, 'VOLUME_UP')):
            before = middle_page()
            key(code, 1.5)
            got, _ = observe(before, timeout=12)
            if got == 'NONE':
                clear_dialogs()
            if not on:
                want = 'NONE'
            elif (code == KEY_VOL_DOWN) != inverted:
                want = 'NEXT'
            else:
                want = 'PREV'
            rows.append({'key': name, 'expected': want, 'got': got})
        d.shot(f'volume-{on}-{inverted}')
        check(f'volume keys option {on}, inverted {inverted}', all(r['expected'] == r['got'] for r in rows), rows)
        key(KEY_BACK, 3)  # the volume panel, if any
        leave_reader()
    set_prefs({'reader_volume_keys': None, 'reader_volume_keys_inverted': None})


def overflow_item(label):
    """Opens the toolbar's overflow menu and taps [label]."""
    for _ in range(3):
        n = d.find('更多選項', exact=True)
        if n is None:
            time.sleep(2)
            continue
        d.tap(n['x'], n['y'], 3)
        item = None
        for _ in range(4):
            item = d.find(label, exact=True)
            if item:
                break
            time.sleep(2)
        if item:
            d.tap(item['x'], item['y'], 4)
            return True
        key(KEY_BACK, 2)
    return False


def wait_resumed(name, timeout=180):
    t = time.time()
    while time.time() - t < timeout:
        r = d.resumed()
        if name in r:
            return r
        clear_dialogs()
        time.sleep(3)
    return d.resumed()


def image_reader_menu():
    """The image reader shows its toolbar on a centre tap."""
    for _ in range(4):
        if d.find('更多選項', exact=True):
            return True
        d.tap(540, 960, 4)
    return d.find('更多選項', exact=True) is not None


def activity_starts():
    """Activities of the App started since the last `logcat -c`, in order (ActivityManager log)."""
    log = d.adb('logcat', '-d', '-s', 'ActivityManager:I')
    return [ln.split('cmp=')[1].split()[0].rstrip('}') for ln in log.splitlines() if 'START u0' in ln and d.PKG in ln and 'cmp=' in ln]


def to_images():
    """Text reader: toolbar overflow menu, 以圖片模式開啟."""
    show_menu()
    return overflow_item('以圖片模式開啟')


def to_text():
    """Image reader: its toolbar (centre tap), overflow menu, 以文字模式開啟."""
    return image_reader_menu() and overflow_item('以文字模式開啟')


def step_switch(manga, chapter, label, has_images):
    """A text EPUB: to the image reader and back (has_images), or, for a book without pictures, the image
    reader finds no pages and the text reader opens again with a notice."""
    STEP[0] = 'switch:' + label
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    m = main_rows(chapter)
    open_book(manga, chapter)
    d.adb('logcat', '-c')
    ok = to_images()
    if not has_images:
        t = time.time()
        starts = []
        while time.time() - t < 120:
            starts = activity_starts()
            if any(IMAGE_READER in x for x in starts) and any(READER in x for x in starts[1:]):
                break
            time.sleep(3)
        r = wait_resumed(READER)
        d.shot(label + '-1-back-in-text-reader')
        check('book without pictures: the image reader finds no pages and the text reader opens again',
              ok and READER in r and len(starts) >= 2 and IMAGE_READER in starts[0] and READER in starts[-1], {'starts': starts, 'resumed': r})
        st = None
        try:
            pid = d.shell(f'pidof {d.PKG}').strip()
            d.adb('forward', '--remove-all')
            d.adb('forward', 'tcp:9333', f'localabstract:webview_devtools_remote_{pid}')
            st = d.wait_ready(settle=2.0)
        except RuntimeError as e:
            st = {'error': str(e)}
        check('the text reader shows the book again', st and st.get('ready') and not st.get('error'), st)
        leave_reader()
        stop_app()
        _, book = ebook_rows(m['key'])
        check('text is kept as the choice (kind_user = TEXT), so the next open goes straight to text', book and book['kind_user'] == 'TEXT', book)
        return
    r = wait_resumed(IMAGE_READER)
    time.sleep(20)
    r = d.resumed()
    d.shot(label + '-1-image-reader')
    check('text reader 以圖片模式開啟: the image reader shows the book', ok and IMAGE_READER in r and READER not in r, r)
    stop_app()
    _, book = ebook_rows(m['key'])
    check('the choice is kept: kind_user = COMIC', book and book['kind_user'] == 'COMIC', book)
    d.shell(f'am start -n {d.PKG}/{IMAGE_READER} --el manga {manga} --el chapter {chapter}')
    time.sleep(40)
    r = d.resumed()
    d.shot(label + '-2-image-reader-after-restart')
    check('after a restart the chapter opens in the image reader', IMAGE_READER in r and READER not in r, r)
    ok = to_text()
    r = wait_resumed(READER)
    d.shot(label + '-3-text-reader')
    check('image reader 以文字模式開啟: the text reader opens', ok and READER in r, r)
    stop_app()
    _, book = ebook_rows(m['key'])
    check('the choice is kept: kind_user = TEXT', book and book['kind_user'] == 'TEXT', book)
    try:
        open_book(manga, chapter)
        r = d.resumed()
    except RuntimeError as e:
        r = str(e)
    check('after a restart the chapter opens in the text reader', READER in r, r)
    leave_reader()
    stop_app()


def step_switch_back(manga, chapter, label, pages):
    """A text book with fewer pictures than text pages, read for [pages] pages, switched to the image reader
    and back. The chapter's page numbers are the text reader's estimate, past the image reader's pages
    (it used to crash on them); the image reader starts on one of its own pages, and the switch back to text
    returns to the text position."""
    STEP[0] = 'switch_back:' + label
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    ensure_unread(manga, chapter)
    open_book(manga, chapter)
    note('start: ' + str(go_to_start()))
    turn(pages)
    p = pos()
    s = doc_path(src())
    d.adb('logcat', '-c')
    ok = to_images()
    r = wait_resumed(IMAGE_READER)
    time.sleep(20)
    r = d.resumed()
    starts = activity_starts()
    crash = d.adb('logcat', '-d', '-b', 'crash')
    d.shot(label + '-1-image-reader')
    check('text reader 以圖片模式開啟 with a text page past the pictures: the image reader shows the book, no crash',
          ok and IMAGE_READER in r and not any('CrashActivity' in x for x in starts) and 'FATAL EXCEPTION' not in crash,
          {'resumed': r, 'starts': starts, 'crash log': crash[-800:], 'text position': [s, p and p['location']]})
    ok = to_text()
    r = wait_resumed(READER)
    st = None
    try:
        pid = d.shell(f'pidof {d.PKG}').strip()
        d.adb('forward', '--remove-all')
        d.adb('forward', 'tcp:9333', f'localabstract:webview_devtools_remote_{pid}')
        st = d.wait_ready(settle=2.0)
    except RuntimeError as e:
        st = {'error': str(e)}
    p2 = pos()
    s2 = doc_path(src())
    d.shot(label + '-2-back-to-text')
    check('image reader 以文字模式開啟: the text reader returns to the text position',
          ok and READER in r and p and p2 and s2 == s and p2['location'] == p['location'],
          {'before': [s, p and p['location']], 'after': [s2, p2 and p2['location']], 'status': st})
    leave_reader()
    stop_app()
    m = main_rows(chapter)
    note(f"chapter after the image reader: read={m['read']} last_page_read={m['last_page_read']} pages_left={m['pages_left']}")


def step_switch_comic(manga, chapter):
    """A comic EPUB (image reader by its classification): to text and back to images."""
    STEP[0] = 'switch:comic'
    set_prefs({}, reset_typesetting=True)
    rotate(False)
    m = main_rows(chapter)
    d.shell(f'am start -n {d.PKG}/{IMAGE_READER} --el manga {manga} --el chapter {chapter}')
    time.sleep(40)
    r = d.resumed()
    d.shot('switch-comic-1-image-reader')
    check('comic EPUB opens in the image reader', IMAGE_READER in r and READER not in r, r)
    ok = to_text()
    r = wait_resumed(READER)
    st = None
    if READER in r:
        pid = d.shell(f'pidof {d.PKG}').strip()
        d.adb('forward', '--remove-all')
        d.adb('forward', 'tcp:9333', f'localabstract:webview_devtools_remote_{pid}')
        try:
            st = d.wait_ready(settle=2.0)
        except RuntimeError as e:
            st = {'error': str(e)}
    d.shot('switch-comic-2-text-reader')
    check('image reader 以文字模式開啟: the comic opens in the text reader', ok and READER in r and st and st.get('ready') and not st.get('error'),
          {'resumed': r, 'status': st})
    # Pages without text: the position is kept by page, the whole-book progress by documents.
    turn(2)
    p = pos()
    st2 = d.status()
    doc = doc_path(src())
    ns = show_menu()
    pct = percent(ns)
    d.shot('switch-comic-3-progress')
    leave_reader()
    stop_app()
    saved, book = ebook_rows(m['key'])
    n_docs = len(book['char_counts']) if book and book['char_counts'] else None
    check('kind_user = TEXT, kind_auto stays COMIC', book and book['kind_user'] == 'TEXT' and book['kind_auto'] == 'COMIC', book)
    want = None
    if saved and n_docs:
        want = (saved['spine'] + (saved.get('pageProgression') or 0)) / n_docs
    check('picture pages: saved by page (no text location), whole-book progress by documents',
          saved and saved.get('location') is None and saved.get('pageProgression') is not None and saved.get('href') == doc
          and want is not None and abs((saved.get('total') or 0) - want) < 1e-6 and pct is not None and abs(pct / 100 - want) <= 0.01,
          {'saved': saved, 'shown': {'doc': doc, 'page': st2 and st2['page'], 'position': p}, 'char counts': book and book['char_counts'],
           'expected total': want, 'percent shown': pct})
    st3 = open_book(manga, chapter)
    doc3 = doc_path(src())
    d.shot('switch-comic-4-reopened')
    check('picture pages: reopened at the same document and page', doc3 == doc and st3['page'] == (st2 and st2['page']),
          {'doc': (doc, doc3), 'page': (st2 and st2['page'], st3['page'])})
    ok = to_images()
    r = wait_resumed(IMAGE_READER)
    time.sleep(20)
    r = d.resumed()
    d.shot('switch-comic-5-image-reader-again')
    check('back to images with 以圖片模式開啟', ok and IMAGE_READER in r, r)
    stop_app()
    _, book = ebook_rows(m['key'])
    check('kind_user = COMIC', book and book['kind_user'] == 'COMIC', book)


def step_classify(manga, chapter):
    """An EPUB never opened: classified once (image reader start, then hand-off), stored in ebook.db, and
    opened directly in the text reader from the chapter list after an App restart."""
    STEP[0] = 'classify'
    stop_app(0)
    m = main_rows(chapter)
    _, book0 = ebook_rows(m['key'])
    if book0 is not None and book0['kind_auto'] is not None:
        # The book was opened by an earlier run on this emulator (the stage 6 regression runs the checks of
        # stage 5 again): it is made "never opened" again by removing its rows from ebook.db.
        forget_book(m['key'])
        note(f'classify: the book had been opened before ({book0}); its rows in ebook.db were removed')
        _, book0 = ebook_rows(m['key'])
    check('not classified yet', book0 is None or book0['kind_auto'] is None, book0)

    def open_from_chapter_list():
        d.adb('logcat', '-c')
        d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity -a eu.kanade.tachiyomi.SHOW_MANGA --el manga {manga}')
        row = None
        for _ in range(20):
            time.sleep(4)
            if not wait_app_drawn():
                note('the launch screen is still shown')
            clear_dialogs()
            row = d.find(m['chapter'], exact=True)
            if row:
                time.sleep(3)  # the manga screen fades in (a touch during the transition is ignored)
                row = d.find(m['chapter'], exact=True) or row
                break
        if row is None:
            return None, None
        d.adb('logcat', '-c')
        d.tap(row['x'], row['y'], 2)
        r = wait_resumed(READER)
        time.sleep(3)
        log = d.adb('logcat', '-d', '-s', 'ActivityManager:I')
        starts = [ln.split('cmp=')[1].split()[0] for ln in log.splitlines() if 'START u0' in ln and d.PKG in ln and 'cmp=' in ln]
        return r, starts

    r, starts = open_from_chapter_list()
    d.shot('classify-1-first-open')
    check('first open from the chapter list: image reader, then the text reader', r and READER in r and starts and any('ReaderActivity' in s and 'Ebook' not in s for s in starts),
          {'resumed': r, 'activity starts': starts})
    leave_reader()
    stop_app()
    _, book1 = ebook_rows(m['key'])
    check('classification stored in ebook.db', book1 and book1['kind_auto'] == 'TEXT', book1)
    r, starts = open_from_chapter_list()
    d.shot('classify-2-second-open')
    check('after an App restart: opened directly in the text reader', r and READER in r and starts and all('EbookReaderActivity' in s for s in starts),
          {'resumed': r, 'activity starts': starts})
    leave_reader()
    stop_app()

# endregion


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('step')
    ap.add_argument('args', nargs='*')
    ap.add_argument('--pages', type=int, default=6)
    ap.add_argument('--columns', default='off')
    ap.add_argument('--landscape', action='store_true')
    a = ap.parse_args()
    x = a.args
    try:
        run_step(a, x)
    finally:
        try:
            save_system_logs(' '.join([a.step] + x))
        except Exception as e:  # the logs are evidence only
            print('system logs not saved:', e)


def run_step(a, x):
    if a.step == 'warmup':
        step_warmup(int(x[0]), int(x[1]))
    elif a.step == 'ids':
        step_ids()
    elif a.step == 'restore':
        step_restore(int(x[0]), int(x[1]), x[2], a.pages, a.columns, a.landscape)
    elif a.step == 'rotate':
        step_rotate(int(x[0]), int(x[1]), x[2], a.pages)
    elif a.step == 'settings':
        step_settings(int(x[0]), int(x[1]), x[2], a.pages)
    elif a.step == 'fallback':
        step_fallback(int(x[0]), int(x[1]), x[2])
    elif a.step == 'parity':
        step_parity(int(x[0]), int(x[1]), x[2])
    elif a.step == 'incognito':
        step_incognito(int(x[0]), int(x[1]))
    elif a.step == 'chapter_list':
        step_chapter_list(int(x[0]), int(x[1]))
    elif a.step == 'toc':
        step_toc(int(x[0]), int(x[1]), x[2], int(x[3]))
    elif a.step == 'slider':
        step_slider(int(x[0]), int(x[1]), x[2], float(x[3]))
    elif a.step == 'end':
        step_end(int(x[0]), int(x[1]), x[2])
    elif a.step == 'tapzones':
        step_tapzones(int(x[0]), int(x[1]), x[2], int(x[3]), x[4] if len(x) > 4 else 'NONE')
    elif a.step == 'volume':
        step_volume(int(x[0]), int(x[1]))
    elif a.step == 'switch':
        step_switch(int(x[0]), int(x[1]), x[2], x[3] == 'images')
    elif a.step == 'switch_back':
        step_switch_back(int(x[0]), int(x[1]), x[2], int(x[3]))
    elif a.step == 'switch_comic':
        step_switch_comic(int(x[0]), int(x[1]))
    elif a.step == 'classify':
        step_classify(int(x[0]), int(x[1]))
    elif a.step == 'backup_setting':
        step_backup_setting(int(x[0]))
    elif a.step == 'backup_setting_clear':
        step_backup_setting_clear()
    elif a.step == 'backup_setting_verify':
        step_backup_setting_verify()
    elif a.step == 'backup_check':
        step_backup_check(x[0])
    elif a.step == 'backup_prepare':
        step_backup_prepare(x[0])
    elif a.step == 'backup_verify':
        step_backup_verify()
    else:
        raise SystemExit('unknown step ' + a.step)


if __name__ == '__main__':
    main()
