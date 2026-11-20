"""Links in a two-column spread: taps on links in either frame. Opens the vertical EPUB with two
columns, goes to the spread that shows the link paragraph of chapter 1, taps the external link
(the confirmation dialog must appear; it is cancelled) and the cross-chapter link (chapter 2 must open).
Usage: python3 links2.py <manga id> <chapter id> <label>
"""
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

FIND = """(function (needle) {
  var frames = document.querySelectorAll('#stage iframe'), dpr = window.devicePixelRatio;
  for (var k = 0; k < frames.length; k++) {
    var f = frames[k];
    if (f.style.visibility === 'hidden') continue;
    var fr = f.getBoundingClientRect(), links = f.contentDocument.querySelectorAll('a[href]');
    for (var i = 0; i < links.length; i++) {
      if (links[i].getAttribute('href').indexOf(needle) < 0) continue;
      var r = links[i].getClientRects()[0];
      if (r && r.right > 0 && r.left < f.clientWidth && r.bottom > 0 && r.top < f.clientHeight)
        return JSON.stringify({ frame: k, x: Math.round((fr.left + r.left + r.width / 2) * dpr), y: Math.round((fr.top + r.top + r.height / 2) * dpr) });
    }
  }
  return 'null';
})(%s)"""


def main():
    manga, chapter, label = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    write_prefs({'columns': 'on'})
    d.shell('settings put system user_rotation 0')
    d.open_book(manga, chapter)
    for _ in range(30):  # input focus can lag behind start-up on a slow emulator
        if 'EbookReaderActivity' in d.shell('dumpsys window windows | grep mCurrentFocus'):
            break
        clear_dialogs()
        time.sleep(2)
    time.sleep(5)
    st = d.status()
    # find the spread that shows the external link
    found = None
    for page in range(0, st['pages'], 2):
        d.cdp('window.__reader.goPage(%d); "ok"' % page)
        time.sleep(1)
        v = d.cdp(FIND % json.dumps('example.com'))
        found = json.loads(v) if isinstance(v, str) and v != 'null' else None
        if found:
            break
    result('external link found on a spread', bool(found), found, step='links')
    if not found:
        return
    dialog = None
    for _ in range(3):  # retry a lost tap
        d.tap(found['x'], found['y'], 6)
        ns = d.nodes()
        dialog = d.find('要用瀏覽器開啟這個連結嗎？', ns, exact=True)
        if dialog:
            break
    d.shot(label + '-external-link-dialog')
    result('tap on the external link (frame %d) asks before opening' % found['frame'], dialog is not None, found, step='links')
    if dialog:
        d.tap_label('取消', exact=True, wait=3)
    v = d.cdp(FIND % json.dumps('ch02'))
    cross = json.loads(v) if isinstance(v, str) and v != 'null' else None
    if cross:
        s = None
        for attempt in range(3):
            d.tap(cross['x'], cross['y'], 6)
            for _ in range(20):
                s = d.cdp('JSON.stringify([document.querySelector("#stage iframe").src.replace(/^.*\\/book\\//, ""), window.__reader.status()])')
                s = json.loads(s) if isinstance(s, str) else None
                if s and 'ch02' in s[0] and s[1]['ready']:
                    break
                time.sleep(2)
            if s and 'ch02' in s[0]:
                break
        result('tap on the cross-chapter link (frame %d) opens chapter 2' % cross['frame'], bool(s and 'ch02' in s[0]), s, step='links')
        d.shot(label + '-cross-chapter')


if __name__ == '__main__':
    main()
