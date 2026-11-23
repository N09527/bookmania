'use strict';
// Bookmania reader shell. One book document per iframe; the native layer drives everything
// through window.__reader and polls status() while a layout is in progress.
//
// Modes:
//   H = horizontal-tb; CSS multicol, pages side by side on the x axis
//   V = vertical-rl;   CSS multicol, pages stacked on the y axis (classic vertical pagination)
// Two columns (stage 4): two iframes with the same document, each paginated as above but half as wide.
// A spread shows page 2k in the first frame, on the side where reading starts (right when pages turn
// right-to-left, as in vertical text), and page 2k+1 in the second frame on the other side. This is the
// "B" layout of the stage 1 prototype, generalised to both writing modes; it needs no column-wrap support.
//
// Book documents are loaded with sandbox="allow-same-origin" (no allow-scripts) and a CSP
// without script-src, so book scripts never run. The shell styles them from the outside.
// Keep this file to syntax supported by old Android WebViews (no ?., ??, object spread).
(function () {
  var stage = document.getElementById('stage');
  var P = 8;        // overflow allowance around the page box (ruby, glyph overhang)
  var GAP = 24;     // invisible gap between consecutive pages, must be > 2 * P
  var COL_GAP = 40; // gap between the two columns of a spread (fixed, decision 9 of the design)
  var MIN_COL = 120; // narrower than this, two columns fall back to one
  var POSITION_TEXT = 24; // characters of text saved with a reading position (to find it again)
  // anchor: first character of the page the reader navigated to. Relayouts (rotation, settings) keep
  // returning to it, so repeated relayouts do not drift; any navigation clears it.
  // t0/ms: start and duration of the last open or relayout (for diagnostics).
  // frames[0] shows the first page of the spread (frame is the same element); frames[1] the second.
  var S = { frame: null, frames: [], src: null, cols: 1, mode: 'H', settings: null, geo: null, page: 0, pages: 1,
    ready: false, error: null, seq: 0, anchor: null, t0: 0, ms: 0, rubyFix: false, textIdx: null };

  // Old WebViews (seen on WebView 69) draw the ruby of a page's first line at the end of the previous
  // page: the annotation sticks out above its line box and the page break falls between them. Once
  // that is detected, lines with ruby get enough leading to hold the annotation (stage 4 experiment:
  // 14 of 128 annotations misplaced without it, 0 with it). Newer WebViews keep the book's look.
  var RUBY_FIX_CSS = 'rt { line-height: 1 !important; } ruby { line-height: 2.6 !important; }\n';

  // The imported font is loaded once per reader session (in this shell document) and the same FontFace
  // is added to every book document: loading a large CJK font again for each chapter file took tens of
  // seconds on a slow device. Where sharing is not possible the document loads it through @font-face.
  var USER_FAMILY = 'BookmaniaUserFont';
  var U = { url: null, face: null, ready: null };

  function userFontUrl(s) {
    return s && s.font && s.font.kind === 'imported' && s.font.url ? s.font.url : null;
  }

  // Starts loading the imported font named by the settings (once per URL). Resolves when it has loaded
  // or failed; a failed font simply falls back to the next family.
  function prepareUserFont(s) {
    var url = userFontUrl(s);
    if (url === U.url) return U.ready || Promise.resolve();
    U.url = url; U.face = null; U.ready = Promise.resolve();
    if (url && typeof FontFace === 'function') {
      try {
        U.face = new FontFace(USER_FAMILY, 'url("' + url + '")');
        U.ready = U.face.load().then(function () {}, function () {});
      } catch (e) { U.face = null; }
    }
    return U.ready;
  }

  // Puts the shared font into the document, or takes it out when another font is chosen.
  // Returns 'none' (no imported font), 'shared', 'pending' (still loading), 'failed', or 'fallback'
  // (sharing not possible here: the document must load the font itself through @font-face).
  function attachUserFont(d, s) {
    var url = userFontUrl(s), fonts = d.fonts;
    if (d.__bookmaniaFace && (!url || d.__bookmaniaFace !== U.face)) {
      try { fonts.delete(d.__bookmaniaFace); } catch (e) {}
      d.__bookmaniaFace = null;
    }
    if (!url) return 'none';
    if (!U.face || !fonts || !fonts.add) return 'fallback';
    if (U.face.status === 'error') return 'failed';
    if (U.face.status !== 'loaded') return 'pending';
    if (d.__bookmaniaFace === U.face) return 'shared';
    try {
      fonts.add(U.face);
      d.__bookmaniaFace = U.face;
      return 'shared';
    } catch (e) {
      return 'fallback';
    }
  }

  function setImp(el, props) {
    Object.keys(props).forEach(function (k) { el.style.setProperty(k, props[k], 'important'); });
  }

  // Columns wanted by the settings: 'on', 'off', or 'landscape' (two when the window is wider than tall).
  function wantedColumns(s) {
    var c = s && s.columns;
    if (c === 'on') return 2;
    if (c === 'landscape') return window.innerWidth > window.innerHeight ? 2 : 1;
    return 1;
  }

  // pageW: width of one page box (a column); G: gap between the two columns (rounding goes into it).
  function geometry(s) {
    var W = window.innerWidth, H = window.innerHeight, m = s.margins;
    var w = Math.max(80, W - m.left - m.right), h = Math.max(80, H - m.top - m.bottom);
    var cols = wantedColumns(s), pageW = w, G = 0;
    if (cols === 2) {
      pageW = Math.floor((w - COL_GAP) / 2);
      if (pageW < MIN_COL) { cols = 1; pageW = w; } else G = w - 2 * pageW;
    }
    return { W: W, H: H, m: m, contentW: w, contentH: h, cols: cols, pageW: pageW, G: G,
      step: (S.mode === 'V' ? h : pageW) + GAP };
  }

  // Left edge of frame i's page box: the first page sits on the side where reading starts.
  function pageLeft(g, i) {
    if (g.cols === 1) return g.m.left;
    var firstOnRight = !!(S.settings && S.settings.rtl);
    var onRight = (i === 0) === firstOnRight;
    return onRight ? g.m.left + g.pageW + g.G : g.m.left;
  }

  function bookStyle(s, geo, userFontMode) {
    var vertical = S.mode === 'V';
    var wm = vertical ? 'vertical-rl' : 'horizontal-tb';
    var css = '' +
      'html { -webkit-text-size-adjust: 100% !important; font-size: ' + s.fontSize + 'px !important; }\n' +
      'html, body { writing-mode: ' + wm + ' !important; -webkit-writing-mode: ' + wm + ' !important; -epub-writing-mode: ' + wm + ' !important; }\n' +
      'body { line-height: ' + s.lineHeight + ' !important; }\n' +
      'p, div, li, blockquote, dd, dt, td, th { line-height: inherit !important; }\n' +
      'img, svg, video { ' + (vertical ? 'max-height' : 'max-width') + ': 100% !important; ' +
        (vertical ? 'max-width' : 'max-height') + ': ' + (vertical ? geo.pageW : geo.contentH) + 'px !important; ' +
        'object-fit: contain; box-sizing: border-box; break-inside: avoid; page-break-inside: avoid; }\n' +
      'html { color: ' + s.textColor + '; }\n';
    // Ruby in vertical text: the default orientation (mixed) lays non-CJK characters sideways, the bopomofo
    // tone marks too, so the 2nd and 4th tones look swapped (WebView 69 and Chromium 153, stage 6). Upright
    // keeps them as written; kana and bopomofo letters are upright either way. Not !important: a more specific
    // rule of the book for its ruby still applies.
    if (vertical) css += 'rt { text-orientation: upright; -webkit-text-orientation: upright; }\n';
    // Font: the book's own (nothing to add), a generic family, or an imported font.
    var family = null;
    if (userFontUrl(s)) {
      if (userFontMode === 'fallback') css += '@font-face { font-family: "' + USER_FAMILY + '"; src: url("' + s.font.url + '"); }\n';
      family = '"' + USER_FAMILY + '", serif';
    } else if (s.font && (s.font.kind === 'sans' || s.font.kind === 'serif')) {
      family = s.font.kind === 'sans' ? 'sans-serif' : 'serif';
    }
    if (family) css += 'html, body, body * { font-family: ' + family + ' !important; }\n';
    // Bold (stage 7): every element, so a book that sets its paragraphs to normal weight is bold too. A font
    // without a bold face is emboldened by the browser.
    if (s.bold) css += 'body, body * { font-weight: bold !important; }\n';
    // 0 adds nothing, so the book's own letter spacing (e.g. spaced headings) is kept.
    if (typeof s.letterSpacing === 'number' && s.letterSpacing > 0) css += 'body, body * { letter-spacing: ' + s.letterSpacing + 'em !important; }\n';
    if (typeof s.indent === 'number') css += 'p { text-indent: ' + s.indent + 'em !important; }\n';
    if (typeof s.paragraphSpacing === 'number') {
      // Logical sides, so the spacing goes between paragraphs in vertical text too; -webkit- forms for old WebViews.
      css += 'p { -webkit-margin-before: 0 !important; -webkit-margin-after: ' + s.paragraphSpacing + 'em !important; ' +
        'margin-block-start: 0 !important; margin-block-end: ' + s.paragraphSpacing + 'em !important; }\n';
    }
    if (S.rubyFix) css += RUBY_FIX_CSS;
    if (s.dark) {
      css += 'html, body { color: ' + s.textColor + ' !important; background-color: transparent !important; }\n' +
        'body * { color: inherit !important; background-color: transparent !important; }\n';
    }
    return css;
  }

  // Places and styles every frame for S.settings (S.geo must be current, see layoutDocument).
  function applyLayout() {
    var g = S.geo, mode = 'none';
    S.frames.forEach(function (f, i) {
      var d = f.contentDocument;
      Object.assign(f.style, {
        left: (pageLeft(g, i) - P) + 'px', top: (g.m.top - P) + 'px',
        width: (g.pageW + 2 * P) + 'px', height: (g.contentH + 2 * P) + 'px'
      });
      var base = { margin: '0', padding: P + 'px', 'box-sizing': 'border-box', overflow: 'hidden', 'column-fill': 'auto',
        height: (g.contentH + 2 * P) + 'px', background: 'transparent' };
      if (S.mode === 'V') {
        base.width = (g.pageW + 2 * P) + 'px';
        base['column-width'] = g.contentH + 'px';
      } else {
        base.width = 'auto';
        base['column-width'] = g.pageW + 'px';
      }
      base['column-gap'] = GAP + 'px';
      setImp(d.documentElement, base);
      var st = d.getElementById('__bookmania_style');
      if (!st) {
        st = d.createElement('style');
        st.id = '__bookmania_style';
        (d.head || d.documentElement).appendChild(st);
      }
      var m = attachUserFont(d, S.settings);
      if (i === 0 || m === 'pending') mode = m;
      st.textContent = bookStyle(S.settings, g, m);
    });
    S.userFontMode = mode;
  }

  // An iframe for the current document, resolved once it has loaded.
  function loadFrame(src) {
    return new Promise(function (resolve) {
      var f = document.createElement('iframe');
      f.setAttribute('sandbox', 'allow-same-origin');
      f.style.visibility = 'hidden'; // shown by scrollToPage once it is laid out
      f.addEventListener('load', function () { resolve(f); }, { once: true });
      f.src = src;
      stage.appendChild(f);
    });
  }

  // Makes the number of frames match the columns of the current geometry; new frames load S.src.
  function ensureFrames() {
    var want = S.geo.cols;
    while (S.frames.length > want) {
      var f = S.frames.pop();
      if (f.parentNode) f.parentNode.removeChild(f);
    }
    if (S.frames.length >= want) return Promise.resolve();
    var loads = [];
    for (var i = S.frames.length; i < want; i++) loads.push(loadFrame(S.src));
    return Promise.all(loads).then(function (added) {
      S.frames = S.frames.concat(added);
      S.frame = S.frames[0];
    });
  }

  // Lays out the open document with S.settings: styled at once, and once more when an imported font
  // that was still loading is ready; then waits for fonts and images and counts the pages.
  function layoutDocument(seq) {
    S.geo = geometry(S.settings);
    S.cols = S.geo.cols;
    return ensureFrames().then(function () {
      if (seq !== S.seq) return false;
      applyLayout();
      var pending = S.userFontMode === 'pending';
      return (pending ? U.ready : Promise.resolve()).then(function () {
        if (seq !== S.seq) return false;
        if (pending) applyLayout();
        return settle(seq);
      });
    });
  }

  function countPages() {
    var g = S.geo, el = S.frame.contentDocument.scrollingElement || S.frame.contentDocument.documentElement;
    var extent = S.mode === 'V' ? el.scrollHeight : el.scrollWidth;
    return Math.max(1, Math.round((extent - 2 * P + GAP) / g.step));
  }

  // Shows page k in the first frame and k+1 in the second (hidden past the last page).
  function scrollToPage(k) {
    S.frames.forEach(function (f, i) {
      var p = k + i, w = f.contentWindow;
      f.style.visibility = i === 0 || p < S.pages ? 'visible' : 'hidden';
      if (S.mode === 'V') w.scrollTo(0, p * S.geo.step); else w.scrollTo(p * S.geo.step, 0);
    });
  }

  // Goes to the spread that contains page k (with two columns a spread starts at an even page).
  function goPage(k) {
    var p = Math.max(0, Math.min(S.pages - 1, k));
    if (S.cols === 2) p -= p % 2;
    S.page = p;
    scrollToPage(S.page);
  }

  // Page that contains the start of a client rect measured at the scroll origin.
  function pageOfRect(r) {
    var pos = S.mode === 'V' ? r.top : r.left;
    return Math.max(0, Math.min(S.pages - 1, Math.floor((pos - P + 1) / S.geo.step)));
  }

  function rectAtOrigin(node) {
    var rects;
    if (node.nodeType === 3) {
      var range = node.ownerDocument.createRange();
      range.selectNodeContents(node);
      rects = range.getClientRects();
    } else {
      rects = node.getClientRects();
    }
    return rects.length ? rects[0] : (node.getBoundingClientRect ? node.getBoundingClientRect() : null);
  }

  function pageOfElement(el) {
    scrollToPage(0);
    var r = rectAtOrigin(el);
    var k = r ? pageOfRect(r) : 0;
    scrollToPage(S.page);
    return k;
  }

  function findFragment(d, id) {
    if (!id) return null;
    var el = d.getElementById(id);
    if (!el) {
      var named = d.getElementsByName(id);
      el = named.length ? named[0] : null;
    }
    return el;
  }

  // First character of the current page, as [text node index, offset], for relayout.
  function locate() {
    var d = S.frame.contentDocument, w = d.createTreeWalker(d.body || d.documentElement, NodeFilter.SHOW_TEXT);
    var range = d.createRange(), i = 0;
    var lo = P, hi = (S.mode === 'V' ? S.geo.contentH : S.geo.pageW) + P;
    for (var n = w.nextNode(); n; n = w.nextNode(), i++) {
      if (!/\S/.test(n.data)) continue;
      range.selectNodeContents(n);
      var rects = range.getClientRects(), hit = false;
      for (var j = 0; j < rects.length && !hit; j++) {
        var a = S.mode === 'V' ? rects[j].top : rects[j].left, b = S.mode === 'V' ? rects[j].bottom : rects[j].right;
        if (b > lo && a < hi) hit = true;
      }
      if (!hit) continue;
      for (var c = 0; c < n.data.length; c++) {
        if (/\s/.test(n.data.charAt(c))) continue;
        range.setStart(n, c); range.setEnd(n, c + 1);
        var r = range.getClientRects()[0];
        if (!r) continue;
        var s = S.mode === 'V' ? r.top : r.left;
        if (s >= lo - 1 && s < hi) return [i, c];
      }
    }
    return null;
  }

  function pageOfLocation(loc) {
    if (!loc) return 0;
    var d = S.frame.contentDocument, w = d.createTreeWalker(d.body || d.documentElement, NodeFilter.SHOW_TEXT), i = 0;
    for (var n = w.nextNode(); n; n = w.nextNode(), i++) {
      if (i !== loc[0]) continue;
      var range = d.createRange(), c = Math.min(loc[1], Math.max(0, n.data.length - 1));
      range.setStart(n, c); range.setEnd(n, Math.min(n.data.length, c + 1));
      scrollToPage(0);
      var r = range.getClientRects()[0];
      var k = r ? pageOfRect(r) : 0;
      return k;
    }
    return 0;
  }

  // Every non-whitespace character of the open document's body in document order, with the text node
  // (index in the same walk as locate()) and offset it comes from. Used to save and restore a reading
  // position by its text and to convert between positions and fractions. Built once per document.
  function isSpace(code) {
    return code === 32 || (code >= 9 && code <= 13) || code === 0xA0 || code === 0x3000 || code === 0x1680 ||
      (code >= 0x2000 && code <= 0x200A) || code === 0x2028 || code === 0x2029 || code === 0x202F ||
      code === 0x205F || code === 0xFEFF;
  }

  function textIndex() {
    var d = S.frame.contentDocument;
    if (S.textIdx && S.textIdx.doc === d) return S.textIdx;
    var w = d.createTreeWalker(d.body || d.documentElement, NodeFilter.SHOW_TEXT), i = 0;
    var chars = [], node = [], off = [];
    for (var n = w.nextNode(); n; n = w.nextNode(), i++) {
      var t = n.data;
      for (var c = 0; c < t.length; c++) {
        if (isSpace(t.charCodeAt(c))) continue;
        chars.push(t.charAt(c)); node.push(i); off.push(c);
      }
    }
    S.textIdx = { doc: d, text: chars.join(''), node: node, off: off };
    return S.textIdx;
  }

  // Index in textIndex() of the first character at or after location [node, offset].
  function indexOfLocation(idx, loc) {
    var lo = 0, hi = idx.node.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (idx.node[mid] < loc[0] || (idx.node[mid] === loc[0] && idx.off[mid] < loc[1])) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  function locationAt(idx, k) {
    if (!idx.node.length) return null;
    k = Math.max(0, Math.min(idx.node.length - 1, k));
    return [idx.node[k], idx.off[k]];
  }

  // A saved position, tried in order: the location itself (when the text there still matches), the
  // saved text (the occurrence nearest the saved fraction), then the fraction. Null when the
  // document has no text.
  function resolvePosition(t) {
    var idx = textIndex(), total = idx.text.length, want = t.text || '';
    if (!total) return null;
    // The fraction was saved as index / total; the small margin undoes rounding (546 / 1880 * 1880 can
    // come out as 545.999…, which would open one character, possibly one page, too early).
    var expected = typeof t.progression === 'number' ? Math.min(total - 1, Math.floor(t.progression * total + 1e-6)) : 0;
    if (t.location) {
      var k = indexOfLocation(idx, t.location);
      if (k < total && idx.node[k] === t.location[0] && idx.off[k] === t.location[1] &&
          (!want || idx.text.substr(k, want.length) === want)) {
        return t.location;
      }
    }
    if (want.length >= 4) {
      var best = -1, from = 0, at;
      while ((at = idx.text.indexOf(want, from)) >= 0) {
        if (best < 0 || Math.abs(at - expected) < Math.abs(best - expected)) best = at;
        from = at + 1;
      }
      if (best >= 0) return locationAt(idx, best);
    }
    if (typeof t.progression === 'number') return locationAt(idx, expected);
    return null;
  }

  // The current reading position: first character of the current page (or the anchor kept across
  // relayouts), the text from there, and where it is in the document's text.
  // A page without text (a picture) has no location; it is saved by its page instead.
  function position() {
    if (!S.frame || !S.ready || S.error) return null;
    var idx = textIndex(), loc = S.anchor || locate(), total = idx.text.length;
    var base = { chars: total, page: S.page, pages: S.pages, cols: S.cols };
    if (!loc) return Object.assign(base, { location: null, text: '', before: null });
    var k = indexOfLocation(idx, loc);
    if (k < total) loc = [idx.node[k], idx.off[k]];
    return Object.assign(base, { location: loc, text: idx.text.substr(k, POSITION_TEXT), before: k });
  }

  // Goes to the page with the character at fraction f of the document's text (pages, for a document
  // without text).
  function goProgress(f) {
    if (!S.ready || S.error) return false;
    f = Math.max(0, Math.min(1, +f || 0));
    var idx = textIndex(), loc = idx.text.length ? locationAt(idx, Math.floor(f * idx.text.length)) : null;
    goPage(loc ? pageOfLocation(loc) : Math.round(f * (S.pages - 1)));
    S.anchor = null;
    return true;
  }

  function waitForImages(d) {
    var imgs = Array.prototype.slice.call(d.images || []);
    return Promise.all(imgs.map(function (img) {
      if (img.complete) return null;
      return new Promise(function (resolve) {
        img.addEventListener('load', resolve, { once: true });
        img.addEventListener('error', resolve, { once: true });
      });
    }));
  }

  // Waits for fonts and images, then counts the pages. Layout is forced first: font loads start only
  // when a layout needs the font, and fonts.ready taken before that would not wait for them.
  // Whether a ruby annotation of the document lies on another page than its base text.
  function rubyMisplaced(f) {
    var d = f.contentDocument, rts = d.getElementsByTagName('rt');
    if (!rts.length) return false;
    var w = f.contentWindow, V = S.mode === 'V', step = S.geo.step, r = d.createRange();
    function page(rect) { return Math.floor(((V ? rect.top + w.scrollY : rect.left + w.scrollX) - P + 1) / step); }
    for (var i = 0; i < rts.length; i++) {
      var rt = rts[i], base = rt.previousSibling;
      while (base && !(base.nodeType === 3 && /\S/.test(base.data)) && !(base.nodeType === 1 && base.localName === 'rb')) {
        base = base.previousSibling;
      }
      if (!base) continue;
      r.selectNodeContents(base);
      var b = r.getClientRects()[0];
      r.selectNodeContents(rt);
      var t = r.getClientRects()[0];
      if (b && t && page(b) !== page(t)) return true;
    }
    return false;
  }

  function settle(seq) {
    var waits = [];
    S.frames.forEach(function (f) {
      var d = f.contentDocument;
      d.documentElement.getBoundingClientRect();
      if (d.fonts && d.fonts.ready) {
        if (userFontUrl(S.settings)) waits.push(d.fonts.load('1em "' + USER_FAMILY + '"').catch(function () {}));
        waits.push(d.fonts.ready);
      }
      waits.push(waitForImages(d));
    });
    return Promise.all(waits).then(function () {
      if (seq !== S.seq) return false;
      S.frames.forEach(function (f) { f.contentDocument.documentElement.getBoundingClientRect(); }); // force layout
      if (!S.rubyFix && rubyMisplaced(S.frame)) {
        S.rubyFix = true; // for the rest of the session
        applyLayout();
        S.frames.forEach(function (f) { f.contentDocument.documentElement.getBoundingClientRect(); });
      }
      S.pages = countPages();
      return true;
    });
  }

  // target: 'start', 'end', {fragment}, a saved position {location, text, progression} (see
  // resolvePosition) or {pageProgression} (a page without text). A restored position becomes the
  // anchor, so later relayouts keep it.
  function start(target) {
    var k = 0;
    if (target === 'end') k = S.pages - 1;
    else if (target && target.fragment) {
      var el = findFragment(S.frame.contentDocument, target.fragment);
      k = el ? pageOfElement(el) : 0;
    } else if (target && (target.location || target.text || typeof target.progression === 'number')) {
      var loc = resolvePosition(target);
      if (loc) {
        k = pageOfLocation(loc);
        S.anchor = loc;
      } else if (typeof target.progression === 'number') {
        k = Math.round(target.progression * (S.pages - 1));
      }
    } else if (target && typeof target.pageProgression === 'number') {
      k = Math.floor(target.pageProgression * S.pages + 1e-6); // a page without text, saved by its page
    }
    goPage(k);
  }

  function fail(seq, e) {
    if (seq !== S.seq) return;
    S.error = String(e && e.message ? e.message : e);
    S.ready = true;
  }

  // End of an open or relayout. If the viewport changed while it ran (a rotation during a slow layout:
  // relayout() refuses while a layout runs), the geometry it used is stale, so lay out again at once.
  // ready turns true here and, synchronously, false again in relayout(): the native side polling
  // status() never sees the stale layout as ready.
  function finished() {
    S.ms = Date.now() - S.t0;
    S.ready = true;
    if (window.innerWidth !== S.geo.W || window.innerHeight !== S.geo.H) relayout(null);
  }

  function open(src, settings, target) {
    var seq = ++S.seq;
    S.t0 = Date.now();
    S.ready = false; S.error = null; S.page = 0; S.pages = 1;
    S.anchor = null; S.textIdx = null;
    S.settings = settings; S.mode = settings.vertical ? 'V' : 'H';
    prepareUserFont(settings); // in parallel with the document
    document.body.style.background = settings.background;
    while (stage.firstChild) stage.removeChild(stage.firstChild);
    S.frames = []; S.frame = null; S.src = src;
    loadFrame(src).then(function (f) {
      if (seq !== S.seq) return false;
      S.frames = [f]; S.frame = f;
      return layoutDocument(seq);
    }).then(function (ok) {
      if (!ok) return;
      start(target);
      finished();
    }).catch(function (e) { fail(seq, e); });
    return true;
  }

  function relayout(settings) {
    if (!S.frame || !S.ready || S.error) return false;
    var seq = ++S.seq, loc = S.anchor || locate();
    S.t0 = Date.now();
    S.anchor = loc;
    S.ready = false;
    if (settings) S.settings = settings;
    S.mode = S.settings.vertical ? 'V' : 'H';
    prepareUserFont(S.settings);
    document.body.style.background = S.settings.background;
    layoutDocument(seq).then(function (ok) {
      if (!ok) return;
      goPage(pageOfLocation(loc)); // the spread that contains the anchor
      finished();
    }).catch(function (e) { fail(seq, e); });
    return true;
  }

  function next() {
    if (!S.ready || S.error) return 'busy';
    if (S.page + S.cols > S.pages - 1) return 'end';
    goPage(S.page + S.cols);
    S.anchor = null;
    return 'ok';
  }

  function prev() {
    if (!S.ready || S.error) return 'busy';
    if (S.page <= 0) return 'start';
    goPage(S.page - S.cols);
    S.anchor = null;
    return 'ok';
  }

  function goFragment(id) {
    if (!S.ready || S.error) return false;
    var el = findFragment(S.frame.contentDocument, id);
    if (!el) return false;
    goPage(pageOfElement(el));
    S.anchor = null;
    return true;
  }

  // Link under a point given in shell CSS pixels. Returns the absolute URL or null.
  function hit(x, y) {
    if (!S.frame || !S.ready) return null;
    for (var i = 0; i < S.frames.length; i++) {
      var f = S.frames[i];
      if (f.style.visibility === 'hidden') continue;
      var r = f.getBoundingClientRect();
      if (x < r.left || x >= r.right || y < r.top || y >= r.bottom) continue;
      var el = f.contentDocument.elementFromPoint(x - r.left, y - r.top);
      var a = el && el.closest ? el.closest('a[href]') : null;
      return a ? a.href : null;
    }
    return null;
  }

  // gutter: with two columns, the centre of the gap between them (stage 7: the native layer draws the fold's
  // shadow there); vw: the viewport width the layout used (window.innerWidth, a whole number). Both in CSS px.
  function status() {
    var g = S.geo, two = !!g && S.cols === 2;
    return { ready: S.ready, error: S.error, page: S.page, pages: S.pages, cols: S.cols, mode: S.mode, seq: S.seq, ms: S.ms,
      rubyFix: S.rubyFix, gutter: two ? g.m.left + g.pageW + g.G / 2 : null, vw: g ? g.W : null };
  }

  var resizeTimer = null;
  window.addEventListener('resize', function () {
    if (resizeTimer) clearTimeout(resizeTimer);
    // While a document is still being laid out, relayout() refuses; finished() catches up afterwards.
    resizeTimer = setTimeout(function () { resizeTimer = null; relayout(null); }, 120);
  });

  function goToPage(k) {
    if (!S.ready || S.error) return false;
    goPage(k);
    S.anchor = null;
    return true;
  }

  window.__reader = { open: open, relayout: relayout, next: next, prev: prev, goPage: goToPage, goFragment: goFragment,
    goProgress: goProgress, position: position, hit: hit, status: status };
})();
