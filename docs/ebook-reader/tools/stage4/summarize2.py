"""Checks a run of probe2.js lines: for every document, the visible text of all spreads (frames in
reading order) joined together must equal the document's full text, every spread must have been
seen, and the frames must sit on the expected sides. Usage: summarize2.py run.jsonl [expect_first=right|left]"""
import json, re, sys

FW = '０１２３４５６７８９'
path = sys.argv[1]
expect_first = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] in ('right', 'left') else None
rows = []
for line in open(path, encoding='utf-8'):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(json.loads(line)))
    except Exception:
        pass
docs, order, side_errors, cols_seen = {}, [], [], set()
for r in rows:
    if r.get('none'):
        continue
    st = r['st']
    cols_seen.add(st.get('cols', 1))
    d = docs.setdefault(r['src'], {'all': r['all'], 'spreads': {}, 'pages': st['pages'], 'cols': st.get('cols', 1)})
    if r['src'] not in order:
        order.append(r['src'])
    d['spreads'].setdefault(st['page'], r['vis'])
    fr = [f for f in r['frames'] if not f['hidden']]
    if expect_first and len(r['frames']) == 2:
        first_right = r['frames'][0]['left'] > r['frames'][1]['left']
        if first_right != (expect_first == 'right'):
            side_errors.append((r['src'], st['page']))
ok = True
text = ''
for src in order:
    d = docs[src]
    starts = list(range(0, d['pages'], d['cols']))
    seen = [k for k in sorted(d['spreads'])]
    missing = [k for k in starts if k not in d['spreads']]
    joined = ''.join(d['spreads'][k] for k in seen)
    same = joined == d['all']
    text += d['all']
    if not same or missing:
        ok = False
    detail = ''
    if not same:
        i = next((k for k in range(min(len(joined), len(d['all']))) if joined[k] != d['all'][k]), min(len(joined), len(d['all'])))
        detail = f' first difference at {i}: visible={joined[i:i+12]!r} expected={d["all"][i:i+12]!r} (lengths {len(joined)} vs {len(d["all"])})'
    print(f'  {src}: cols {d["cols"]}, pages {d["pages"]}, spreads seen {len(seen)}/{len(starts)}, chars {len(d["all"])}, visible==all: {same}{detail}'
          + (f', missing spreads {missing}' if missing else ''))
nums = [int(''.join(str(FW.index(c)) if c in FW else c for c in m)) for m in re.findall(r'【第([０-９0-9]+)段】', text)]
expect = list(range(1, max(nums) + 1)) if nums else []
print(f'{path.split("/")[-1]}: documents {len(order)}, columns {sorted(cols_seen)}, paragraphs {len(nums)} in order: {nums == expect}, '
      f'all spreads complete: {ok}, first page on the expected side: {not side_errors if expect_first else "not checked"}'
      + (f' (wrong at {side_errors[:5]})' if side_errors else ''))
