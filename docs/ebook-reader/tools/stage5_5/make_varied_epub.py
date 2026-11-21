"""A small horizontal EPUB whose pages all look different (Bookmania stage 5.5 page turn checks): paragraphs
of random common characters with varied lengths, so that no two pages or spreads match pixel for pixel."""
import random
import sys
import zipfile

POOL = ('的一是在不了有和人這中大為上個國我以要他時來用們生到作地於出就分對成會可主發年動同工也能下過子說產種面而方後多定行學法所民得經十三之進著等部度家電力裡如水化高自二理起小物現實加量都兩體制機當使點從業本去把性好應開它合還因由其些然前外天政四日那社義事平形相全表間樣與關各重新線內數正心反你明看原又麼利比或但質氣第向道命此變條只沒結解問意建月公無系軍很情者最立代想已通並提直題黨程展五果料象員革位入常文總次品式活設及管特件長求老頭基資邊流路級少圖山統接知較將組見計別她手角期根論運農指幾九區強放決西被幹做必戰先回則任取據處府研質')
rng = random.Random(55)


def para(n):
    return ''.join(rng.choice(POOL) for _ in range(n))


def chapter(i):
    ps = []
    for k in range(60):
        size = rng.choice([8, 14, 22, 35, 50, 70, 95])
        ps.append(f'<p>（{i}-{k + 1}）{para(size)}。</p>')
        if k % 9 == 4:
            ps.append(f'<h2>小節 {i}.{k // 9 + 1}　{para(4)}</h2>')
    body = '\n'.join(ps)
    return f'''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-Hant"><head><title>第{i}章</title></head>
<body><h1>第{i}章　{para(6)}</h1>
{body}
</body></html>'''


def main(out):
    chapters = [chapter(i) for i in range(1, 4)]
    manifest = '\n'.join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(1, 4))
    spine = '\n'.join(f'<itemref idref="c{i}"/>' for i in range(1, 4))
    nav_items = '\n'.join(f'<li><a href="c{i}.xhtml">第{i}章</a></li>' for i in range(1, 4))
    opf = f'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id" xml:lang="zh-Hant">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="id">bookmania-test-varied</dc:identifier><dc:title>翻頁測試（不重複內容）</dc:title>
<dc:language>zh-Hant</dc:language><meta property="dcterms:modified">2026-11-21T00:00:00Z</meta>
</metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
{manifest}</manifest>
<spine>{spine}</spine>
</package>'''
    nav = f'''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目錄</title></head>
<body><nav epub:type="toc"><ol>{nav_items}</ol></nav></body></html>'''
    container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''
    with zipfile.ZipFile(out, 'w') as z:
        z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        z.writestr('META-INF/container.xml', container, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/content.opf', opf, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/nav.xhtml', nav, compress_type=zipfile.ZIP_DEFLATED)
        for i, text in enumerate(chapters, 1):
            z.writestr(f'OEBPS/c{i}.xhtml', text, compress_type=zipfile.ZIP_DEFLATED)


if __name__ == '__main__':
    main(sys.argv[1])
