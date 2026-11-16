'use strict';
// Prototype reader shell. Modes:
//   A = vertical-rl, CSS multicol with column-wrap (columns wrap leftwards, side by side)
//   B = vertical-rl, one iframe per visible column; each iframe paginates on the y axis
//       (classic vertical pagination); right frame shows page 2k, left frame page 2k+1
//   H = horizontal-tb, classic CSS multicol pagination (columns side by side, rightwards)
(() => {
  const stage = document.getElementById('stage');
  const S = { frames: [], mode: null, geo: null, settings: null, spread: 0, src: null, timings: {}, columnCount: null };

  const setImp = (el, props) => { for (const [k, v] of Object.entries(props)) el.style.setProperty(k, v, 'important'); };
  const place = (f, left, top, w, h) => Object.assign(f.style, { left: left + 'px', top: top + 'px', width: w + 'px', height: h + 'px' });

  function loadFrame(src) {
    return new Promise((resolve, reject) => {
      const f = document.createElement('iframe');
      // No allow-scripts: scripts inside the book can never run. allow-same-origin lets the
      // shell (same origin) read and style the book DOM from the outside.
      f.setAttribute('sandbox', 'allow-same-origin');
      f.addEventListener('load', () => resolve(f), { once: true });
      f.addEventListener('error', reject, { once: true });
      f.src = src;
      stage.appendChild(f);
    });
  }

  function geometry(s) {
    const W = innerWidth, H = innerHeight, m = s.margins;
    const contentW = W - m.left - m.right, contentH = H - m.top - m.bottom;
    const cols = s.columns;
    const colW = cols === 2 ? Math.floor((contentW - s.gap) / 2) : contentW;
    const G = cols === 2 ? contentW - 2 * colW : s.gap; // absorb rounding into the gap
    // P = overflow allowance around every column (ruby, glyph overhang); keep P < G/2 and P < pageGap/2.
    return { W, H, m, contentW, contentH, cols, colW, G, P: 8, pageGap: 24, colBlock: s.vertical ? colW : contentH };
  }

  function typography(doc, s, geo) {
    let st = doc.getElementById('__reader_typo');
    if (!st) { st = doc.createElement('style'); st.id = '__reader_typo'; (doc.head || doc.documentElement).appendChild(st); }
    const wm = s.vertical ? 'vertical-rl' : 'horizontal-tb';
    st.textContent = `
@font-face { font-family: "ReaderImported"; src: url("/fonts/imported-noto-serif-tc.otf") format("opentype"); }
html { font-size: ${s.fontSize}px !important; }
html, body { writing-mode: ${wm} !important; -epub-writing-mode: ${wm} !important; }
body { margin: 0 !important; padding: 0 !important; font-family: ${s.fontFamily} !important;
       line-height: ${s.lineHeight} !important; letter-spacing: ${s.letterSpacing}em !important; }
p { text-indent: ${s.indent}em !important; margin: 0 !important; ${s.vertical ? 'margin-left' : 'margin-bottom'}: ${s.paraSpacing}em !important; }
img, svg, video { ${s.vertical ? 'max-height' : 'max-width'}: 100% !important; ${s.vertical ? 'max-width' : 'max-height'}: ${geo.colBlock}px !important;
       object-fit: contain; break-inside: avoid; box-sizing: border-box; }
`;
  }

  function layout() {
    const g = S.geo = geometry(S.settings), P = g.P;
    const base = { margin: '0', padding: P + 'px', 'box-sizing': 'border-box', overflow: 'hidden', 'column-fill': 'auto' };
    for (const f of S.frames) { const pd = f.contentDocument.getElementById('__reader_pad'); if (pd) pd.parentNode.removeChild(pd); }
    if (S.mode === 'A') {
      const f = S.frames[0];
      place(f, g.m.left - P, g.m.top - P, g.contentW + 2 * P, g.contentH + 2 * P);
      setImp(f.contentDocument.documentElement, Object.assign({}, base, { 'writing-mode': 'vertical-rl', height: g.contentH + 2 * P + 'px', width: 'auto',
        'column-count': '1', 'column-wrap': 'wrap', 'column-height': g.colW + 'px', 'row-gap': g.G + 'px' }));
    } else if (S.mode === 'B') {
      const [r, l] = S.frames; // r = right (read first), l = left
      place(r, g.m.left + g.contentW - g.colW - P, g.m.top - P, g.colW + 2 * P, g.contentH + 2 * P);
      if (l) place(l, g.m.left - P, g.m.top - P, g.colW + 2 * P, g.contentH + 2 * P);
      for (const f of S.frames) setImp(f.contentDocument.documentElement, Object.assign({}, base, { 'writing-mode': 'vertical-rl',
        width: g.colW + 2 * P + 'px', height: g.contentH + 2 * P + 'px', 'column-width': g.contentH + 'px', 'column-gap': g.pageGap + 'px' }));
    } else {
      const f = S.frames[0];
      place(f, g.m.left - P, g.m.top - P, g.contentW + 2 * P, g.contentH + 2 * P);
      setImp(f.contentDocument.documentElement, Object.assign({}, base, { 'writing-mode': 'horizontal-tb', height: g.contentH + 2 * P + 'px', width: 'auto',
        'column-width': g.colW + 'px', 'column-gap': g.G + 'px' }));
    }
    for (const f of S.frames) typography(f.contentDocument, S.settings, g);
    // Shell-side decoration: a faint rule in the middle of the gutter (not part of the book).
    { const gu = stage.querySelector('.gutter'); if (gu) gu.parentNode.removeChild(gu); }
    if (g.cols === 2) {
      const r = document.createElement('div'); r.className = 'gutter';
      Object.assign(r.style, { position: 'absolute', left: (g.m.left + g.colW + g.G / 2 - 0.5) + 'px', top: (g.m.top + 12) + 'px',
        width: '1px', height: (g.contentH - 24) + 'px', background: 'rgba(0,0,0,.12)', pointerEvents: 'none' });
      stage.appendChild(r);
    }
  }

  // Number of layout columns (pages), from the scroll extent of the first frame.
  function countColumns() {
    const g = S.geo, el = S.frames[0].contentDocument.scrollingElement;
    if (S.mode === 'B') return Math.max(1, Math.round((el.scrollHeight - 2 * g.P + g.pageGap) / (g.contentH + g.pageGap)));
    return Math.max(1, Math.round((el.scrollWidth - 2 * g.P + g.G) / (g.colW + g.G)));
  }

  // Make the last spread complete so that scrolling to it is never clamped by the browser.
  function finishLayout() {
    let n = countColumns();
    if ((S.mode === 'A' || S.mode === 'H') && n % S.geo.cols) {
      const d = S.frames[0].contentDocument, pad = d.createElement('div');
      pad.id = '__reader_pad';
      pad.setAttribute('style', 'break-before: column !important; block-size: 1px; inline-size: 1px;');
      d.body.appendChild(pad);
      n = countColumns();
    }
    S.columnCount = n;
    return n;
  }

  async function settle() {
    await Promise.all(S.frames.map(f => f.contentDocument.fonts.ready));
    for (const f of S.frames) f.contentDocument.documentElement.getBoundingClientRect(); // force layout
    return finishLayout();
  }

  async function open({ src, mode, settings }) {
    const t0 = performance.now();
    while (stage.firstChild) stage.removeChild(stage.firstChild); S.frames = [];
    S.mode = mode; S.settings = settings; S.src = src;
    const n = mode === 'B' && settings.columns === 2 ? 2 : 1;
    for (let i = 0; i < n; i++) S.frames.push(await loadFrame(src));
    const t1 = performance.now();
    layout();
    await settle();
    const t2 = performance.now();
    S.timings = { loadMs: t1 - t0, layoutMs: t2 - t1 };
    goSpread(0);
    return { supportsColumnWrap: CSS.supports('column-wrap', 'wrap'), frames: n, geo: S.geo, timings: S.timings, columnCount: S.columnCount };
  }

  async function relayout(settings) {
    const t0 = performance.now();
    S.settings = settings; layout();
    await settle();
    return { relayoutMs: performance.now() - t0, geo: S.geo, columnCount: S.columnCount };
  }

  function scrollFrame(f, x, y) { f.contentWindow.scrollTo(x, y); }

  function goSpread(k) {
    S.spread = k; const g = S.geo;
    if (S.mode === 'A') scrollFrame(S.frames[0], -k * g.cols * (g.colW + g.G), 0);
    else if (S.mode === 'B') {
      const step = g.contentH + g.pageGap;
      scrollFrame(S.frames[0], 0, k * g.cols * step);
      if (S.frames[1]) {
        const page = k * g.cols + 1, exists = page < (S.columnCount == null ? Infinity : S.columnCount);
        S.frames[1].style.visibility = exists ? 'visible' : 'hidden';
        if (exists) scrollFrame(S.frames[1], 0, page * step);
      }
    } else scrollFrame(S.frames[0], k * g.cols * (g.colW + g.G), 0);
  }

  // Every non-space character in document order with its first client rect.
  function chars(doc) {
    const out = []; const w = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT); const range = doc.createRange();
    for (let n = w.nextNode(); n; n = w.nextNode()) {
      const t = n.data;
      for (let j = 0; j < t.length; j++) {
        const c = t.charCodeAt(j), len = (c >= 0xD800 && c <= 0xDBFF) ? 2 : 1, ch = t.substr(j, len);
        if (!/\s/.test(ch)) {
          range.setStart(n, j); range.setEnd(n, j + len);
          const r = range.getClientRects()[0];
          out.push({ ch, x: r ? r.left : NaN, y: r ? r.top : NaN, w: r ? r.width : 0, h: r ? r.height : 0 });
        }
        j += len - 1;
      }
    }
    return out;
  }

  // Column/page index of every character, computed at the scroll origin.
  function analyze() {
    const g = S.geo, eps = 0.5, P = g.P;
    for (const f of S.frames) scrollFrame(f, 0, 0);
    const cs = chars(S.frames[0].contentDocument);
    const vw = S.frames[0].clientWidth;
    let monotonicViolations = 0, straddles = 0, inlineOverflow = 0, overhang = 0, noRect = 0, prev = -1, maxCol = 0;
    const colOf = [];
    for (const c of cs) {
      if (Number.isNaN(c.x)) { noRect++; colOf.push(prev); continue; }
      // a = axis along which columns are laid out, b = the other axis
      let i, a0, a1, alo, ahi, b0, b1, blo, bhi;
      if (S.mode === 'A') {
        const step = g.colW + g.G, right = vw - P;
        i = Math.floor((right - (c.x + c.w / 2)) / step);
        ahi = right - i * step; alo = ahi - g.colW; a0 = c.x; a1 = c.x + c.w; blo = P; bhi = P + g.contentH; b0 = c.y; b1 = c.y + c.h;
      } else if (S.mode === 'B') {
        const step = g.contentH + g.pageGap;
        i = Math.floor((c.y + c.h / 2 - P) / step);
        alo = P + i * step; ahi = alo + g.contentH; a0 = c.y; a1 = c.y + c.h; blo = P; bhi = P + g.colW; b0 = c.x; b1 = c.x + c.w;
      } else {
        const step = g.colW + g.G;
        i = Math.floor((c.x + c.w / 2 - P) / step);
        alo = P + i * step; ahi = alo + g.colW; a0 = c.x; a1 = c.x + c.w; blo = P; bhi = P + g.contentH; b0 = c.y; b1 = c.y + c.h;
      }
      const outA = a0 < alo - P - eps || a1 > ahi + P + eps;           // would leak into a neighbour column
      const outB = b0 < blo - P - eps || b1 > bhi + P + eps;           // would be clipped at the content edge
      const strict = a0 < alo - eps || a1 > ahi + eps || b0 < blo - eps || b1 > bhi + eps;
      if (outA) straddles++; else if (outB) inlineOverflow++; else if (strict) overhang++;
      if (i < prev) monotonicViolations++;
      prev = Math.max(prev, i); maxCol = Math.max(maxCol, i); colOf.push(i);
    }
    S.colOf = colOf;
    goSpread(S.spread);
    const columns = maxCol + 1;
    return { totalChars: cs.length, text: cs.map(c => c.ch).join(''), columns, columnCountFromScroll: S.columnCount,
      spreads: Math.ceil(columns / g.cols), monotonicViolations, straddles, inlineOverflow, overhang, noRect };
  }

  // Characters fully visible in each visible column of spread k, in reading order.
  function visibleAt(k) {
    goSpread(k);
    const g = S.geo, eps = 0.5, cols = [];
    let partial = 0;
    const take = (f, split) => {
      const vw = f.clientWidth, vh = f.clientHeight;
      const buckets = split ? [[], []] : [[]];
      chars(f.contentDocument).forEach((c, idx) => {
        if (Number.isNaN(c.x)) return;
        const inside = c.x >= -eps && c.y >= -eps && c.x + c.w <= vw + eps && c.y + c.h <= vh + eps;
        const touches = c.x + c.w > 0 && c.x < vw && c.y + c.h > 0 && c.y < vh;
        if (inside) {
          if (!split) buckets[0].push(idx);
          else if (S.mode === 'A') buckets[(c.x + c.w / 2) > vw / 2 ? 0 : 1].push(idx); // right column first
          else buckets[(c.x + c.w / 2) < vw / 2 ? 0 : 1].push(idx);                    // left column first
        } else if (touches) partial++;
      });
      cols.push(...buckets);
    };
    if (S.mode === 'B') S.frames.forEach(f => { if (f.style.visibility !== 'hidden') take(f, false); });
    else take(S.frames[0], g.cols === 2);
    return { columns: cols.map(a => (a.length ? [a[0], a[a.length - 1], a.length] : [null, null, 0])), lists: cols, partial };
  }

  // Reading location = first character of the first column (in reading order) of the spread.
  function location() { const v = visibleAt(S.spread); const first = v.lists.find(a => a.length); return first ? first[0] : null; }
  function goToChar(idx) { const col = S.colOf[idx]; const k = Math.floor(col / S.geo.cols); goSpread(k); return k; }

  function hit(x, y) {
    for (const f of S.frames) {
      if (f.style.visibility === 'hidden') continue;
      const r = f.getBoundingClientRect();
      if (x >= r.left && x < r.right && y >= r.top && y < r.bottom) {
        const el = f.contentDocument.elementFromPoint(x - r.left, y - r.top);
        const a = el && el.closest('a[href]');
        return { tag: el && el.tagName, href: a && a.getAttribute('href') };
      }
    }
    return null;
  }

  function linkRects(href) {
    const out = [];
    for (const f of S.frames) {
      if (f.style.visibility === 'hidden') continue;
      const fr = f.getBoundingClientRect();
      const a = f.contentDocument.querySelector(`a[href="${href}"]`);
      if (!a) continue;
      const r = a.getClientRects()[0];
      if (r && r.right > 0 && r.left < f.clientWidth && r.bottom > 0 && r.top < f.clientHeight)
        out.push({ x: fr.left + r.left + r.width / 2, y: fr.top + r.top + r.height / 2 });
    }
    return out;
  }

  function frameInfo() {
    return S.frames.map(f => {
      const d = f.contentDocument, b = d.body;
      const cs = d.defaultView.getComputedStyle(b);
      return { title: d.title, writingMode: cs.writingMode, fontFamily: cs.fontFamily,
        importedFontLoaded: (d.fonts && d.fonts.check) ? d.fonts.check(`${S.settings.fontSize}px "ReaderImported"`) : null,
        fontFaces: (function () { const a = []; if (d.fonts && d.fonts.forEach) d.fonts.forEach(ff => a.push(ff.family + ':' + ff.status)); return a; })(),
        userAgent: navigator.userAgent };
    });
  }

  // [textNode, offset, length] of every non-space character, in the same order as chars().
  function charIndex(doc) {
    const out = []; const w = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(); n; n = w.nextNode()) {
      const t = n.data;
      for (let j = 0; j < t.length; j++) {
        const c = t.charCodeAt(j), len = (c >= 0xD800 && c <= 0xDBFF) ? 2 : 1;
        if (!/\s/.test(t.substr(j, len))) out.push([n, j, len]);
        j += len - 1;
      }
    }
    return out;
  }
  function rectOf(f, map, i) {
    const e = map[i], r = f.contentDocument.createRange();
    r.setStart(e[0], e[1]); r.setEnd(e[0], e[1] + e[2]);
    return r.getClientRects()[0];
  }

  // Cheaper full check for slow devices: per-character geometry once (analyze), then for every
  // spread only the boundary characters of each visible column and their neighbours.
  // analyze() proves every character sits inside exactly one column box (in order); the boundary
  // checks prove each spread shows exactly the right columns, so together: no gap, no duplicate.
  function verifyFast() {
    const an = analyze(); const g = S.geo, n = an.totalChars, colOf = S.colOf, eps = 0.5;
    const first = [], last = [];
    for (let i = 0; i < n; i++) { const c = colOf[i]; if (c < 0) continue; if (first[c] === undefined) first[c] = i; last[c] = i; }
    const maps = S.frames.map(f => charIndex(f.contentDocument));
    const fails = []; let checks = 0;
    const state = (f, map, i) => {
      const r = rectOf(f, map, i); if (!r) return 'norect';
      const vw = f.clientWidth, vh = f.clientHeight;
      if (r.left >= -eps && r.top >= -eps && r.right <= vw + eps && r.bottom <= vh + eps) return 'full';
      if (r.right > 0 && r.left < vw && r.bottom > 0 && r.top < vh) return 'partial';
      return 'hidden';
    };
    for (let k = 0; k < an.spreads; k++) {
      goSpread(k);
      for (let j = 0; j < g.cols; j++) {
        const c = k * g.cols + j;
        if (first[c] === undefined) continue; // padding column or past the end
        const f = S.mode === 'B' ? S.frames[j] : S.frames[0], map = S.mode === 'B' ? maps[j] : maps[0];
        if (!f || f.style.visibility === 'hidden') { fails.push({ k, c, why: 'frame hidden' }); continue; }
        for (const i of [first[c], last[c]]) {
          checks++; const st = state(f, map, i);
          if (st !== 'full') fails.push({ k, c, i, why: 'boundary ' + st });
          if (g.cols === 2 && S.mode !== 'B' && st === 'full') { // correct side of the spread
            const r = rectOf(f, map, i), right = (r.left + r.width / 2) > f.clientWidth / 2;
            const wantRight = S.mode === 'A' ? j === 0 : j === 1;
            if (right !== wantRight) fails.push({ k, c, i, why: 'wrong side' });
          }
        }
        const before = first[c] - 1, after = last[c] + 1;
        const checkBefore = S.mode === 'B' || j === 0, checkAfter = S.mode === 'B' || j === g.cols - 1;
        if (checkBefore && before >= 0) { checks++; const st = state(f, map, before); if (st !== 'hidden') fails.push({ k, c, i: before, why: 'previous char ' + st }); }
        if (checkAfter && after < n) { checks++; const st = state(f, map, after); if (st !== 'hidden') fails.push({ k, c, i: after, why: 'next char ' + st }); }
      }
    }
    goSpread(0);
    return { totalChars: n, columns: an.columns, columnCountFromScroll: an.columnCountFromScroll, spreads: an.spreads,
      monotonicViolations: an.monotonicViolations, straddles: an.straddles, clipped: an.inlineOverflow, overhang: an.overhang,
      noRect: an.noRect, boundaryChecks: checks, failCount: fails.length, fails: fails.slice(0, 12),
      firstSpread: g.cols === 2 ? [[first[0], last[0]], [first[1], last[1]]] : [[first[0], last[0]]],
      text: an.text };
  }

  // Is character idx fully visible in any visible frame right now? (cheap single-character check)
  function charVisible(idx) {
    const eps = 0.5;
    return S.frames.some(f => {
      if (f.style.visibility === 'hidden') return false;
      const r = rectOf(f, charIndex(f.contentDocument), idx);
      return !!r && r.left >= -eps && r.top >= -eps && r.right <= f.clientWidth + eps && r.bottom <= f.clientHeight + eps;
    });
  }

  window.__reader = { open, relayout, goSpread, analyze, visibleAt, location, goToChar, hit, linkRects, frameInfo, verifyFast, charVisible, state: S };
})();
