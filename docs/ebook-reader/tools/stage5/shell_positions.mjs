// Desktop Chromium check of the shell's reading-position functions (position, restore by location,
// by text and by fraction, goProgress), before they are tried in the app. Serves the shell from the
// app assets and the book from an extracted EPUB folder through request interception, under the same
// virtual origin as the app.
//
// Usage: node shell_positions.mjs <extracted book folder> <document path in the book> [vertical 0|1] [columns off|on]
// Needs the Playwright that is installed in this environment (require('playwright')).
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const SHELL = path.resolve(HERE, '../../../../app/src/main/assets/ebook');
const ORIGIN = 'https://appassets.androidplatform.net';
const [bookDir, docPath, verticalArg = '1', columns = 'off'] = process.argv.slice(2);
const vertical = verticalArg === '1';

const types = { html: 'text/html', js: 'text/javascript', xhtml: 'application/xhtml+xml', css: 'text/css',
  png: 'image/png', jpg: 'image/jpeg', svg: 'image/svg+xml' };
const settings = {
  vertical, rtl: vertical, columns, font: null, fontSize: 20, lineHeight: 1.8, letterSpacing: 0, indent: null,
  paragraphSpacing: null, margins: { top: 32, bottom: 32, left: 20, right: 20 }, background: '#FFFFFF',
  textColor: '#000000', dark: false,
};
const results = [];
function check(name, ok, detail) {
  results.push({ name, ok: !!ok, detail });
  console.log((ok ? 'PASS ' : 'FAIL ') + name + ' ' + JSON.stringify(detail));
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 412, height: 732 } });
await page.route(ORIGIN + '/**', (route) => {
  const url = new URL(route.request().url());
  let file;
  if (url.pathname.startsWith('/shell/')) file = path.join(SHELL, url.pathname.slice('/shell/'.length));
  else if (url.pathname.startsWith('/book/')) file = path.join(bookDir, decodeURIComponent(url.pathname.slice('/book/'.length)));
  if (!file || !fs.existsSync(file)) return route.fulfill({ status: 404, body: '' });
  const ext = path.extname(file).slice(1).toLowerCase();
  route.fulfill({ status: 200, contentType: types[ext] || 'application/octet-stream', body: fs.readFileSync(file) });
});
await page.goto(ORIGIN + '/shell/reader.html');

async function waitReady() {
  for (let i = 0; i < 200; i++) {
    const st = await page.evaluate(() => window.__reader.status());
    if (st.ready) return st;
    await page.waitForTimeout(50);
  }
  throw new Error('layout timed out');
}
async function open(target) {
  await page.evaluate(([src, s, t]) => window.__reader.open(src, s, t), [ORIGIN + '/book/' + docPath, settings, target]);
  return waitReady();
}
const pos = () => page.evaluate(() => window.__reader.position());

let st = await open('start');
check('opens', st.pages > 3, st);
const target = Math.min(st.pages - 1, Math.max(2, Math.floor(st.pages / 2)) - (Math.floor(st.pages / 2) % (columns === 'on' ? 2 : 1)));
await page.evaluate((k) => window.__reader.goPage(k), target);
const saved = await pos();
check('position on a middle page', saved.location && saved.text.length > 0 && saved.page === target, saved);
const progression = saved.before / saved.chars;

// 1. reopen with the full saved position
st = await open({ location: saved.location, text: saved.text, progression });
let p = await pos();
check('restore by location: same page and character', st.page === saved.page && JSON.stringify(p.location) === JSON.stringify(saved.location), { st, p });

// 2. location wrong (e.g. the document changed), text still there
st = await open({ location: [saved.location[0] + 7, 0], text: saved.text, progression });
p = await pos();
check('restore by text when the location does not match', st.page === saved.page && p.text === saved.text, { st, p });

// 3. only the fraction
st = await open({ progression });
p = await pos();
check('restore by fraction', st.page === saved.page && p.before === saved.before, { st, p, progression });

// 3b. the fraction alone gives back the first character of every page (no rounding to the character
// before it, which can be on the previous page)
{
  const starts = [];
  for (let k = 0; k < st.pages; k += (columns === 'on' ? 2 : 1)) {
    await open('start');
    await page.evaluate((n) => window.__reader.goPage(n), k);
    const q = await pos();
    if (q.location) starts.push(q);
  }
  const wrong = [];
  for (const q of starts) {
    await open({ progression: q.before / q.chars });
    const r = await pos();
    if (r.before !== q.before || r.page !== q.page) wrong.push({ page: q.page, before: q.before, got: r.before, gotPage: r.page });
  }
  check('restore by fraction, first character of every page', starts.length > 2 && wrong.length === 0, { pages: starts.length, wrong });
}

// 4. relayout with another font size keeps the restored character on screen
st = await open({ location: saved.location, text: saved.text, progression });
await page.evaluate((s) => window.__reader.relayout(Object.assign({}, s, { fontSize: 26 })), settings);
st = await waitReady();
p = await pos();
check('font size change keeps the restored character', JSON.stringify(p.location) === JSON.stringify(saved.location), { st, p });
await page.evaluate((s) => window.__reader.relayout(s), settings);
st = await waitReady();

// 5. goProgress
await page.evaluate(() => window.__reader.goProgress(0));
p = await pos();
check('goProgress(0) is the first page', p.page === 0, p);
await page.evaluate(() => window.__reader.goProgress(1));
p = await pos();
const last = st.pages - 1 - ((st.pages - 1) % (columns === 'on' ? 2 : 1));
check('goProgress(1) is the last page', p.page === last, { p, last });
await page.evaluate(() => window.__reader.goProgress(0.5));
p = await pos();
await page.evaluate((k) => window.__reader.goPage(k), p.page + (columns === 'on' ? 2 : 1));
const nextPage = await pos();
const middle = Math.floor(0.5 * p.chars);
// the page shown starts at or before the middle character, and the next page starts after it
check('goProgress(0.5) shows the page with the middle character', p.before <= middle && (nextPage.page === p.page || nextPage.before > middle),
  { p, nextPage, middle });

// 6. text that is not in the document, no location: falls back to the fraction
st = await open({ text: 'XXXXXXXXXXXX', progression: 0.5 });
p = await pos();
check('unknown text falls back to the fraction', p.before === Math.floor(0.5 * p.chars), { st, p });

await browser.close();
const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
