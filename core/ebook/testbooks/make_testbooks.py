#!/usr/bin/env python3
"""Generate the e-book test fixtures used by :core:ebook unit tests.

All text is original (written for these tests); images are drawn here; the embedded
test font is a tiny synthetic font built with fontTools. MOBI/AZW3 files are produced
with Calibre's `ebook-convert` (only used as an external tool, not shipped).

Usage: python3 make_testbooks.py <output-dir>
"""
import hashlib
import io
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
import zipfile

OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'out')
os.makedirs(OUT, exist_ok=True)
FW = str.maketrans('0123456789', '０１２３４５６７８９')


# ---------------------------------------------------------------- content
def zh_paragraph(n):
    num = str(n).translate(FW)
    k = n % 5
    if k == 0:
        return f'<p>【第{num}段】這是一段用來測試的文字，包含「引號」、『雙引號』、（括號）與全形標點：逗號，句號。驚嘆號！問號？</p>'
    if k == 1:
        return f'<p>【第{num}段】英文單字 WebView 與阿拉伯數字 {n} 混在其中；年份寫成二〇二六年；省略號……與破折號——也要檢查。</p>'
    if k == 2:
        return (f'<p>【第{num}段】<ruby>漢<rt>ㄏㄢˋ</rt></ruby><ruby>字<rt>ㄗˋ</rt></ruby>可以加上注音；'
                f'日期<span class="tcy">12</span>月<span class="tcy">31</span>日使用縱中橫。</p>')
    if k == 3:
        return f'<p>【第{num}段】長一點的段落：閱讀程式需要依照使用者的設定調整字級、行距、字距、首行縮排與段落間距，並且在直書與橫書之間切換，翻頁時內容不可缺漏也不可重複。</p>'
    return f'<p>【第{num}段】短段落。</p>'


def ja_paragraph(n):
    num = str(n).translate(FW)
    k = n % 3
    if k == 0:
        return f'<p>第{num}段落。これは縦書きの試験用に書いた文章です。「かぎ括弧」や、読点、句点。を含みます。</p>'
    if k == 1:
        return f'<p>第{num}段落。<ruby>漢字<rt>かんじ</rt></ruby>にふりがなを付けます。数字の<span class="tcy">25</span>は縦中横です。</p>'
    return f'<p>第{num}段落。短い段落です。</p>'


def xhtml(title, body, lang, extra_head=''):
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="{lang}" xml:lang="{lang}">
<head>
<meta charset="UTF-8"/>
<title>{title}</title>
<link rel="stylesheet" type="text/css" href="../styles/book.css"/>{extra_head}
</head>
<body>
{body}
</body>
</html>
'''


def css(vertical):
    wm = 'vertical-rl' if vertical else 'horizontal-tb'
    return f'''@charset "UTF-8";
html {{ writing-mode: {wm}; -webkit-writing-mode: {wm}; -epub-writing-mode: {wm}; }}
body {{ margin: 0; padding: 0; }}
p {{ margin: 0; text-indent: 1em; }}
h1 {{ font-size: 1.4em; }}
.tcy {{ text-combine-upright: all; -webkit-text-combine: horizontal; }}
.fig {{ text-indent: 0; text-align: center; }}
'''


# ---------------------------------------------------------------- images
def png(width, height, label, color):
    from PIL import Image, ImageDraw
    im = Image.new('RGB', (width, height), color)
    d = ImageDraw.Draw(im)
    d.rectangle([20, 20, width - 20, height - 20], outline=(30, 30, 30), width=6)
    d.ellipse([width // 4, height // 4, width * 3 // 4, height // 4 + width // 2], outline=(30, 30, 30), width=6)
    d.text((40, height - 80), label, fill=(0, 0, 0))
    b = io.BytesIO()
    im.save(b, 'PNG', optimize=True)
    return b.getvalue()


# ---------------------------------------------------------------- font
def tiny_font():
    """A tiny synthetic TrueType font (one box glyph mapped to a few code points)."""
    try:
        from fontTools.fontBuilder import FontBuilder
        from fontTools.pens.ttGlyphPen import TTGlyphPen
    except ImportError:
        return None
    fb = FontBuilder(1000, isTTF=True)
    glyphs = ['.notdef', 'box']
    fb.setupGlyphOrder(glyphs)
    fb.setupCharacterMap({ord(c): 'box' for c in '測試字型ABC'})
    pen = TTGlyphPen(None)
    pen.moveTo((100, 0)); pen.lineTo((100, 800)); pen.lineTo((900, 800)); pen.lineTo((900, 0)); pen.closePath()
    box = pen.glyph()
    fb.setupGlyf({'.notdef': box, 'box': box})
    fb.setupHorizontalMetrics({'.notdef': (1000, 100), 'box': (1000, 100)})
    fb.setupHorizontalHeader(ascent=880, descent=-120)
    fb.setupNameTable({'familyName': 'BookmaniaTestFont', 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=880, sTypoDescender=-120, usWinAscent=880, usWinDescent=120)
    fb.setupPost()
    b = io.BytesIO()
    fb.save(b)
    return b.getvalue()


def idpf_obfuscate(data, unique_id):
    key = hashlib.sha1(''.join(unique_id.split()).encode('utf-8')).digest()
    out = bytearray(data)
    for i in range(min(1040, len(out))):
        out[i] ^= key[i % len(key)]
    return bytes(out)


# ---------------------------------------------------------------- EPUB writer
def write_epub(path, *, title, lang, uid, chapters, vertical=False, ppd=None, layout=None,
               images=None, cover=None, fonts=None, encryption_xml=None, extra_meta_inf=None,
               nav=True, ncx=True, version='3.0', raw_override=None):
    """chapters: list of (id, title, body_html). images: {href: bytes}. fonts: {href: bytes}."""
    images = images or {}
    fonts = fonts or {}
    manifest, spine = [], []
    if nav and version.startswith('3'):
        manifest.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
    if ncx:
        manifest.append('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
    manifest.append('<item id="css" href="styles/book.css" media-type="text/css"/>')
    for href in images:
        mid = 'img-' + os.path.splitext(os.path.basename(href))[0]
        props = ' properties="cover-image"' if (cover == href and version.startswith('3')) else ''
        mt = 'image/png' if href.endswith('.png') else 'image/jpeg'
        manifest.append(f'<item id="{mid}" href="{href}" media-type="{mt}"{props}/>')
    for href in fonts:
        manifest.append(f'<item id="font-{os.path.basename(href).split(".")[0]}" href="{href}" media-type="font/ttf"/>')
    for cid, ctitle, _ in chapters:
        manifest.append(f'<item id="{cid}" href="text/{cid}.xhtml" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="{cid}"/>')
    meta = [f'<dc:identifier id="bookid">{uid}</dc:identifier>', f'<dc:title>{title}</dc:title>',
            '<dc:creator>Bookmania 測試</dc:creator>', f'<dc:language>{lang}</dc:language>']
    if version.startswith('3'):
        meta.append('<meta property="dcterms:modified">2026-11-18T00:00:00Z</meta>')
    if layout:
        meta.append(f'<meta property="rendition:layout">{layout}</meta>')
    if cover:
        meta.append(f'<meta name="cover" content="img-{os.path.splitext(os.path.basename(cover))[0]}"/>')
    spine_attrs = (f' page-progression-direction="{ppd}"' if ppd else '') + (' toc="ncx"' if ncx else '')
    prefix = ' prefix="rendition: http://www.idpf.org/vocab/rendition/#"' if layout else ''
    opf = f'''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="{version}" unique-identifier="bookid" xml:lang="{lang}"{prefix}>
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
{chr(10).join(meta)}
</metadata>
<manifest>
{chr(10).join(manifest)}
</manifest>
<spine{spine_attrs}>
{chr(10).join(spine)}
</spine>
</package>
'''
    nav_doc = xhtml('目錄', '<nav epub:type="toc" id="toc"><h1>目錄</h1><ol>' + ''.join(
        f'<li><a href="text/{cid}.xhtml">{ct}</a></li>' for cid, ct, _ in chapters) + '</ol></nav>', lang).replace('../styles/', 'styles/')
    ncx_doc = f'''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="{uid}"/></head>
<docTitle><text>{title}</text></docTitle>
<navMap>
''' + ''.join(f'<navPoint id="np{i}" playOrder="{i + 1}"><navLabel><text>{ct}</text></navLabel><content src="text/{cid}.xhtml"/></navPoint>\n'
              for i, (cid, ct, _) in enumerate(chapters)) + '</navMap>\n</ncx>\n'
    container = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
'''
    files = {'META-INF/container.xml': container.encode(), 'OEBPS/content.opf': opf.encode(),
             'OEBPS/styles/book.css': css(vertical).encode()}
    if nav and version.startswith('3'):
        files['OEBPS/nav.xhtml'] = nav_doc.encode()
    if ncx:
        files['OEBPS/toc.ncx'] = ncx_doc.encode()
    for cid, ctitle, body in chapters:
        files[f'OEBPS/text/{cid}.xhtml'] = xhtml(ctitle, body, lang, '\n<meta name="viewport" content="width=600, height=900"/>' if layout == 'pre-paginated' else '').encode()
    for href, data in images.items():
        files['OEBPS/' + href] = data
    for href, data in fonts.items():
        files['OEBPS/' + href] = data
    if encryption_xml:
        files['META-INF/encryption.xml'] = encryption_xml.encode()
    for name, data in (extra_meta_inf or {}).items():
        files['META-INF/' + name] = data
    for name, data in (raw_override or {}).items():
        files[name] = data
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        for name, data in files.items():
            z.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
    return path


def chapters_zh(n_chapters, paras_per_chapter, with_figure=False, links=False):
    out, n = [], 1
    for c in range(1, n_chapters + 1):
        body = [f'<h1>第{str(c).translate(FW)}章　測試章節</h1>']
        for _ in range(paras_per_chapter):
            body.append(zh_paragraph(n)); n += 1
        if with_figure and c == 1:
            body.insert(3, '<p class="fig"><img src="../images/fig1.png" alt="插圖一"/></p>')
        if links and c == 1:
            body.append('<p>註腳測試：<a epub:type="noteref" href="#note1" id="ref1">註一</a>；'
                        '外部連結：<a href="https://example.com/">example.com</a>；'
                        f'跨章連結：<a href="ch{2:02d}.xhtml#p2">第二章</a>。</p>')
            body.append('<aside epub:type="footnote" id="note1"><p>註一：這是書內註腳。</p></aside>')
        out.append((f'ch{c:02d}', f'第{c}章', '\n'.join(body)))
    if links and n_chapters >= 2:
        cid, ct, b = out[1]
        out[1] = (cid, ct, b.replace('<p>', '<p id="p2">', 1))
    return out


def main():
    made = []
    # 1. Vertical Traditional Chinese, RTL spread, with figure, ruby, links, cover.
    imgs = {'images/fig1.png': png(600, 800, 'FIG 1', (220, 230, 240)), 'images/cover.png': png(600, 900, 'COVER', (240, 220, 200))}
    made.append(write_epub(f'{OUT}/zh-vertical.epub', title='直排測試書', lang='zh-Hant', uid='urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000001',
                           chapters=chapters_zh(3, 40, with_figure=True, links=True), vertical=True, ppd='rtl', images=imgs, cover='images/cover.png'))
    # 2. Horizontal Traditional Chinese, LTR.
    made.append(write_epub(f'{OUT}/zh-horizontal.epub', title='橫排測試書', lang='zh-Hant', uid='urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000002',
                           chapters=chapters_zh(3, 40, links=True), vertical=False, ppd='ltr'))
    # 3. Japanese vertical.
    ja = [(f'ch{c:02d}', f'第{c}章', '\n'.join([f'<h1>第{c}章</h1>'] + [ja_paragraph(i) for i in range(1, 31)])) for c in (1, 2)]
    made.append(write_epub(f'{OUT}/ja-vertical.epub', title='縦書きテスト', lang='ja', uid='urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000003',
                           chapters=ja, vertical=True, ppd='rtl'))
    # 4. Text book with several illustrations (must still be treated as text).
    imgs4 = {f'images/fig{i}.png': png(500, 700, f'FIG {i}', (200 + i * 10, 220, 230)) for i in range(1, 4)}
    ch4 = chapters_zh(2, 30)
    ch4[0] = (ch4[0][0], ch4[0][1], ch4[0][2] + ''.join(f'<p class="fig"><img src="../images/fig{i}.png" alt=""/></p>' for i in range(1, 4)))
    made.append(write_epub(f'{OUT}/text-with-images.epub', title='圖文書', lang='zh-Hant', uid='urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000004',
                           chapters=ch4, images=imgs4))
    # 5. Comic, fixed layout (one image per page).
    pages = {f'images/p{i:03d}.png': png(600, 900, f'PAGE {i}', (250, 250, 250 - i * 10)) for i in range(1, 7)}
    comic_ch = [(f'p{i:03d}', f'{i}', f'<div><img src="../images/p{i:03d}.png" alt=""/></div>') for i in range(1, 7)]
    made.append(write_epub(f'{OUT}/comic-fixed.epub', title='漫畫測試', lang='ja', uid='urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000005',
                           chapters=comic_ch, ppd='rtl', layout='pre-paginated', images=pages, cover='images/p001.png'))
    # 6. Comic, reflowable (no rendition:layout), image-only pages.
    made.append(write_epub(f'{OUT}/comic-reflowable.epub', title='漫畫測試二', lang='ja', uid='urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000006',
                           chapters=comic_ch, ppd='rtl', images=pages))
    # 7. EPUB 2 with NCX only.
    made.append(write_epub(f'{OUT}/epub2-ncx.epub', title='EPUB2 測試', lang='zh-Hant', uid='urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000007',
                           chapters=chapters_zh(2, 10), version='2.0', nav=False))
    # 8. Embedded font obfuscated with the IDPF algorithm (not DRM).
    uid8 = 'urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000008'
    font = tiny_font()
    if font:
        enc8 = '''<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
<enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
<enc:CipherData><enc:CipherReference URI="OEBPS/fonts/test.ttf"/></enc:CipherData></enc:EncryptedData>
</encryption>
'''
        made.append(write_epub(f'{OUT}/font-obfuscated.epub', title='字型混淆測試', lang='zh-Hant', uid=uid8,
                               chapters=chapters_zh(1, 5), fonts={'fonts/test.ttf': idpf_obfuscate(font, uid8)}, encryption_xml=enc8))
        with open(f'{OUT}/font-obfuscated.expected.ttf', 'wb') as f:
            f.write(font)
    # 9. DRM-protected sample (Adobe ADEPT style markers; the content is random bytes).
    rnd = random.Random(9)
    enc9 = '''<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
<enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
<enc:CipherData><enc:CipherReference URI="OEBPS/text/ch01.xhtml"/></enc:CipherData></enc:EncryptedData>
</encryption>
'''
    rights = b'<?xml version="1.0"?><adept:rights xmlns:adept="http://ns.adobe.com/adept"><adept:licenseToken/></adept:rights>'
    made.append(write_epub(f'{OUT}/drm-adept.epub', title='DRM 測試', lang='zh-Hant', uid='urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000009',
                           chapters=chapters_zh(1, 5), encryption_xml=enc9, extra_meta_inf={'rights.xml': rights},
                           raw_override={'OEBPS/text/ch01.xhtml': bytes(rnd.getrandbits(8) for _ in range(2048))}))
    # 10. Corrupt EPUB (truncated zip) and a non-ebook file with an .epub extension.
    with open(f'{OUT}/zh-horizontal.epub', 'rb') as f:
        data = f.read()
    with open(f'{OUT}/corrupt-truncated.epub', 'wb') as f:
        f.write(data[: len(data) * 3 // 5])
    with open(f'{OUT}/not-an-ebook.epub', 'wb') as f:
        f.write(b'This is plain text, not a ZIP archive.\n' * 20)
    made += [f'{OUT}/corrupt-truncated.epub', f'{OUT}/not-an-ebook.epub']

    # 11. MOBI 6, KF8 (AZW3) and joint MOBI via Calibre, plus a DRM-flagged MOBI.
    conv = shutil.which('ebook-convert')
    if conv:
        env = dict(os.environ, QT_QPA_PLATFORM='offscreen')
        jobs = [('zh-horizontal.epub', 'zh-horizontal-mobi6.mobi', ['--mobi-file-type', 'old']),
                ('zh-horizontal.epub', 'zh-horizontal.azw3', []),
                ('zh-vertical.epub', 'zh-vertical.azw3', []),
                ('zh-vertical.epub', 'zh-vertical-joint.mobi', ['--mobi-file-type', 'both']),
                ('text-with-images.epub', 'text-with-images-mobi6.mobi', ['--mobi-file-type', 'old'])]
        for src, dst, extra in jobs:
            r = subprocess.run([conv, f'{OUT}/{src}', f'{OUT}/{dst}', '--no-inline-toc'] + extra,
                               env=env, capture_output=True, text=True)
            if r.returncode != 0:
                print('ebook-convert failed', dst, r.stderr[-500:])
                continue
            made.append(f'{OUT}/{dst}')
        src = f'{OUT}/zh-horizontal-mobi6.mobi'
        if os.path.exists(src):
            b = bytearray(open(src, 'rb').read())
            rec0 = struct.unpack('>I', b[78:82])[0]          # offset of record 0
            b[rec0 + 12: rec0 + 14] = struct.pack('>H', 2)   # PalmDOC header: encryption type = 2 (Mobipocket)
            open(f'{OUT}/drm-flagged.mobi', 'wb').write(bytes(b))
            made.append(f'{OUT}/drm-flagged.mobi')
    else:
        print('ebook-convert not found: MOBI/AZW3 fixtures skipped')

    for p in made:
        print(f'{os.path.getsize(p):>9}  {os.path.basename(p)}')


if __name__ == '__main__':
    main()
