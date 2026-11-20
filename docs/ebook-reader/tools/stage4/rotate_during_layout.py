"""Rotation while the reader is busy, with "two columns: landscape only".

A: start a relayout in portrait (through DevTools, with a new font size, as a settings change would) and
   rotate to landscape while it runs; the page logs whether the resize event came during that layout. When the reader is
   ready, the layout must be the landscape one: two columns, frames inside the landscape window.
B: with the menu shown (page indicator visible), rotate portrait -> landscape -> portrait; after each
   relayout the indicator must show the new page count (and both pages of the spread in landscape).

Usage: python3 rotate_during_layout.py <manga id> <chapter id> <label>
"""
import json
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

PAGE_INFO = re.compile(r'^\d+/\d+ · ')

GEOMETRY = """(function () {
  var fr = Array.prototype.map.call(document.querySelectorAll('#stage iframe'), function (f) {
    var r = f.getBoundingClientRect();
    return { left: Math.round(r.left), right: Math.round(r.right), width: Math.round(r.width), hidden: f.style.visibility === 'hidden' };
  });
  return JSON.stringify({ w: window.innerWidth, h: window.innerHeight, frames: fr, st: window.__reader ? window.__reader.status() : null });
})()"""

HOOK = """(function (settings, delayMs) {
  // Logs orientation and resize events with the reader's state; on the first orientation event while
  // the viewport is still portrait (or, if delayMs >= 0, that many ms after this call) it starts a
  // relayout, so that the resize which follows lands in a running layout.
  var log = window.__rotLog = [], started = false;
  function note(type) {
    var st = window.__reader.status();
    log.push({ type: type, t: Date.now(), ready: st.ready, seq: st.seq, w: window.innerWidth, h: window.innerHeight });
  }
  function start(why) {
    if (started) return;
    started = true;
    var ok = window.__reader.relayout(settings);
    note('relayout ' + why + ' ' + ok);
  }
  window.addEventListener('orientationchange', function () {
    note('orientationchange');
    if (delayMs < 0 && window.innerWidth < window.innerHeight) start('on orientationchange');
  });
  window.addEventListener('resize', function () { note('resize'); });
  if (delayMs >= 0) setTimeout(function () { start('after ' + delayMs + ' ms'); }, delayMs);
  note('hook');
  return JSON.stringify(log);
})(%s, %d)"""


def settings(font_size, columns='landscape'):
    """The settings object the app sends (EbookReaderActivity.settingsJson): defaults except these."""
    return {'vertical': True, 'font': None, 'fontSize': font_size, 'lineHeight': 1.8, 'letterSpacing': 0,
            'indent': None, 'paragraphSpacing': None, 'margins': {'top': 32, 'bottom': 32, 'left': 20, 'right': 20},
            'background': '#FAFAFA', 'textColor': '#000000', 'dark': False, 'rtl': True, 'columns': columns}


def check(name, ok, detail):
    result(name, ok, detail, step='rotate-busy')


def geometry():
    v = d.cdp(GEOMETRY)
    return json.loads(v) if isinstance(v, str) else None


def page_info():
    n = next((m for m in d.nodes() if PAGE_INFO.match(m['text'])), None)
    return n['text'] if n else None


def show_menu():
    """Centre tap shows the toolbar and the page indicator; a tap can be lost on this emulator, and a
    second tap on a shown menu would hide it again, so each tap is followed by a few looks."""
    ns = d.nodes()
    w = max((m['b'][2] for m in ns), default=1080)
    h = max((m['b'][3] for m in ns), default=1920)
    for _ in range(3):
        t = page_info()
        if t:
            return t
        d.tap(w // 2, h // 2, 2)
        for _ in range(3):
            t = page_info()
            if t:
                return t
            time.sleep(2)
    return None


def wait_new_layout(seq_before, tries=90):
    st = None
    for _ in range(tries):
        st = d.status()
        if st and st['ready'] and st['seq'] != seq_before:
            return st
        time.sleep(2)
    return st


def wait_stable(tries=60):
    """Ready, and the layout counter no longer moves (a catch-up relayout may follow the first one)."""
    last = None
    for _ in range(tries):
        st = d.status()
        if st and st['ready'] and last is not None and st['seq'] == last['seq']:
            return st
        last = st
        time.sleep(3)
    return last


def precondition(log):
    """A relayout started with the portrait viewport, and a resize to landscape came while it ran."""
    rel = next((i for i, e in enumerate(log or []) if e['type'].startswith('relayout') and e['type'].endswith('true')), None)
    if rel is None or log[rel]['w'] >= log[rel]['h']:
        return False
    return any(e['type'] == 'resize' and e['ready'] is False and e['w'] > e['h'] for e in log[rel + 1:])


def wait_landscape():
    for _ in range(40):
        g = geometry()
        if g and g['w'] > g['h']:
            return g
        time.sleep(2)
    return geometry()


def part_a(manga, chapter, label):
    write_prefs({'columns': 'landscape'})
    d.shell('settings put system accelerometer_rotation 0')
    d.shell('settings put system user_rotation 0')
    time.sleep(8)
    st0 = d.open_book(manga, chapter)
    clear_dialogs()
    time.sleep(3)
    # On this emulator the orientation event comes about 3 s after the rotation command, the viewport
    # width changes about 1 s later and the resize event about 5 s after that. A relayout started on the
    # orientation event (portrait geometry) that also switches to two columns (a second frame to load and
    # lay out) runs long enough to still be busy when the resize event comes. A few attempts, because the
    # timing varies; the page log tells whether an attempt met the condition.
    size = 24
    for attempt in range(4):
        size = 26 if size == 24 else 24
        d.cdp(HOOK % (json.dumps(settings(size, 'on')), -1))
        d.shell('settings put system user_rotation 1')
        wait_landscape()
        st = wait_stable()
        v = d.cdp('JSON.stringify(window.__rotLog || null)')
        log = json.loads(v) if isinstance(v, str) else None
        print('attempt', attempt, 'log', log, flush=True)
        if precondition(log):
            g1 = geometry()
            clear_dialogs()
            d.shot(label + '-a-landscape-after-busy-rotation')
            check('A: a relayout started in portrait and the resize to landscape came while it ran', True,
                  {'portrait': st0, 'events': log, 'attempt': attempt})
            # Landscape geometry: two frames that together span the landscape window (portrait geometry
            # would leave them in the left 400 px).
            spans = bool(g1) and max(f['right'] for f in g1['frames']) >= g1['w'] - 40
            check('A: once ready, the landscape layout (two columns spanning the landscape window)',
                  bool(g1) and g1['w'] > g1['h'] and st.get('cols') == 2 and len(g1['frames']) == 2 and spans,
                  {'status': st, 'geometry': g1})
            return
        d.shell('settings put system user_rotation 0')  # back to portrait for the next attempt
        time.sleep(8)
        wait_stable()
    check('A: a relayout started in portrait and the resize to landscape came while it ran', False,
          {'portrait': st0, 'last events': log, 'note': 'condition not met in 4 attempts; nothing to judge'})


def part_b(manga, chapter, label):
    write_prefs({'columns': 'landscape'})
    d.shell('settings put system user_rotation 0')
    time.sleep(8)  # part A ends in landscape; the rotation back takes a few seconds on this emulator
    st0 = d.open_book(manga, chapter)
    clear_dialogs()
    time.sleep(3)
    info0 = show_menu()
    check('B: menu shown in portrait, indicator for one column', info0 is not None and f'· 1/{st0["pages"]}' in info0, [info0, st0])
    d.shell('settings put system user_rotation 1')
    st1 = wait_new_layout(st0['seq'])
    time.sleep(4)
    info1 = page_info()
    d.shot(label + '-b-landscape-menu')
    check('B: after rotating to landscape the indicator shows the spread of the new layout',
          info1 is not None and st1.get('cols') == 2 and f'· 1–2/{st1["pages"]}' in info1, [info1, st1])
    d.shell('settings put system user_rotation 0')
    st2 = wait_new_layout(st1['seq'])
    time.sleep(4)
    info2 = page_info()
    d.shot(label + '-b-portrait-menu')
    check('B: after rotating back the indicator shows one page of the new count',
          info2 is not None and st2.get('cols') == 1 and f'· {st2["page"] + 1}/{st2["pages"]}' in info2, [info2, st2])


def main():
    manga, chapter, label = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    parts = sys.argv[4] if len(sys.argv) > 4 else 'ab'
    if 'a' in parts:
        part_a(manga, chapter, label)
    if 'b' in parts:
        part_b(manga, chapter, label)
    d.shell('settings put system user_rotation 0')


if __name__ == '__main__':
    main()
