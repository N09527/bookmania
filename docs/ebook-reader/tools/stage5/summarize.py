"""Summary of out/results.jsonl: per step, checks passed / run, and the failed checks.

Usage: python3 -I summarize.py [results.jsonl]
When a step was run more than once (a rerun after an interrupted run), each run is listed; a run is the
sequence of checks of one step between two other steps.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'out', 'results.jsonl')
    runs = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            r = json.loads(line)
            if not runs or runs[-1]['step'] != r['step']:
                runs.append({'step': r['step'], 'start': r['time'], 'checks': []})
            runs[-1]['checks'].append(r)
    total = passed = 0
    for run in runs:
        ok = sum(c['ok'] for c in run['checks'])
        total += len(run['checks'])
        passed += ok
        print(f"{run['start']}  {run['step']:<45} {ok}/{len(run['checks'])}")
        for c in run['checks']:
            if not c['ok']:
                print(f"    FAIL {c['check']}: {json.dumps(c['detail'], ensure_ascii=False)[:600]}")
    print(f'{passed}/{total} checks passed in {len(runs)} runs')


if __name__ == '__main__':
    main()
