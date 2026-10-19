"""Build a Unicode lookup over the existing licensed 8x8 GB2312 bitmap font."""
from pathlib import Path
import sys
font = Path(sys.argv[1]).read_bytes()
glyphs = []
ascii_font = Path(sys.argv[1]).with_name('font_ascii.bin').read_bytes()
for code in range(32, 127):
    offset = (code - 32) * 9
    glyphs.append((code, ascii_font[offset:offset + 8], max(1, min(ascii_font[offset + 8], 8))))
for high in range(0xA1, 0xF8):
    for low in range(0xA1, 0xFF):
        try:
            char = bytes([high, low]).decode('gb2312')
        except UnicodeDecodeError:
            continue
        index = ((high - 0xA1) * 94 + low - 0xA1) * 8
        if index + 8 <= len(font):
            glyphs.append((ord(char), font[index:index + 8], 8))
print('typedef struct { unsigned short unicode; unsigned char rows[8]; unsigned char width; } unicode_glyph_t;')
print('static const unicode_glyph_t unicode_glyphs[] = {')
for code, rows, width in sorted(glyphs):
    print('{%d,{%s},%d},' % (code, ','.join(str(b) for b in rows), width))
print('};')
