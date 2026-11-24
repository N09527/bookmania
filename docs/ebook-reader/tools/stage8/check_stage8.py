"""Stage 8 checks on the emulator (the user's four requests of 11/24), on the debug App:

  strings   the work page: the description header reads 內容簡介 (was 關於此日漫) and the chapter count 共 N 冊.
  fields    the typesetting panel's value fields: each of the nine values typed and applied (stored, and on the
            page: computed styles and the page box); a value outside the range is refused with the allowed range
            shown; the keyboard pushes the panel up and does not lay the page out again; with two columns the
            frames are where they belong after a value typed in a field (a typed value once left a link of the
            first frame focused and that frame scrolled to the end of the chapter).
  margins   two columns: the left / right margins stop where each column would be narrower than 120 dp (field
            and slider), the panel says so, the page never falls back to one column; margins stored beyond the
            limit are narrowed for the layout; no limit with one column or in landscape.
  cleanup   settings back to their defaults.

Usage: ADB=/path/to/adb python3 -I check_stage8.py strings fields margins cleanup
Results: out/results.jsonl (one JSON line per check), screenshots in out/shots/.
"""
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage7'))
sys.dont_write_bytecode = True
import check_stage7 as s7  # noqa: E402  (also the stage 3-6 helpers)

c, d, acc = s7.c, s7.d, s7.acc
HORZ = (8, 10)  # 橫排測試書 EPUB / zh-horizontal.epub
WORK = '橫排測試書 EPUB'
W, H = 412, 732  # the reader's viewport in portrait on this emulator (CSS px)
P, GAP, COL_GAP = 8, 24, 40  # as in the shell (reader.js)
FRAMES = """JSON.stringify(Array.prototype.map.call(document.querySelectorAll('#stage iframe'), function (f) {
  var w = f.contentWindow, a = f.contentDocument.activeElement;
  return { sx: w.scrollX, active: a ? a.tagName : null };
}))"""


def check(name, ok, detail=None):
    return c.check(name, ok, detail)


def px(v):
    return float(str(v).replace('px', '')) if v not in (None, 'normal') else None


def keyboard_shown():
    return 'mInputShown=true' in d.shell('dumpsys input_method | grep -m1 mInputShown')


def label_node(label, ns):
    """The panel's label (a TextView; the book's own text nodes are Views and can hold the same word)."""
    return next((n for n in ns if n['text'] == label and n['cls'].endswith('TextView')), None)


def field(label, ns=None):
    """The value field on the row of [label] (its description sits on a child node, not on the EditText)."""
    ns = ns if ns is not None else d.nodes()
    lab = label_node(label, ns)
    return next((n for n in ns if lab and n['cls'].endswith('EditText') and abs(n['y'] - lab['y']) < 60), None)


def reveal_row(label):
    """Scrolls the panel until the row of [label] is fully shown."""
    def pred(ns):
        lab = label_node(label, ns)
        return lab if lab is not None and 1290 < lab['b'][1] and lab['b'][3] < 1700 else None
    return d.reveal_node(pred)


def wait_seq(seq, timeout):
    t = time.time()
    while time.time() - t < timeout:
        st = d.status()
        if st and st.get('seq') != seq and st.get('ready'):
            time.sleep(3)
            return d.status()
        time.sleep(1)
    return d.status()


def type_value(label, text, expect_change=True):
    """Taps the field of [label], types [text] (the field selects its value on focus, so typing replaces it) and
    presses Enter (the keyboard's Done). Returns what was seen on the way."""
    reveal_row(label)
    f = field(label)
    if f is None:
        return {'field': None}
    st0 = d.status()
    d.tap(f['x'], f['y'], 3)
    up = keyboard_shown()
    f2 = field(label)
    st_up = d.status()
    d.shell(f'input text {text}')
    time.sleep(1.5)
    d.shell('input keyevent 66')
    st = wait_seq(st0['seq'], 45 if expect_change else 8)
    return {'field': f['b'], 'keyboard shown': up, 'field with the keyboard': f2 and f2['b'],
            'laid out again while the keyboard was up': st_up['seq'] != st0['seq'], 'seq': [st0['seq'], st['seq']], 'status': st}


def expected_frames(st):
    """Where the shell puts each frame: page p of frame i at (page + i) * step (horizontal text)."""
    page_w = (st['vw'] - st['marginLeft'] - st['marginRight'] - COL_GAP) // 2 if st['cols'] == 2 else \
        st['vw'] - st['marginLeft'] - st['marginRight']
    step = page_w + GAP
    return [(st['page'] + i) * step for i in range(st['cols'])]


def frames():
    v = d.cdp(FRAMES)
    return json.loads(v) if isinstance(v, str) else []


def visible_texts():
    return [n['text'] for n in d.nodes() if n['text'] and n['cls'].endswith('TextView')]


# region strings

def open_work_page(title):
    """Browse > Local source > [title], scrolling the list of works (it grew past one screen in stage 7)."""
    c.stop_app(0)
    d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity')
    time.sleep(6)
    c.wait_app_drawn()
    time.sleep(4)
    c.clear_dialogs()
    for labels, wait in ((('探索', 'Browse'), 5), (('本機來源', 'Local source'), 10)):
        n = next((m for m in (d.find(x, exact=True) for x in labels) if m), None)
        if n is None:
            s7.shot('strings-not-found-' + labels[0])
            return False
        d.tap(n['x'], n['y'], wait)
    for _ in range(10):
        n = d.find(title, exact=True)
        if n is not None and n['y'] < 1650:
            d.tap(n['x'], n['y'], 10)
            for _ in range(12):
                texts = [m['text'] for m in d.nodes() if m['text']]
                if any(t in texts for t in ('開始閱讀', '繼續閱讀', '加入書櫃', '在書櫃中')) or any(t.startswith('繼續閱讀') for t in texts):
                    time.sleep(20)  # the chapters are read from the folder
                    return True
                time.sleep(3)
            s7.shot('strings-work-page-not-shown')
            return False
        d.swipe(540, 1350, 540, 550, 800, 3)  # above the floating filter bar of the list
    s7.shot('strings-work-not-in-list')
    return False


def step_strings():
    c.STEP[0] = 'strings'
    c.rotate(False)
    opened = open_work_page(WORK)
    check('the work page shows', opened)
    texts = []
    for _ in range(4):
        texts = [n['text'] for n in d.nodes() if n['text']]
        if '內容簡介' in texts and any(re.fullmatch(r'共 \d+ 冊', t) for t in texts):
            break
        d.swipe(540, 1500, 540, 900, 800, 3)
    s7.shot('strings-work-page')
    check('the description header reads 內容簡介', '內容簡介' in texts, [t for t in texts if '簡介' in t or '關於' in t])
    check('no header starts with 關於此', not any(t.startswith('關於此') for t in texts), [t for t in texts if t.startswith('關於')])
    count = next((t for t in texts if re.fullmatch(r'共 \d+ 冊', t)), None)
    check('the chapter count reads 共 N 冊', count is not None, count or [t for t in texts if t.startswith('共')])
    c.stop_app()

# endregion

# region fields


def step_fields():
    c.STEP[0] = 'fields'
    c.set_prefs({'pref_ebook_columns': 'off'}, reset_typesetting=True)
    c.rotate(False)
    c.open_book(*HORZ)
    d.open_panel()
    reveal_row('字級')
    s7.shot('fields-01-text-tab')
    ns = d.nodes()
    f = field('字級', ns)
    check('a value field on the font size row, showing the value (20)', f is not None and f['text'] == '20',
          [(n['text'], n['b']) for n in ns if n['cls'].endswith('EditText')])

    # Font size: the keyboard pushes the panel up, the page is not laid out again until Done.
    r = type_value('字級', '26')
    s7.shot('fields-02-font-size-26')
    sty = d.style()
    p = d.ebook_prefs()
    check('font size typed: the keyboard shows', r.get('keyboard shown'), r)
    check('font size typed: the field moves above the keyboard',
          r.get('field') and r.get('field with the keyboard') and r['field with the keyboard'][3] < r['field'][1] - 300, r)
    check('font size typed: no relayout while the keyboard is up', r.get('laid out again while the keyboard was up') is False, r)
    check('font size 26 applied (stored, on the page)', p.get('pref_ebook_fontSize') == '26' and sty['p']['fontSize'] == '26px',
          {'stored': p.get('pref_ebook_fontSize'), 'css': sty['p']['fontSize']})
    check('the keyboard is hidden after Done', not keyboard_shown())

    # A value outside the range: refused, the allowed range shows; leaving the field puts the value back.
    r = type_value('字級', '60', expect_change=False)
    texts = visible_texts()
    s7.shot('fields-03-out-of-range')
    p = d.ebook_prefs()
    check('font size 60 refused: the allowed range shows', '可輸入 12～48 的整數' in texts and p.get('pref_ebook_fontSize') == '26',
          {'texts': [t for t in texts if '可輸入' in t], 'stored': p.get('pref_ebook_fontSize'), 'seq': r.get('seq')})
    d.shell('input keyevent 4')  # hides the keyboard
    time.sleep(2)
    d.shell('input keyevent 4')  # takes the focus from the field: the value goes back
    time.sleep(3)
    f = field('字級')
    texts = visible_texts()
    check('leaving the field puts the value back and hides the note', f is not None and f['text'] == '26' and '可輸入 12～48 的整數' not in texts,
          {'field': f and f['text'], 'notes': [t for t in texts if '可輸入' in t]})

    cases = [
        ('行距', '1.75', 'pref_ebook_lineHeight', '1.75', lambda s: abs(px(s['p']['lineHeight']) - 1.75 * 26) < 0.6, 'lineHeight'),
        ('字距', '0.07', 'pref_ebook_letterSpacing', '0.07', lambda s: abs(px(s['p']['letterSpacing']) - 0.07 * 26) < 0.1, 'letterSpacing'),
    ]
    for label, text, key, stored, ok, prop in cases:
        r = type_value(label, text)
        sty = d.style()
        p = d.ebook_prefs()
        check(f'{label} {text} applied (stored, on the page)', p.get(key) == stored and ok(sty),
              {'stored': p.get(key), 'css': sty['p'][prop], 'seq': r.get('seq')})

    # Indent and paragraph spacing follow the book by default: their fields show once that is switched off.
    for label, text, key, ok, prop in (
        ('首行縮排', '1.5', 'pref_ebook_indent', lambda s: abs(px(s['p']['textIndent']) - 1.5 * 26) < 0.6, 'textIndent'),
        ('段落間距', '0.35', 'pref_ebook_paragraphSpacing', lambda s: abs(px(s['p']['margin'][2]) - 0.35 * 26) < 0.6, 'margin'),
    ):
        reveal_row(label)
        ns = d.nodes()
        had = field(label, ns) is not None
        sw = d.switch_for(label, ns)
        seq = d.status()['seq']
        if sw is not None:
            d.tap(sw['x'], sw['y'], 3)
            wait_seq(seq, 45)
        check(f'{label}: no field while it follows the book, a field once switched off', not had and field(label) is not None,
              {'field before': had, 'switch': sw and sw['b']})
        r = type_value(label, text)
        sty = d.style()
        p = d.ebook_prefs()
        check(f'{label} {text} applied (stored, on the page)', p.get(key) == text and ok(sty),
              {'stored': p.get(key), 'css': sty['p'][prop], 'seq': r.get('seq')})
    s7.shot('fields-04-text-tab-typed')
    d.close_panel()

    # Margins (layout tab), one column: odd values are kept (the slider steps by 2).
    s7.panel_layout_tab()
    s7.shot('fields-05-layout-tab')
    expect = {'上': ('40', 'pref_ebook_marginTop'), '下': ('25', 'pref_ebook_marginBottom'),
              '左': ('25', 'pref_ebook_marginLeft'), '右': ('31', 'pref_ebook_marginRight')}
    for label, (text, key) in expect.items():
        r = type_value(label, text)
        p = d.ebook_prefs()
        check(f'margin {label} {text} stored', p.get(key) == text, {'stored': p.get(key), 'seq': r.get('seq')})
    sty = d.style()
    box = sty.get('frame')
    want = [25 - P, 40 - P, (W - 25 - 31) + 2 * P, (H - 40 - 25) + 2 * P]
    check('the page box follows the typed margins (left, top, width, height)', box == want, {'frame': box, 'expected': want})
    s7.shot('fields-06-margins-typed')
    d.close_panel()
    c.leave_reader()
    c.stop_app()

    # Two columns: after a value typed in a field the frames are where they belong.
    c.set_prefs({'pref_ebook_columns': 'on'}, reset_typesetting=True)
    c.open_book(*HORZ)
    d.open_panel()
    r = type_value('字級', '24')
    st = d.status()
    fr = frames()
    want = expected_frames(st)
    s7.shot('fields-07-two-columns-after-typing')
    check('two columns, font size typed: each frame shows its page, nothing focused in them',
          [f['sx'] for f in fr] == want and all(f['active'] == 'BODY' for f in fr) and st['cols'] == 2,
          {'frames': fr, 'expected scroll': want, 'status': {k: st[k] for k in ('page', 'pages', 'cols', 'seq')}})
    d.close_panel()
    c.leave_reader()
    c.stop_app()

# endregion

# region margins


def step_margins():
    c.STEP[0] = 'margins'
    c.set_prefs({'pref_ebook_columns': 'on'}, reset_typesetting=True)
    c.rotate(False)
    c.open_book(*HORZ)
    st = d.status()
    check('two columns in portrait: the shell reports the limit (412 - 2 x 120 - 40 = 132)',
          st.get('twoWanted') is True and st.get('marginMost') == 132 and st['cols'] == 2,
          {k: st.get(k) for k in ('twoWanted', 'marginMost', 'cols', 'vw')})
    s7.panel_layout_tab()
    note = '雙欄時，左右邊距合計最多 132 dp（每欄至少 120 dp）。'
    d.reveal_node(lambda ns: next((n for n in ns if n['text'] == note and n['b'][3] < 1790), None))
    check('the panel says how far the side margins go with two columns', note in visible_texts())
    s7.shot('margins-01-note')

    r = type_value('左', '120', expect_change=False)
    texts = visible_texts()
    p = d.ebook_prefs()
    check('left 120 refused with two columns (right 20): 0 to 112 allowed', '可輸入 0～112 的整數' in texts and p.get('pref_ebook_marginLeft') is None,
          {'notes': [t for t in texts if '可輸入' in t], 'stored': p.get('pref_ebook_marginLeft'), 'seq': r.get('seq')})
    s7.shot('margins-02-left-120-refused')
    d.shell('input keyevent 4')
    time.sleep(2)
    d.shell('input keyevent 4')
    time.sleep(3)
    r = type_value('左', '112')
    st = d.status()
    check('left 112 applied: still two columns of 120', st['cols'] == 2 and st['marginLeft'] == 112 and
          (st['vw'] - st['marginLeft'] - st['marginRight'] - COL_GAP) // 2 == 120,
          {k: st.get(k) for k in ('cols', 'marginLeft', 'marginRight', 'pages', 'seq')})
    s7.shot('margins-03-left-112')

    # The slider stops at the limit: left back to 60, then the right slider's thumb dragged past the end (a tap on
    # the very edge of a slider does not register, on any slider: the drag is what a finger does).
    type_value('左', '60')
    reveal_row('右')
    sl = d.reveal_slider('右')
    seq = d.status()['seq']
    x1, y1, x2, y2 = sl['b']
    thumb = x1 + 5 + (20 / 72) * (x2 - x1 - 10)
    d.swipe(int(thumb), int((y1 + y2) / 2), 1076, int((y1 + y2) / 2), 1500, 3)
    st = wait_seq(seq, 45)
    p = d.ebook_prefs()
    check('the right slider ends at the limit (132 - 60 = 72): still two columns',
          p.get('pref_ebook_marginRight') == '72' and st['cols'] == 2,
          {'stored': p.get('pref_ebook_marginRight'), 'status': {k: st.get(k) for k in ('cols', 'marginLeft', 'marginRight')}})
    s7.shot('margins-04-right-slider-end')

    # The stage 7 reproduction, now: the left margin moved up and down never changes the columns.
    cols = []
    for value in (80, 40, 70):
        r = type_value('左', str(min(value, 132 - 72)))
        cols.append((value, d.status()['cols'], d.ebook_prefs().get('pref_ebook_marginLeft')))
    check('left margin moved back and forth: two columns every time', all(x[1] == 2 for x in cols), cols)
    d.close_panel()
    c.leave_reader()
    c.stop_app()

    # Margins stored beyond the limit (set with one column, or in landscape): narrowed in proportion, two columns.
    c.set_prefs({'pref_ebook_columns': 'on', 'pref_ebook_marginLeft': '80', 'pref_ebook_marginRight': '90'}, reset_typesetting=True)
    c.open_book(*HORZ)
    st = d.status()
    want_left = 80 * 132 // 170
    check('margins 80 + 90 stored, limit 132: two columns, margins narrowed in proportion',
          st['cols'] == 2 and st['marginLeft'] == want_left and st['marginRight'] == 132 - want_left,
          {k: st.get(k) for k in ('cols', 'marginLeft', 'marginRight', 'marginMost')})
    s7.shot('margins-05-stored-beyond')
    s7.panel_layout_tab()
    over = '目前合計 170 dp，雙欄時會按比例縮小。'
    d.reveal_node(lambda ns: next((n for n in ns if n['text'] == over and n['b'][3] < 1790), None))
    check('the panel says the stored margins are narrowed', over in visible_texts())
    s7.shot('margins-06-over-note')
    d.close_panel()

    # Landscape: the limit is beyond 120 + 120, no note.
    c.rotate(True)
    t = time.time()
    st = d.status()
    while time.time() - t < 90 and not (st and st.get('vw', 0) > 600 and st.get('ready')):
        time.sleep(3)
        st = d.status()
    check('landscape: two columns, the stored margins fit (no narrowing)', st['cols'] == 2 and st['marginLeft'] == 80 and st['marginRight'] == 90,
          {k: st.get(k) for k in ('cols', 'marginLeft', 'marginRight', 'marginMost', 'vw')})
    s7.panel_layout_tab()
    texts = visible_texts()
    for _ in range(4):
        d.scroll_panel(320)
        texts += visible_texts()
    check('landscape: no two-column margin note', not any('雙欄時，左右邊距' in t for t in texts), [t for t in texts if '雙欄' in t])
    s7.shot('margins-07-landscape')
    d.close_panel()
    c.rotate(False)
    c.leave_reader()
    c.stop_app()

    # One column: no limit, no note.
    c.set_prefs({'pref_ebook_columns': 'off'}, reset_typesetting=True)
    c.open_book(*HORZ)
    st = d.status()
    s7.panel_layout_tab()
    texts = visible_texts()
    for _ in range(4):
        d.scroll_panel(320)
        texts += visible_texts()
    r = type_value('左', '120')
    p = d.ebook_prefs()
    check('one column: no limit reported, no note, left 120 accepted',
          st.get('twoWanted') is False and not any('雙欄時，左右邊距' in t for t in texts) and p.get('pref_ebook_marginLeft') == '120',
          {'twoWanted': st.get('twoWanted'), 'stored': p.get('pref_ebook_marginLeft')})
    d.close_panel()
    c.leave_reader()
    c.stop_app()

# endregion


def step_cleanup():
    c.STEP[0] = 'cleanup'
    c.rotate(False)
    c.set_prefs({}, reset_typesetting=True)
    c.note('typesetting settings back to their defaults')


def main():
    steps = {'strings': step_strings, 'fields': step_fields, 'margins': step_margins, 'cleanup': step_cleanup}
    for name in sys.argv[1:]:
        try:
            steps[name]()
        except Exception as e:  # noqa: BLE001  (record it and go on with the next step)
            check(f'{name}: the step ran to its end', False, repr(e))
            try:
                s7.shot(f'{name}-exception')
                c.stop_app()
            except Exception:  # noqa: BLE001
                pass


if __name__ == '__main__':
    main()
