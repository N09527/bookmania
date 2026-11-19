#!/bin/bash
# Opens a work's details page (so Local Source rescans its folder and new files become chapters),
# then lists its chapters from the database. Usage: refresh-work.sh <manga id>
ADB=${ADB:-adb}; PKG=${PKG:-io.github.n09527.bookmania.debug}
HERE=$(cd "$(dirname "$0")" && pwd); OUT=${OUT:-$HERE/out}; mkdir -p "$OUT"
$ADB shell am force-stop $PKG; sleep 2
$ADB shell am start -n $PKG/eu.kanade.tachiyomi.ui.main.MainActivity -a eu.kanade.tachiyomi.SHOW_MANGA --el manga "$1" >/dev/null
sleep 40
# Copy the WAL as well: recent writes may not be checkpointed into the main file yet.
for f in tachiyomi.db tachiyomi.db-wal tachiyomi.db-shm; do
  $ADB exec-out run-as $PKG cat databases/$f > "$OUT/$f" 2>/dev/null || rm -f "$OUT/$f"
done
python3 - "$OUT/tachiyomi.db" "$1" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for r in c.execute("select _id, url, name from chapters where manga_id = ? order by _id", (int(sys.argv[2]),)):
    print(*r, sep='\t')
PY
