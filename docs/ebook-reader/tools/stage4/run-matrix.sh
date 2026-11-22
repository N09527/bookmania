#!/bin/bash
# Two-column verification matrix (see README.md). Each line: manga chapter label expected-first-side options
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
export OUT="${OUT:-$HERE/out}"  # results, logs and screenshots (out/shots)
while read -r manga chapter label side opts; do
  [ -z "$manga" ] && continue
  python3 verify_columns.py $manga $chapter $label $opts < /dev/null 2>&1 | tail -2
  python3 summarize2.py "$OUT/runs/$label.jsonl" $side
  [ -f "$OUT/runs/$label.ruby.jsonl" ] && python3 summarize_ruby.py "$OUT/runs/$label.ruby.jsonl"
done <<'LIST'
14 16 v-epub-2col-portrait right --columns on --shot-pages 2
8 10 h-epub-2col-portrait left --columns on
14 16 v-epub-2col-ltr left --columns on --direction ltr
13 15 v-azw3-2col-landscape right --columns landscape --landscape
9 11 h-mobi6-2col-landscape left --columns landscape --landscape
3 1 v-jointmobi-2col-landscape right --columns landscape --landscape
LIST
