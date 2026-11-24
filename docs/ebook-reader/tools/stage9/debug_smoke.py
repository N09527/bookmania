"""Quick check of the debug App signed with the repository's debug key: each text book opens in the text
reader, the shell lays it out, and a page key turns the page.
Usage: ADB=/path/to/adb python3 -I debug_smoke.py   (screenshots in $OUT/shots, default out/debug-smoke)"""
import json, os, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, '..')
os.environ.setdefault('OUT', os.path.join(HERE, 'out', 'debug-smoke'))
sys.path.insert(0, os.path.join(TOOLS, 'stage5'))
import check_stage5 as c  # noqa: E402
d = c.d
BOOKS = [(14, 16, 'vertical-epub'), (8, 10, 'horizontal-epub'), (13, 15, 'vertical-azw3'), (9, 11, 'horizontal-mobi6')]
results = []
for manga, chapter, label in BOOKS:
    try:
        st = c.open_book(manga, chapter)
        d.shot(f'{label}-open')
        before = d.status()
        c.key(c.KEY_PAGE_DOWN, 1.5)
        after = c.wait_change(before)
        d.shot(f'{label}-after-key')
        turned = bool(after) and (after.get('page') != before.get('page') or after.get('seq') != before.get('seq'))
        results.append({'book': label, 'ready': bool(st and st.get('ready')), 'before': {k: before.get(k) for k in ('page', 'pages', 'seq')},
                        'after': {k: (after or {}).get(k) for k in ('page', 'pages', 'seq')}, 'turned': turned})
    except Exception as e:  # noqa: BLE001
        results.append({'book': label, 'error': str(e)})
    print(json.dumps(results[-1], ensure_ascii=False), flush=True)
d.shell(f'am force-stop {d.PKG}')
