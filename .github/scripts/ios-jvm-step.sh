#!/bin/bash
# Runs one step of the embedded JVM build (.github/workflows/ios-jvm.yml) in the runtime's jvm-ios folder, with its
# output in a log file. GitHub annotations report how it went, because the job log itself is not readable from where
# this project is developed: a notice with the time it took and the free disk space, or on failure errors with the
# last lines of the log (10 annotations of up to 30 lines, the most GitHub keeps for one step).
#   ios-jvm-step.sh NAME COMMAND [ARGS...]
set -uo pipefail
name="$1"
shift
logs="${RUNNER_TEMP:-/tmp}/ios-jvm-logs"
mkdir -p "$logs"
log="$logs/$name.log"
cd "$GITHUB_WORKSPACE/ios/Vendor/oneechan-runtime/jvm-ios" || exit 1
start=$(date +%s)
"$@" > "$log" 2>&1
status=$?
minutes=$(( ($(date +%s) - start + 59) / 60 ))
free=$(df -h "$GITHUB_WORKSPACE" | awk 'NR==2 {print $4}')
if [ "$status" -eq 0 ]; then
  echo "::notice title=$name::done in ${minutes} min; free disk ${free}; log $(wc -l < "$log") lines"
  exit 0
fi
# The last 300 lines, without colour codes, as 10 annotations of 30 lines (newlines encoded as %0A).
tail -n 300 "$log" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-400 | split -l 30 - "$logs/$name.part."
n=0
for part in "$logs/$name.part."*; do
  n=$((n + 1))
  body=$(sed 's/%/%25/g' "$part" | awk 'BEGIN { ORS = "%0A" } { print }')
  echo "::error title=$name failed (exit $status, ${minutes} min) part $n::$body"
done
exit "$status"
