"""Stage 6: the App's own notifications after a text book was open (Android 8.0 emulator).

In the regression the debug App crashed once when LeakCanary (a debug-only tool) showed a notification:
NotificationManager.getNotificationChannel threw "SecurityException: Calling uid 10079 gave package
com.android.chrome", com.android.chrome being the WebView provider of this emulator. This checks whether
the App's own notifications are affected in the same way once the WebView has been loaded in the App's
process: a library update (pull to refresh in the library) posts a foreground notification.

Two rounds, each from a stopped App:
  - control: library update without opening a book;
  - after a book: a text book is opened (WebView loaded), left with BACK, then the library is updated in
    the same process.
Each round: the App's process must be the same before and after the update, the crash buffer must stay
empty, and the App's notification must show up in `dumpsys notification` during the update.

Usage: ADB=/path/to/adb [PKG=io.github.n09527.bookmania(.debug)] python3 -I check_notification.py [settings-browse]
       settings-browse: Settings > 探索 after a text book (a smoke check; see the function's note)
For the release App, PKG=io.github.n09527.bookmania (opening the book then needs no DevTools: the reader is
waited for by its activity only). Results: out/notification/results.jsonl.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out', 'notification'))
os.makedirs(os.environ['OUT'], exist_ok=True)
sys.path.insert(0, os.path.join(HERE, '..', 'stage5'))
import check_stage5 as c  # noqa: E402

d = c.d
PKG = d.PKG
MAIN = 'eu.kanade.tachiyomi.ui.main.MainActivity'
TEXT = f'{PKG}/yokai.ebook.EbookReaderActivity'


def pid():
    return d.shell(f'pidof {PKG}').strip()


def app_notifications():
    out = d.shell('dumpsys notification --noredact')
    return [ln.strip() for ln in out.splitlines() if 'NotificationRecord' in ln and f'pkg={PKG}' in ln]


def open_library():
    """The main screen opens on its last tab (it was 最新, Recents): the 書櫃 (library) tab is tapped."""
    d.shell(f'am start -n {PKG}/{MAIN}')
    time.sleep(8)
    c.wait_app_drawn()
    time.sleep(4)
    c.clear_dialogs()
    n = d.find('書櫃', exact=True)
    if n:
        d.tap(n['x'], n['y'], 5)
    c.check('the library tab is shown', d.find('書櫃', exact=True) is not None, None)


def update_library(label):
    """Pull to refresh in the library; watches for the App's notification for up to a minute."""
    before = pid()
    d.shell('logcat -b crash -c')
    d.swipe(540, 600, 540, 1500, ms=700, wait=1)
    seen = []
    t = time.time()
    while time.time() - t < 60 and not seen:
        seen = app_notifications()
        time.sleep(2)
    time.sleep(10)
    after = pid()
    crashes = [ln for ln in d.shell('logcat -d -b crash').splitlines() if 'FATAL' in ln or 'Fatal signal' in ln]
    d.shot(f'notification-{label}')
    own = [x for x in seen if 'LEAKCANARY' not in x]  # LeakCanary (debug only) posts under the App's package too
    c.check("the App posted its own notification (not LeakCanary's)", bool(own), seen[:3])
    c.check('the App was not restarted or killed (same process)', before != '' and before == after,
            {'before': before, 'after': after})
    c.check('no crash in the crash buffer', not crashes, crashes[:5])


def browse_settings_after_book():
    """Settings > 探索 opened in the same process after a text book was open. NOTE (stage 6): this does NOT reach
    the App's own NotificationManager.getNotificationChannel call on this emulator. SettingsBrowseController
    builds the switch that calls Notifications.isNotificationChannelEnabled only when
    ExtensionManager.canAutoInstallUpdates() (Android 12+, or the Shizuku installer), and onActivityResumed
    uses that switch only if it exists. The other caller, LibraryUpdateJob, calls it only after an update was
    skipped or failed. Kept as a smoke check: the screen opens without a crash after the WebView was loaded."""
    c.STEP[0] = 'notification:settings-browse-after-a-text-book'
    c.stop_app(0)
    d.shell('logcat -b crash -c')
    d.shell(f'am start -n {PKG}/{c.IMAGE_READER} --el manga 8 --el chapter 10')
    t = time.time()
    while TEXT not in d.resumed() and time.time() - t < 180:
        time.sleep(3)
    time.sleep(20)
    c.check('the text book opened (the WebView is loaded in the App process)', TEXT in d.resumed(), d.resumed())
    before = pid()
    for _ in range(2):
        if TEXT in d.resumed():
            d.shell('input keyevent 4')
            time.sleep(4)
    d.shell(f'am start -n {PKG}/{MAIN}')
    time.sleep(8)
    c.wait_app_drawn()
    time.sleep(4)
    c.clear_dialogs()
    path = []
    for label in ('書櫃', '其他', '設定', '探索'):
        n = d.find(label, exact=True)
        if n:
            d.tap(n['x'], n['y'], 5)
        path.append((label, n is not None))
    time.sleep(5)
    shown = [x['text'] or x['desc'] for x in d.nodes() if x['text'] or x['desc']]
    d.shot('notification-settings-browse')
    after = pid()
    crashes = [ln for ln in d.shell('logcat -d -b crash').splitlines() if 'FATAL' in ln or 'Fatal signal' in ln]
    c.check('Settings > 探索 opened in the same process after the text book, no crash (does not reach getNotificationChannel on Android 8)',
            all(ok for _, ok in path) and before != '' and before == after and not crashes,
            {'path': path, 'process before/after': [before, after], 'crashes': crashes[:5], 'screen': shown[:12]})
    c.stop_app(0)


def main():
    if sys.argv[1:] == ['settings-browse']:
        browse_settings_after_book()
        return
    c.STEP[0] = 'notification:control'
    c.stop_app(0)
    open_library()
    update_library('control')
    c.STEP[0] = 'notification:after-a-text-book'
    c.stop_app(0)
    d.shell(f'am start -n {PKG}/{c.IMAGE_READER} --el manga 8 --el chapter 10')
    t = time.time()
    while TEXT not in d.resumed() and time.time() - t < 180:
        time.sleep(3)
    time.sleep(20)  # laid out: the WebView is loaded in the App's process
    c.check('the text book opened (the WebView is loaded in the App process)', TEXT in d.resumed(), d.resumed())
    d.shell('input keyevent 4')
    time.sleep(4)
    if TEXT in d.resumed():  # the menu took the first BACK
        d.shell('input keyevent 4')
        time.sleep(4)
    open_library()
    update_library('after-a-text-book')
    c.stop_app(0)

if __name__ == '__main__':
    main()
