"""Stage 5: the backup round trip through the App's own screens (Settings > Data and storage), between
steps of check_stage5.py. The order used for the stage 5 report:

  python3 -I check_stage5.py backup_setting 16          a per-file typesetting setting, to go through the backup
  python3 -I backup_ui.py create                        creates a backup in the App; prints the file on the device
  adb pull <that file> out/                             then: python3 -I check_stage5.py backup_check out/<file>
  python3 -I check_stage5.py backup_prepare "<source|manga url|chapter url>"
  python3 -I check_stage5.py backup_setting_clear
  python3 -I backup_ui.py restore <file name>           restores it, picked in the system file picker (Downloads)
  python3 -I check_stage5.py backup_verify
  python3 -I check_stage5.py backup_setting_verify

Labels are the App's Traditional Chinese ones (the settings item "Data and storage" has no translation)
and those of the Android 8.0 file picker. Screenshots: out/shots/backup-*.png.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_stage5 as c  # noqa: E402

d = c.d
BACKUP_DIR = '/storage/emulated/0/BookmaniaStorage/backup'  # the App's storage location on the test emulator (set in Data and storage > Storage location)
DOWNLOADS = '/storage/emulated/0/Download'


def wait_label(label, tries=10, exact=True, pause=2.0):
    for _ in range(tries):
        n = d.find(label, exact=exact)
        if n:
            return n
        c.clear_dialogs()
        time.sleep(pause)
    return None


def tap(label, tries=10, exact=True, wait=3.0):
    n = wait_label(label, tries, exact)
    if not n:
        d.shot('backup-missing-' + str(abs(hash(label)) % 10000))
        raise RuntimeError(f'not found: {label}')
    d.tap(n['x'], n['y'], wait)
    return n


def open_data_settings():
    """Library > 其他 (toolbar) > 設定 > Data and storage."""
    c.stop_app(0)
    d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity')
    time.sleep(4)
    c.wait_app_drawn()
    time.sleep(4)
    c.clear_dialogs()
    tap('其他')
    tap('設定')
    tap('Data and storage')
    time.sleep(2)


def files_in(folder):
    return set(d.shell(f'ls {folder}').split())


def create():
    before = files_in(BACKUP_DIR)
    open_data_settings()
    tap('建立備份')
    d.shot('backup-1-create-dialog')
    tap('建立')
    t = time.time()
    while time.time() - t < 600:
        time.sleep(5)
        new = sorted(files_in(BACKUP_DIR) - before)
        if new:
            path = f'{BACKUP_DIR}/{new[-1]}'
            size = -1
            while True:  # written once its size stops changing
                time.sleep(5)
                s = d.shell(f'stat -c %s "{path}"').strip()
                if s == size:
                    break
                size = s
            d.shot('backup-2-created')
            print(path)
            return path
    d.shot('backup-2-no-file')
    raise RuntimeError('no backup file appeared in ' + BACKUP_DIR)


def restore(name):
    """The file is copied to Downloads first, which the file picker lists among its roots."""
    d.shell(f'cp "{BACKUP_DIR}/{name}" "{DOWNLOADS}/{name}"')
    open_data_settings()
    tap('還原備份')
    time.sleep(4)
    d.shot('backup-3-picker')
    # Android shows a chooser of the apps that can pick a file (Intent.createChooser) when there are
    # several; the system file picker is 檔案.
    if not d.find(name, exact=True):
        n = d.find('檔案', exact=True)
        if n:
            d.tap(n['x'], n['y'], 4)
    if not d.find(name, exact=True):
        # roots drawer of the file picker, then Downloads
        n = d.find('顯示根目錄', exact=True) or d.find('Show roots', exact=True)
        if n:
            d.tap(n['x'], n['y'], 3)
        else:
            d.tap(70, 140, 3)
        d.shot('backup-4-roots')
        n = d.find('下載', exact=True) or d.find('Downloads', exact=True)
        if n:
            d.tap(n['x'], n['y'], 4)
    d.shot('backup-5-downloads')
    tap(name, tries=15)
    time.sleep(3)
    d.shot('backup-6-restore-dialog')
    tap('還原')
    t = time.time()
    while time.time() - t < 600:  # the restore runs as a background job with a notification
        time.sleep(10)
        out = d.shell('dumpsys notification --noredact')
        if '還原成功' in out or 'Restore completed' in out:
            d.shot('backup-7-restored')
            print('restore completed')
            return True
    d.shot('backup-7-not-finished')
    raise RuntimeError('the restore did not report completion')


if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in ('create', 'restore'):
        print(__doc__)
        sys.exit(2)
    c.STEP[0] = 'backup:ui'
    if sys.argv[1] == 'create':
        create()
    else:
        restore(sys.argv[2])
