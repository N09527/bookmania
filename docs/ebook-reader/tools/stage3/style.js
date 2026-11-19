// Computed styles of the open book document, for checking the typesetting settings.
// Returns a JSON string: reader status, the settings the shell uses, the iframe box (CSS px),
// computed styles of <html>, <body> and the first <p> with text, font faces and the first
// fully visible character of the page.
(function () {
  var f = document.querySelector('#stage iframe');
  if (!f || !window.__reader) return JSON.stringify({ none: true });
  var d = f.contentDocument, w = d.defaultView;
  function pick(el) {
    if (!el) return null;
    var cs = w.getComputedStyle(el);
    return {
      tag: el.localName, fontSize: cs.fontSize, lineHeight: cs.lineHeight, letterSpacing: cs.letterSpacing,
      textIndent: cs.textIndent, fontFamily: cs.fontFamily,
      writingMode: cs.writingMode || cs.getPropertyValue('-webkit-writing-mode'),
      margin: [cs.marginTop, cs.marginRight, cs.marginBottom, cs.marginLeft]
    };
  }
  var ps = d.querySelectorAll('p'), p = null;
  for (var i = 0; i < ps.length && !p; i++) if (/\S/.test(ps[i].textContent)) p = ps[i];
  var r = f.getBoundingClientRect();
  var faces = [];
  if (d.fonts && d.fonts.forEach) d.fonts.forEach(function (ff) { faces.push(ff.family + ':' + ff.status); });
  // Fully visible characters of the page (same rule as stage2/probe.js, ruby text included), and the first one.
  var tw = d.createTreeWalker(d.body || d.documentElement, NodeFilter.SHOW_TEXT), rg = d.createRange(), first = null, idx = 0;
  var vw = f.clientWidth, vh = f.clientHeight, vis = [];
  for (var n = tw.nextNode(); n && vis.length < 400; n = tw.nextNode(), idx++) {
    for (var j = 0; j < n.data.length; j++) {
      if (/\s/.test(n.data.charAt(j))) continue;
      rg.setStart(n, j); rg.setEnd(n, j + 1);
      var rc = rg.getClientRects()[0];
      if (rc && rc.left >= -0.5 && rc.top >= -0.5 && rc.right <= vw + 0.5 && rc.bottom <= vh + 0.5) {
        if (!first) first = { node: idx, offset: j, text: n.data.substr(j, 12) };
        vis.push(n.data.charAt(j));
      }
    }
  }
  var st = window.__reader.status();
  return JSON.stringify({
    src: (f.src || '').replace(/^.*\/book\//, ''), st: st, win: [window.innerWidth, window.innerHeight],
    frame: [r.left, r.top, r.width, r.height], html: pick(d.documentElement), body: pick(d.body), p: pick(p),
    faces: faces, first: first, vis: vis.join('')
  });
})()
