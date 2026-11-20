#!/bin/bash
# Ruby placement with the reader's own fix, in the configurations the stage 1 note and the two-column
# shell need: vertical and horizontal, one and two columns (portrait; two columns forced on).
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
export OUT="${OUT:-$HERE/out}"  # results, logs and screenshots (out/shots)
python3 ruby_check.py 14 16 --columns off --label v-epub < /dev/null
python3 ruby_check.py 14 16 --columns on --label v-epub < /dev/null
python3 ruby_check.py 8 10 --columns off --label h-epub < /dev/null
python3 ruby_check.py 8 10 --columns on --label h-epub < /dev/null
