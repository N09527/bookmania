// Minimal static server for the prototype. Book documents get a strict CSP,
// mirroring what the Android WebView request handler would return.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const root = path.dirname(new URL(import.meta.url).pathname);
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.xhtml': 'application/xhtml+xml; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.png': 'image/png', '.jpg': 'image/jpeg' };
const BOOK_CSP = "default-src 'self'; script-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; media-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
const port = Number(process.argv[2] || 8765);
http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const rel = decodeURIComponent(u.pathname).replace(/^\/+/, '');
  const file = path.join(root, rel);
  if (!file.startsWith(root + path.sep) || !['reader/', 'book/', 'fonts/'].some(p => rel.startsWith(p))) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end(); }
    const headers = { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' };
    if (rel.startsWith('book/')) headers['Content-Security-Policy'] = BOOK_CSP;
    res.writeHead(200, headers); res.end(data);
  });
}).listen(port, '127.0.0.1', () => console.log('listening ' + port));
