"""Pages through a whole book in the text reader and records, for every spread, the fully visible text
of each frame (probe2.js). Check the result with summarize2.py.

Usage: python3 verify_columns.py <manga id> <chapter id> <label> [--columns on|off|landscape]
       [--direction auto|rtl|ltr] [--landscape] [--writing book|vertical|horizontal] [--font-size N]
The typesetting settings are reset to the defaults first (global level), then the given ones are set.
Needs ../stage3/drive.py (adb, uiautomator, DevTools) and the debug APK; see ../stage3/README.md.
"""
import argparse
import json
import os
import sys
import time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'stage3'))
import drive as d  # noqa: E402

OUT = os.environ.get('OUT', os.path.join(HERE, 'out'))
os.makedirs(os.path.join(OUT, 'runs'), exist_ok=True)


def write_prefs(values):
    """Removes every pref_ebook_* key (global and per book), then sets [values] (app stopped)."""
    d.shell(f'am force-stop {d.PKG}')
    time.sleep(1)
    root = ET.fromstring(d.prefs())
    for e in list(root):
        if e.get('name', '').startswith('pref_ebook_'):
            root.remove(e)
    for k, v in values.items():
        ET.SubElement(root, 'string', name='pref_ebook_' + k).text = v
    tmp = os.path.join(OUT, 'prefs-columns.xml')
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n" + ET.tostring(root, encoding='unicode'))
    d.adb('push', tmp, '/data/local/tmp/p.xml')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/p.xml shared_prefs/{d.PKG}_preferences.xml')


def start_at_beginning(chapter):
    """Since stage 5 the reader reopens a book where it was left (ebook.db), or near the page of the chapter
    list; a page-through must start at the first page (stage 6: three runs started in their second document).
    Removes the chapter's saved position and sets its page in the chapter list to 0 (App stopped)."""
    sys.path.insert(0, os.path.join(HERE, '..', 'stage5'))
    import check_stage5 as c5  # here, not at the top: check_stage5 imports this module
    key = c5.main_rows(chapter)['key']
    con = c5.pull_db('ebook.db')
    removed = con.execute('DELETE FROM position WHERE source = ? AND manga_url = ? AND chapter_url = ?', key).rowcount
    con.commit()
    con.close()
    c5.push_ebook_db()
    con = c5.pull_db('tachiyomi.db')
    con.execute('UPDATE chapters SET last_page_read = 0 WHERE _id = ?', (chapter,))
    con.commit()
    con.close()
    d.adb('push', os.path.join(c5.DB, 'tachiyomi.db'), '/data/local/tmp/tachiyomi.db')
    d.shell(f'run-as {d.PKG} rm -f databases/tachiyomi.db-wal databases/tachiyomi.db-shm')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/tachiyomi.db databases/tachiyomi.db')
    print(f'start at the beginning: saved positions removed {removed}, page in the chapter list 0', flush=True)


def clear_dialogs():
    """Closes a system "not responding" dialog that took the input focus, and logs it (dialogs.log)."""
    t = d.dismiss_anr()
    if t:
        with open(os.path.join(OUT, 'dialogs.log'), 'a', encoding='utf-8') as f:
            f.write(time.strftime('%H:%M:%S') + ' ' + t + '\n')
        print('dismissed:', t, flush=True)
    return t


def probe():
    with open(os.path.join(HERE, 'probe2.js'), encoding='utf-8') as f:
        v = d.cdp(f.read())
    return v if isinstance(v, str) else None


def ruby_check():
    """Ruby annotations of the open document that lie on another page than their base text (ruby.js,
    first frame; both frames have the same layout)."""
    with open(os.path.join(HERE, 'ruby.js'), encoding='utf-8') as f:
        v = d.cdp('(%s)(null)' % f.read())
    return json.loads(v) if isinstance(v, str) else {'error': str(v)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('manga', type=int)
    ap.add_argument('chapter', type=int)
    ap.add_argument('label')
    ap.add_argument('--columns', default='on')
    ap.add_argument('--direction', default='auto')
    ap.add_argument('--writing', default='book')
    ap.add_argument('--landscape', action='store_true')
    ap.add_argument('--font-size', default=None)
    ap.add_argument('--shot-pages', default='', help='also take a screenshot at these pages of the first document, e.g. 2,4')
    a = ap.parse_args()
    shot_pages = {int(x) for x in a.shot_pages.split(',') if x.strip()}

    prefs = {'columns': a.columns, 'pageDirection': a.direction, 'writingMode': a.writing}
    if a.font_size:
        prefs['fontSize'] = a.font_size
    write_prefs(prefs)
    start_at_beginning(a.chapter)
    d.shell('settings put system accelerometer_rotation 0')
    d.shell(f'settings put system user_rotation {1 if a.landscape else 0}')
    time.sleep(3)
    d.open_book(a.manga, a.chapter)
    # Right after start-up the window can be without input focus for a while on a slow emulator.
    for _ in range(30):
        if 'EbookReaderActivity' in d.shell('dumpsys window windows | grep mCurrentFocus'):
            break
        clear_dialogs()
        time.sleep(2)
    time.sleep(5)
    d.wait_ready(settle=3.0)
    out_path = os.path.join(OUT, 'runs', a.label + '.jsonl')
    first = json.loads(probe())
    st = first['st']
    rtl = None
    if len(first['frames']) == 2:
        rtl = first['frames'][0]['left'] > first['frames'][1]['left']
    else:
        # one column: the next page is on the left for right-to-left books
        rtl = a.direction == 'rtl' or (a.direction == 'auto' and st['mode'] == 'V')
    ns = d.nodes()
    w = max((m['b'][2] for m in ns), default=1080)
    h = max((m['b'][3] for m in ns), default=1920)
    tap_x = int(w * 0.12) if rtl else int(w * 0.88)
    print(f'{a.label}: cols {st.get("cols")}, mode {st["mode"]}, first frame on the {"right" if rtl else "left"}, tap x {tap_x}')
    d.shot(a.label + '-first')
    prev_key, same, steps, ruby_seen, first_src = None, 0, 0, set(), None
    ruby_path = os.path.join(OUT, 'runs', a.label + '.ruby.jsonl')
    open(ruby_path, 'w').close()
    with open(out_path, 'w', encoding='utf-8') as f:
        for steps in range(1, 400):
            line = probe()
            if line is None:
                time.sleep(2)
                continue
            f.write(json.dumps(line) + '\n')
            f.flush()
            v = json.loads(line)
            if v['st']['ready'] and v['src'] not in ruby_seen:
                ruby_seen.add(v['src'])
                r = ruby_check()
                r = {'src': v['src'], 'rubyFix': v['st'].get('rubyFix'), 'ruby': r.get('ruby'), 'misplaced': r.get('misplaced'),
                     'examples': r.get('examples'), 'error': r.get('error')}
                with open(ruby_path, 'a', encoding='utf-8') as rf:
                    rf.write(json.dumps(r, ensure_ascii=False) + '\n')
                print('  ruby', json.dumps(r, ensure_ascii=False), flush=True)
            if v['st']['ready'] and v['st']['page'] in shot_pages and first_src in (None, v['src']):
                first_src = v['src']
                shot_pages.discard(v['st']['page'])
                d.shot(f"{a.label}-p{v['st']['page']}")
            key = (v['src'], v['st']['page'], v['st']['ready'])
            same = same + 1 if key == prev_key else 0
            at_last_spread = v['st']['page'] + v['st'].get('cols', 1) > v['st']['pages'] - 1
            # unchanged at the last spread of a document: the end of the book (or a lost tap: retry a few times)
            if same >= (2 if at_last_spread else 6):
                break
            prev_key = key
            # Page Down turns to the next spread whatever the direction, and cannot hit a link (taps are
            # checked separately).
            clear_dialogs()
            d.shell('input keyevent 93')
            time.sleep(1.5)
            for _ in range(30):  # wait while a new document is laid out
                st = d.status()
                if st and st['ready']:
                    break
                time.sleep(1)
    print(f'{a.label}: steps {steps}, log {out_path}')
    d.shell('settings put system user_rotation 0')


if __name__ == '__main__':
    main()
