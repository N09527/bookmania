"""Stage 6, acceptance item 9 on the emulator (debug App, Android 8.0, no hardware acceleration): opening long
books and turning their pages. The times describe this slow emulator only, not a phone.

  setup               copies the books of make_long_books.py into Local Source work folders, opens those works'
                      pages so the App lists the new files, writes out/long/ids.json
  open <label> [runs] cold starts, the App stopped before each: the time from the start command to the first
                      page laid out (the shell's status "ready"), polled from this computer every 0.1 s over
                      one DevTools connection (open_poll.mjs); the shell's own layout time of that document; the
                      App's memory (PSS) afterwards. The first run is the first time the book is ever opened
                      (no saved position, no stored classification or character counts); the next runs open it
                      again at its saved position.
  middle <label>      the saved position moved to document 50 (the middle of a 100-document book), cold start
  turns <label> [n]   n page turns with the page turn animation "none", then n with the default curl, starting
                      two pages before the end of the first document so that one turn goes into the next
                      document. Measured in the shell (hooks on the shell's next() and open()): from the App's
                      call to the new page painted, or for the move into the next document, from the App's
                      next() call until the new document is laid out and painted. For the curl the App's own
                      log lines are added (holding the page, the start of the animation, its frames).
Labels: long-vertical, long-horizontal, long-azw3, long-one, short-vertical (zh-vertical.epub, for comparison).
Usage: ADB=/path/to/adb python3 -I measure_long.py <step> [arguments]
Results: out/long/results.jsonl.
"""
import json
import os
import re
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out', 'long'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage5'))
import check_stage5 as c  # noqa: E402
from verify_columns import start_at_beginning  # noqa: E402

d = c.d
OUT = os.environ['OUT']
BOOKS_DIR = os.path.join(HERE, 'out', 'long-books')
LOCAL = f'/sdcard/Android/data/{d.PKG}/files/local'
IDS = os.path.join(OUT, 'ids.json')
BOOKS = {  # label: (file, Local Source work folder, manga id of that work)
    'long-vertical': ('long-vertical.epub', '直排測試書 EPUB', 14),
    'long-one': ('long-one-document.epub', '直排測試書 EPUB', 14),
    'long-azw3': ('long-vertical.azw3', '直排測試書 AZW3', 13),
    'long-horizontal': ('long-horizontal.epub', '橫排測試書 EPUB', 8),
}

HOOK = r"""(function () {
  var r = window.__reader;
  if (r.__timed) return 'already';
  r.__timed = true; window.__turns = [];
  var next = r.next, open = r.open;
  function painted(cb) { requestAnimationFrame(function () { requestAnimationFrame(cb); }); }
  r.next = function () {
    var t0 = performance.now(), res = next.apply(this, arguments), rec = { kind: 'next', result: res, call: t0 };
    window.__turns.push(rec);
    if (res === 'ok') painted(function () { rec.painted = performance.now() - t0; });
    return res;
  };
  r.open = function () {
    var t0 = performance.now(), res = open.apply(this, arguments), rec = { kind: 'open', call: t0 };
    window.__turns.push(rec);
    var iv = setInterval(function () {
      var s = r.status();
      if (s.ready) { clearInterval(iv); painted(function () { rec.ready = performance.now() - t0; rec.ms = s.ms; rec.pages = s.pages; }); }
    }, 20);
    return res;
  };
  return 'ok';
})()"""


def ids():
    with open(IDS, encoding='utf-8') as f:
        return json.load(f)


def book(label):
    return tuple(ids()[label])


def pss():
    out = d.shell(f'dumpsys meminfo {d.PKG}')
    m = re.search(r'^\s*TOTAL\s+(\d+)', out, re.M)
    return int(m.group(1)) if m else None


def cold_open(manga, chapter, limit=300):
    d.shell(f'am force-stop {d.PKG}')
    time.sleep(3)
    d.adb('forward', '--remove-all')
    poll = subprocess.Popen(['node', os.path.join(HERE, 'open_poll.mjs'), '9333', str(limit * 1000)], stdout=subprocess.PIPE)
    t0 = time.time()
    d.shell(f'am start -n {d.PKG}/{c.IMAGE_READER} --el manga {manga} --el chapter {chapter}')
    pid = ''
    while time.time() - t0 < 120 and not pid:
        pid = d.shell(f'pidof {d.PKG}').strip()
        if not pid:
            time.sleep(0.2)
    d.adb('forward', 'tcp:9333', f'localabstract:webview_devtools_remote_{pid}')
    try:
        out = poll.communicate(timeout=limit + 30)[0].decode('utf-8', 'replace').strip()
    except subprocess.TimeoutExpired:
        poll.kill()
        out = ''
    r = json.loads(out.splitlines()[-1]) if out else {'timeout': 'no answer'}
    if 'readyAt' in r:
        r['open_s'] = round(r['readyAt'] / 1000 - t0, 2)
        r['shell_page_s'] = round(r['shellAt'] / 1000 - t0, 2)
    time.sleep(5)
    r['pss_kb'] = pss()
    r['front'] = d.resumed().split()[-2:]
    return r


def step_setup():
    c.STEP[0] = 'setup'
    for label, (name, folder, manga) in BOOKS.items():
        d.adb('push', os.path.join(BOOKS_DIR, name), f'{LOCAL}/{folder}/{name}', timeout=300)
    for manga in sorted({b[2] for b in BOOKS.values()}):
        c.stop_app(0)
        c.open_manga(manga)  # Local Source lists the new files of the work's folder
        time.sleep(45)
        c.stop_app(3)
    con = c.pull_db('tachiyomi.db')
    found = {'short-vertical': [14, 16]}
    for label, (name, folder, manga) in BOOKS.items():
        row = con.execute('SELECT _id FROM chapters WHERE manga_id = ? AND url LIKE ?', (manga, '%' + name)).fetchone()
        found[label] = [manga, row[0]] if row else None
    con.close()
    with open(IDS, 'w', encoding='utf-8') as f:
        json.dump(found, f)
    sizes = {label: os.path.getsize(os.path.join(BOOKS_DIR, b[0])) for label, b in BOOKS.items()}
    c.check('the long books are listed as chapters', all(found.values()), {'ids': found, 'bytes': sizes})


def step_open(label, runs=3):
    c.STEP[0] = 'open:' + label
    manga, chapter = book(label)
    c.set_prefs({}, reset_typesetting=True)
    c.rotate(False)
    c.stop_app(0)
    key = c.main_rows(chapter)['key']
    c.forget_book(key)  # never opened: no classification, character counts or position
    start_at_beginning(chapter)
    times = []
    for i in range(runs):
        r = cold_open(manga, chapter)
        times.append(r.get('open_s'))
        d.shot(f'long-{label}-open-{i + 1}')
        st = r.get('status') or {}
        c.check(f'{label}, cold start {i + 1}{" (first time ever)" if i == 0 else ""}: the first page is laid out',
                'open_s' in r and not st.get('error') and 'EbookReaderActivity' in ' '.join(r['front']),
                {'seconds to the first page': r.get('open_s'), 'seconds to the shell page': r.get('shell_page_s'),
                 'layout of the document (shell, ms)': st.get('ms'), 'pages of the document': st.get('pages'),
                 'App memory PSS (KB)': r.get('pss_kb'), 'front': r.get('front'), 'raw': r if 'open_s' not in r else None})
        c.leave_reader()
        c.stop_app(3)
    c.note(f'{label}: open times {times}')


def step_middle(label):
    c.STEP[0] = 'middle:' + label
    manga, chapter = book(label)
    c.stop_app(0)
    key = c.main_rows(chapter)['key']
    saved, _ = c.ebook_rows(key)
    if not c.check('a saved position exists (run "open" first)', bool(saved), saved):
        return
    new = c.edit_position(key, lambda loc: {'spine': 49, 'href': 'not-a-document', 'progression': 0.5,
                                            'updatedAt': loc.get('updatedAt', 0), 'version': loc.get('version', 1)})
    r = cold_open(manga, chapter)
    st = r.get('status') or {}
    doc = c.doc_path(c.src())
    d.shot(f'long-{label}-middle')
    c.leave_reader()
    c.stop_app(3)
    saved, _ = c.ebook_rows(key)
    c.check(f'{label}: opened at document 50 (cold start)', 'open_s' in r and bool(saved) and saved.get('spine') == 49,
            {'seconds to the first page': r.get('open_s'), 'layout (ms)': st.get('ms'), 'page': st.get('page'),
             'pages': st.get('pages'), 'document': doc, 'saved after': saved, 'set before': new,
             'App memory PSS (KB)': r.get('pss_kb')})


def turn_records():
    v = d.cdp('JSON.stringify(window.__turns || [])')
    return json.loads(v) if isinstance(v, str) else []


def complete(recs):
    if not recs:
        return False
    last = recs[-1]
    return ('painted' in last) if last['kind'] == 'next' and last['result'] == 'ok' else ('ready' in last) if last['kind'] == 'open' else False


def summarize(recs):
    within, crossing = [], []
    for i, r in enumerate(recs):
        if r['kind'] == 'next' and r['result'] == 'ok' and 'painted' in r:
            within.append(round(r['painted']))
        elif r['kind'] == 'next' and r['result'] == 'end':
            o = next((x for x in recs[i + 1:] if x['kind'] == 'open'), None)
            if o and 'ready' in o:
                crossing.append({'ms from next() to the new document painted': round(o['call'] - r['call'] + o['ready']),
                                 'layout (shell, ms)': o.get('ms'), 'pages': o.get('pages')})
    return within, crossing


def step_turns(label, n=6):
    c.STEP[0] = 'turns:' + label
    manga, chapter = book(label)
    c.rotate(False)
    for style in ('none', 'curl'):
        c.set_prefs({'pref_ebook_page_turn': style}, reset_typesetting=True)
        c.stop_app(0)
        start_at_beginning(chapter)
        c.open_book(manga, chapter)
        d.cdp(HOOK)
        st = d.status()
        d.cdp(f'window.__reader.goPage({max(0, st["pages"] - 3)})')
        time.sleep(3)
        d.shell('logcat -c')
        lost = 0
        for _ in range(n):
            before = len(turn_records())
            c.key(c.KEY_PAGE_DOWN, 0.5)
            t = time.time()
            recs = turn_records()
            while time.time() - t < 150 and not (len(recs) > before and complete(recs)):
                time.sleep(1)
                recs = turn_records()
            if len(recs) == before:
                lost += 1
            time.sleep(2)
        recs = turn_records()
        within, crossing = summarize(recs)
        log = [ln.split('page turn: ', 1)[1] for ln in d.shell('logcat -d').splitlines() if 'page turn: ' in ln]
        held = [int(m.group(1)) for ln in log for m in [re.search(r'held after (\d+) ms', ln)] if m]
        starts = [int(m.group(1)) for ln in log for m in [re.search(r'starts (\d+) ms after', ln)] if m]
        frames = [int(m.group(2)) for ln in log for m in [re.search(r'(\d+) frames in (\d+) ms', ln)] if m]
        med = lambda xs: statistics.median(xs) if xs else None  # noqa: E731
        c.check(f'{label}, animation {style}: {n} page turns measured, one into the next document',
                len(within) + len(crossing) >= n - 1 and len(crossing) >= 1,
                {'within a document: ms from the App\'s call to the new page painted': within,
                 'into the next document': crossing, 'median within (ms)': med(within),
                 'curl, App log: page held after (ms)': held, 'animation starts after the change (ms)': starts,
                 'animation (ms)': frames, 'keys without a turn': lost, 'other log lines': [x for x in log if 'not animated' in x][:3]})
        c.leave_reader()
        c.stop_app(3)
    c.set_prefs({}, reset_typesetting=True)


def step_cleanup():
    """Removes the long books from the work folders and lets the App drop them from the chapter lists."""
    c.STEP[0] = 'cleanup'
    for label, (name, folder, manga) in BOOKS.items():
        d.shell(f"rm -f '{LOCAL}/{folder}/{name}'")
    for manga in sorted({b[2] for b in BOOKS.values()}):
        c.stop_app(0)
        c.open_manga(manga)
        time.sleep(45)
        c.stop_app(3)
    con = c.pull_db('tachiyomi.db')
    left = [r for r in con.execute("SELECT _id, url FROM chapters WHERE url LIKE '%long-%'")]
    con.close()
    c.check('the long books are gone from the chapter lists', not left, left)


def main():
    step, args = sys.argv[1], sys.argv[2:]
    if step == 'setup':
        step_setup()
    elif step == 'open':
        step_open(args[0], int(args[1]) if len(args) > 1 else 3)
    elif step == 'middle':
        step_middle(args[0])
    elif step == 'turns':
        step_turns(args[0], int(args[1]) if len(args) > 1 else 6)
    elif step == 'cleanup':
        step_cleanup()
    c.save_system_logs(c.STEP[0])


if __name__ == '__main__':
    main()
