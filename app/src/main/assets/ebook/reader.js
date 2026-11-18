'use strict';
// Bookmania reader shell. One book document per iframe; the native layer drives everything
// through window.__reader and polls status() while a layout is in progress.
//
// Modes (single column, stage 2):
//   H = horizontal-tb; CSS multicol, pages side by side on the x axis
//   V = vertical-rl;   CSS multicol, pages stacked on the y axis (classic vertical pagination)
//
// Book documents are loaded with sandbox="allow-same-origin" (no allow-scripts) and a CSP
// without script-src, so book scripts never run. The shell styles them from the outside.
// Keep this file to syntax supported by old Android WebViews (no ?., ??, object spread).
(function () {
  var stage = document.getElementById('stage');
  var P = 8;        // overflow allowance around the page box (ruby, glyph overhang)
  var GAP = 24;     // invisible gap between consecutive pages, must be > 2 * P
  // anchor: first character of the page the reader navigated to. Relayouts (rotation, settings) keep
  // returning to it, so repeated relayouts do not drift; any navigation clears it.
  var S = { frame: null, mode: 'H', settings: null, geo: null, page: 0, pages: 1, ready: false, error: null, seq: 0, anchor: null };

  function setImp(el, props) {
    Object.keys(props).forEach(function (k) { el.style.setProperty(k, props[k], 'important'); });
  }

  function geometry(s) {
    var W = window.innerWidth, H = window.innerHeight, m = s.margins;
    var w = Math.max(80, W - m.left - m.right), h = Math.max(80, H - m.top - m.bottom);
    return { W: W, H: H, m: m, contentW: w, contentH: h, step: (S.mode === 'V' ? h : w) + GAP };
  }

  function bookStyle(s, geo) {
    var vertical = S.mode === 'V';
    var wm = vertical ? 'vertical-rl' : 'horizontal-tb';
    var css = '' +
      'html { -webkit-text-size-adjust: 100% !important; font-size: ' + s.fontSize + 'px !important; }\n' +
      'html, body { writing-mode: ' + wm + ' !important; -webkit-writing-mode: ' + wm + ' !important; -epub-writing-mode: ' + wm + ' !important; }\n' +
      'body { line-height: ' + s.lineHeight + ' !important; }\n' +
      'p, div, li, blockquote, dd, dt, td, th { line-height: inherit !important; }\n' +
      'img, svg, video { ' + (vertical ? 'max-height' : 'max-width') + ': 100% !important; ' +
        (vertical ? 'max-width' : 'max-height') + ': ' + (vertical ? geo.contentW : geo.contentH) + 'px !important; ' +
        'object-fit: contain; box-sizing: border-box; break-inside: avoid; page-break-inside: avoid; }\n' +
      'html { color: ' + s.textColor + '; }\n';
    if (s.dark) {
      css += 'html, body { color: ' + s.textColor + ' !important; background-color: transparent !important; }\n' +
        'body * { color: inherit !important; background-color: transparent !important; }\n';
    }
    return css;
  }

  function applyLayout() {
    var f = S.frame, d = f.contentDocument, g = S.geo = geometry(S.settings);
    Object.assign(f.style, {
      left: (g.m.left - P) + 'px', top: (g.m.top - P) + 'px',
      width: (g.contentW + 2 * P) + 'px', height: (g.contentH + 2 * P) + 'px'
    });
    var base = { margin: '0', padding: P + 'px', 'box-sizing': 'border-box', overflow: 'hidden', 'column-fill': 'auto',
      height: (g.contentH + 2 * P) + 'px', background: 'transparent' };
    if (S.mode === 'V') {
      base.width = (g.contentW + 2 * P) + 'px';
      base['column-width'] = g.contentH + 'px';
    } else {
      base.width = 'auto';
      base['column-width'] = g.contentW + 'px';
    }
    base['column-gap'] = GAP + 'px';
    setImp(d.documentElement, base);
    var st = d.getElementById('__bookmania_style');
    if (!st) {
      st = d.createElement('style');
      st.id = '__bookmania_style';
      (d.head || d.documentElement).appendChild(st);
    }
    st.textContent = bookStyle(S.settings, g);
  }

  function countPages() {
    var g = S.geo, el = S.frame.contentDocument.scrollingElement || S.frame.contentDocument.documentElement;
    var extent = S.mode === 'V' ? el.scrollHeight : el.scrollWidth;
    return Math.max(1, Math.round((extent - 2 * P + GAP) / g.step));
  }

  function scrollToPage(k) {
    var w = S.frame.contentWindow;
    if (S.mode === 'V') w.scrollTo(0, k * S.geo.step); else w.scrollTo(k * S.geo.step, 0);
  }

  function goPage(k) {
    S.page = Math.max(0, Math.min(S.pages - 1, k));
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
    var lo = P, hi = (S.mode === 'V' ? S.geo.contentH : S.geo.contentW) + P;
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

  function settle(seq) {
    var d = S.frame.contentDocument;
    var fonts = d.fonts && d.fonts.ready ? d.fonts.ready : Promise.resolve();
    return Promise.all([fonts, waitForImages(d)]).then(function () {
      if (seq !== S.seq) return false;
      d.documentElement.getBoundingClientRect(); // force layout
      S.pages = countPages();
      return true;
    });
  }

  function start(target) {
    var k = 0;
    if (target === 'end') k = S.pages - 1;
    else if (target && target.fragment) {
      var el = findFragment(S.frame.contentDocument, target.fragment);
      k = el ? pageOfElement(el) : 0;
    } else if (target && target.location) k = pageOfLocation(target.location);
    goPage(k);
  }

  function fail(seq, e) {
    if (seq !== S.seq) return;
    S.error = String(e && e.message ? e.message : e);
    S.ready = true;
  }

  function open(src, settings, target) {
    var seq = ++S.seq;
    S.ready = false; S.error = null; S.page = 0; S.pages = 1;
    S.anchor = target && target.location ? target.location : null;
    S.settings = settings; S.mode = settings.vertical ? 'V' : 'H';
    document.body.style.background = settings.background;
    while (stage.firstChild) stage.removeChild(stage.firstChild);
    var f = document.createElement('iframe');
    f.setAttribute('sandbox', 'allow-same-origin');
    S.frame = f;
    f.addEventListener('load', function () {
      if (seq !== S.seq) return;
      try {
        applyLayout();
        settle(seq).then(function (ok) {
          if (!ok) return;
          start(target);
          S.ready = true;
        }).catch(function (e) { fail(seq, e); });
      } catch (e) { fail(seq, e); }
    }, { once: true });
    f.src = src;
    stage.appendChild(f);
    return true;
  }

  function relayout(settings) {
    if (!S.frame || !S.ready || S.error) return false;
    var seq = ++S.seq, loc = S.anchor || locate();
    S.anchor = loc;
    S.ready = false;
    if (settings) S.settings = settings;
    S.mode = S.settings.vertical ? 'V' : 'H';
    document.body.style.background = S.settings.background;
    applyLayout();
    settle(seq).then(function (ok) {
      if (!ok) return;
      goPage(pageOfLocation(loc));
      S.ready = true;
    }).catch(function (e) { fail(seq, e); });
    return true;
  }

  function next() {
    if (!S.ready || S.error) return 'busy';
    if (S.page >= S.pages - 1) return 'end';
    goPage(S.page + 1);
    S.anchor = null;
    return 'ok';
  }

  function prev() {
    if (!S.ready || S.error) return 'busy';
    if (S.page <= 0) return 'start';
    goPage(S.page - 1);
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
    var r = S.frame.getBoundingClientRect();
    if (x < r.left || x >= r.right || y < r.top || y >= r.bottom) return null;
    var el = S.frame.contentDocument.elementFromPoint(x - r.left, y - r.top);
    var a = el && el.closest ? el.closest('a[href]') : null;
    return a ? a.href : null;
  }

  function status() {
    return { ready: S.ready, error: S.error, page: S.page, pages: S.pages, mode: S.mode, seq: S.seq };
  }

  var resizeTimer = null;
  window.addEventListener('resize', function () {
    if (resizeTimer) clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () { resizeTimer = null; relayout(null); }, 120);
  });

  function goToPage(k) {
    if (!S.ready || S.error) return false;
    goPage(k);
    S.anchor = null;
    return true;
  }

  window.__reader = { open: open, relayout: relayout, next: next, prev: prev, goPage: goToPage, goFragment: goFragment,
    hit: hit, status: status };
})();
