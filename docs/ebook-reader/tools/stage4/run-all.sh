#!/bin/bash
# Every stage 4 check on the installed debug APK, in two parts (each fits in a two-hour emulator session):
#   ./run-all.sh checks   rotation, settings panel, links, picture page, ruby (about 50 minutes)
#   ./run-all.sh pages    page-through runs: two-column matrix and single-column regression (about 100 minutes)
# Results: out/results.jsonl and the printed summaries; see README.md.
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
export OUT="${OUT:-$HERE/out}"  # results, logs and screenshots (out/shots)
part=${1:-checks}
if [ "$part" = checks ]; then
  python3 rotate_during_layout.py 14 16 rot-busy < /dev/null
  python3 panel_columns.py 14 16 < /dev/null
  python3 links2.py 14 16 links-v-epub < /dev/null
  python3 rotate_anchor.py 14 16 6 rot-v-epub < /dev/null
  python3 gap_check.py 14 16 gap-v-epub-2col < /dev/null
  ./run-ruby.sh
elif [ "$part" = pages ]; then
  ./run-matrix.sh
  ./run-regression.sh
fi
