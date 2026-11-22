"""A test EPUB whose content tries what book content must not do (Bookmania stage 6 security check, see
check_security.py): scripts (inline, a script file, event attributes, a javascript: link, SVG), a refresh
meta, frames, objects, a form, media, and resources from another host (pictures, style sheets, @import,
@font-face, CSS backgrounds) and from a local file (file://). Only for testing: nothing in it is harmful,
the "attacks" only set marker variables or ask the test server for a file.

Usage: python3 -I make_hostile_epub.py <out.epub> <host:port of the test server, e.g. 10.0.2.2:8765>
"""
import struct
import sys
import zipfile
import zlib


def png(width=8, height=8, rgb=(200, 40, 40)):
    """A small plain PNG (the picture inside the book; the same picture as a local file for the file:// test)."""
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    row = b'\x00' + bytes(rgb) * width
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(row * height)) + chunk(b'IEND', b''))


def chapter(host):
    u = f'http://{host}'
    return f'''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xml:lang="zh-Hant">
<head>
<title>安全測試</title>
<meta http-equiv="refresh" content="0;url={u}/refresh"/>
<script>window.__bm_inline = 1; document.title = 'SCRIPT-RAN';</script>
<script src="evil.js"></script>
<link rel="stylesheet" href="{u}/external.css"/>
<link rel="prefetch" href="{u}/prefetch"/>
<link rel="stylesheet" href="style.css"/>
<style>
@import url({u}/import.css);
@font-face {{ font-family: bmexternal; src: url({u}/font.ttf); }}
.bg {{ background-image: url({u}/background.png); font-family: bmexternal, serif; }}
</style>
</head>
<body onload="window.__bm_onload = 1">
<h1>安全測試頁</h1>
<p id="marker">這一頁的內容不可信：書裡的腳本不應執行，也不應連網或讀取 App 的其他檔案。</p>
<p class="bg">這一段的背景圖與字型來自另一台主機。</p>
<p><img id="inbook" src="images/ok.png" alt="書內的圖片"/></p>
<p><img id="external" src="{u}/image.png" alt="另一台主機的圖片"/></p>
<p><img id="localfile" src="file:///sdcard/Download/bm-file.png" alt="本機檔案"/></p>
<p><img id="handler" src="images/missing.png" onerror="window.__bm_onerror = 1" alt="事件屬性"/></p>
<p><a id="jslink" href="javascript:window.__bm_js = 1">javascript 連結</a></p>
<iframe src="{u}/iframe"></iframe>
<object data="{u}/object"><p>object 的替代內容</p></object>
<embed src="{u}/embed"/>
<form action="{u}/form"><input name="q" value="x"/></form>
<video src="{u}/video.mp4"></video>
<audio src="{u}/audio.mp3"></audio>
<svg:svg width="10" height="10"><svg:script>window.__bm_svg = 1</svg:script><svg:image xlink:href="{u}/svg-image.png" width="10" height="10"/></svg:svg>
<p style="background: url({u}/inline-style.png)">行內樣式的背景來自另一台主機。</p>
<p>最後一段。</p>
</body></html>'''


def main(out, host):
    opf = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id" xml:lang="zh-Hant">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="id">bookmania-test-security</dc:identifier><dc:title>安全測試</dc:title>
<dc:language>zh-Hant</dc:language><meta property="dcterms:modified">2026-11-22T00:00:00Z</meta>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml" properties="scripted svg"/>
<item id="js" href="evil.js" media-type="application/javascript"/>
<item id="css" href="style.css" media-type="text/css"/>
<item id="img" href="images/ok.png" media-type="image/png"/>
</manifest>
<spine><itemref idref="c1"/></spine>
</package>'''
    nav = '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目錄</title></head>
<body><nav epub:type="toc"><ol><li><a href="c1.xhtml">安全測試頁</a></li></ol></nav></body></html>'''
    container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''
    u = f'http://{host}'
    with zipfile.ZipFile(out, 'w') as z:
        z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        z.writestr('META-INF/container.xml', container, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/content.opf', opf, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/nav.xhtml', nav, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/c1.xhtml', chapter(host), compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/evil.js', 'window.__bm_file = 1;\n', compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/style.css', f'@import url({u}/import2.css);\n#marker {{ background: url({u}/css-background.png); }}\n',
                   compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/images/ok.png', png(), compress_type=zipfile.ZIP_STORED)


if __name__ == '__main__':
    if len(sys.argv) == 3:
        main(sys.argv[1], sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == '--png':
        sys.stdout.buffer.write(png())
    else:
        print(__doc__)
        sys.exit(2)
