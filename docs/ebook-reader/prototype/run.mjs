// Prototype verification runner (Playwright + pre-installed Chromium).
// Usage: node run.mjs <outDir> [--no-column-wrap]
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
const { chromium } = createRequire(import.meta.url)('/opt/node-tools/node_modules/playwright/index.js');
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const outDir = path.resolve(process.argv[2] || path.join(here, 'out'));
const disableWrap = process.argv.includes('--no-column-wrap');
fs.mkdirSync(outDir, { recursive: true });
const PORT = 8765 + (disableWrap ? 1 : 0);
const server = spawn(process.execPath, [path.join(here, 'server.mjs'), String(PORT)], { stdio: ['ignore', 'pipe', 'inherit'] });
await new Promise(r => server.stdout.once('data', r));

const args = disableWrap ? ['--disable-blink-features=MulticolColumnWrapping'] : [];
const browser = await chromium.launch({ args });
const report = { browser: browser.version(), flags: args, cases: [] };

const baseSettings = {
  vertical: true, columns: 2, gap: 40, fontSize: 20, lineHeight: 1.8, letterSpacing: 0.05, indent: 1, paraSpacing: 0.5,
  fontFamily: '"ReaderImported", "Noto Sans CJK TC", serif', margins: { top: 40, bottom: 40, left: 30, right: 30 },
};

async function runCase(name, mode, settings, { shots = [], dsf = 1 } = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 600 }, deviceScaleFactor: dsf });
  const page = await ctx.newPage();
  const external = [], consoleErrors = [];
  await page.route('**/*', route => {
    const u = new URL(route.request().url());
    if (u.hostname !== '127.0.0.1') { external.push(route.request().url()); return route.abort(); }
    return route.continue();
  });
  page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  await page.goto(`http://127.0.0.1:${PORT}/reader/reader.html`);
  await page.evaluate(() => { window.__msgs = []; addEventListener('message', e => window.__msgs.push(String(e.data))); });
  const opened = await page.evaluate(([mode, s]) => window.__reader.open({ src: '/book/zh.xhtml', mode, settings: s }), [mode, settings]);
  const an = await page.evaluate(() => window.__reader.analyze());

  // Walk every spread; concatenate visible characters in reading order.
  const seq = []; let partial = 0; const perSpread = [];
  for (let k = 0; k < an.spreads; k++) {
    const v = await page.evaluate(k => window.__reader.visibleAt(k), k);
    partial += v.partial; perSpread.push(v.columns);
    for (const list of v.lists) seq.push(...list);
  }
  let missing = 0, dup = 0, outOfOrder = 0; const seen = new Set();
  for (let i = 0; i < seq.length; i++) { if (seen.has(seq[i])) dup++; seen.add(seq[i]); if (i && seq[i] < seq[i - 1]) outOfOrder++; }
  for (let i = 0; i < an.totalChars; i++) if (!seen.has(i)) missing++;

  for (const k of shots) {
    if (k >= an.spreads) continue;
    await page.evaluate(k => window.__reader.goSpread(k), k);
    await page.screenshot({ path: path.join(outDir, `${name}-spread${k}.png`) });
  }
  const frames = await page.evaluate(() => window.__reader.frameInfo());
  const msgs = await page.evaluate(() => window.__msgs);
  const res = { name, mode, columnsSetting: settings.columns, vertical: settings.vertical, supportsColumnWrap: opened.supportsColumnWrap,
    frames: opened.frames, timings: opened.timings, totalChars: an.totalChars, layoutColumns: an.columns, spreads: an.spreads,
    monotonicViolations: an.monotonicViolations, straddles: an.straddles, inlineOverflow: an.inlineOverflow, noRect: an.noRect,
    overhang: an.overhang, columnCountFromScroll: an.columnCountFromScroll,
    walk: { visibleCharsCounted: seq.length, missing, duplicated: dup, outOfOrder, partiallyVisible: partial },
    firstSpreads: perSpread.slice(0, 3), frameInfo: frames, bookScriptMessages: msgs, externalRequests: external, consoleErrors };
  return { res, page, ctx, an };
}

const findIdx = (text, needle) => { const t = text.replace(/\s/g, ''); return t.indexOf(needle); };

// 1) Main matrix
const cases = [
  ['A-vertical-2col', 'A', { ...baseSettings }],
  ['B-vertical-2col', 'B', { ...baseSettings }],
  ['B-vertical-1col', 'B', { ...baseSettings, columns: 1 }],
  ['A-vertical-1col', 'A', { ...baseSettings, columns: 1 }],
  ['H-horizontal-2col', 'H', { ...baseSettings, vertical: false }],
  ['H-horizontal-1col', 'H', { ...baseSettings, vertical: false, columns: 1 }],
];
for (const [name, mode, s] of cases) {
  const { res, page, ctx, an } = await runCase(name, mode, s, { shots: [0, 1], dsf: 1 });
  // screenshot of the spread containing the figure and the security probe paragraph
  const figPara = findIdx(an.text, '【第３１段】');
  const secPara = findIdx(an.text, '【安全測試】');
  for (const [label, idx] of [['figure', figPara], ['security', secPara]]) {
    if (idx < 0) continue;
    const k = await page.evaluate(i => window.__reader.goToChar(i), idx);
    await page.screenshot({ path: path.join(outDir, `${name}-${label}-spread${k}.png`) });
    if (label === 'security') {
      const pts = await page.evaluate(() => window.__reader.linkRects('#note1'));
      res.footnoteLinkHit = pts.length ? await page.evaluate(([x, y]) => window.__reader.hit(x, y), [pts[0].x, pts[0].y]) : 'link not visible on this spread';
    }
  }
  report.cases.push(res);
  await ctx.close();
}

// 2) Reading-location restore across settings changes (vertical two-column first).
async function locationTest(name, mode, s, changes) {
  const { page, ctx, an } = await runCase(name, mode, s);
  const k0 = Math.min(5, an.spreads - 1);
  await page.evaluate(k => window.__reader.goSpread(k), k0);
  const loc = await page.evaluate(() => window.__reader.location());
  const steps = [];
  for (const [label, patch] of changes) {
    const ns = { ...s, ...patch, margins: { ...s.margins, ...(patch.margins || {}) } };
    const rl = await page.evaluate(ns => window.__reader.relayout(ns), ns);
    await page.evaluate(() => window.__reader.analyze());
    const k = await page.evaluate(i => window.__reader.goToChar(i), loc);
    const v = await page.evaluate(k => window.__reader.visibleAt(k), k);
    const visible = v.lists.some(a => a.includes(loc));
    const firstCol = v.lists.find(a => a.length) || [];
    steps.push({ change: label, spread: k, locVisible: visible, newFirstChar: firstCol[0], relayoutMs: Math.round(rl.relayoutMs) });
  }
  await ctx.close();
  return { name, startSpread: k0, locationCharIndex: loc, steps };
}
report.location = [];
report.location.push(await locationTest('loc-B', 'B', { ...baseSettings }, [
  ['fontSize 20→26', { fontSize: 26 }], ['lineHeight 1.8→2.2', { fontSize: 26, lineHeight: 2.2 }],
  ['margins wider', { fontSize: 26, lineHeight: 2.2, margins: { left: 80, right: 80 } }], ['back to defaults', {}],
]));
if (report.cases[0].supportsColumnWrap) report.location.push(await locationTest('loc-A', 'A', { ...baseSettings }, [
  ['fontSize 20→26', { fontSize: 26 }], ['letterSpacing 0.05→0.2', { fontSize: 26, letterSpacing: 0.2 }], ['back to defaults', {}],
]));
report.location.push(await locationTest('loc-H', 'H', { ...baseSettings, vertical: false }, [
  ['fontSize 20→26', { fontSize: 26 }], ['indent 1→2, paraSpacing 0.5→1.5', { fontSize: 26, indent: 2, paraSpacing: 1.5 }], ['back to defaults', {}],
]));

// 3) A screenshot set at 2x for the person reading the report.
for (const [name, mode, s] of [['A-vertical-2col', 'A', baseSettings], ['B-vertical-2col', 'B', baseSettings]]) {
  const { ctx } = await runCase(`${name}@2x`, mode, s, { shots: [0], dsf: 2 });
  await ctx.close();
}

fs.writeFileSync(path.join(outDir, 'report.json'), JSON.stringify(report, null, 2));
await browser.close(); server.kill();
console.log(JSON.stringify({ browser: report.browser, flags: report.flags, cases: report.cases.map(c => ({ name: c.name, supportsColumnWrap: c.supportsColumnWrap,
  frames: c.frames, chars: c.totalChars, spreads: c.spreads, mono: c.monotonicViolations, straddles: c.straddles, inlineOverflow: c.inlineOverflow,
  walk: c.walk, timings: c.timings, script: c.bookScriptMessages, ext: c.externalRequests, titles: c.frameInfo.map(f => f.title),
  wm: c.frameInfo.map(f => f.writingMode), font: c.frameInfo.map(f => f.importedFontLoaded), hit: c.footnoteLinkHit, errors: c.consoleErrors })), location: report.location }, null, 1));
