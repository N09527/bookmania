(function () {
  var f = document.querySelector('#stage iframe');
  if (!f || !window.__reader) return JSON.stringify({ none: true });
  var st = window.__reader.status();
  var d = f.contentDocument, vw = f.clientWidth, vh = f.clientHeight, eps = 0.5;
  var src = (f.src || '').replace(/^.*\/book\//, '');
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
          if (rc.left >= -eps && rc.top >= -eps && rc.right <= vw + eps && rc.bottom <= vh + eps) vis.push(ch);
        }
      }
      j += len - 1;
    }
  }
  return JSON.stringify({ src: src, st: st, vis: vis.join(''), all: all.join('') });
})()
