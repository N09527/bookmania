#!/bin/bash
# Stage 6: the acceptance checks of check_acceptance.py, one process per step (a failing step does not stop
# the others). Usage: ADB=/path/to/adb ./run-acceptance.sh [step ...]   (default: all, in order)
cd "$(dirname "$0")"
export OUT=${OUT:-$PWD/out/acceptance}
mkdir -p "$OUT"
STEPS=("$@")
[ ${#STEPS[@]} -eq 0 ] && STEPS=(warmup fonts glyphs "positions vertical" "positions horizontal" corrupt cleanup)
for s in "${STEPS[@]}"; do
  echo "=== $(date +%T) $s" | tee -a "$OUT/parts.log"
  if [ "$s" = warmup ]; then
    python3 -I ../stage5/check_stage5.py warmup 14 16
  else
    python3 -I check_acceptance.py $s
  fi
  echo "=== $(date +%T) end $s (exit $?)" | tee -a "$OUT/parts.log"
done
