"""Setting 9 through the real panel: the "Two columns" choice on the layout tab, what it stores, the
spread it gives, and the page indicator ("1–2/23", "3–4/23"); then landscape with the side panel.
Usage: python3 panel_columns.py <manga id> <chapter id> [portrait|keys|landscape]   (default: all three)
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'stage3'))
sys.path.insert(0, HERE)
import drive as d  # noqa: E402
from rotate_anchor import result  # noqa: E402
from verify_columns import write_prefs, clear_dialogs  # noqa: E402
from rotate_during_layout import show_menu  # noqa: E402

PAGE_INFO = re.compile(r'^\d+/\d+ · ')


def check(name, ok, detail):
    result(name, ok, detail, step='panel')


def page_info(ns=None):
    ns = ns if ns is not None else d.nodes()
    n = next((m for m in ns if PAGE_INFO.match(m['text'])), None)
    return n['text'] if n else None


def hide_menu():
    """Centre tap hides the toolbar and the page indicator (a lost tap is retried)."""
    ns = d.nodes()
    w = max((m['b'][2] for m in ns), default=1080)
    h = max((m['b'][3] for m in ns), default=1920)
    for _ in range(3):
        if not page_info():
            return True
        d.tap(w // 2, h // 2, 3)
    return not page_info()


def wait_cols(cols, tries=40):
    st = None
    for _ in range(tries):
        st = d.status()
        if st and st.get('ready') and st.get('cols') == cols:
            return st
        time.sleep(2)
    return st


def portrait_panel(manga, chapter):
    """Portrait: the choices on the layout tab; 開啟 gives two columns and is stored; the indicator."""
    write_prefs({})
    d.shell('settings put system accelerometer_rotation 0')
    d.shell('settings put system user_rotation 0')
    time.sleep(3)
    st = d.open_book(manga, chapter)
    clear_dialogs()
    check('portrait, default: one column', st.get('cols') == 1, st)
    d.open_panel()
    d.tap_label('版面', exact=True)
    lab = d.reveal('僅橫向畫面')  # the row of choices, just under the "雙欄" label
    ns = d.nodes()
    texts = [n['text'] for n in ns]
    check('layout tab shows "雙欄" with 關閉 / 開啟 / 僅橫向畫面',
          lab is not None and all(t in texts for t in ('雙欄', '關閉', '開啟', '僅橫向畫面')), [t for t in texts if t][:40])
    d.shot('s4-01-panel-columns-default')
    d.tap_revealed('開啟')
    st = wait_cols(2)
    check('choosing 開啟 lays out two columns', st.get('cols') == 2, st)
    check('stored globally as pref_ebook_columns = on', d.ebook_prefs().get('pref_ebook_columns') == 'on', d.ebook_prefs())
    d.shot('s4-02-panel-columns-on')
    d.close_panel()
    time.sleep(2)
    info = show_menu()
    st = d.status()
    check('page indicator shows both pages of the spread', info is not None and f'· 1–2/{st["pages"]}' in info, [info, st])
    d.shot('s4-03-spread-page-info')
    hide_menu()


def page_keys(manga, chapter):
    """The indicator after Page Down (two columns on, portrait). While the menu is shown, page keys go to
    the toolbar (EbookReaderActivity.dispatchKeyEvent, since stage 2), so the menu is hidden first."""
    write_prefs({'columns': 'on'})
    d.shell('settings put system accelerometer_rotation 0')
    d.shell('settings put system user_rotation 0')
    time.sleep(3)
    st = d.open_book(manga, chapter)
    clear_dialogs()
    info = show_menu()
    check('keys: indicator on the first spread', info is not None and f'· 1–2/{st["pages"]}' in info, [info, st])
    hide_menu()
    d.shell('input keyevent 93')  # Page Down: next spread
    time.sleep(3)
    st = d.wait_ready()
    info = show_menu()
    check('after Page Down: next spread, indicator 3–4', st['page'] == 2 and info is not None and f'· 3–4/{st["pages"]}' in info,
          [info, st])
    d.shot('s4-06-spread-page-info-3-4')
    hide_menu()


def reveal_landscape(label, tries=6):
    """The side panel in landscape: scrolls its content up along the left edge (inside the panel, which is
    on the left for vertical books) until a node with text [label] is fully above the bottom edge. The
    portrait helpers in drive.py scroll at y = 1430..1770, below a landscape screen."""
    for _ in range(tries):
        ns = d.nodes()
        h = max((m['b'][3] for m in ns), default=1080)
        n = next((m for m in ns if m['text'] == label and m['b'][3] < h - 10), None)
        if n:
            return n
        d.swipe(12, int(h * 0.8), 12, int(h * 0.4), 1500, 2.0)
    return None


def landscape_panel(manga, chapter):
    """Landscape: the side panel's two-column choices (after scrolling), back to 僅橫向畫面, then portrait."""
    write_prefs({'columns': 'on'})
    d.shell('settings put system accelerometer_rotation 0')
    d.shell('settings put system user_rotation 1')
    time.sleep(8)
    st = d.open_book(manga, chapter)
    clear_dialogs()
    check('landscape, columns on: two columns', st.get('cols') == 2, st)
    d.open_panel()
    d.tap_label('版面', exact=True)
    n = reveal_landscape('僅橫向畫面')
    ns = d.nodes()
    nodes = {m['text']: m for m in ns if m['text'] in ('關閉', '開啟', '僅橫向畫面')}
    check('landscape side panel: the three choices, after scrolling', n is not None and len(nodes) == 3,
          {k: v['b'] for k, v in nodes.items()})
    d.shot('s4-04-side-panel-columns')
    if n:
        d.tap(n['x'], n['y'], 3)
    st = wait_cols(2)
    check('僅橫向畫面 in landscape: still two columns, stored as landscape', st.get('cols') == 2 and
          d.ebook_prefs().get('pref_ebook_columns') == 'landscape', [st, d.ebook_prefs().get('pref_ebook_columns')])
    d.close_panel()
    d.shell('settings put system user_rotation 0')
    time.sleep(8)
    st = wait_cols(1)
    check('僅橫向畫面 in portrait: one column', st.get('cols') == 1, st)
    d.shot('s4-05-portrait-one-column')


def main():
    manga, chapter = int(sys.argv[1]), int(sys.argv[2])
    part = sys.argv[3] if len(sys.argv) > 3 else 'all'
    if part in ('all', 'portrait'):
        portrait_panel(manga, chapter)
    if part in ('all', 'keys'):
        page_keys(manga, chapter)
    if part in ('all', 'landscape'):
        landscape_panel(manga, chapter)


if __name__ == '__main__':
    main()
