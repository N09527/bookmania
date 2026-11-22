"""Stage 6: a smoke test of the signed release APK on the emulator (R8, not debuggable; WebView debugging
is off, so the DevTools checks of the other stages cannot be used).

The release App (io.github.n09527.bookmania) is installed next to the debug App and gets the debug App's
library database and books (adb runs as root on this emulator), with onboarding marked as done and the
existing "external local source" option on, as stage 2 did for the debug App. Then each test book is opened
through the image reader entry point (with the work and chapter ids, as the other checks do):
  - which reader ends up in front, what the screen says, and whether the App crashed;
  - text books: the page indicator before and after a page key (the page turns, with the default curl).

Usage: ADB=/path/to/adb python3 -I release_smoke.py <universal or x86_64 release APK>
Results: out/release/results.jsonl and screenshots in out/release/shots/.
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out', 'release'))
REL = 'io.github.n09527.bookmania'
DEBUG = 'io.github.n09527.bookmania.debug'
os.environ['PKG'] = REL  # the driver's package: the release App
sys.path.insert(0, os.path.join(HERE, '..', 'stage5'))
import check_stage5 as c  # noqa: E402

d = c.d
OUT = os.environ['OUT']
KEY_PAGE_DOWN = 93
IMAGE_CLASS = 'eu.kanade.tachiyomi.ui.reader.ReaderActivity'
TEXT = f'{REL}/yokai.ebook.EbookReaderActivity'  # as dumpsys names it; the debug App's names start with
IMAGE = f'{REL}/{IMAGE_CLASS}'                    # "io.github.n09527.bookmania.debug/", so they never match
# (manga, chapter, label, expected reader: 'text', 'image' or 'message')
BOOKS = [
    (14, 16, 'vertical-epub', 'text'),
    (8, 10, 'horizontal-epub', 'text'),
    (13, 15, 'vertical-azw3', 'text'),
    (9, 11, 'horizontal-mobi6', 'text'),
    (3, 1, 'joint-mobi', 'text'),
    (1, 3, 'drm-adept-epub', 'message'),
    (1, 2, 'drm-flagged-mobi', 'message'),
    (6, 8, 'corrupt-truncated', 'message'),
    (10, 12, 'comic-cbz', 'image'),
    (11, 13, 'comic-fixed-epub', 'image'),
]
PAGE = re.compile(r'^(\d+)/(\d+)')


def root(cmd, timeout=300):
    return d.shell(cmd, timeout=timeout)


def install(apk):
    c.STEP[0] = 'release:install'
    out = d.adb('install', '-r', apk, timeout=900)
    ok = 'Success' in out
    c.check('the release APK installs', ok, out.strip().splitlines()[-1:] if out else None)
    info = root(f'dumpsys package {REL} | grep -E "versionCode|versionName|pkgFlags|flags=" | head -5')
    c.check('the installed App is the release build (not debuggable)', ok and 'DEBUGGABLE' not in info, info.strip())
    return ok


def copy_data():
    """The debug App's library database and books for the release App (as root), onboarding done."""
    c.STEP[0] = 'release:data'
    root(f'am force-stop {REL}; am force-stop {DEBUG}')
    uid = root(f'stat -c %u /data/data/{REL}').strip()
    root(f'mkdir -p /data/data/{REL}/databases /data/data/{REL}/shared_prefs')
    root(f'cp /data/data/{DEBUG}/databases/tachiyomi.db* /data/data/{REL}/databases/ 2>/dev/null; true')
    prefs = ("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n"
             '    <boolean name="__APP_STATE_onboarding_complete" value="true" />\n'
             '    <boolean name="pref_external_local_source" value="true" />\n</map>\n')
    tmp = os.path.join(OUT, 'prefs.xml')
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(prefs)
    d.adb('push', tmp, f'/data/data/{REL}/shared_prefs/{REL}_preferences.xml')
    root(f'chown -R {uid}:{uid} /data/data/{REL}/databases /data/data/{REL}/shared_prefs; restorecon -R /data/data/{REL}')
    src, dst = f'/sdcard/Android/data/{DEBUG}/files/local', f'/sdcard/Android/data/{REL}/files/local'
    root(f'mkdir -p {dst} && cp -r {src}/. {dst}/', timeout=900)
    n_src = root(f'find {src} -type f | wc -l').strip()
    n_dst = root(f'find {dst} -type f | wc -l').strip()
    c.check('the books and the library are in place for the release App', n_src == n_dst and n_src != '0',
            {'files in the debug folder': n_src, 'copied': n_dst, 'uid': uid})


def screen_texts():
    return [n['text'] or n['desc'] for n in d.nodes() if n['text'] or n['desc']]


def page_of(texts):
    return next((t for t in texts if PAGE.match(t.replace(' ', ''))), None)


def open_book(manga, chapter, label, kind):
    c.STEP[0] = f'release:{label}'
    root(f'am force-stop {REL}')
    root('logcat -c')
    time.sleep(2)
    root(f'am start -n {REL}/{IMAGE_CLASS} --el manga {manga} --el chapter {chapter}')
    t = time.time()
    front = ''
    while time.time() - t < 150:
        front = d.resumed()
        if TEXT in front or (kind != 'text' and IMAGE in front and time.time() - t > 30):
            break
        time.sleep(3)
    time.sleep(20)  # laid out
    c.clear_dialogs()
    front = d.resumed()
    texts = screen_texts()
    d.shot(f'release-{label}-1')
    want = {'text': TEXT, 'image': IMAGE, 'message': None}[kind]
    if kind == 'message':
        c.check('the App shows a message in a reader screen', (TEXT in front or IMAGE in front) and bool(texts),
                {'front': front.split()[-2:] if front else None, 'screen': texts[:8]})
    else:
        c.check(f'the book opens in the {kind} reader', want in front, {'front': front.split()[-2:] if front else None})
    if kind == 'text':
        before = page_of(texts)
        if before is None:  # the bottom bar is part of the menu
            c.show_menu()
            before = page_of(screen_texts())
            c.hide_menu()
        root(f'input keyevent {KEY_PAGE_DOWN}')
        time.sleep(12)
        after = page_of(screen_texts())
        if after is None:
            c.show_menu()
            after = page_of(screen_texts())
            c.hide_menu()
        d.shot(f'release-{label}-2')
        c.check('a page key turns the page', bool(before and after and before != after), {'before': before, 'after': after})
    log = root('logcat -d')
    crashes = [l for l in log.splitlines() if 'FATAL EXCEPTION' in l or ('Fatal signal' in l)]
    firebase = [l.split(': ', 1)[-1] for l in log.splitlines() if 'FirebaseApp' in l or 'FirebaseInitProvider' in l]
    c.check('no crash while the book is open', not crashes, {'crashes': crashes[:3]})
    if firebase:
        c.note(f'{label}: Firebase log lines: {firebase[:3]}')
    root(f'am force-stop {REL}')


def main():
    apk = sys.argv[1]
    os.makedirs(os.path.join(OUT, 'shots'), exist_ok=True)
    c.rotate(False)
    if not install(apk):
        return
    copy_data()
    for m, ch, label, kind in BOOKS:
        open_book(m, ch, label, kind)


if __name__ == '__main__':
    main()
