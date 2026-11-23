"""Stage 6, acceptance item 9: long test books. The text is generated here (no third-party content): words
from a small hand-written list in a fixed pseudo-random order, so every run makes the same books.

  long-vertical.epub      EPUB 3, vertical Traditional Chinese, right-to-left; 100 documents (chapters) of
                          about 10,000 characters each, about 1,000,000 characters in all
  long-horizontal.epub    the same text, horizontal, left-to-right
  long-vertical.azw3      KF8 made from long-vertical.epub with Calibre's ebook-convert (a local tool only)
  long-one-document.epub  vertical; the first 100,000 characters in a single document, like a book that was
                          converted without chapter breaks

Usage: python3 -I make_long_books.py <output dir>
Prints each file with its size and the number of characters.
"""
import os
import random
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'out', 'long-books'))
sys.argv = [sys.argv[0], OUT_DIR]  # make_testbooks reads its output folder from argv at import
sys.dont_write_bytecode = True  # no __pycache__ in core/ebook/testbooks
sys.path.insert(0, os.path.join(HERE, '..', '..', '..', '..', 'core', 'ebook', 'testbooks'))
import make_testbooks as mt  # noqa: E402

WORDS = ('今天 早上 天氣 晴朗 我們 一起 走到 河邊 看見 許多 小船 慢慢 划過 水面 遠處 山上 雲霧 '
         '漸漸 散開 陽光 照在 樹林 之間 鳥兒 開始 唱歌 村子 裡的 人們 忙著 準備 午飯 孩子 跑來 跑去 '
         '老師 說過 讀書 需要 耐心 時間 過得 很快 轉眼 已經 黃昏 街上 燈火 一盞 一盞 亮起 窗外 '
         '下起 小雨 屋頂 傳來 細細 聲音 他們 談到 從前 的事 有人 笑了 也有人 沉默 不語 這座 城市 '
         '變化 很大 新的 道路 舊的 巷子 市場 熱鬧 書店 安靜 圖書館 桌上 放著 一本 厚厚 小說 翻開 '
         '第一頁 故事 從這裡 開始 旅人 背著 行囊 穿過 田野 越過 橋樑 來到 海邊 浪花 拍打 岩石 '
         '風吹 衣角 心情 平靜 記得 那年 夏天 我們 種下 一棵 樹 如今 枝葉 茂盛 每到 秋天 落葉 '
         '鋪滿 小路 腳步 輕輕 走過 留下 回憶').split()


def paragraph(rng, chapter, n, target):
    """About [target] characters: a marker, then sentences of 4-9 words."""
    out = f'【第{str(chapter).translate(mt.FW)}章第{str(n).translate(mt.FW)}段】'
    while len(out) < target:
        words = [rng.choice(WORDS) for _ in range(rng.randint(4, 9))]
        if rng.random() < 0.15:
            words.insert(rng.randint(1, len(words) - 1), '「' + rng.choice(WORDS) + rng.choice(WORDS) + '」')
        out += ''.join(words) + rng.choice('，，，。。！？')
    return '<p>' + out.rstrip('，') + '。</p>'


def chapters(n_chapters, chars_per_chapter, seed=2026):
    rng = random.Random(seed)
    out, total = [], 0
    for c in range(1, n_chapters + 1):
        body, size, n = [f'<h1>第{str(c).translate(mt.FW)}章　長篇測試</h1>'], 0, 1
        while size < chars_per_chapter:
            p = paragraph(rng, c, n, rng.randint(120, 320))
            body.append(p)
            size += len(p) - 7  # without <p></p>
            n += 1
        total += size
        out.append((f'ch{c:03d}', f'第{c}章', '\n'.join(body)))
    return out, total


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    made = []
    chs, total = chapters(100, 10_000)
    for name, vertical in (('long-vertical.epub', True), ('long-horizontal.epub', False)):
        path = os.path.join(OUT_DIR, name)
        mt.write_epub(path, title='長篇測試書（' + ('直排' if vertical else '橫排') + '）', lang='zh-Hant',
                      uid=f'urn:uuid:bookmania-long-{"v" if vertical else "h"}', chapters=chs, vertical=vertical,
                      ppd='rtl' if vertical else 'ltr')
        made.append((path, total))
    one, one_total = chapters(1, 100_000, seed=7)
    path = os.path.join(OUT_DIR, 'long-one-document.epub')
    mt.write_epub(path, title='長篇測試書（單一檔案）', lang='zh-Hant', uid='urn:uuid:bookmania-long-one',
                  chapters=one, vertical=True, ppd='rtl')
    made.append((path, one_total))
    conv = shutil.which('ebook-convert')
    if conv:
        dst = os.path.join(OUT_DIR, 'long-vertical.azw3')
        r = subprocess.run([conv, os.path.join(OUT_DIR, 'long-vertical.epub'), dst, '--no-inline-toc'],
                           env=dict(os.environ, QT_QPA_PLATFORM='offscreen'), capture_output=True, text=True)
        if r.returncode == 0:
            made.append((dst, total))
        else:
            print('ebook-convert failed:', r.stderr[-500:])
    else:
        print('ebook-convert not found: no AZW3')
    for path, n in made:
        print(f'{os.path.getsize(path):>10} bytes  {n:>9} characters  {os.path.basename(path)}')


if __name__ == '__main__':
    main()
