#!/bin/bash
# Prints compile errors of an xcodebuild log as GitHub error annotations: 10 of them, starting with the error number
# given (1-based), each distinct error once. Without errors in the log, the last lines of the log are reported.
log="$1"
first="${2:-1}"
[ -f "$log" ] || { echo "::error title=xcodebuild::no build log"; exit 0; }
errors=$(grep -E ': error: |^error: ' "$log" | sed 's/\x1b\[[0-9;]*m//g' | awk '!seen[$0]++')
if [ -z "$errors" ]; then
  if [ "$first" = "1" ]; then
    tail -20 "$log" | tr '\n' ' ' | cut -c1-3000 | sed 's/^/::error title=xcodebuild (no error lines)::/'
    echo
  fi
  exit 0
fi
echo "$errors" | tail -n +"$first" | head -10 | while IFS= read -r line; do
  if [[ "$line" =~ ^(/[^:]+):([0-9]+):([0-9]+):\ error:\ (.*)$ ]]; then
    file="${BASH_REMATCH[1]#"$GITHUB_WORKSPACE/"}"
    echo "::error file=${file},line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::${BASH_REMATCH[4]}"
  else
    echo "::error title=xcodebuild::${line}"
  fi
done
