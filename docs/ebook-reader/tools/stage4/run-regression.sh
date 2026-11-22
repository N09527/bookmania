#!/bin/bash
# After the two-column refactor of the shell: one column again (as in stage 2), and complete
# pagination with one column while the ruby fix is active (font size 30, see ruby_check.py). Two
# columns with the fix active are covered by run-matrix.sh (vertical EPUB in portrait at the default
# size: the fix is on for every chapter file, see the .ruby.jsonl summaries).
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
export OUT="${OUT:-$HERE/out}"  # results, logs and screenshots (out/shots)
while read -r manga chapter label side opts; do
  [ -z "$manga" ] && continue
  python3 verify_columns.py $manga $chapter $label $opts < /dev/null 2>&1 | tail -2
  python3 summarize2.py "$OUT/runs/$label.jsonl" $side
  [ -f "$OUT/runs/$label.ruby.jsonl" ] && python3 summarize_ruby.py "$OUT/runs/$label.ruby.jsonl"
done <<'LIST'
14 16 v-epub-1col-default - --columns off
8 10 h-epub-1col-default - --columns off
14 16 v-epub-1col-size30-rubyfix - --columns off --font-size 30
LIST
