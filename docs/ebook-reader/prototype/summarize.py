import json, sys
r = json.load(open(sys.argv[1]))
print('browser', r['browser'], 'flags', r['flags'])
for c in r['cases']:
    w = c['walk']
    print(f"{c['name']:18s} wrap={c['supportsColumnWrap']!s:5s} frames={c['frames']} chars={c['totalChars']} cols={c['layoutColumns']}/{c['columnCountFromScroll']} spreads={c['spreads']} mono={c['monotonicViolations']} straddle={c['straddles']} clip={c['inlineOverflow']} overhang={c['overhang']} | walk: seen={w['visibleCharsCounted']} missing={w['missing']} dup={w['duplicated']} order={w['outOfOrder']} partial={w['partiallyVisible']} | t={ {k: round(v) for k, v in c['timings'].items()} }")
    print('     spread0-2:', c['firstSpreads'], '| hit:', c.get('footnoteLinkHit'), '| script msgs:', c['bookScriptMessages'], '| ext:', c['externalRequests'], '| titles:', [f['title'] for f in c['frameInfo']], '| font:', [f['importedFontLoaded'] for f in c['frameInfo']], '| wm:', [f['writingMode'] for f in c['frameInfo']])
for l in r['location']:
    print(l['name'], 'loc', l['locationCharIndex'], [(s['change'], s['spread'], s['locVisible'], s['relayoutMs']) for s in l['steps']])
