"""Bookmania 1.0.0 (rebrand) on the emulator, release App:
  1. the new release APK installed over the release App 1.10.3 (162) that is there: an update in place;
  2. the library is still there after the update;
  3. Settings > About: Bookmania's version and links only (no Mihon website, Discord or translation links);
  4. no Firebase lines in the App's log since the update.
Usage: ADB=... OUT=<dir> python3 -I verify_rebrand.py <universal release APK>
The Firebase check reads the whole system log, so lines of other Apps on the emulator count too (stage 9: the
older debug App, which still had Firebase); see the stage 9 report, 3.2."""
import json
import os
import subprocess
import sys
import time

os.environ['PKG'] = 'io.github.n09527.bookmania'
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'stage3'))
sys.dont_write_bytecode = True
import drive as d  # noqa: E402

REL = 'io.github.n09527.bookmania'
OUT = os.environ['OUT']
os.makedirs(OUT, exist_ok=True)
results = []


def check(name, ok, detail=None):
    results.append({'check': name, 'ok': bool(ok), 'detail': detail})
    print('PASS' if ok else 'FAIL', name, json.dumps(detail, ensure_ascii=False)[:600], flush=True)


def version():
    out = d.shell(f'dumpsys package {REL}')
    name = next((l.split('=', 1)[1].strip() for l in out.splitlines() if 'versionName=' in l), None)
    code = next((l.strip().split()[0].split('=', 1)[1] for l in out.splitlines() if 'versionCode=' in l), None)
    return name, code


def shot(name):
    png = d.adb('exec-out', 'screencap', '-p', text=False, timeout=60)
    with open(os.path.join(OUT, name + '.png'), 'wb') as f:
        f.write(png)


def texts():
    return [n['text'] or n['desc'] for n in d.nodes() if n['text'] or n['desc']]


def main(apk):
    before = version()
    d.shell('logcat -c')
    r = subprocess.run([d.ADB, 'install', '-r', apk], capture_output=True, text=True, timeout=600)
    after = version()
    check('installed over the existing release App (update in place)',
          'Success' in r.stdout and after == ('1.0.0', '200'),
          {'before': before, 'after': after, 'adb': (r.stdout + r.stderr).strip()[-200:]})

    d.shell(f'am force-stop {REL}')
    d.shell(f'am start -n {REL}/eu.kanade.tachiyomi.ui.main.MainActivity')
    found = []
    for _ in range(20):
        time.sleep(5)
        found = texts()
        if any('測試書' in t for t in found):
            break
    shot('rebrand-01-library')
    check('the library is still there after the update', any('測試書' in t for t in found),
          [t for t in found if '測試' in t][:8])

    # The overflow menu (⋮) of the main screen, then About.
    more = None
    for _ in range(4):
        ns = d.nodes()
        more = next((n for n in ns if n['desc'] in ('More options', 'More', '更多選項', '更多')), None)
        if more:
            break
        time.sleep(3)
    if more is None:
        check('About reached', False, texts()[:20])
        return
    d.tap(more['x'], more['y'], 4)
    about = d.find('About') or d.find('關於')  # the item reads "About\nv1.0.0"
    if about is None:
        shot('rebrand-02-menu')
        check('About reached', False, texts()[:30])
        return
    check('the menu shows About with v1.0.0', 'v1.0.0' in (about['text'] or ''), about['text'])
    d.tap(about['x'], about['y'], 8)
    seen = texts()
    shot('rebrand-03-about')
    # Scroll to the end of the About screen, where the links are.
    d.swipe(540, 1500, 540, 500, 600, 3)
    seen_end = texts()
    shot('rebrand-04-about-end')
    all_texts = seen + seen_end
    check('About shows "Release 1.0.0"', 'Release 1.0.0' in all_texts, [t for t in all_texts if 'Release' in t or 'Debug' in t])
    check('About has no translation links', not any(t in all_texts for t in ('Help translate', 'Helpful translation links')),
          [t for t in all_texts if 'ranslat' in t])
    check('About links: GitHub only (no Website, no Discord)',
          'GitHub' in all_texts and 'Discord' not in all_texts and 'Website' not in all_texts,
          [t for t in all_texts if t in ('GitHub', 'Discord', 'Website')])
    time.sleep(5)
    log = d.shell('logcat -d')
    firebase = [l for l in log.splitlines() if 'Firebase' in l or 'firebase' in l]
    github = [l for l in log.splitlines() if 'api.github.com' in l]
    check('no Firebase lines in the log since the update', not firebase, firebase[:3])
    check('no api.github.com in the log (no update check)', not github, github[:3])
    tagged = [l for l in log.splitlines() if ' Bookmania' in l and ': ' in l][:3]
    print('.. log lines with the tag Bookmania (sample):', tagged, flush=True)


try:
    main(sys.argv[1])
finally:
    with open(os.path.join(OUT, 'results.jsonl'), 'w', encoding='utf-8') as f:
        for r in results:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')
