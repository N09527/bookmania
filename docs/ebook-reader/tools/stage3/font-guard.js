// Tries to load fonts from URLs that must be refused by the request handler, plus (optionally) the
// imported font given as ?id. Resolves to a JSON string {url: "loaded" | "error: ..."}.
(function (goodId) {
  var base = location.origin + '/fonts/';
  var urls = [
    // Encoded slashes reach the handler as "../../shared_prefs/…" (a plain "../" is resolved by the URL parser first).
    base + '..%2F..%2Fshared_prefs%2Fio.github.n09527.bookmania.debug_preferences.xml',
    base + '0123456789abcdef0123456789abcdef',
    base + 'ABCDEF0123456789ABCDEF0123456789',
    base + (goodId || '') + '.ttf',
    'https://example.com/font.ttf'
  ];
  if (goodId) urls.push(base + goodId);
  return Promise.all(urls.map(function (u, i) {
    var face = new FontFace('Guard' + i, 'url("' + u + '")');
    return face.load().then(function () { return [u, 'loaded']; }, function (e) { return [u, 'error: ' + (e && e.name)]; });
  })).then(function (pairs) {
    var o = {};
    pairs.forEach(function (p) { o[p[0].replace(location.origin, '')] = p[1]; });
    return JSON.stringify(o);
  });
})
