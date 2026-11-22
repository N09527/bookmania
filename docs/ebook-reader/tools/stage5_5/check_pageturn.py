"""Stage 5.5 checks on the emulator (debug APK): the text reader's page turn animation (none / slide /
curl), the image reader's page curl, and the text reader's chapter panel.

Each turn is recorded with `screenrecord` and analysed frame by frame against a screenshot taken before
and one taken after the turn: every cell of a grid is "old" (as before), "new" (as after) or neither (the
flap, the shadow, a moving page). Where the new page shows up first tells the edge the page turns by.

Usage: python3 -I check_pageturn.py <step> [arguments]        (environment: ADB=/path/to/adb)
  text <manga> <chapter> <none|slide|curl|default> <label> [--columns on] [--back] [--landscape] [--direction rtl|ltr] [--warm]
                                        --warm: one animated turn first, the recorded turn is the second
                                        chapter 0: the work's chapter whose file name ends with --file
  rapid <manga> <chapter> <none|slide|curl> <label>   three keys in one command: each turn counts, nothing is left on top
  image <manga> <chapter> <l2r|r2l|vertical|webtoon> <label> [--curl on|off] [--double] [--back] [--swipe]
                                        --swipe: a quick swipe instead of a key
  swipe_frames <label> <on|off> <horizontal|vertical>   whether the page followed the finger, for a saved
                                        swipe recording (the check of image --swipe, added in stage 6)
  add_chapter <manga> <file on the device> <new file name>   copies a file into the work's folder and refreshes
                                        the work's chapter list (pull to refresh on its page)
  chapters <manga> <first chapter> <other text chapter> <image chapter, 0: the work's .cbz>
  settings_ui <manga> <chapter>          the new settings in the text reader's panel and in Settings > Reader
Results: out/results.jsonl, recordings and frames: out/rec/<label>/, frame sheets: out/shots/<label>-frames.png.
Needs ../stage5/check_stage5.py (and what it needs), ffmpeg, Pillow and numpy.
"""
import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OUT', os.path.join(HERE, 'out'))
sys.path.insert(0, os.path.join(HERE, '..', 'stage5'))
import check_stage5 as c  # noqa: E402

d = c.d
OUT = os.environ['OUT']
os.makedirs(os.path.join(OUT, 'shots'), exist_ok=True)
ADB = os.environ.get('ADB', 'adb')
KEY_PAGE_UP, KEY_PAGE_DOWN = 92, 93
CELL = [20]  # grid cell in pixels of the recording: 20 at half size, 10 at quarter size (set by record_turn)


def check(name, ok, detail=None):
    return c.check(name, ok, detail)


def note(text):
    c.note(text)


# region Recording and analysis

def rotate(landscape, timeout=60):
    """Rotates the screen and waits until the display has the orientation (it can take a while here)."""
    c.rotate(landscape)
    want = '1920x1080' if landscape else '1080x1920'
    t = time.time()
    while time.time() - t < timeout:
        if f'cur={want}' in d.shell('dumpsys window displays'):
            return True
        time.sleep(2)
    note(f'the display did not turn to {want}')
    return False


def grab(size):
    """A screenshot, scaled to the recording size, in grey."""
    png = d.adb('exec-out', 'screencap', '-p', text=False, timeout=90)
    path = os.path.join(OUT, 'grab.png')
    with open(path, 'wb') as f:
        f.write(png)
    img = Image.open(path).convert('RGB')
    return img.resize(size, Image.BILINEAR) if size else img


def screen_size():
    img = grab(None)
    return img.size  # (width, height) in the current orientation


SLOW = 40  # animator duration scale while recording: more frames of each turn on the slow emulator


def record_turn(label, code, seconds=60, size=None, action=None):
    """Records the screen while key [code] turns the page, with animations [SLOW] times slower (the system
    setting "animator duration scale", which the App's animations follow). Sending a key with `input` takes
    seconds on this emulator, hence the long recording. Returns (before, after, frames, after_late)."""
    folder = os.path.join(OUT, 'rec', label)
    os.makedirs(folder, exist_ok=True)
    for f in os.listdir(folder):
        os.remove(os.path.join(folder, f))
    w, h = size
    CELL[0] = max(10, min(size) // 27)
    record_turn.since = device_time()
    before = grab(size)
    before.save(os.path.join(folder, 'before.png'))
    d.shell('rm -f /sdcard/turn.mp4')
    d.shell(f'settings put global animator_duration_scale {SLOW}')
    rw, rh = w // 16 * 16, h // 16 * 16  # video encoders want multiples of 16; frames are scaled back to size
    rec = subprocess.Popen([ADB, 'shell', 'screenrecord', '--time-limit', str(seconds), '--size', f'{rw}x{rh}',
                            '--bit-rate', '8000000', '/sdcard/turn.mp4'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)  # screenrecord has started
    t_key = time.time()
    d.shell(action or f'input keyevent {code}')
    try:
        rec.wait(timeout=seconds + 60)
    except subprocess.TimeoutExpired:
        rec.kill()
    d.shell('settings put global animator_duration_scale 1')
    time.sleep(2)
    d.adb('pull', '/sdcard/turn.mp4', os.path.join(folder, 'turn.mp4'), timeout=120)
    after = grab(size)
    after.save(os.path.join(folder, 'after.png'))
    time.sleep(3)
    late = grab(size)
    frames = extract(folder, size)
    note(f'{label}: {len(frames)} frames, key sent {t_key:.1f}')
    return before, after, frames, late


def extract(folder, size):
    video = os.path.join(folder, 'turn.mp4')
    if not os.path.exists(video) or os.path.getsize(video) == 0:
        return []
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', video, '-vsync', 'passthrough', os.path.join(folder, 'f%04d.png')], check=False)
    probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time',
                            '-of', 'csv=p=0', video], capture_output=True, text=True)
    times = [float(x) for x in probe.stdout.split() if x.strip() and x.strip() != 'N/A']
    names = sorted(n for n in os.listdir(folder) if n.startswith('f') and n.endswith('.png'))
    frames = []
    for i, n in enumerate(names):
        img = fit(Image.open(os.path.join(folder, n)).convert('RGB'), size)
        frames.append((times[i] if i < len(times) else float(i), img))
    return frames


def fit(img, size):
    """A video frame at [size]: screenrecord keeps the screen's proportions and fills the rest of the video
    with black bars (the video size is rounded to multiples of 16), so the bars are cut off first."""
    if img.size == size:
        return img
    vw, vh = img.size
    aspect = size[0] / size[1]
    if vw / vh > aspect:  # bars left and right
        cw = vh * aspect
        box = ((vw - cw) / 2, 0, (vw + cw) / 2, vh)
    else:  # bars above and below
        ch = vw / aspect
        box = (0, (vh - ch) / 2, vw, (vh + ch) / 2)
    return img.resize(size, Image.BILINEAR, box=box)


def grey(img):
    return np.asarray(img.convert('L'), dtype=np.int16)


def cells(diff):
    cell = CELL[0]
    h, w = diff.shape
    gh, gw = h // cell, w // cell
    return np.abs(diff[:gh * cell, :gw * cell]).reshape(gh, cell, gw, cell).mean(axis=(1, 3))


def colour_diff(x, y):
    """Per pixel, the mean difference of the three colour channels: two comic pages can differ only in
    colour, which a grey picture hardly shows; the mean (not the largest) keeps the video's colour
    compression noise around black text small."""
    return np.abs(np.asarray(x, dtype=np.int16) - np.asarray(y, dtype=np.int16)).mean(axis=2)


def classify(frame, before, after):
    """Per cell: informative (the two pages differ there), old (as before) and new (as after)."""
    F, B, A = frame.convert('RGB'), before.convert('RGB'), after.convert('RGB')
    d_fb, d_fa, d_ab = cells(colour_diff(F, B)), cells(colour_diff(F, A)), cells(colour_diff(A, B))
    informative = d_ab > 12
    old = informative & (d_fb < 7) & (d_fa > 10)
    new = informative & (d_fa < 7) & (d_fb > 10)
    return informative, old, new


def centroid(mask):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    gh, gw = mask.shape
    return round(float((xs.mean() + 0.5) / gw), 3), round(float((ys.mean() + 0.5) / gh), 3)


def analyse(before, after, frames):
    rows = []
    for t, img in frames:
        inf, old, new = classify(img, before, after)
        n = int(inf.sum()) or 1
        rows.append({
            't': round(t, 3),
            'old': round(int(old.sum()) / n, 3),
            'new': round(int(new.sum()) / n, 3),
            'new_at': centroid(new),
            'old_at': centroid(old),
            'new_right_half': round(float(new[:, new.shape[1] // 2:].sum()) / max(1, int(new.sum())), 3),
            'new_bottom_half': round(float(new[new.shape[0] // 2:, :].sum()) / max(1, int(new.sum())), 3),
        })
    return rows


def mid(rows, share=0.8):
    """Frames during the turn: neither the old page nor the new page is on the screen as it is before or
    after the turn (compared with the frames of the recording that show most of each; the video's own
    compression keeps them below 1). The flap of a curl covers much of the old page, so a frame can show
    little of either page."""
    if not rows:
        return []
    old_most = max(r['old'] for r in rows)
    new_most = max(r['new'] for r in rows)
    return [r for r in rows if r['old'] < share * old_most and r['new'] < share * new_most]


def sheet(label, before, after, frames, rows, picks=6):
    """Before, some frames of the turn and after, side by side, with their times."""
    middle = [i for i, r in enumerate(rows) if 0.03 < r['new'] < 0.97 or 0.03 < r['old'] < 0.97]
    if len(middle) > picks:
        middle = [middle[round(k * (len(middle) - 1) / (picks - 1))] for k in range(picks)]
    images = [('before', before)] + [(f"{rows[i]['t']:.2f}s", frames[i][1]) for i in middle] + [('after', after)]
    w, h = before.size
    scale = 0.5
    tw, th = int(w * scale), int(h * scale)
    out = Image.new('RGB', (tw * len(images), th + 28), 'white')
    draw = ImageDraw.Draw(out)
    for k, (name, img) in enumerate(images):
        out.paste(img.resize((tw, th), Image.BILINEAR), (k * tw, 28))
        draw.text((k * tw + 6, 6), name, fill='black')
    path = os.path.join(OUT, 'shots', f'{label}-frames.png')
    out.save(path)
    return path


def patch_shift(frame, page, vertical=False, size=None, max_err=None):
    """How far [page] is shifted in [frame] (pixels of the recording, along x; along y when [vertical]):
    small patches of the page that hold text are looked for in the same rows of the frame; the median of
    the shifts found with a small difference, or None when no patch is found (the page is off the frame)."""
    half = CELL[0] >= 20
    size = size or ((48, 32) if half else (24, 16))
    max_err = max_err or (6.0 if half else 8.0)
    F = grey(frame)
    P = grey(page)
    if vertical:
        F, P = F.T, P.T
    h, w = P.shape
    pw, ph = size
    shifts = []
    for py in range(10, h - ph - 10, ph * 2):
        for px in range(0, w - pw, pw):
            patch = P[py:py + ph, px:px + pw]
            if patch.std() < 20:  # blank: matches anywhere
                continue
            band = F[py:py + ph, :]
            best = None
            for x in range(0, w - pw + 1, 2 if half else 1):
                err = np.abs(band[:, x:x + pw] - patch).mean()
                if best is None or err < best[1]:
                    best = (x - px, err)
            if best and best[1] < max_err:
                shifts.append(best[0])
    if len(shifts) < 3:
        return None, len(shifts)
    median = int(np.median(shifts))
    agree = sum(abs(x - median) <= (4 if half else 2) for x in shifts)
    if agree < max(3, 0.6 * len(shifts)):  # patches that also match elsewhere (repeated characters)
        return None, len(shifts)
    return median, agree


def slide_check(rows, frames, before, after, expect_old_sign, vertical=False):
    """For the frames of a slide: how far the old page and the new page are shifted. The old page leaves
    in the direction [expect_old_sign] (-1 left / up, 1 right / down) and the new page follows it in."""
    found = []
    old_most = max(r['old'] for r in rows)
    new_most = max(r['new'] for r in rows)
    for r, (t, img) in zip(rows, frames):
        if r['old'] >= 0.95 * old_most or r['new'] >= 0.95 * new_most:
            continue  # the page before or after the turn
        dx_old, n_old = patch_shift(img, before, vertical)
        dx_new, n_new = patch_shift(img, after, vertical)
        # In a slide the two pages are one page apart, so they are never shifted by the same amount. Patches of
        # the new page found where the old page is (stage 6: the vertical test book repeats its sentences on
        # every page) matched the old page's text: the new page is not found in this frame.
        same = dx_old is not None and dx_new is not None and abs(dx_new - dx_old) <= (4 if CELL[0] >= 20 else 2)
        if same:
            dx_new = None
        found.append({'t': r['t'], 'old page shifted by': dx_old, 'patches': n_old, 'new page shifted by': dx_new,
                      'patches new': n_new, **({'new page matched where the old page is': True} if same else {})})
    # judged on the first frame where each page is found moved: later frames show mostly the new page, and
    # the test book repeats its sentences, so patches of the old page can also match the new page there
    moved_old = [f['old page shifted by'] for f in found if f['old page shifted by'] not in (None, 0)]
    moved_new = [f['new page shifted by'] for f in found if f['new page shifted by'] not in (None, 0)]
    ok = bool(moved_old or moved_new) and (not moved_old or moved_old[0] * expect_old_sign > 0) and \
        (not moved_new or moved_new[0] * expect_old_sign < 0)
    return ok, found


def incoming_fit(frame, before, after, sign, vertical=False):
    """What comes in during a slide. The frame is fitted with the old page moved by dx and, in the strip it
    uncovered, one of three pictures, for every dx in the direction the old page leaves ([sign]: -1 left / up,
    1 right / down):
      - the new page sliding in, one page away from the old page (the App had a copy of the new page);
      - the new page at its place, uncovered (no copy of the new page: the App shows its own view there);
      - a copy of the old page sliding in (the problem found in stage 6).
    At the dx that fits best, the strip is compared with each. Returns {dx, strip, errors} in pixels of the
    recording (halved here), or None when the strip is too narrow."""
    F, B, A = grey(frame)[::2, ::2], grey(before)[::2, ::2], grey(after)[::2, ::2]
    if vertical:
        F, B, A = F.T, B.T, A.T
    h, w = F.shape
    best = None
    for dx in range(2, w - 2, 2):
        if sign < 0:  # the old page shows its columns dx.. at 0..; the strip is at the right
            shared = np.abs(F[:, :w - dx] - B[:, dx:]).mean()
            strip_f, slide, uncovered, old = F[:, w - dx:], A[:, :dx], A[:, w - dx:], B[:, :dx]
        else:         # the old page shows at dx..; the strip is at the left
            shared = np.abs(F[:, dx:] - B[:, :w - dx]).mean()
            strip_f, slide, uncovered, old = F[:, :dx], A[:, w - dx:], A[:, :dx], B[:, w - dx:]
        errors = [float(np.abs(strip_f - x).mean()) for x in (slide, uncovered, old)]
        total = (shared * (w - dx) + min(errors) * dx) / w
        if best is None or total < best[0]:
            best = (total, dx, errors)
    if best is None or best[1] < 0.1 * w:
        return None
    e_slide, e_uncovered, e_old = best[2]
    return {'dx': best[1] * 2 * sign, 'strip': best[1] * 2, 'error against the new page sliding in': round(e_slide, 2),
            'error against the new page uncovered': round(e_uncovered, 2), 'error against a copy of the old page': round(e_old, 2)}


def incoming_check(rows, frames, before, after, expect_old_sign, vertical=False):
    """The page that comes in during a slide is the new page, not a copy of the old one (stage 6: the copy of
    the new page was made before the WebView showed it, and the old page came in again). The new page may
    slide in (a copy of it) or be uncovered at its place (no copy). Judged on the frames of the turn where a
    strip of at least a tenth of the page came in."""
    old_most = max(r['old'] for r in rows)
    new_most = max(r['new'] for r in rows)
    fits = []
    for r, (t, img) in zip(rows, frames):
        if r['old'] >= 0.95 * old_most or r['new'] >= 0.95 * new_most:
            continue
        fit_ = incoming_fit(img, before, after, expect_old_sign, vertical)
        if fit_:
            e_slide = fit_['error against the new page sliding in']
            e_unc = fit_['error against the new page uncovered']
            e_old = fit_['error against a copy of the old page']
            fit_['t'] = r['t']
            if e_old < 0.7 * min(e_slide, e_unc):
                fit_['shows'] = 'a copy of the old page'
            elif min(e_slide, e_unc) < 0.7 * e_old:
                fit_['shows'] = 'the new page sliding in' if e_slide <= e_unc else 'the new page uncovered'
            else:
                fit_['shows'] = 'unclear'
            fits.append(fit_)
    ok = any(f['shows'].startswith('the new page') for f in fits) and not any(f['shows'] == 'a copy of the old page' for f in fits)
    return ok, fits


def device_time():
    try:
        return float(d.shell('date +%s').strip())
    except ValueError:
        return 0.0


def turn_logs(since):
    """The App's debug lines about page turns (PageTurner) written since [since] (device time, seconds)."""
    out = d.adb('logcat', '-d', '-v', 'epoch', '-s', 'Yokai:D')
    lines = []
    for ln in out.splitlines():
        parts = ln.split()
        try:
            t = float(parts[0])
        except (ValueError, IndexError):
            continue
        if t >= since and 'page turn:' in ln:
            lines.append(ln[ln.index('page turn:'):])
    return lines


def no_overlay_left(after, late):
    """The picture after the turn stays as it is: nothing is left on top of the reader."""
    diff = cells(grey(late) - grey(after))
    return float((diff > 10).mean())

# endregion


# region Text reader

def text_step(manga, chapter, style, label, columns='off', back=False, landscape=False, direction=None, warm=False):
    c.STEP[0] = f'text:{label}'
    # 'default': no choice stored, the text reader's default (curl since stage 6)
    values = {'pref_ebook_page_turn': None if style == 'default' else style, 'pref_ebook_columns': columns}
    style = 'curl' if style == 'default' else style
    if direction:
        values['pref_ebook_pageDirection'] = direction
    c.set_prefs(values, reset_typesetting=True)
    rotate(landscape)
    st = c.open_book(manga, chapter)
    if not st or not st.get('ready'):
        return check('the book opened', False, st)
    # a page in the middle of the document: the turn stays in it (a turn into the next document is played
    # only when that one is laid out quickly, which this emulator never does)
    start_page = 4 if back else 2
    d.cdp(f'window.__reader.goPage({start_page - 1 if warm else start_page})')
    time.sleep(4)
    if warm:
        # one animated turn first: the recorded turn is the second one of this reading session
        d.shell(f'input keyevent {KEY_PAGE_DOWN}')
        time.sleep(15)
    st = d.status()
    if not st or st.get('pages', 0) < start_page + 2 * st.get('cols', 1):
        return check('the document has pages around page %d' % start_page, False, st)
    size = screen_size()
    check('the screen is in ' + ('landscape' if landscape else 'portrait'), (size[0] > size[1]) == landscape,
          {'screen': size, 'columns shown': st.get('cols')})
    size = (size[0] // 2, size[1] // 2)  # text needs half size to be told apart in the frames
    before, after, frames, late = record_turn(label, KEY_PAGE_UP if back else KEY_PAGE_DOWN, size=size)
    st2 = d.status()
    rows = analyse(before, after, frames)
    with open(os.path.join(OUT, 'rec', label, 'analysis.json'), 'w') as f:
        json.dump(rows, f, indent=1)
    path = sheet(label, before, after, frames, rows)
    step = st.get('cols', 1)
    expected = st['page'] - step if back else st['page'] + step
    check('the page turned', st2 and st2['page'] == expected, {'before': st, 'after': st2, 'expected page': expected})
    logs = turn_logs(record_turn.since)
    # the App's line that the turn started (a turn that was not animated logs why instead; stage 6)
    started = {'slide': 'SLIDE starts', 'curl': 'CURL starts', 'default': 'CURL starts'}.get(style)
    check('the App logged the turn (debug log)', any(started in l for l in logs) if started else not logs, {'log': logs})
    # the page direction: as set, else vertical text turns right to left (the shell's mode 'V')
    rtl = direction == 'rtl' or (direction is None and st.get('mode') == 'V')
    verdicts(label, style, rows, back, columns == 'on', rtl=rtl, edge=None, sheet_path=path,
             leftover=no_overlay_left(after, late), slide_frames=(frames, before, after))
    rotate(False)


def verdicts(label, style, rows, back, spread, rtl, edge, sheet_path, leftover, slide_frames=None):
    during = mid(rows)
    detail = {'frames': len(rows), 'frames during the turn': len(during), 'sheet': os.path.relpath(sheet_path, OUT)}
    if leftover is not None:  # not measured again by reanalyse
        check('nothing is left over the page after the turn', leftover < 0.02, {'changed cells': round(leftover, 4)})
    if not rows:
        return check('recorded', False, detail)
    last = rows[-1]
    # relative to the frames that show most of each page: the video's compression keeps them below 1
    new_most = max(r['new'] for r in rows)
    old_most = max(r['old'] for r in rows)
    check('the recording ends on the new page', last['new'] >= 0.9 * new_most and last['old'] <= 0.1 * old_most,
          {'last': last, 'most new': new_most, 'most old': old_most})
    if style == 'none':
        return check('no animation: no frame shows parts of both pages', len(during) == 0, {**detail, 'during': during[:3]})
    # one frame between the two pages is enough to tell the turn was animated: this emulator draws about one
    # frame of the turn per second even with animations 20 times slower, and a slide moves most of the way
    # in its first quarter
    check('the turn is animated (frames between the two pages)', len(during) >= 1, detail)
    # the first frame of the turn that shows some of the new page: where it shows up tells the direction
    showing = [r for r in during if r['new'] >= 0.02 and r['new_at']]
    if not showing:
        return check('a frame of the turn shows part of the new page', False, detail)
    first = showing[0]
    if style == 'slide':
        # the new page comes in from the side the next page lies on, the old page leaves on the other
        expect_right = (not back) != bool(rtl)
        if slide_frames is None:
            side = first['new_at'][0] if first['new_at'] else None
            return check('the new page slides in from the ' + ('right' if expect_right else 'left'),
                         side is not None and ((side > 0.5) if expect_right else (side < 0.5)), {**detail, 'first': first})
        ok, found = slide_check(rows, *slide_frames, expect_old_sign=-1 if expect_right else 1)
        check('the old page moves ' + ('left' if expect_right else 'right') + ' and the new page comes in from the '
              + ('right' if expect_right else 'left'), ok, {**detail, 'shifts': found})
        ok, fits = incoming_check(rows, *slide_frames, expect_old_sign=-1 if expect_right else 1)
        return check('the page that comes in is the new page, not a copy of the old one', ok, {'frames': fits})
    # curl: the part of the page that has not turned yet is the copy of the page that was on the screen (a
    # copy of an earlier page would show here instead, see the stage 5.5 report)
    check('during the curl, part of the page that was on the screen is still shown',
          any(r['old'] >= 0.1 * old_most for r in during), {'old during the turn': [r['old'] for r in during]})
    if edge == 'BOTTOM':
        ok = first['new_bottom_half'] >= 0.8 if not back else first['new_bottom_half'] <= 0.2
        return check('vertical pager: the page curls from the bottom edge' + (' (back: comes down over the top edge)' if back else ''),
                     ok, {**detail, 'first': first})
    lifted_on_right = not rtl  # the edge that is lifted going forward
    if back:
        # the turn runs in reverse: the previous page comes back over the hinge side first
        lifted_on_right = not lifted_on_right
    share = first['new_right_half']
    ok = share >= 0.8 if lifted_on_right else share <= 0.2
    what = ('two columns: one page turns about the centre line, ' if spread else '') + \
        ('the new page shows on the right first' if lifted_on_right else 'the new page shows on the left first')
    check(what, ok, {**detail, 'first': first})
    if not back and not spread:
        y = first['new_at'][1] if first['new_at'] else 0
        check('the curl starts at the bottom corner', y > 0.5, {'first': first})
    if spread and not back:
        # going forward the turning page's back lands on the other half, so until late in the turn the new
        # page does not show there as it lies at the end. (Going back, the previous spread lands in place on
        # both halves: the other half is uncovered as the page lifts off it, and the turning half fills in
        # from the centre line.)
        early = [r for r in during if r['new'] < 0.5]
        other_half = [r['new_right_half'] for r in early]
        ok = all((s >= 0.75) if lifted_on_right else (s <= 0.25) for s in other_half)
        check('two columns: the other half shows the back of the turning page, not the new page in place', ok,
              {'new_right_half during the first half of the turn': other_half})
    return True

def rapid_step(manga, chapter, style, label):
    """Three Page Down keys sent together: a turn still being prepared or played when the next key comes
    is ended at once, and every key turns a page."""
    c.STEP[0] = f'rapid:{label}'
    c.set_prefs({'pref_ebook_page_turn': style}, reset_typesetting=True)
    rotate(False)
    st = c.open_book(manga, chapter)
    if not st or not st.get('ready'):
        return check('the book opened', False, st)
    d.cdp('window.__reader.goPage(1)')
    time.sleep(4)
    st = d.status()
    size = screen_size()
    size = (size[0] // 2, size[1] // 2)
    before = grab(size)
    d.shell(f'input keyevent {KEY_PAGE_DOWN} {KEY_PAGE_DOWN} {KEY_PAGE_DOWN}')
    time.sleep(30)
    st2 = d.status()
    after = grab(size)
    time.sleep(3)
    late = grab(size)
    after.save(os.path.join(OUT, 'shots', f'{label}-after.png'))
    check('three quick keys turn three pages', st2 and st2['page'] == st['page'] + 3, {'before': st, 'after': st2})
    check('nothing is left over the page', no_overlay_left(after, late) < 0.02, None)

def reanalyse(label, style, back=False, spread=False, rtl=False, edge=None):
    """The verdicts again for a recording in out/rec/<label> (after a change of the analysis)."""
    folder = os.path.join(OUT, 'rec', label)
    before = Image.open(os.path.join(folder, 'before.png')).convert('RGB')
    after = Image.open(os.path.join(folder, 'after.png')).convert('RGB')
    CELL[0] = max(10, min(before.size) // 27)
    frames = extract(folder, before.size) if not any(n.startswith('f0') for n in os.listdir(folder)) else [
        (t, fit(Image.open(os.path.join(folder, n)).convert('RGB'), before.size))
        for t, n in zip([r['t'] for r in json.load(open(os.path.join(folder, 'analysis.json')))],
                        sorted(n for n in os.listdir(folder) if n.startswith('f0') and n.endswith('.png')))]
    rows = analyse(before, after, frames)
    path = sheet(label, before, after, frames, rows)
    verdicts(label, style, rows, back, spread, rtl, edge, path, leftover=None, slide_frames=(frames, before, after))

# endregion


# region Image reader

MODES = {'l2r': 1, 'r2l': 2, 'vertical': 3, 'webtoon': 4}


def swipe_action(mode, back, size, curl='on'):
    """A swipe that turns to the next page (or back): the finger moves left in left-to-right pagers, right in
    right-to-left ones, up in the vertical pager and in the long strip. Over 400 ms: with a shorter swipe, the
    slow emulator's `input` sent the press, one move at the start and the release, and no move in between.

    With the curl off, the pager follows the finger itself and turns by its own rule: when the finger is
    lifted, the page turns if it moved fast enough, or if it was dragged past about 60 % of the page. Here
    `input` waits until the App has handled each move, so the moves come 20 to 130 ms apart, and Android 8
    measures the speed from the moves of the last 100 ms only (the release does not count): the quick swipe
    had no speed and was dragged about half the page, so the page sprang back (stage 6 report, events seen
    with `dumpsys input`). With the curl off, the finger is therefore dragged slowly over most of the page."""
    w, h = size
    drag = curl == 'off' and mode != 'webtoon'
    if mode in ('vertical', 'webtoon'):
        y1, y2 = (int(h * 0.93), int(h * 0.07)) if drag else (int(h * 0.75), int(h * 0.3))
        if back:
            y1, y2 = y2, y1
        return f"input swipe {w // 2} {y1} {w // 2} {y2} {1500 if drag else 400}"
    x1, x2 = (int(w * 0.93), int(w * 0.07)) if drag else (int(w * 0.8), int(w * 0.2))
    if (mode == 'r2l') != back:
        x1, x2 = x2, x1
    return f"input swipe {x1} {h // 2} {x2} {h // 2} {1500 if drag else 400}"


def scroll_shift(before, after):
    """How far the picture moved up from [before] to [after], in pixels of the images (a scroll of the long
    strip): the shift at which the two overlap best. Returns (shift, difference there, difference unmoved);
    the page number at the bottom stays where it is, so the lowest tenth of the screen is left out."""
    a = np.asarray(before.convert('L'), dtype=np.float32)
    b = np.asarray(after.convert('L'), dtype=np.float32)
    h = int(a.shape[0] * 0.9)
    a, b = a[:h], b[:h]
    diffs = [float(np.abs(a[s:] - b[:h - s]).mean()) for s in range(0, int(h * 0.6))]
    shift = int(np.argmin(diffs))
    return shift, diffs[shift], diffs[0]


def frame_shift(before, frames, rows, horizontal):
    """How far the black frame of the comic test page moved (the largest shift, in pixels of the recording)
    in the frames before the new page first shows, that is before the curl's first frame, or before the next
    page comes in with a drag: a page that follows the finger moves, one that waits for the curl does not.
    The frame's first and last dark pixel are found across the page at 30 % of its height (of its width in
    the vertical pager). Returns (largest shift or None, frames measured)."""
    def edges(img):
        a = np.asarray(img.convert('L'), dtype=np.int16)
        line = a[int(a.shape[0] * 0.3)] if horizontal else a[:, int(a.shape[1] * 0.3)]
        dark = np.where(line < 60)[0]
        return (int(dark[0]), int(dark[-1])) if len(dark) else None
    ref = edges(before)
    first_new = next((k for k, r in enumerate(rows) if r['new'] > 0.005), len(rows))
    shifts = [max(abs(e[0] - ref[0]), abs(e[1] - ref[1])) for e in (edges(img) for _, img in frames[:first_new])
              if ref and e]
    return (max(shifts) if shifts else None), len(shifts)


def follow_check(curl, before, frames, rows, horizontal):
    """A swipe in the pager: with the curl on, the page stays where it is until the curl (the user's
    decision, stage 5.5 report 6.1); with the curl off, the pager drags the page with the finger as before."""
    shift, n = frame_shift(before, frames, rows, horizontal)
    detail = {'largest shift of the page frame (pixels of the recording, a quarter of the screen)': shift,
              'frames before the new page shows': n}
    if curl == 'on':
        check('the page did not follow the finger before the curl (its frame stayed in place)',
              shift is not None and shift <= 3, detail)
    else:
        check("the page followed the finger (the pager's own drag)", shift is not None and shift >= 10, detail)


def swipe_frames(label, curl, horizontal):
    """follow_check again for a recording in out/rec/<label> (recordings made before the check existed)."""
    folder = os.path.join(OUT, 'rec', label)
    before = Image.open(os.path.join(folder, 'before.png')).convert('RGB')
    with open(os.path.join(folder, 'analysis.json')) as f:
        rows = json.load(f)
    names = sorted(n for n in os.listdir(folder) if n.startswith('f0') and n.endswith('.png'))
    frames = [(r['t'], fit(Image.open(os.path.join(folder, n)).convert('RGB'), before.size)) for r, n in zip(rows, names)]
    follow_check(curl, before, frames, rows, horizontal)


def image_step(manga, chapter, mode, label, curl='on', double=False, back=False, swipe=False):
    c.STEP[0] = f'image:{label}'
    c.set_prefs({
        'pref_default_reading_mode_key': MODES[mode],
        'pref_bookmania_pager_curl': curl == 'on',
        'page_layout': 1 if double else 0,
        'pref_enable_transitions_key': True,
    })
    set_page(chapter, 0)  # the chapter opens at its first page
    rotate(double)
    d.shell(f'am start -n {d.PKG}/{c.IMAGE_READER} --el manga {manga} --el chapter {chapter}')
    t = time.time()
    while c.IMAGE_READER.split('.')[-1] not in d.resumed() and time.time() - t < 120:
        time.sleep(3)
    time.sleep(25)  # pages decoded
    c.clear_dialogs()
    hide_reader_menu()
    note(f'{label}: the screen was still after {wait_still()} s more')
    if back:
        d.shell(f'input keyevent {KEY_PAGE_DOWN}')
        time.sleep(8)
        note(f'{label}: after the first turn, the screen was still after {wait_still()} s more')
    size = screen_size()
    action = swipe_action(mode, back, size, curl) if swipe else None
    check('the screen is in ' + ('landscape' if double else 'portrait'), (size[0] > size[1]) == double, {'screen': size})
    size = (size[0] // 4, size[1] // 4)  # comic pages are told apart by colour: a small, cheaper recording
    before, after, frames, late = record_turn(label, KEY_PAGE_UP if back else KEY_PAGE_DOWN, size=size, action=action)
    rows = analyse(before, after, frames)
    with open(os.path.join(OUT, 'rec', label, 'analysis.json'), 'w') as f:
        json.dump(rows, f, indent=1)
    path = sheet(label, before, after, frames, rows)
    logs = turn_logs(record_turn.since)
    # the page the reader is on, as it saves it when it is left (the page indicator cannot be read here:
    # the screen of the image reader never gets idle for uiautomator)
    d.shell('input keyevent 4')
    time.sleep(6)
    c.stop_app()
    page = chapter_row(chapter)[6]
    if mode == 'webtoon' and swipe:
        # The long strip follows the finger. Its page is the last one whose bottom edge is on the screen, so
        # one swipe does not reach the next page (the pages here are almost as tall as the screen); the scroll
        # is checked instead.
        shift, diff, unmoved = scroll_shift(before, after)
        check('the strip scrolled up with the finger', shift >= 0.1 * size[1] and diff < 0.5 * unmoved,
              {'moved up (pixels of the screen)': shift * 4, 'difference there': round(diff, 2),
               'difference unmoved': round(unmoved, 2), 'last_page_read': page, 'swipe': action})
    else:
        check('the page turned' + (' back to the first page' if back else ''), page == 0 if back else page >= 1,
              {'last_page_read after the turn': page, 'started at': 0, 'turned forward once first': back,
               'swipe': action})
    if swipe and mode != 'webtoon':
        follow_check(curl, before, frames, rows, horizontal=mode != 'vertical')
    if mode == 'webtoon' or curl == 'off':
        during = mid(rows)
        check('no curl: the App did not play a page turn of its own (debug log)', not logs,
              {'log': logs, 'frames during the turn': len(during), 'sheet': os.path.relpath(path, OUT)})
    else:
        check('the App logged the curl (debug log)', any('CURL starts' in l for l in logs), {'log': logs})
        verdicts(label, 'curl', rows, back, double, rtl=(mode == 'r2l'), edge='BOTTOM' if mode == 'vertical' else None,
                 sheet_path=path, leftover=no_overlay_left(after, late))
    rotate(False)


def wait_still(timeout=120, pause=3.0):
    """Waits until the screen stops changing: a page that is still loading shows an animated spinner (stage 6:
    on a slow run a comic page took more than 25 s, and the picture "before the turn" was the spinner).
    Returns the seconds waited, or None when the screen still changed after [timeout]."""
    t = time.time()
    last = grey(grab((270, 480)))
    while time.time() - t < timeout:
        time.sleep(pause)
        now = grey(grab((270, 480)))
        if float(np.abs(now - last).mean()) < 0.5:
            return round(time.time() - t, 1)
        last = now
    return None


def chapter_row(chapter):
    db = c.pull_db('tachiyomi.db')
    return db.execute('SELECT _id, manga_id, url, name, read, bookmark, last_page_read FROM chapters WHERE _id = ?',
                      (chapter,)).fetchone()


def set_page(chapter, page):
    """With the App stopped: the chapter is unread and opens at [page]."""
    row = chapter_row(chapter)
    restore_chapter(chapter, 0, row[5], page)


def hide_reader_menu():
    """The image reader may open with its menu shown; the curl is not used while it is."""
    ns = d.nodes()
    if any(n['desc'] in ('向上瀏覽', 'Navigate up') for n in ns):
        w = max((m['b'][2] for m in ns), default=1080)
        h = max((m['b'][3] for m in ns), default=1920)
        d.tap(w // 2, h // 2, 3)


def reader_page():
    """The page number the image reader shows ("2 / 3"), from the page indicator."""
    for n in d.nodes():
        text = n['text'].replace(' ', '')
        if '/' in text and text.replace('/', '').replace('-', '').isdigit():
            return text
    return None

# endregion


# region Chapter panel

def chapters_step(manga, first, other, image):
    c.STEP[0] = 'chapters'
    c.set_prefs({'pref_ebook_page_turn': 'none'}, reset_typesetting=True)
    rotate(False)
    rows = {r[0]: r for r in chapter_rows(manga)}
    if image == 0:  # the work's picture chapter (add_chapter)
        image = next(r[0] for r in rows.values() if r[2].lower().endswith('.cbz'))
    st = c.open_book(manga, first)
    if not st or not st.get('ready'):
        return check('the book opened', False, st)
    c.turn(1)
    panel = open_chapters()
    d.shot('s55-chapters-panel')
    names = [n['text'] for n in d.nodes() if n['text']]
    expected = [r[3] for r in rows.values()]
    check('the panel lists the chapters of the work', all(any(e == t for t in names) for e in expected),
          {'shown': names, 'chapters': expected})
    # long press: read / unread, as in the image reader's chapter sheet
    item = d.find(rows[other][3], exact=True)
    d.shell(f"input swipe {item['x']} {item['y']} {item['x']} {item['y']} 1500")
    time.sleep(3)
    # the bookmark button of the same row
    bookmark = [n for n in d.nodes() if n['res'].endswith('bookmark_button') and abs(n['y'] - item['y']) < 60]
    if bookmark:
        d.tap(bookmark[0]['x'], bookmark[0]['y'], 3)
    d.shot('s55-chapters-toggled')
    d.shell('input keyevent 4')  # closes the panel
    time.sleep(2)
    c.stop_app()
    toggled = {r[0]: r for r in chapter_rows(manga)}
    check('a long press marks the chapter read / unread', toggled[other][4] != rows[other][4],
          {'before': rows[other], 'after': toggled[other]})
    check('the bookmark button sets / clears the bookmark', toggled[other][5] != rows[other][5],
          {'before': rows[other], 'after': toggled[other]})
    # put both back
    restore_chapter(other, rows[other][4], rows[other][5], rows[other][6])

    # a tap opens another text chapter in the text reader, after saving this one's position
    pos_before = positions()
    st = c.open_book(manga, first)
    open_chapters()
    item = d.find(rows[other][3], exact=True)
    d.tap(item['x'], item['y'], 5)
    t = time.time()
    while time.time() - t < 120 and not (c.READER.split('.')[-1] in d.resumed() and d.status() and d.status().get('ready')):
        time.sleep(3)
    resumed = d.resumed()
    time.sleep(8)
    d.shot('s55-chapters-opened-text')
    c.stop_app()
    pos_after = positions()
    check('a tap on a text chapter opens it in the text reader', 'EbookReaderActivity' in resumed, resumed)
    check('the position of the chapter left is saved, the one opened gets its own',
          pos_after.get(rows[first][2], 0) > pos_before.get(rows[first][2], 0) and rows[other][2] in pos_after,
          {'before': pos_before, 'after': pos_after})

    # a tap on a picture chapter opens the image reader
    c.open_book(manga, first)
    open_chapters()
    item = d.find(rows[image][3], exact=True)
    d.tap(item['x'], item['y'], 5)
    t = time.time()
    while time.time() - t < 120 and 'ReaderActivity' not in d.resumed().replace('EbookReaderActivity', ''):
        time.sleep(3)
    resumed = d.resumed()
    time.sleep(10)
    d.shot('s55-chapters-opened-image')
    check('a tap on a picture chapter opens the image reader', 'ui.reader.ReaderActivity' in resumed, resumed)
    c.stop_app()


def add_chapter(manga, source, name):
    c.STEP[0] = 'add_chapter'
    db = c.pull_db('tachiyomi.db')
    folder = db.execute('SELECT url FROM mangas WHERE _id = ?', (manga,)).fetchone()[0]
    local = f'/sdcard/Android/data/{d.PKG}/files/local'
    d.shell(f'cp "{source}" "{local}/{folder}/{name}"')
    rows = chapter_rows(manga)
    added = any(r[2].endswith(name) for r in rows)
    for attempt in range(3):  # a pull to refresh is sometimes not taken on this emulator
        if added:
            break
        d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity -a eu.kanade.tachiyomi.SHOW_MANGA --el manga {manga}')
        time.sleep(8)
        c.wait_app_drawn()
        time.sleep(8)
        c.clear_dialogs()
        d.swipe(540, 500, 540, 1500, ms=700, wait=20)  # pull to refresh
        d.shot(f's55-add-chapter-{attempt + 1}')
        c.stop_app()
        rows = chapter_rows(manga)
        added = any(r[2].endswith(name) for r in rows)
    check('the new file is a chapter of the work', added, rows)


def open_chapters():
    for _ in range(4):
        n = d.find('章節', exact=True)
        if n and n['desc'] == '章節':
            d.tap(n['x'], n['y'], 4)
            return True
        d.tap(540, 960, 4)
        d.wait_for('章節', tries=4)
    return False


def chapter_rows(manga):
    db = c.pull_db('tachiyomi.db')
    return db.execute('SELECT _id, manga_id, url, name, read, bookmark, last_page_read FROM chapters WHERE manga_id = ? ORDER BY _id',
                      (manga,)).fetchall()


def restore_chapter(chapter, read, bookmark, last_page):
    db_path = os.path.join(c.DB, 'tachiyomi.db')
    con = c.pull_db('tachiyomi.db')
    con.execute('UPDATE chapters SET read = ?, bookmark = ?, last_page_read = ? WHERE _id = ?', (read, bookmark, last_page, chapter))
    con.commit()
    con.close()
    d.adb('push', db_path, '/data/local/tmp/tachiyomi.db')
    d.shell(f'run-as {d.PKG} rm -f databases/tachiyomi.db-wal databases/tachiyomi.db-shm')
    d.shell(f'run-as {d.PKG} cp /data/local/tmp/tachiyomi.db databases/tachiyomi.db')


def positions():
    db = c.pull_db('ebook.db')
    return {r[0]: r[1] for r in db.execute('SELECT chapter_url, updated_at FROM position')}

# endregion


# region Settings

def settings_ui(manga, chapter):
    c.STEP[0] = 'settings_ui'
    c.set_prefs({'pref_ebook_page_turn': None, 'pref_bookmania_pager_curl': None}, reset_typesetting=True)
    rotate(False)
    st = c.open_book(manga, chapter)
    if not st or not st.get('ready'):
        return check('the book opened', False, st)
    d.open_panel()
    d.tap_label('版面', wait=3, exact=True)
    ns = []
    for _ in range(12):  # the row is at the end of the 版面 tab
        ns = d.nodes()
        if any(n['text'] == '捲曲' for n in ns) and any(n['text'] == '翻頁動畫' for n in ns):
            break
        d.scroll_panel(320)
    d.shot('s55-settings-text-panel')
    labels = {n['text']: n for n in ns if n['text'] in ('翻頁動畫', '無', '滑動', '捲曲')}

    def chosen(label):
        n = labels.get(label)
        return n is not None and any((m['selected'] or m['checked']) and m['b'][0] <= n['x'] <= m['b'][2]
                                     and m['b'][1] <= n['y'] <= m['b'][3] for m in ns)

    check('the text reader panel has 翻頁動畫 with 無／滑動／捲曲', len(labels) == 4, sorted(labels))
    check('捲曲 is chosen by default', chosen('捲曲') and not chosen('無') and not chosen('滑動'),
          {label: chosen(label) for label in ('無', '滑動', '捲曲')})
    if '滑動' in labels:
        d.tap(labels['滑動']['x'], labels['滑動']['y'], 3)
    d.shot('s55-settings-text-panel-slide')
    c.stop_app()
    prefs = d.prefs()
    check('choosing 滑動 stores pref_ebook_page_turn = slide', 'name="pref_ebook_page_turn">slide<' in prefs, None)

    # Settings > Reader: the new switch next to the existing transition switch
    d.shell(f'am start -n {d.PKG}/eu.kanade.tachiyomi.ui.main.MainActivity')
    time.sleep(6)
    c.wait_app_drawn()
    time.sleep(3)
    c.clear_dialogs()
    for label in ('其他', '設定'):
        d.tap_label(label, wait=3, exact=True)
    # the tap on 閱讀 can be lost while the settings list is still moving in (stage 6, after a cold boot): tapped
    # again while entries of the main settings list are still shown
    for _ in range(3):
        n = d.find('閱讀', exact=True)
        if n:
            d.tap(n['x'], n['y'], 4)
        if not any(x['text'] in ('下載', '探索') for x in d.nodes()):
            break
    found = transitions = None
    for _ in range(6):
        ns = d.nodes()
        found = next((n for n in ns if n['text'] == '捲曲翻頁'), None)
        transitions = next((n for n in ns if n['text'] == '翻頁轉場動畫'), None)
        if found:
            break
        d.swipe(540, 1500, 540, 900, ms=1200, wait=2)
    d.shot('s55-settings-reader')
    check('Settings > Reader has 捲曲翻頁 right after 翻頁轉場動畫',
          found is not None and transitions is not None and 0 < found['y'] - transitions['y'] < 300,
          {'捲曲翻頁': found and found['b'], '翻頁轉場動畫': transitions and transitions['b']})
    if found:
        d.tap(found['x'], found['y'], 3)
    c.stop_app()
    check('the switch stores pref_bookmania_pager_curl = true', 'name="pref_bookmania_pager_curl" value="true"' in d.prefs(), None)

# endregion


def main():
    p = argparse.ArgumentParser()
    p.add_argument('step')
    p.add_argument('args', nargs='*')
    p.add_argument('--columns', default='off')
    p.add_argument('--back', action='store_true')
    p.add_argument('--landscape', action='store_true')
    p.add_argument('--direction')
    p.add_argument('--curl', default='on')
    p.add_argument('--double', action='store_true')
    p.add_argument('--edge')
    p.add_argument('--file', default='zh-varied.epub')
    p.add_argument('--warm', action='store_true')
    p.add_argument('--swipe', action='store_true')
    a = p.parse_args()
    try:
        if a.step == 'text':
            m, ch, style, label = a.args
            ch = int(ch)
            if ch == 0:  # the work's chapter whose file is --file
                ch = next(r[0] for r in chapter_rows(int(m)) if r[2].endswith(a.file))
            text_step(int(m), ch, style, label, a.columns, a.back, a.landscape, a.direction, a.warm)
        elif a.step == 'reanalyse':
            label, style = a.args[:2]
            c.STEP[0] = a.args[2] if len(a.args) > 2 else f'text:{label}'
            reanalyse(label, style, a.back, a.columns == 'on', a.direction == 'rtl', a.edge)
        elif a.step == 'swipe_frames':
            label, curl, direction = a.args
            c.STEP[0] = f'image:{label}'
            swipe_frames(label, curl, direction != 'vertical')
        elif a.step == 'rapid':
            m, ch, style, label = a.args
            rapid_step(int(m), int(ch), style, label)
        elif a.step == 'image':
            m, ch, mode, label = a.args
            image_step(int(m), int(ch), mode, label, a.curl, a.double, a.back, a.swipe)
        elif a.step == 'add_chapter':
            m, source, name = a.args
            add_chapter(int(m), source, name)
        elif a.step == 'chapters':
            m, first, other, image = map(int, a.args)
            chapters_step(m, first, other, image)
        elif a.step == 'settings_ui':
            m, ch = map(int, a.args)
            settings_ui(m, ch)
        else:
            print(__doc__)
            sys.exit(2)
    finally:
        rotate(False)


if __name__ == '__main__':
    main()
