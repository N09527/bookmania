#!/usr/bin/env python3
"""Generates the tiny fonts used by FontInspectorTest (needs fontTools).

    python3 make_testfonts.py ../src/test/resources/fixtures/fonts

- vertical-ok.ttf     TrueType with vhea/vmtx and a GSUB 'vert' feature; names in English and zh-TW
- horizontal-only.ttf TrueType without any vertical data
- vertical-cff.otf    CFF-flavoured OpenType with vhea/vmtx and 'vrt2'
"""
import os
import sys

from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.ttGlyphPen import TTGlyphPen

GLYPHS = ['.notdef', 'uni4E00', 'uni3001', 'uni3001.vert']
CMAP = {0x4E00: 'uni4E00', 0x3001: 'uni3001'}


def square_tt():
    pen = TTGlyphPen(None)
    pen.moveTo((100, 100)); pen.lineTo((900, 100)); pen.lineTo((900, 900)); pen.lineTo((100, 900)); pen.closePath()
    return pen.glyph()


def square_cff():
    pen = T2CharStringPen(1000, None)
    pen.moveTo((100, 100)); pen.lineTo((900, 100)); pen.lineTo((900, 900)); pen.lineTo((100, 900)); pen.closePath()
    return pen.getCharString()


def build(path, *, cff, vertical, feature, names):
    fb = FontBuilder(1000, isTTF=not cff)
    fb.setupGlyphOrder(GLYPHS)
    fb.setupCharacterMap(CMAP)
    if cff:
        fb.setupCFF(names['en'], {'FullName': names['en']}, {g: square_cff() for g in GLYPHS}, {})
    else:
        fb.setupGlyf({g: square_tt() for g in GLYPHS})
    fb.setupHorizontalMetrics({g: (1000, 100) for g in GLYPHS})
    fb.setupHorizontalHeader(ascent=880, descent=-120)
    family = {'en': names['en']}
    if 'zh-TW' in names:
        family['zh-TW'] = names['zh-TW']
    fb.setupNameTable({'familyName': family, 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=880, sTypoDescender=-120, usWinAscent=880, usWinDescent=120)
    fb.setupPost()
    if vertical:
        fb.setupVerticalMetrics({g: (1000, 100) for g in GLYPHS})
        fb.setupVerticalHeader(ascent=500, descent=-500)
    if feature:
        addOpenTypeFeaturesFromString(fb.font, f'feature {feature} {{ sub uni3001 by uni3001.vert; }} {feature};')
    fb.save(path)
    print('wrote', path, os.path.getsize(path), 'bytes')


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'fonts'
    os.makedirs(out, exist_ok=True)
    build(os.path.join(out, 'vertical-ok.ttf'), cff=False, vertical=True, feature='vert',
          names={'en': 'Bookmania Test Vertical', 'zh-TW': '書狂測試直排'})
    build(os.path.join(out, 'horizontal-only.ttf'), cff=False, vertical=False, feature=None,
          names={'en': 'Bookmania Test Horizontal'})
    build(os.path.join(out, 'vertical-cff.otf'), cff=True, vertical=True, feature='vrt2',
          names={'en': 'Bookmania Test CFF'})


if __name__ == '__main__':
    main()
