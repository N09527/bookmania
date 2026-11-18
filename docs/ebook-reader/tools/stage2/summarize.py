import json, re, sys
FW = '０１２３４５６７８９'
for path in sys.argv[1:]:
    rows = []
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if not line: continue
        try: rows.append(json.loads(json.loads(line)))
        except Exception: pass
    docs, order = {}, []
    for r in rows:
        if r.get('none'): continue
        key = (r['src'], r['st']['page'])
        d = docs.setdefault(r['src'], {'all': r['all'], 'pages': {}, 'count': r['st']['pages']})
        if r['src'] not in order: order.append(r['src'])
        d['pages'].setdefault(r['st']['page'], r['vis'])
    ok = True; total_pages = 0; text = ''
    for src in order:
        d = docs[src]
        pages = [d['pages'][k] for k in sorted(d['pages'])]
        missing = [k for k in range(d['count']) if k not in d['pages']]
        joined = ''.join(pages)
        same = joined == d['all']
        total_pages += len(pages)
        text += d['all']
        if not same or missing: ok = False
        detail = ''
        if not same:
            i = next((k for k in range(min(len(joined), len(d['all']))) if joined[k] != d['all'][k]), min(len(joined), len(d['all'])))
            detail = f' first difference at {i}: visible={joined[i:i+12]!r} expected={d["all"][i:i+12]!r} (lengths {len(joined)} vs {len(d["all"])})'
        print(f'  {src}: pages seen {len(pages)}/{d["count"]}, chars {len(d["all"])}, visible==all: {same}{detail}' + (f', missing pages {missing}' if missing else ''))
    nums = [int(''.join(str(FW.index(c)) if c in FW else c for c in m)) for m in re.findall(r'【第([０-９0-9]+)段】', text)]
    expect = list(range(1, max(nums) + 1)) if nums else []
    print(f'{path.split("/")[-1]}: documents {len(order)}, pages {total_pages}, paragraphs {len(nums)} in order: {nums == expect}, all pages complete: {ok}')
