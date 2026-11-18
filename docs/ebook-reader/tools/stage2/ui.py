"""Tiny uiautomator helper. Usage:
  python3 -I ui.py dump                 -> list visible nodes with text/desc and centres
  python3 -I ui.py tap "<substring>"    -> tap the first node whose text or content-desc contains it
  python3 -I ui.py has "<substring>"    -> exit 0 if such a node exists
"""
import os, re, subprocess, sys, xml.etree.ElementTree as ET
ADB = os.environ.get('ADB', 'adb')

def nodes():
    subprocess.run([ADB, 'shell', 'uiautomator', 'dump', '/sdcard/ui.xml'], capture_output=True, timeout=120)
    raw = subprocess.run([ADB, 'exec-out', 'cat', '/sdcard/ui.xml'], capture_output=True, timeout=60).stdout
    try:
        root = ET.fromstring(raw.decode('utf-8', 'replace'))
    except ET.ParseError:
        return []
    out = []
    for n in root.iter('node'):
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', n.get('bounds', ''))
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        out.append({'text': n.get('text', ''), 'desc': n.get('content-desc', ''), 'cls': n.get('class', ''),
                    'res': n.get('resource-id', ''), 'x': (x1 + x2) // 2, 'y': (y1 + y2) // 2, 'b': (x1, y1, x2, y2)})
    return out

def find(sub):
    for n in nodes():
        if sub in n['text'] or sub in n['desc'] or (sub.startswith('id:') and n['res'].endswith(sub[3:])):
            return n
    return None

cmd = sys.argv[1]
if cmd == 'dump':
    for n in nodes():
        if n['text'] or n['desc'] or n['res']:
            print(f"{n['x']:5d},{n['y']:5d}  {n['cls'].split('.')[-1]:16s} {n['res'].split('/')[-1]:22s} {n['text'][:40]!r} {n['desc'][:30]!r}")
elif cmd in ('tap', 'has'):
    n = find(sys.argv[2])
    if not n:
        print('not found:', sys.argv[2]); sys.exit(1)
    if cmd == 'tap':
        subprocess.run([ADB, 'shell', 'input', 'tap', str(n['x']), str(n['y'])], timeout=60)
    print('found', n['text'] or n['desc'] or n['res'], n['x'], n['y'])
