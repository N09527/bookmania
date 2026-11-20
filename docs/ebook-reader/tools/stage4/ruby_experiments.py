"""Stage 1 found that WebView 69 draws the ruby of a page's first line on the previous page (design
4.5 point 6). This lays the vertical test book out at several font sizes and counts ruby annotations
whose page differs from their base text, first as is and then with candidate CSS fixes (ruby.js adds
the CSS to the book document; the shell's own style is left alone).
Usage: python3 ruby_experiments.py <manga id> <chapter id> <label> [--columns off|on]
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'stage3'))
sys.path.insert(0, HERE)
import drive as d  # noqa: E402
from verify_columns import write_prefs, OUT  # noqa: E402

CANDIDATES = [
    ('none', ''),
    ('rt line-height 1', 'rt { line-height: 1 !important; }'),
    ('rt 1 + ruby 2.2', 'rt { line-height: 1 !important; } ruby { line-height: 2.2 !important; }'),
    ('rt 1 + ruby 2.6', 'rt { line-height: 1 !important; } ruby { line-height: 2.6 !important; }'),
    ('all lines 2.2 (reference)', 'body, p { line-height: 2.2 !important; }'),
]


def settings(font_size, columns):
    return {'vertical': True, 'font': None, 'fontSize': font_size, 'lineHeight': 1.8, 'letterSpacing': 0,
            'indent': None, 'paragraphSpacing': None, 'margins': {'top': 32, 'bottom': 32, 'left': 20, 'right': 20},
            'background': '#FAFAFA', 'textColor': '#000000', 'dark': False, 'rtl': True, 'columns': columns}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('manga', type=int)
    ap.add_argument('chapter', type=int)
    ap.add_argument('label')
    ap.add_argument('--columns', default='off')
    a = ap.parse_args()
    write_prefs({'columns': a.columns})
    d.shell('settings put system user_rotation 0')
    d.open_book(a.manga, a.chapter)
    time.sleep(5)
    with open(os.path.join(HERE, 'ruby.js'), encoding='utf-8') as f:
        ruby_js = f.read()
    rows = []
    for size in range(16, 32, 2):
        before = d.status()['seq']
        d.cdp('window.__reader.relayout(%s)' % json.dumps(settings(size, a.columns)))
        for _ in range(60):
            st = d.status()
            if st and st['seq'] != before and st['ready']:
                break
            time.sleep(1)
        for name, css in CANDIDATES:
            v = d.cdp('(%s)(%s)' % (ruby_js, json.dumps(css)))
            r = json.loads(v) if isinstance(v, str) else {'error': v}
            rows.append({'fontSize': size, 'candidate': name, **r})
            print(size, name, r.get('ruby'), 'misplaced', r.get('misplaced'), r.get('examples', [])[:2], flush=True)
        d.cdp('(%s)(%s)' % (ruby_js, json.dumps('')))  # back to no experiment CSS
    with open(os.path.join(OUT, a.label + '.json'), 'w', encoding='utf-8') as f:
        json.dump(rows, f, ensure_ascii=False, indent=1)
    print('summary (total misplaced over all font sizes):')
    for name, _ in CANDIDATES:
        print(f'  {name}: {sum(r.get("misplaced", 0) for r in rows if r["candidate"] == name)} '
              f'of {sum(r.get("ruby", 0) for r in rows if r["candidate"] == name)}')


if __name__ == '__main__':
    main()
