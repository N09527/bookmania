"""Why the first page of a narrow two-column spread can end early: opens the vertical test book with two
columns (portrait, default settings) and records, for the first blocks, the page of every line and of the
picture (gap.js), first as is and then with orphans/widows set to 1; then shows the picture's spread.
Usage: python3 gap_check.py <manga id> <chapter id> <label>
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'stage3'))
sys.path.insert(0, HERE)
import drive as d  # noqa: E402
from verify_columns import write_prefs, clear_dialogs, OUT  # noqa: E402


def main():
    manga, chapter, label = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    write_prefs({'columns': 'on'})
    d.shell('settings put system user_rotation 0')
    d.open_book(manga, chapter)
    clear_dialogs()
    time.sleep(3)
    with open(os.path.join(HERE, 'gap.js'), encoding='utf-8') as f:
        gap_js = f.read()
    rows = []
    for css in ('', 'p { orphans: 1 !important; widows: 1 !important; }'):
        v = d.cdp('(%s)(%s)' % (gap_js, json.dumps(css)))
        r = json.loads(v) if isinstance(v, str) else {'error': v}
        rows.append(r)
        print(json.dumps(r, ensure_ascii=False))
    d.cdp('(%s)(%s)' % (gap_js, json.dumps('')))
    with open(os.path.join(OUT, label + '.json'), 'w', encoding='utf-8') as f:
        json.dump({'status': d.status(), 'rows': rows}, f, ensure_ascii=False, indent=1)
    d.shot(label + '-first-spread')
    pics = [b for b in rows[0].get('blocks', []) if b.get('tag') in ('img', 'svg', 'figure')]
    if pics:
        d.cdp('window.__reader.goPage(%d); "ok"' % pics[0]['page'])
        time.sleep(3)
        d.shot(label + '-picture-spread')
        print('picture', pics[0], d.status())


if __name__ == '__main__':
    main()
