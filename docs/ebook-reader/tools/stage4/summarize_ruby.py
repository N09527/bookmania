"""Prints the ruby placement recorded by verify_columns.py for each document of a run
(<label>.ruby.jsonl): whether the reader's ruby fix was on, and how many annotations were misplaced.
Usage: summarize_ruby.py out/runs/<label>.ruby.jsonl"""
import json
import sys

path = sys.argv[1]
rows = [json.loads(l) for l in open(path, encoding='utf-8') if l.strip()]
bad = sum(r.get('misplaced') or 0 for r in rows)
for r in rows:
    print(f"  {r['src']}: ruby fix {r.get('rubyFix')}, annotations {r.get('ruby')}, misplaced {r.get('misplaced')}"
          + (f", e.g. {r.get('examples')[:2]}" if r.get('misplaced') else '') + (f", error {r['error']}" if r.get('error') else ''))
print(f"{path.split('/')[-1]}: documents {len(rows)}, misplaced ruby in total: {bad}")
