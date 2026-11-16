// Cross-check verifyFast() against the full per-spread walk on desktop Chromium.
import { createRequire } from 'node:module'; import { spawn } from 'node:child_process'; import path from 'node:path';
const { chromium } = createRequire(import.meta.url)('/opt/node-tools/node_modules/playwright/index.js');
const here = path.dirname(new URL(import.meta.url).pathname);
const server = spawn(process.execPath, [path.join(here, 'server.mjs'), '8775'], { stdio: ['ignore', 'pipe', 'inherit'] });
await new Promise(r => server.stdout.once('data', r));
const b = await chromium.launch();
const base = { vertical: true, columns: 2, gap: 40, fontSize: 20, lineHeight: 1.8, letterSpacing: 0.05, indent: 1, paraSpacing: 0.5,
  fontFamily: '"ReaderImported", serif', margins: { top: 40, bottom: 40, left: 30, right: 30 } };
for (const [name, mode, s] of [['B-2col', 'B', base], ['A-2col', 'A', base], ['B-1col', 'B', { ...base, columns: 1 }], ['H-2col', 'H', { ...base, vertical: false }], ['H-1col', 'H', { ...base, vertical: false, columns: 1 }]]) {
  const page = await (await b.newContext({ viewport: { width: 1000, height: 600 } })).newPage();
  await page.goto('http://127.0.0.1:8775/reader/reader.html');
  await page.evaluate(([m, s]) => window.__reader.open({ src: '/book/zh.xhtml', mode: m, settings: s }), [mode, s]);
  const v = await page.evaluate(() => { const r = window.__reader.verifyFast(); delete r.text; return r; });
  console.log(name, JSON.stringify(v));
  // negative control: break the pagination on purpose (scroll one column too far) and expect failures
  if (name === 'B-2col') {
    const neg = await page.evaluate(() => { const S = window.__reader.state; const orig = S.geo.pageGap; S.geo.pageGap = orig + 30; const r = window.__reader.verifyFast(); S.geo.pageGap = orig; return { failCount: r.failCount, sample: r.fails.slice(0, 2) }; });
    console.log('negative-control(B, wrong scroll step)', JSON.stringify(neg));
  }
  await page.context().close();
}
await b.close(); server.kill();
