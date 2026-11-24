"""Stage 3 checks on an emulator: typesetting settings through the real panel, read back from the
book document with DevTools. Usage: python3 -I check_settings.py <step> [<step> ...]
Steps: reset defaults global persist scopes vol2 reset_levels fonts
Results are printed as PASS/FAIL lines and appended to out/results.jsonl; screenshots go to out/shots.
Needs: drive.py (same folder), the debug APK with the stage 2 test books (see ../stage2/README.md),
the app language set to Traditional Chinese (labels are matched in zh-TW).
"""
import json
import re
import os
import sys
import time
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # also under python3 -I
import drive as d  # noqa: E402

VERT = (14, 16)  # 直排測試書 EPUB (vertical)
HORZ = (8, 10)   # 橫排測試書 EPUB (horizontal), work "橫排測試書 EPUB"
RESULTS = os.path.join(d.OUT, 'results.jsonl')


def check(name, ok, detail=None):
    line = {'step': STEP, 'check': name, 'ok': bool(ok), 'detail': detail}
    with open(RESULTS, 'a', encoding='utf-8') as f:
        f.write(json.dumps(line, ensure_ascii=False) + '\n')
    print('PASS' if ok else 'FAIL', name, '' if detail is None else json.dumps(detail, ensure_ascii=False)[:300])
    return ok


def px(v):
    try:
        return float(str(v).replace('px', ''))
    except ValueError:
        return None


def near(a, b, eps=0.6):
    return a is not None and b is not None and abs(a - b) <= eps


def anchor_visible(first):
    """Whether the character the page started with before a change is still fully visible."""
    if not first:
        return None
    expr = """(function(ni, off){ var f=document.querySelector('#stage iframe'), dd=f.contentDocument;
      var tw=dd.createTreeWalker(dd.body||dd.documentElement, NodeFilter.SHOW_TEXT), i=0;
      for (var n=tw.nextNode(); n; n=tw.nextNode(), i++) { if (i===ni) { var r=dd.createRange(); r.setStart(n,off); r.setEnd(n,off+1);
        var rc=r.getClientRects()[0]; return JSON.stringify(rc ? [rc.left, rc.top, rc.right, rc.bottom, f.clientWidth, f.clientHeight] : null); } }
      return 'null'; })(%d, %d)""" % (first['node'], first['offset'])
    v = d.cdp(expr)
    r = json.loads(v) if isinstance(v, str) else None
    if not r:
        return False
    left, top, right, bottom, w, h = r
    return left >= -0.5 and top >= -0.5 and right <= w + 0.5 and bottom <= h + 0.5


def after_change(label):
    """Waits for the relayout, records the styles and a screenshot."""
    time.sleep(2)
    d.wait_ready()
    s = d.style()
    d.shot(label)
    return s


def write_prefs_without_ebook():
    d.shell(f'am force-stop {d.PKG}')
    time.sleep(1)
    root = ET.fromstring(d.prefs())
    for e in list(root):
        n = e.get('name', '')
        if n.startswith('pref_ebook_') or n == '__APP_STATE_ebook_fonts':
            root.remove(e)
    data = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n" + ET.tostring(root, encoding='unicode')
    tmp = os.path.join(d.OUT, 'prefs-clean.xml')
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(data)
    d.adb('push', tmp, '/data/local/tmp/p.xml')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/p.xml shared_prefs/{d.PKG}_preferences.xml')
    d.shell(f'run-as {d.PKG} rm -rf files/ebook-fonts')


def selected_scope(ns=None):
    """The level whose segment is checked (uiautomator marks the selected segment's container)."""
    ns = ns if ns is not None else d.nodes()
    for m in ns:
        if not m['checked']:
            continue
        for label in ('全部書籍', '這部作品', '這個檔案'):
            t = d.find(label, ns, exact=True)
            if t and m['b'][0] <= t['x'] <= m['b'][2] and m['b'][1] <= t['y'] <= m['b'][3]:
                return label
    return None


def scope_is(expected, tries=4):
    """Polls: the screen dump can be taken before the panel has redrawn on a slow emulator."""
    got = None
    for _ in range(tries):
        got = selected_scope()
        if got == expected:
            break
        time.sleep(2)
    return got


# ---------------------------------------------------------------- steps

def step_reset():
    write_prefs_without_ebook()
    check('ebook prefs cleared', not d.ebook_prefs(), d.ebook_prefs())


def step_defaults():
    st = d.open_book(*VERT)
    s = d.style()
    w, h = s['win']
    check('vertical book opens in V mode', st['mode'] == 'V', st)
    check('default font size 20px', s['html']['fontSize'] == '20px', s['html']['fontSize'])
    check('default line height 1.8 (36px)', near(px(s['body']['lineHeight']), 36), s['body']['lineHeight'])
    check('default margins 32/32/20/20', s['frame'] == [12, 24, w - 40 + 16, h - 64 + 16], s['frame'])
    check('letter spacing not overridden at 0', s['p']['letterSpacing'] == 'normal', s['p']['letterSpacing'])
    check("book's own indent kept (1em = 20px)", s['p']['textIndent'] == '20px', s['p']['textIndent'])
    d.shot('s3-01-default-vertical')


def step_global():
    d.open_book(*VERT)
    d.open_panel()
    ns = d.nodes()
    d.shot('s3-02-panel-text-tab')
    check('panel starts on the global level', selected_scope(ns) == '全部書籍', selected_scope(ns))

    before = d.style()
    d.set_slider('字級', (30 - 12) / 36)
    s = after_change('s3-03-font-size-30')
    check('font size 30px', s['html']['fontSize'] == '30px', s['html']['fontSize'])
    check('stored as global pref_ebook_fontSize=30', d.ebook_prefs().get('pref_ebook_fontSize') == '30', d.ebook_prefs())
    check('same text position after relayout', anchor_visible(before['first']), {'before': before['first'], 'after': s['first']})

    d.set_slider('行距', (2.4 - 1.0) / 2.0)
    s = after_change('s3-04-line-height-2.4')
    check('line height 2.4 (72px)', near(px(s['body']['lineHeight']), 72), s['body']['lineHeight'])

    d.set_slider('字距', 0.1 / 0.5)
    s = after_change('s3-05-letter-spacing-0.1')
    check('letter spacing 0.1em (3px)', near(px(s['p']['letterSpacing']), 3), s['p']['letterSpacing'])

    # First-line indent: "follow the book" switch off → 2 characters, then the slider to 1.
    d.reveal('首行縮排')
    sw = d.switch_for('首行縮排')
    check('indent: "follow the book" switch on by default', bool(sw and sw['checked']), sw and sw['b'])
    if sw:
        d.tap(sw['x'], sw['y'], 3)
        s = after_change('s3-06-indent-2')
        check('indent switched to 2 characters (60px)', near(px(s['p']['textIndent']), 60), s['p']['textIndent'])
        # 3 characters: unlike 1, this cannot be confused with the book's own 1em indent
        d.set_slider('首行縮排', 3 / 4)
        s = after_change('s3-07-indent-3')
        check('indent 3 characters (90px)', near(px(s['p']['textIndent']), 90), s['p']['textIndent'])
    # Paragraph spacing: switch off → 0.5em, then the slider to 1em.
    d.reveal('段落間距')
    sw = d.switch_for('段落間距')
    check('paragraph spacing: "follow the book" switch on by default', bool(sw and sw['checked']), sw and sw['b'])
    if sw:
        d.tap(sw['x'], sw['y'], 3)
        s = after_change('s3-08-paragraph-spacing-0.5')
        # vertical-rl: the block end of a paragraph is its left side
        check('paragraph spacing 0.5em (15px, left side in vertical text)', near(px(s['p']['margin'][3]), 15), s['p']['margin'])
        d.set_slider('段落間距', 1.0 / 3.0)
        s = after_change('s3-09-paragraph-spacing-1')
        check('paragraph spacing 1em (30px)', near(px(s['p']['margin'][3]), 30), s['p']['margin'])

    d.tap_label('版面', exact=True)
    d.shot('s3-10-panel-layout-tab')
    d.tap_revealed('橫書')
    s = after_change('s3-11-writing-horizontal')
    check('writing mode forced horizontal', s['st']['mode'] == 'H' and s['html']['writingMode'] == 'horizontal-tb',
          [s['st']['mode'], s['html']['writingMode']])
    d.tap_revealed('依書籍')
    s = after_change('s3-12-writing-book')
    check('writing mode back to the book (vertical)', s['st']['mode'] == 'V', s['st']['mode'])

    # Margins: the tap lands near the wanted value; compare the page box with the value actually stored.
    d.set_slider('上', 60 / 120)
    s = after_change('s3-13-margin-top-60')
    top = int(d.ebook_prefs().get('pref_ebook_marginTop', '-1'))
    check('top margin set near 60 and the page box follows it (top = margin - 8)',
          abs(top - 60) <= 4 and s['frame'][1] == top - 8, {'stored': top, 'frame': s['frame']})
    d.set_slider('左', 40 / 120)
    s = after_change('s3-14-margin-left-40')
    left = int(d.ebook_prefs().get('pref_ebook_marginLeft', '-1'))
    w = s['win'][0]
    check('left margin set near 40 and the page box follows it (x = margin - 8, width = W - left - 20 + 16)',
          abs(left - 40) <= 4 and s['frame'][0] == left - 8 and s['frame'][2] == w - left - 20 + 16,
          {'stored': left, 'frame': s['frame']})
    d.close_panel()


def step_direction():
    """Page direction: auto (vertical = right-to-left), then left-opening, then back to auto."""
    d.open_book(*VERT)
    st0 = d.status()
    d.tap(180, 960, 3)  # left third
    st1 = d.wait_ready()
    check('auto, vertical: left tap = next page', st1['page'] == st0['page'] + 1, [st0['page'], st1['page']])
    d.open_panel()
    d.tap_label('版面', exact=True)
    d.tap_revealed('左開')
    d.close_panel()
    st1 = d.status()
    d.tap(900, 960, 3)  # right third
    st2 = d.wait_ready()
    check('left-opening: right tap = next page', st2['page'] == st1['page'] + 1, [st1['page'], st2['page']])
    d.shell('input keyevent 22')  # DPAD_RIGHT
    time.sleep(3)
    st3 = d.wait_ready()
    check('left-opening: DPAD_RIGHT = next page', st3['page'] == st2['page'] + 1, [st2['page'], st3['page']])
    d.open_panel()
    d.tap_label('版面', exact=True)
    d.tap_revealed('自動')
    d.close_panel()
    check('direction stored as auto again', d.ebook_prefs().get('pref_ebook_pageDirection') == 'auto', d.ebook_prefs())


def step_persist():
    d.open_book(*VERT)
    s = d.style()
    check('after restart: font size 30', s['html']['fontSize'] == '30px', s['html']['fontSize'])
    check('after restart: line height 72px', near(px(s['body']['lineHeight']), 72), s['body']['lineHeight'])
    check('after restart: indent 90px', near(px(s['p']['textIndent']), 90), s['p']['textIndent'])
    check('after restart: paragraph spacing 30px', near(px(s['p']['margin'][3]), 30), s['p']['margin'])
    check('after restart: letter spacing 3px', near(px(s['p']['letterSpacing']), 3), s['p']['letterSpacing'])
    p = d.ebook_prefs()
    check('after restart: page box from the stored margins',
          s['frame'][:2] == [int(p['pref_ebook_marginLeft']) - 8, int(p['pref_ebook_marginTop']) - 8], [s['frame'], p.get('pref_ebook_marginLeft'), p.get('pref_ebook_marginTop')])
    d.shot('s3-15-after-restart')
    print(json.dumps(d.ebook_prefs(), ensure_ascii=False, indent=1))


def overrides():
    """(work, file) override maps from the stored preferences (identity fields included)."""
    work, file = {}, {}
    for k, v in d.ebook_prefs().items():
        if k.startswith('pref_ebook_override_'):
            m = json.loads(v)
            if '_chapter' in m:
                file = m
            else:
                work = m
    return work, file


def gfloat(key, default):
    v = d.ebook_prefs().get('pref_ebook_' + key)
    return float(v) if v is not None else default


def step_scopes():
    d.open_book(*HORZ)
    s = d.style()
    g_size = gfloat('fontSize', 20)
    check('other book (another work) uses the global font size', px(s['html']['fontSize']) == g_size, [s['html']['fontSize'], g_size])
    d.open_panel()
    d.tap_label('這部作品', exact=True)
    got = scope_is('這部作品')
    check('work level selected', got == '這部作品', got)
    d.set_slider('字級', (24 - 12) / 36)
    s = after_change('s3-16-work-font-24')
    work, _ = overrides()
    w_size = float(work.get('fontSize', -1))
    check('work level font size stored (near 24) and applied', abs(w_size - 24) <= 1 and px(s['html']['fontSize']) == w_size,
          {'stored': work, 'css': s['html']['fontSize']})
    check('global value unchanged', gfloat('fontSize', 20) == g_size, gfloat('fontSize', 20))
    d.tap_label('全部書籍', exact=True)
    ns = d.nodes()
    d.shot('s3-17-global-view-with-work-override')
    note = [n['text'] for n in ns if '也有設定' in n['text']]
    check('global view notes the work-level override', any('這部作品' in t for t in note), note)
    d.tap_label('這個檔案', exact=True)
    d.set_slider('行距', (1.5 - 1.0) / 2.0)
    s = after_change('s3-18-file-line-height-1.5')
    _, file = overrides()
    f_lh = float(file.get('lineHeight', -1))
    check('file level line height stored (near 1.5) and applied', abs(f_lh - 1.5) <= 0.1 and near(px(s['body']['lineHeight']), f_lh * w_size),
          {'stored': file, 'css': s['body']['lineHeight']})
    d.close_panel()
    work, file = overrides()
    check('override entries carry the identity (_source, _manga; file also _chapter)',
          {'_source', '_manga'} <= set(work) and {'_source', '_manga', '_chapter'} <= set(file), [work, file])

    # Restart: the nearer levels still win, and the panel starts on the file level.
    d.open_book(*HORZ)
    s = d.style()
    check('after restart: work font size', px(s['html']['fontSize']) == w_size, s['html']['fontSize'])
    check('after restart: file line height', near(px(s['body']['lineHeight']), f_lh * w_size), s['body']['lineHeight'])
    d.open_panel()
    got = scope_is('這個檔案')
    check('panel starts on the file level', got == '這個檔案', got)
    d.shot('s3-19-panel-file-level')
    d.close_panel()

    # The vertical book (another work) is not affected.
    d.open_book(*VERT)
    s = d.style()
    g_lh = gfloat('lineHeight', 1.8)
    check('other work keeps the global values', px(s['html']['fontSize']) == g_size and near(px(s['body']['lineHeight']), g_lh * g_size),
          [s['html']['fontSize'], s['body']['lineHeight']])


def step_vol2(manga, chapter):
    """A second file of the same work: work settings apply, file settings do not."""
    work, _ = overrides()
    w_size = float(work['fontSize'])
    g_lh = gfloat('lineHeight', 1.8)
    d.open_book(manga, chapter)
    s = d.style()
    check('same work, other file: work font size', px(s['html']['fontSize']) == w_size, [s['html']['fontSize'], w_size])
    check('same work, other file: global line height (not the other file\'s)', near(px(s['body']['lineHeight']), g_lh * w_size),
          [s['body']['lineHeight'], g_lh * w_size])
    d.shot('s3-20-same-work-other-file')


def step_reset_levels():
    work, _ = overrides()
    w_size = float(work['fontSize'])
    g_size, g_lh = gfloat('fontSize', 20), gfloat('lineHeight', 1.8)
    d.open_book(*HORZ)
    d.open_panel()
    got = scope_is('這個檔案')
    check('panel starts on the file level', got == '這個檔案', got)
    d.tap_label('清除這一層的設定', exact=True)
    s = after_change('s3-21-file-level-cleared')
    check('file level cleared: line height back to global', near(px(s['body']['lineHeight']), g_lh * w_size),
          [s['body']['lineHeight'], g_lh * w_size])
    d.tap_label('這部作品', exact=True)
    got = scope_is('這部作品')
    check('work level selected for clearing', got == '這部作品', got)
    d.tap_label('清除這一層的設定', exact=True)
    s = after_change('s3-22-work-level-cleared')
    check('work level cleared: font size back to global', px(s['html']['fontSize']) == g_size, [s['html']['fontSize'], g_size])
    p = d.ebook_prefs()
    check('no override entries left', not any(k.startswith('pref_ebook_override_') for k in p), sorted(p))
    d.close_panel()


def pick_font_file(file_name):
    """From the panel's text tab: 匯入字型… → system picker (DocumentsUI) → Downloads → the file. The picker lists
    the newest files first, in a grid; newer test files in Download (backups, test books) had pushed the fonts
    out of view, so the list view is chosen and the list scrolled until the file shows (stage 7; the stage 6
    acceptance checks had met the same problem). Before, the fallback to the storage root could press BACK and
    close the picker."""
    for _ in range(4):
        n = d.find('匯入字型', exact=False)
        if n:
            break
        d.scroll_panel(400)
    else:
        raise RuntimeError('import button not found')
    d.tap(n['x'], n['y'], 6)
    t = time.time()
    while 'documentsui' not in d.resumed():
        if time.time() - t > 60:
            raise RuntimeError('picker did not open: ' + d.resumed())
        time.sleep(2)
    time.sleep(4)
    if not d.find('Downloads', exact=True):
        roots = d.find('Show roots', exact=True)
        if roots:
            d.tap(roots['x'], roots['y'], 3)
        if d.find('Downloads', exact=True):
            d.tap_label('Downloads', exact=True, wait=5)
    view = d.find('List view', exact=True)
    if view:
        d.tap(view['x'], view['y'], 3)
    for _ in range(10):
        f = d.find(file_name, exact=True)
        if f:
            d.shot('s3-30-picker-' + file_name.split('.')[0])
            d.tap(f['x'], f['y'], 8)
            return
        d.swipe(540, 1500, 540, 800, 800, 2)
    d.shot('s3-30-picker-not-found-' + file_name.split('.')[0])
    raise RuntimeError(f'not found in the picker: {file_name}')


def font_row(name, ns=None):
    ns = ns if ns is not None else d.nodes()
    return d.find(name, ns, exact=True)


def step_fonts():
    d.open_book(*VERT)
    d.open_panel()
    # 1. A font without vertical layout data: warning, then import anyway.
    pick_font_file('DejaVuSans.ttf')
    warn = []
    for _ in range(6):  # the font is read in the background before the dialog appears
        ns = d.nodes()
        warn = [n['text'] for n in ns if '沒有直排資訊（' in n['text']]
        if warn:
            break
        time.sleep(2)
    d.shot('s3-31-no-vertical-warning')
    check('warning for a font without vertical data', bool(warn), warn)
    d.tap_label('匯入', exact=True, wait=4)
    ns = d.nodes()
    check('imported font listed with its note', font_row('DejaVu Sans', ns) is not None and d.find('沒有直排資訊', ns, exact=True) is not None,
          [n['text'] for n in ns if n['cls'].endswith('TextView')][-8:])
    # 2. A CJK font with vertical data (25 MB): no warning.
    pick_font_file('NotoSerifCJKtc-Bold.otf')
    ns = d.nodes()
    check('no warning for a font with vertical data', not any('沒有直排資訊（' in n['text'] for n in ns))
    fonts = json.loads(d.ebook_prefs().get('__APP_STATE_ebook_fonts') or '[]')
    check('two fonts in the app-state list', len(fonts) == 2, fonts)
    files = d.shell(f'run-as {d.PKG} ls -l files/ebook-fonts')
    check('font files stored in files/ebook-fonts', files.count('.ttf') == 1 and files.count('.otf') == 1, files)
    noto = next((f for f in fonts if f['extension'] == 'otf'), None)
    dejavu = next((f for f in fonts if f['extension'] == 'ttf'), None)
    check('vertical flags from the font tables', bool(noto and noto['vertical'] and dejavu and not dejavu['vertical']), fonts)

    # 3. Use the CJK font.
    t0 = time.time()
    n = font_row(noto['name']) if noto else None
    if n:
        d.tap(n['x'], n['y'], 1)
    s = after_change('s3-32-imported-font-vertical')
    check('imported font applied (font-family and FontFace loaded)',
          'BookmaniaUserFont' in (s['p']['fontFamily'] or '') and 'BookmaniaUserFont:loaded' in s['faces'], [s['p']['fontFamily'], s['faces']])
    check('relayout with a 25 MB font finished', True, {'seconds_including_ui_wait': round(time.time() - t0, 1)})
    guard = d.cdp('(' + open(os.path.join(d.HERE, 'font-guard.js'), encoding='utf-8').read() + ')(%s)' % json.dumps(noto['id']))
    g = json.loads(guard) if isinstance(guard, str) else {}
    bad = {k: v for k, v in g.items() if not k.endswith(noto['id'])}
    check('font URLs other than a listed id are refused', bool(bad) and all(v.startswith('error') for v in bad.values()), g)
    check('the listed id loads from the shell', g.get('/fonts/' + noto['id']) == 'loaded', g)
    d.close_panel()
    d.shot('s3-33-imported-font-page')

    # 4. The font stays after a restart, and is used in the next chapter as well.
    d.open_book(*VERT)
    s = d.style()
    check('after restart: imported font used', 'BookmaniaUserFont:loaded' in s['faces'], s['faces'])

    # 5. Delete both fonts; the selected one falls back to the book's font.
    d.open_panel()
    for f in (dejavu, noto):
        ns = d.nodes()
        row = font_row(f['name'], ns)
        if row is None:
            d.scroll_panel(300)
            ns = d.nodes()
            row = font_row(f['name'], ns)
        dels = [m for m in ns if m['desc'] == '刪除字型' and row and abs(m['y'] - row['y']) < 60]
        if not dels:
            check('delete button for ' + f['name'], False, [m['desc'] for m in ns if m['desc']])
            continue
        d.tap(dels[0]['x'], dels[0]['y'], 3)
        d.shot('s3-34-delete-confirm-' + f['extension'])
        d.tap_label('刪除', exact=True, wait=4)
    s = after_change('s3-35-after-delete')
    check('deleted font falls back to the book font', 'BookmaniaUserFont' not in (s['p']['fontFamily'] or ''), s['p']['fontFamily'])
    files = d.shell(f'run-as {d.PKG} ls files/ebook-fonts')
    check('font files deleted', '.ttf' not in files and '.otf' not in files, files)
    check('font list empty', json.loads(d.ebook_prefs().get('__APP_STATE_ebook_fonts') or '[]') == [], d.ebook_prefs().get('__APP_STATE_ebook_fonts'))
    d.close_panel()


def step_clear_fonts():
    """Removes imported fonts and the list (app stopped), so step_fonts can run again."""
    d.shell(f'am force-stop {d.PKG}')
    time.sleep(1)
    root = ET.fromstring(d.prefs())
    for e in list(root):
        if e.get('name', '') in ('__APP_STATE_ebook_fonts', 'pref_ebook_font'):
            root.remove(e)
    data = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n" + ET.tostring(root, encoding='unicode')
    tmp = os.path.join(d.OUT, 'prefs-clean.xml')
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(data)
    d.adb('push', tmp, '/data/local/tmp/p.xml')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/p.xml shared_prefs/{d.PKG}_preferences.xml')
    d.shell(f'run-as {d.PKG} rm -rf files/ebook-fonts')
    check('imported fonts cleared', '__APP_STATE_ebook_fonts' not in d.ebook_prefs(), sorted(d.ebook_prefs()))


FONT_TEST_ID = '0123456789abcdef0123456789abcd99'
FONT_FILE = os.environ.get('FONT_FILE', '')  # a large CJK OTF on this machine, e.g. Noto Serif CJK TC


def set_test_font(selected):
    """Installs FONT_FILE as an imported font straight into app storage (no picker) and selects it."""
    d.shell(f'am force-stop {d.PKG}')
    time.sleep(1)
    root = ET.fromstring(d.prefs())
    for e in list(root):
        n = e.get('name', '')
        if n.startswith('pref_ebook_override_') or n in ('__APP_STATE_ebook_fonts', 'pref_ebook_font'):
            root.remove(e)
    lst = ET.SubElement(root, 'string', name='__APP_STATE_ebook_fonts')
    lst.text = json.dumps([{'id': FONT_TEST_ID, 'name': 'Test CJK font', 'extension': 'otf', 'vertical': True}])
    if selected:
        ET.SubElement(root, 'string', name='pref_ebook_font').text = FONT_TEST_ID
    tmp = os.path.join(d.OUT, 'prefs-font.xml')
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n" + ET.tostring(root, encoding='unicode'))
    d.adb('push', tmp, '/data/local/tmp/p.xml')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/p.xml shared_prefs/{d.PKG}_preferences.xml')
    if FONT_FILE and 'otf' not in d.shell(f'run-as {d.PKG} ls files/ebook-fonts'):
        d.adb('push', FONT_FILE, '/data/local/tmp/font.otf', timeout=300)
        d.shell(f'run-as {d.PKG} mkdir -p files/ebook-fonts')
        d.shell(f'run-as {d.PKG} cp /data/local/tmp/font.otf files/ebook-fonts/{FONT_TEST_ID}.otf')


def next_chapter_ms():
    """Goes to the last page and turns the page (vertical book: left tap), returns the new document's layout time."""
    before = d.style()
    d.cdp('window.__reader.goPage(100000); "ok"')
    time.sleep(2)
    for attempt in range(4):  # a tap can be lost on the slow emulator; the page only changes once
        d.tap(180, 960, 3)
        t = time.time()
        while time.time() - t < (300 if attempt == 3 else 30):
            s = d.style()
            if s and s['src'] != before['src'] and s['st']['ready']:
                return s
            st = d.status()
            if st and st['seq'] != before['st']['seq'] and not st['ready']:
                t = time.time()  # a new document is being laid out: keep waiting
            time.sleep(2)
    raise RuntimeError('next chapter did not open')


def step_font_speed():
    """Chapter files after the first reuse the imported font loaded once by the shell."""
    set_test_font(selected=True)
    st = d.open_book(*VERT)
    s1 = d.style()
    check('first chapter file with the imported font', 'BookmaniaUserFont:loaded' in s1['faces'], {'ms': st['ms'], 'faces': s1['faces']})
    s2 = next_chapter_ms()
    check('next chapter file uses the shared font', 'BookmaniaUserFont:loaded' in s2['faces'] and 'BookmaniaUserFont' in s2['p']['fontFamily'],
          {'src': s2['src'], 'ms': s2['st']['ms'], 'faces': s2['faces']})
    d.shot('s3-50-shared-font-next-chapter')
    s3 = next_chapter_ms()
    check('third chapter file too', 'BookmaniaUserFont:loaded' in s3['faces'], {'src': s3['src'], 'ms': s3['st']['ms']})
    # Same documents without the imported font, for comparison.
    set_test_font(selected=False)
    st0 = d.open_book(*VERT)
    t2 = next_chapter_ms()
    t3 = next_chapter_ms()
    check('timing without the imported font (comparison)', True,
          {'first': st0['ms'], 'second': t2['st']['ms'], 'third': t3['st']['ms']})


def step_side_panel():
    """Landscape: the panel is a full-height side panel, on the left for vertical books, right for horizontal."""
    d.shell('settings put system accelerometer_rotation 0')
    try:
        for book, side, name in ((VERT, 'left', 's3-51-side-panel-vertical'), (HORZ, 'right', 's3-52-side-panel-horizontal')):
            d.open_book(*book)
            d.shell('settings put system user_rotation 1')
            time.sleep(15)
            d.wait_ready(settle=4.0)  # the native side also has to see the relayout finish before taps count
            d.open_panel()
            ns = d.nodes()
            d.shot(name)
            close = d.close_button(ns)
            tabs = d.find('文字', ns, exact=True)
            ok = bool(close and tabs) and ((close['x'] < 960) if side == 'left' else (tabs['x'] > 960))
            check(f'landscape: side panel on the {side}', ok, {'close': close and close['b'], 'tab': tabs and tabs['b']})
            # A setting still applies from the side panel (a control visible without scrolling).
            d.tap_label('系統襯線', exact=True, wait=3)
            s = after_change(name + '-serif')
            check(f'landscape ({side}): font changed from the side panel', s['p']['fontFamily'] == 'serif', s['p']['fontFamily'])
            d.tap_label('書籍指定', exact=True, wait=3)
            after_change(name + '-book-font')
            # A tap on the page outside the panel closes it.
            d.tap(1700 if side == 'left' else 200, 540, 4)
            check(f'landscape ({side}): tap on the page closes the panel', d.close_button() is None)
            d.shell('settings put system user_rotation 0')
            time.sleep(10)
    finally:
        d.shell('settings put system user_rotation 0')


def step_toolbar():
    """The toolbar with title and subtitle under the status bar, and the page number above the navigation bar."""
    d.open_book(*VERT)
    d.tap(540, 960, 4)
    ns = d.nodes()
    d.shot('s3-40-toolbar')
    title = d.find('直排測試書', ns, exact=True)
    sub = d.find('直排測試書 EPUB', ns, exact=True)
    bar = next((n for n in ns if n['res'].endswith('/toolbar')), None)
    check('subtitle inside the toolbar', bool(title and sub and bar and sub['b'][3] <= bar['b'][3]),
          [title and title['b'], sub and sub['b'], bar and bar['b']])
    # Since stage 5 the page number ("1/3 · 1/35") is in the progress bar at the bottom, not a view with the
    # id page_info (stage 6): it is found by its text.
    info = next((n for n in ns if re.match(r'^\d+/\d+ · \d+(?:–\d+)?/\d+$', n['text'])), None)
    check('page number above the navigation bar (y < 1794)', bool(info and info['b'][3] <= 1794),
          info and {'text': info['text'], 'bounds': info['b']})
    d.tap(540, 960, 3)


def step_rotate():
    """Landscape with the panel open: the panel still fits and the page re-lays out."""
    d.open_book(*VERT)
    d.open_panel()
    d.shell('settings put system accelerometer_rotation 0')
    d.shell('settings put system user_rotation 1')
    time.sleep(12)
    st = d.wait_ready()
    ns = d.nodes()
    d.shot('s3-41-landscape-panel')
    check('landscape: panel shown (close button found)', d.close_button(ns) is not None)
    check('landscape: page laid out again', st['ready'] and st['error'] is None, st)
    d.shell('settings put system user_rotation 0')
    time.sleep(12)
    d.wait_ready()
    d.close_panel()


if __name__ == '__main__':
    STEP = ''
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        STEP = args[i]
        fn = globals().get('step_' + STEP)
        if fn is None:
            raise SystemExit('unknown step ' + STEP)
        if STEP == 'vol2':
            fn(int(args[i + 1]), int(args[i + 2]))
            i += 3
        else:
            fn()
            i += 1
