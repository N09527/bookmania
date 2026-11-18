# Test books

`make_testbooks.py` generates every file in `src/test/resources/fixtures/`.

- All text is original and written for these tests; images are drawn by the script;
  the embedded font in `font-obfuscated.epub` is a synthetic font built with fontTools.
- MOBI and AZW3 files are converted from the generated EPUBs with Calibre 7.6.0
  `ebook-convert` (Calibre is GPL-3.0 and is only used as an external tool to make test
  data; nothing from Calibre is included in the app).
- `drm-adept.epub` only imitates the markers of a DRM-protected EPUB (an `encryption.xml`
  entry that is not font obfuscation, plus `META-INF/rights.xml`); its "encrypted" chapter is random bytes.
- `drm-flagged.mobi` is `zh-horizontal-mobi6.mobi` with the PalmDOC encryption field set to 2.

Requirements: Python 3, Pillow, fontTools, Calibre (`ebook-convert`) for MOBI/AZW3.

```bash
python3 make_testbooks.py ../src/test/resources/fixtures
```
