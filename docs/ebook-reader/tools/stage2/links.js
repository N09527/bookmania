(function () {
  var f = document.querySelector('#stage iframe'), fr = f.getBoundingClientRect(), d = f.contentDocument, out = [];
  var as = d.querySelectorAll('a[href]');
  for (var i = 0; i < as.length; i++) {
    var a = as[i], r = a.getClientRects()[0];
    if (r && r.right > 0 && r.left < f.clientWidth && r.bottom > 0 && r.top < f.clientHeight)
      out.push({ href: a.getAttribute('href'), x: Math.round((fr.left + r.left + r.width / 2) * devicePixelRatio), y: Math.round((fr.top + r.top + r.height / 2) * devicePixelRatio) });
  }
  return JSON.stringify(out);
})()
