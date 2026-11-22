"""Timings of the App's page turns from out/results.jsonl (the debug log lines the checks recorded):
how long the page took to be held (copied and covered), how long after the page changed the animation
started, and how many frames it drew in how long (with animations 40 times slower while recording).

Usage: python3 -I timings.py [results.jsonl]
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HELD = re.compile(r'held after (\d+) ms \(copy (\d+), overlay (\d+), first frame (\d+)\)')
START = re.compile(r'(\w+) starts (\d+) ms after the page changed')
FRAMES = re.compile(r'(\d+) frames in (\d+) ms')


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'out', 'results.jsonl')
    rows = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            r = json.loads(line)
            log = (r.get('detail') or {}).get('log') if isinstance(r.get('detail'), dict) else None
            if not log:
                continue
            row = {'step': r['step']}
            for ln in log:
                if m := HELD.search(ln):
                    row.update(held=int(m[1]), copy=int(m[2]), overlay=int(m[3]), first_frame=int(m[4]))
                if m := START.search(ln):
                    row.update(style=m[1], start=int(m[2]))
                if m := FRAMES.search(ln):
                    row.update(frames=int(m[1]), ms=int(m[2]))
            rows.append(row)
    print(f"{'step':<38}{'style':<7}{'held':>6}{'copy':>6}{'ovl':>6}{'1st':>6}{'start':>7}{'frames':>8}{'ms':>7}{'fps':>6}")
    for r in rows:
        fps = r['frames'] * 1000 / r['ms'] if r.get('ms') else 0
        print(f"{r['step']:<38}{r.get('style', ''):<7}{r.get('held', ''):>6}{r.get('copy', ''):>6}{r.get('overlay', ''):>6}"
              f"{r.get('first_frame', ''):>6}{r.get('start', ''):>7}{r.get('frames', ''):>8}{r.get('ms', ''):>7}{fps:>6.2f}")
    for key in ('held', 'start'):
        values = sorted(r[key] for r in rows if key in r)
        if values:
            print(f'{key}: {values[0]}-{values[-1]} ms, median {values[len(values) // 2]} ms ({len(values)} turns)')
    rates = sorted(r['frames'] * 1000 / r['ms'] for r in rows if r.get('ms'))
    if rates:
        print(f'frames per second while recording: {rates[0]:.2f}-{rates[-1]:.2f}, median {rates[len(rates) // 2]:.2f}')


if __name__ == '__main__':
    main()
