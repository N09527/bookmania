"""Stage 6 security check on the emulator (debug APK). Book content is untrusted input: it must not run
scripts, reach the network or read other files of the App. A test EPUB (make_hostile_epub.py) tries all
three; the checks look at the open book through the WebView's DevTools and count what reached a test HTTP
server on this machine (the emulator reaches it at 10.0.2.2).

  - the network works: a request sent with `nc` from the emulator reaches the test server (control);
  - no script of the book ran, and the book document has no scripts, frames, forms or event attributes left;
  - a script and an event attribute added to the book frame afterwards (as if the sanitizer had missed them)
    do not run either: the frame's sandbox and the CSP stop them;
  - the picture inside the book shows (control), the one from the other host and the local file do not;
  - the font from the other host is not loaded;
  - no request reached the test server while the book was open;
  - the same with two columns (two book frames).

Usage: ADB=/path/to/adb python3 -I check_security.py
Needs ../stage5_5/check_pageturn.py and what it needs (Node for the DevTools client of stage 2).
The test book is added to the work "橫排測試書 EPUB" (id 8) as zh-security-test.epub and stays there.
Airplane mode is turned off for the test and set back afterwards.
Results: out/security/results.jsonl, requests seen by the test server: out/security/server.log.
"""
import http.server
import json
import os
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out', 'security'))
os.makedirs(os.environ['OUT'], exist_ok=True)
sys.path.insert(0, os.path.join(HERE, '..', 'stage5_5'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage4'))
import check_pageturn as p  # noqa: E402
from verify_columns import write_prefs  # noqa: E402

c, d = p.c, p.d
OUT = os.environ['OUT']
PORT = 8765
HOST = f'10.0.2.2:{PORT}'
MANGA = 8
NAME = 'zh-security-test.epub'
MARKERS = ['__bm_inline', '__bm_file', '__bm_onload', '__bm_onerror', '__bm_js', '__bm_svg']
hits = []


class Handler(http.server.BaseHTTPRequestHandler):
    def record(self):
        hits.append({'time': time.strftime('%H:%M:%S'), 'method': self.command, 'path': self.path})
        with open(os.path.join(OUT, 'server.log'), 'a', encoding='utf-8') as f:
            f.write(json.dumps(hits[-1]) + '\n')
        body = b'body { background: red }' if self.path.endswith('.css') else b'x'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_HEAD = record

    def log_message(self, *args):
        pass


def check(name, ok, detail=None):
    return c.check(name, ok, detail)


def airplane(on):
    d.shell(f'settings put global airplane_mode_on {1 if on else 0}')
    d.shell(f'am broadcast -a android.intent.action.AIRPLANE_MODE --ez state {"true" if on else "false"}')
    time.sleep(10)


def control():
    """A request from the emulator's shell: the network between the emulator and the test server works."""
    before = len(hits)
    for _ in range(3):
        d.shell(f"printf 'GET /control HTTP/1.0\\r\\n\\r\\n' | nc -w 5 10.0.2.2 {PORT}", timeout=30)
        time.sleep(2)
        if any(h['path'] == '/control' for h in hits[before:]):
            return True
        time.sleep(5)
    return False


FRAMES_JS = r'''(() => {
  const out = [];
  for (const f of document.querySelectorAll('iframe')) {
    const w = f.contentWindow, doc = f.contentDocument;
    if (!doc || !doc.body) { out.push({error: 'no document'}); continue; }
    const img = id => { const e = doc.getElementById(id); return e ? {complete: e.complete, width: e.naturalWidth} : null; };
    const fonts = []; doc.fonts.forEach(ft => fonts.push(ft.family + ':' + ft.status));
    const all = Array.prototype.slice.call(doc.querySelectorAll('*'));
    out.push({
      sandbox: f.getAttribute('sandbox'),
      markersSet: MARKERS.filter(k => w[k] !== undefined),
      injectedSet: ['__bm_injected', '__bm_injected_handler'].filter(k => w[k] !== undefined),
      title: doc.title,
      marker: !!doc.getElementById('marker'),
      counts: {
        script: doc.querySelectorAll('script').length,
        frame: doc.querySelectorAll('iframe, frame, frameset').length,
        object: doc.querySelectorAll('object, embed, applet').length,
        form: doc.querySelectorAll('form, input, button, textarea, select').length,
        refresh: doc.querySelectorAll('meta[http-equiv]').length,
        handlers: all.filter(e => Array.prototype.some.call(e.attributes, a => /^on/i.test(a.name))).length,
        jsUrls: all.filter(e => ['href', 'src', 'xlink:href'].some(n => /^\s*javascript:/i.test(e.getAttribute(n) || ''))).length,
      },
      images: {inbook: img('inbook'), external: img('external'), localfile: img('localfile')},
      fonts: fonts,
    });
  }
  return JSON.stringify(out);
})()'''.replace('MARKERS', json.dumps(MARKERS))

INJECT_JS = r'''(() => {
  let n = 0;
  for (const f of document.querySelectorAll('iframe')) {
    const doc = f.contentDocument;
    if (!doc || !doc.body) continue;
    const s = doc.createElement('script'); s.textContent = 'window.__bm_injected = 1'; doc.body.appendChild(s);
    const im = doc.createElement('img'); im.setAttribute('onerror', 'window.__bm_injected_handler = 1');
    im.src = 'injected-missing.png'; doc.body.appendChild(im);
    n++;
  }
  return JSON.stringify(n);
})()'''


def frames():
    v = d.cdp(FRAMES_JS)
    try:
        return json.loads(v)
    except (TypeError, ValueError):
        return None


def round_(label, chapter, columns):
    c.STEP[0] = f'security:{label}'
    write_prefs({'columns': columns})
    d.shell('logcat -c')
    before = len(hits)
    st = c.open_book(MANGA, chapter)
    ok = bool(st and st.get('ready'))
    check('the test book opened in the text reader', ok, st)
    if not ok:
        return
    time.sleep(15)  # pictures, style sheets and fonts had time to load (or fail)
    fs = frames()
    want = 2 if columns == 'on' else 1
    check(f'the book is shown in {want} frame(s)', bool(fs) and len(fs) == want and all('error' not in f for f in fs), fs)
    if not fs:
        return
    check('each book frame is sandboxed without scripts (sandbox="allow-same-origin")',
          all(f.get('sandbox') == 'allow-same-origin' for f in fs), [f.get('sandbox') for f in fs])
    check('no script of the book ran (inline, script file, onload, onerror, javascript: link, SVG; the title is unchanged)',
          all(not f['markersSet'] and f['title'] != 'SCRIPT-RAN' for f in fs),
          [{'set': f['markersSet'], 'title': f['title']} for f in fs])
    check('the book documents have no scripts, frames, objects, forms, refresh, event attributes or javascript: URLs left',
          all(not any(f['counts'].values()) for f in fs), [f['counts'] for f in fs])
    check('the picture inside the book is shown (control)',
          all((f['images']['inbook'] or {}).get('width', 0) > 0 for f in fs), [f['images']['inbook'] for f in fs])
    check('the picture from another host is not shown', all((f['images']['external'] or {}).get('width', 1) == 0 for f in fs),
          [f['images']['external'] for f in fs])
    check('the local file (file://) is not shown, although it is the same picture as the one inside the book',
          all((f['images']['localfile'] or {}).get('width', 1) == 0 for f in fs), [f['images']['localfile'] for f in fs])
    check('the font from another host is not loaded', all(not any(x.endswith(':loaded') for x in f['fonts']) for f in fs),
          [f['fonts'] for f in fs])
    n = d.cdp(INJECT_JS)
    time.sleep(5)
    fs2 = frames() or []
    check('a script and an event attribute added to the book frame afterwards do not run (sandbox, CSP)',
          str(n) == str(want) and fs2 and all(not f['injectedSet'] for f in fs2),
          {'frames injected': n, 'set': [f['injectedSet'] for f in fs2]})
    time.sleep(10)
    mine = [h for h in hits[before:] if h['path'] != '/control']
    check('no request of the book reached the test server', not mine, mine)
    log = d.shell('logcat -d')
    blocked = [l.split(': ', 1)[-1] for l in log.splitlines() if 'Blocked request' in l]
    refused = [l for l in log.splitlines() if 'Content Security Policy' in l or 'Refused to' in l]
    c.note(f'{label}: App log "Blocked request" x{len(blocked)} {sorted(set(blocked))}; '
           f'console CSP messages x{len(refused)}')
    with open(os.path.join(OUT, f'{label}-console.log'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(refused + ['--- blocked by the App:'] + blocked) + '\n')
    d.shot(f'security-{label}')
    c.stop_app()


def main():
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    was_airplane = d.shell('settings get global airplane_mode_on').strip() == '1'
    try:
        epub = os.path.join(OUT, NAME)
        subprocess.run([sys.executable, '-I', os.path.join(HERE, 'make_hostile_epub.py'), epub, HOST], check=True)
        pngfile = os.path.join(OUT, 'bm-file.png')
        with open(pngfile, 'wb') as f:
            f.write(subprocess.run([sys.executable, '-I', os.path.join(HERE, 'make_hostile_epub.py'), '--png'],
                                   capture_output=True, check=True).stdout)
        d.adb('push', epub, f'/sdcard/Download/{NAME}')
        d.adb('push', pngfile, '/sdcard/Download/bm-file.png')
        airplane(False)
        c.STEP[0] = 'security:network'
        check('the emulator reaches the test server (control request with nc)', control(), hits[-3:])
        p.add_chapter(MANGA, f'/sdcard/Download/{NAME}', NAME)
        chapter = next((r[0] for r in p.chapter_rows(MANGA) if r[2].endswith(NAME)), None)
        if chapter is None:
            check('the test book is a chapter of the work', False, None)
            return
        p.rotate(False)
        round_('one-column', chapter, 'off')
        round_('two-columns', chapter, 'on')
        write_prefs({})  # typesetting back to the defaults
    finally:
        airplane(was_airplane)
        srv.shutdown()
        print('requests seen by the test server:', json.dumps(hits, ensure_ascii=False))


if __name__ == '__main__':
    main()
