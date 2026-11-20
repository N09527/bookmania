// Fully visible characters of every frame of the current spread, in frame order (= reading order:
// frame 0 holds the first page of the spread), plus each frame's position. Ruby text (rt, rp) is
// left out, as in stage2/probe.js. Returns a JSON string.
(function () {
  var frames = Array.prototype.slice.call(document.querySelectorAll('#stage iframe'));
  if (!frames.length || !window.__reader) return JSON.stringify({ none: true });
  function collect(f, onlyVisible) {
    var d = f.contentDocument, vw = f.clientWidth, vh = f.clientHeight, eps = 0.5;
    var w = d.createTreeWalker(d.body || d.documentElement, NodeFilter.SHOW_TEXT), r = d.createRange();
    var vis = [], all = [];
    for (var n = w.nextNode(); n; n = w.nextNode()) {
      var p = n.parentNode, skip = false;
      while (p && p !== d.body) { var t = (p.localName || '').toLowerCase(); if (t === 'rt' || t === 'rp') { skip = true; break; } p = p.parentNode; }
      if (skip) continue;
      var s = n.data;
      for (var j = 0; j < s.length; j++) {
        var c = s.charCodeAt(j), len = (c >= 0xD800 && c <= 0xDBFF) ? 2 : 1, ch = s.substr(j, len);
        if (!/\s/.test(ch)) {
          r.setStart(n, j); r.setEnd(n, j + len);
          var rc = r.getClientRects()[0];
          if (rc && (rc.width > 0 || rc.height > 0)) {
            all.push(ch);
            if (onlyVisible && rc.left >= -eps && rc.top >= -eps && rc.right <= vw + eps && rc.bottom <= vh + eps) vis.push(ch);
          }
        }
        j += len - 1;
      }
    }
    return { vis: vis.join(''), all: all.join('') };
  }
  var st = window.__reader.status(), out = [], all = null;
  frames.forEach(function (f, i) {
    var hidden = f.style.visibility === 'hidden', b = f.getBoundingClientRect();
    var c = collect(f, !hidden);
    if (i === 0) all = c.all;
    out.push({ left: Math.round(b.left), width: Math.round(b.width), hidden: hidden, vis: hidden ? '' : c.vis });
  });
  return JSON.stringify({ src: (frames[0].src || '').replace(/^.*\/book\//, ''), st: st, frames: out, all: all,
    vis: out.map(function (o) { return o.vis; }).join('') });
})()
