// For every <ruby> in the first frame's document: the page of its base text and of its ruby text,
// computed from client rects plus the frame's scroll offset (P = 8, page step = page box + 24, as in
// reader.js). A ruby whose text lands on another page than its base is the WebView 69 problem from
// stage 1 (4.5 point 6). Optional: extraCss is added to the document first (mitigation experiments).
(function (extraCss) {
  var f = document.querySelector('#stage iframe'), d = f.contentDocument, w = f.contentWindow;
  var st = window.__reader.status(), V = st.mode === 'V', P = 8;
  if (extraCss !== null && extraCss !== undefined) {
    var el = d.getElementById('__ruby_experiment');
    if (!el) { el = d.createElement('style'); el.id = '__ruby_experiment'; (d.head || d.documentElement).appendChild(el); }
    el.textContent = extraCss;
    d.documentElement.getBoundingClientRect();
  }
  var pageBox = V ? f.clientHeight - 2 * P : f.clientWidth - 2 * P, step = pageBox + 24;
  function pageOf(r) {
    var pos = V ? r.top + w.scrollY : r.left + w.scrollX;
    return Math.floor((pos - P + 1) / step);
  }
  var out = [], bad = 0, r = d.createRange();
  Array.prototype.forEach.call(d.querySelectorAll('ruby'), function (ruby) {
    var rts = ruby.querySelectorAll('rt');
    Array.prototype.forEach.call(rts, function (rt) {
      // the base text node is the nearest preceding text sibling that is not inside rt/rp
      var base = rt.previousSibling;
      while (base && !(base.nodeType === 3 && /\S/.test(base.data)) && !(base.nodeType === 1 && base.localName === 'rb')) base = base.previousSibling;
      if (!base) return;
      r.selectNodeContents(base); var b = r.getClientRects()[0];
      r.selectNodeContents(rt); var t = r.getClientRects()[0];
      if (!b || !t) return;
      var bp = pageOf(b), tp = pageOf(t);
      if (bp !== tp) bad++;
      out.push([base.textContent.trim(), rt.textContent.trim(), bp, tp]);
    });
  });
  var cs = d.defaultView.getComputedStyle(d.body);
  return JSON.stringify({ pages: st.pages, ruby: out.length, misplaced: bad, lineHeight: cs.lineHeight,
    examples: out.filter(function (x) { return x[2] !== x[3]; }).slice(0, 6) });
})
