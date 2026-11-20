"""Checks the reader's own ruby fix (reader.js, rubyFix): for each font size the book is opened fresh
(global setting), then status().rubyFix and the number of misplaced annotations (ruby.js, no extra
CSS) are recorded. Sizes 16, 24, 26 and 30 had misplaced annotations without the fix
(ruby_experiments.py); 20 had none.
Usage: python3 ruby_check.py <manga id> <chapter id> [--columns off|on] [--label name]
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
from rotate_anchor import result  # noqa: E402
from verify_columns import write_prefs, clear_dialogs  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('manga', type=int)
    ap.add_argument('chapter', type=int)
    ap.add_argument('--columns', default='off')
    ap.add_argument('--label', default='')
    a = ap.parse_args()
    with open(os.path.join(HERE, 'ruby.js'), encoding='utf-8') as f:
        ruby_js = f.read()
    d.shell('settings put system user_rotation 0')
    for size in (16, 20, 24, 26, 30):
        write_prefs({'columns': a.columns, 'fontSize': str(size)})
        st = d.open_book(a.manga, a.chapter)
        clear_dialogs()
        time.sleep(3)
        v = d.cdp('(%s)(null)' % ruby_js)
        r = json.loads(v) if isinstance(v, str) else {'error': v}
        st = d.status()
        result(f'{a.label} font size {size}, columns {a.columns}: no misplaced ruby'.strip(), r.get('misplaced') == 0,
               {'rubyFix': st.get('rubyFix'), 'ruby': r.get('ruby'), 'misplaced': r.get('misplaced'),
                'cols': st.get('cols'), 'mode': st.get('mode'), 'pages': st.get('pages'),
                'lineHeight': r.get('lineHeight'), 'examples': r.get('examples')}, step='ruby')


if __name__ == '__main__':
    main()
