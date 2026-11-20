// Where the first blocks of the first frame's document fall: the page of each line of the headings and
// paragraphs (with their orphans/widows), and the page, size and containment of pictures; optionally
// after an extra CSS (to test why a page ends early).
(function (extraCss) {
  var f = document.querySelector('#stage iframe'), d = f.contentDocument, w = f.contentWindow;
  var st = window.__reader.status(), V = st.mode === 'V', P = 8;
  var el = d.getElementById('__gap_experiment');
  if (!el) { el = d.createElement('style'); el.id = '__gap_experiment'; (d.head || d.documentElement).appendChild(el); }
  el.textContent = extraCss || '';
  d.documentElement.getBoundingClientRect();
  var pageBox = V ? f.clientHeight - 2 * P : f.clientWidth - 2 * P, step = pageBox + 24;
  function pageOf(r) { return Math.floor(((V ? r.top + w.scrollY : r.left + w.scrollX) - P + 1) / step); }
  var r = d.createRange(), out = [];
  var blocks = d.querySelectorAll('h1, h2, h3, p, figure, img, svg');
  for (var i = 0; i < Math.min(blocks.length, 8); i++) {
    var tag = blocks[i].localName;
    if (tag === 'img' || tag === 'svg' || tag === 'figure') {
      var b = blocks[i].getBoundingClientRect(), pg = pageOf(b);
      // inside: the whole picture lies within its page box (P .. P + page box, in document coordinates)
      var x0 = b.left + w.scrollX, y0 = b.top + w.scrollY, s0 = pg * step + P;
      var inside = V ? (x0 >= P - 0.5 && x0 + b.width <= f.clientWidth - P + 0.5 && y0 >= s0 - 0.5 && y0 + b.height <= s0 + pageBox + 0.5)
                     : (y0 >= P - 0.5 && y0 + b.height <= f.clientHeight - P + 0.5 && x0 >= s0 - 0.5 && x0 + b.width <= s0 + pageBox + 0.5);
      out.push({ tag: tag, page: pg, size: [Math.round(b.width), Math.round(b.height)], inside: inside,
        breakInside: d.defaultView.getComputedStyle(blocks[i]).breakInside });
      continue;
    }
    r.selectNodeContents(blocks[i]);
    var lines = {}, rects = r.getClientRects();
    for (var j = 0; j < rects.length; j++) {
      // one entry per line: lines are columns of text (x) in vertical mode, rows (y) in horizontal mode
      var key = Math.round(V ? rects[j].left : rects[j].top) + '@' + pageOf(rects[j]);
      lines[key] = pageOf(rects[j]);
    }
    var pages = Object.keys(lines).map(function (k) { return lines[k]; });
    var cs = d.defaultView.getComputedStyle(blocks[i]);
    out.push({ tag: tag, text: blocks[i].textContent.trim().slice(0, 8), lines: pages.length, pages: pages.sort(),
      orphans: cs.orphans, widows: cs.widows, margin: V ? [cs.marginRight, cs.marginLeft] : [cs.marginTop, cs.marginBottom] });
  }
  return JSON.stringify({ css: extraCss || '', pageBox: pageBox, blocks: out });
})
