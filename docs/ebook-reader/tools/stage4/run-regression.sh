#!/bin/bash
# After the two-column refactor of the shell: one column again (as in stage 2), and complete
# pagination while the ruby fix is active (font sizes where it switches on, see ruby_check.py).
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
export OUT="${OUT:-$HERE/out}"  # results, logs and screenshots (out/shots)
while read -r manga chapter label side opts; do
  [ -z "$manga" ] && continue
  python3 verify_columns.py $manga $chapter $label $opts < /dev/null 2>&1 | tail -2
  python3 summarize2.py out/runs/$label.jsonl $side
  [ -f out/runs/$label.ruby.jsonl ] && python3 summarize_ruby.py out/runs/$label.ruby.jsonl
done <<'LIST'
14 16 v-epub-1col-default - --columns off
8 10 h-epub-1col-default - --columns off
14 16 v-epub-1col-size30-rubyfix - --columns off --font-size 30
14 16 v-epub-2col-size24-rubyfix right --columns on --font-size 24
LIST
