"""Summary of out/results.jsonl for stage 5.5.

Usage: python3 -I summarize.py [results.jsonl]
Lists every run of a step (a run is the sequence of checks of one step between two other steps, so a
re-analysis of a recording is a run of its own), then the final result of each check: its last result.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'out', 'results.jsonl')
    runs = []
    with open(path, encoding='utf-8') as f:
        rows = [json.loads(line) for line in f if line.strip()]
    for r in rows:
        if not runs or runs[-1]['step'] != r['step']:
            runs.append({'step': r['step'], 'start': r['time'], 'checks': []})
        runs[-1]['checks'].append(r)
    print('Runs:')
    for run in runs:
        ok = sum(c['ok'] for c in run['checks'])
        print(f"  {run['start']}  {run['step']:<40} {ok}/{len(run['checks'])}")
    final = {}
    for r in rows:
        final[(r['step'], r['check'])] = r
    print('Final (last result of each check):')
    steps = []
    for (step, _), r in final.items():
        if step not in steps:
            steps.append(step)
    passed = 0
    for step in steps:
        checks = [r for (s, _), r in final.items() if s == step]
        ok = sum(c['ok'] for c in checks)
        passed += ok
        print(f'  {step:<40} {ok}/{len(checks)}')
        for c in checks:
            if not c['ok']:
                print(f"      FAIL {c['check']}: {json.dumps(c['detail'], ensure_ascii=False)[:500]}")
    print(f'{passed}/{len(final)} checks passed ({len(rows)} results in {len(runs)} runs)')


if __name__ == '__main__':
    main()
