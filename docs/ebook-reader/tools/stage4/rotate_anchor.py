"""Rotation with "two columns: landscape only": portrait shows one column, landscape a two-column
spread, and the character the page started with stays on screen across both rotations.

Usage: python3 rotate_anchor.py <manga id> <chapter id> <page to start from> <label>
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

FIRST = """(function () {
  var f = document.querySelector('#stage iframe'), dd = f.contentDocument;
  var tw = dd.createTreeWalker(dd.body, NodeFilter.SHOW_TEXT), r = dd.createRange(), i = 0;
  for (var n = tw.nextNode(); n; n = tw.nextNode(), i++) for (var j = 0; j < n.data.length; j++) {
    if (/\\s/.test(n.data.charAt(j))) continue;
    r.setStart(n, j); r.setEnd(n, j + 1); var rc = r.getClientRects()[0];
    if (rc && rc.left >= -0.5 && rc.top >= -0.5 && rc.right <= f.clientWidth + 0.5 && rc.bottom <= f.clientHeight + 0.5)
      return JSON.stringify([i, j, n.data.substr(j, 8)]);
  }
  return 'null';
})()"""

VISIBLE = """(function (ni, off) {
  var frames = document.querySelectorAll('#stage iframe'), res = [];
  Array.prototype.forEach.call(frames, function (f) {
    if (f.style.visibility === 'hidden') { res.push(false); return; }
    var dd = f.contentDocument, tw = dd.createTreeWalker(dd.body, NodeFilter.SHOW_TEXT), i = 0, hit = false;
    for (var n = tw.nextNode(); n; n = tw.nextNode(), i++) if (i === ni) {
      var r = dd.createRange(); r.setStart(n, off); r.setEnd(n, off + 1); var rc = r.getClientRects()[0];
      hit = !!rc && rc.left >= -0.5 && rc.top >= -0.5 && rc.right <= f.clientWidth + 0.5 && rc.bottom <= f.clientHeight + 0.5;
      break;
    }
    res.push(hit);
  });
  return JSON.stringify(res);
})(%d, %d)"""


def result(name, ok, detail, step='rotate'):
    line = {'step': step, 'check': name, 'ok': bool(ok), 'detail': detail}
    with open(os.path.join(OUT, 'results.jsonl'), 'a', encoding='utf-8') as f:
        f.write(json.dumps(line, ensure_ascii=False) + '\n')
    print('PASS' if ok else 'FAIL', name, json.dumps(detail, ensure_ascii=False))


def wait_relayout(seq_before):
    for _ in range(90):
        st = d.status()
        if st and st['seq'] != seq_before and st['ready']:
            return st
        time.sleep(2)
    return d.status()


def main():
    manga, chapter, page, label = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    write_prefs({'columns': 'landscape'})
    d.shell('settings put system accelerometer_rotation 0')
    d.shell('settings put system user_rotation 0')
    time.sleep(3)
    st = d.open_book(manga, chapter)
    clear_dialogs()
    result('portrait: one column', st.get('cols') == 1, st)
    d.cdp('window.__reader.goPage(%d); "ok"' % page)
    time.sleep(2)
    anchor = json.loads(d.cdp(FIRST))
    st0 = d.status()
    print('anchor', anchor, st0)
    d.shot(label + '-portrait')
    d.shell('settings put system user_rotation 1')
    st1 = wait_relayout(st0['seq'])
    clear_dialogs()
    time.sleep(3)
    vis1 = json.loads(d.cdp(VISIBLE % (anchor[0], anchor[1])))
    d.shot(label + '-landscape')
    result('landscape: two columns', st1.get('cols') == 2, st1)
    result('landscape: the anchor character is on the spread', any(vis1), {'anchor': anchor, 'visible in frames': vis1, 'page': st1['page']})
    d.shell('settings put system user_rotation 0')
    st2 = wait_relayout(st1['seq'])
    clear_dialogs()
    time.sleep(3)
    vis2 = json.loads(d.cdp(VISIBLE % (anchor[0], anchor[1])))
    d.shot(label + '-portrait-again')
    result('portrait again: one column', st2.get('cols') == 1, st2)
    result('portrait again: the anchor character is on the page', any(vis2), {'anchor': anchor, 'visible': vis2, 'page': st2['page']})


if __name__ == '__main__':
    main()
