# Generates deterministic test chapters (original text written for this test).
import sys, os
out = sys.argv[1]
fw = str.maketrans('0123456789', '０１２３４５６７８９')

def zh_para(n):
    k = n % 5
    num = str(n).translate(fw)
    if k == 0:
        return f'<p>【第{num}段】這是一段用來測試直排的文字，包含「引號」、『雙引號』、（括號）與全形標點：逗號，句號。驚嘆號！問號？</p>'
    if k == 1:
        return f'<p>【第{num}段】英文單字 WebView 與阿拉伯數字 {n} 混在其中；年份寫成二〇二六年；省略號……與破折號——也要檢查。</p>'
    if k == 2:
        return f'<p>【第{num}段】<ruby>漢<rt>ㄏㄢˋ</rt></ruby><ruby>字<rt>ㄗˋ</rt></ruby>可以加上注音；日期<span class="tcy">12</span>月<span class="tcy">31</span>日使用縱中橫。段落之間保留間距。</p>'
    if k == 3:
        return f'<p>【第{num}段】長一點的段落：閱讀程式需要依照使用者的設定調整字級、行距、字距、首行縮排與段落間距，並且在直書與橫書之間切換，翻頁時內容不可缺漏也不可重複。</p>'
    return f'<p>【第{num}段】短段落。</p>'

def page(lang, title, body, vertical=True):
    wm = 'vertical-rl' if vertical else 'horizontal-tb'
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="{lang}" xml:lang="{lang}">
<head>
<meta charset="UTF-8"/>
<title>{title}</title>
<link rel="stylesheet" type="text/css" href="style.css"/>
<style>html {{ writing-mode: {wm}; -epub-writing-mode: {wm}; }}</style>
<script>document.title = "SCRIPT_RAN"; try {{ parent.postMessage("book-script-ran", "*"); }} catch (e) {{}}</script>
</head>
<body>
<h1>{title}</h1>
{body}
</body>
</html>
'''

paras = []
for n in range(1, 121):
    paras.append(zh_para(n))
    if n == 30:
        paras.append('<p class="fig"><img src="fig.svg" alt="插圖"/></p>')
    if n == 45:
        # security probes: remote image, inline handler, external link, internal footnote link
        paras.append('<p>【安全測試】<img src="https://example.com/track.png" alt="remote" onerror="document.title=\'HANDLER_RAN\'"/><a href="https://example.com/">外部連結</a>與<a href="#note1" id="ref1">註一</a>。</p>')
paras.append('<aside epub:type="footnote" id="note1"><p>註一：這是書內註腳。</p></aside>')
open(os.path.join(out, 'zh.xhtml'), 'w', encoding='utf-8').write(page('zh-Hant', '第一章　直排測試', '\n'.join(paras)))

css = '''@charset "UTF-8";
body { margin: 0; padding: 0; }
p { margin: 0; text-indent: 1em; }
h1 { font-size: 1.4em; margin: 0 0 1em 0; }
.tcy { text-combine-upright: all; -webkit-text-combine: horizontal; }
.fig { text-indent: 0; text-align: center; }
'''
open(os.path.join(out, 'style.css'), 'w', encoding='utf-8').write(css)

svg = '''<svg xmlns="http://www.w3.org/2000/svg" width="300" height="400" viewBox="0 0 300 400">
<rect width="300" height="400" fill="#dde6f0"/><circle cx="150" cy="160" r="90" fill="#7a9cc6"/>
<text x="150" y="330" font-size="40" text-anchor="middle" fill="#234">FIG.1</text></svg>'''
open(os.path.join(out, 'fig.svg'), 'w', encoding='utf-8').write(svg)
print('ok')
