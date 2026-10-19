"""Generate the redistributable Lingxi Sans AA subset from Noto CJK (OFL-1.1).

2-bit grayscale grouped LZ is deliberately used instead of pixel font outlines or a
runtime TrueType library. Source: notofonts/noto-cjk Sans/OTF/SimplifiedChinese.
"""
from pathlib import Path
import hashlib
import sys
from PIL import Image, ImageDraw, ImageFont

source, destination = map(Path, sys.argv[1:3])
codes = set(range(32, 127)) | {0x00B0, 0x00B7, 0x2103, 0x2026, 0x2212}
for high in range(0xA1, 0xF8):
    for low in range(0xA1, 0xFF):
        try:
            codes.add(ord(bytes([high, low]).decode("gb2312")))
        except UnicodeDecodeError:
            pass

def build(size, characters, bits=2, group_size=64):
    font = ImageFont.truetype(str(source), size)
    records, groups, data, chunk = [], [], bytearray(), bytearray()
    for n, code in enumerate(sorted(characters)):
        if n and n % group_size == 0:
            encoded = compress(chunk)
            groups.append((len(data), len(encoded), len(chunk)))
            data.extend(encoded)
            chunk.clear()
        ch = chr(code)
        left, top, right, bottom = font.getbbox(ch, anchor="ls")
        width, height = right-left, bottom-top
        image = Image.new("L", (max(1, width), max(1, height)))
        ImageDraw.Draw(image).text((-left, -top), ch, font=font, anchor="ls", fill=255)
        levels = (1 << bits) - 1
        pixels = [(p*levels+127)//255 for p in image.getdata()] if width*height else []
        encoded = bytearray()
        per_byte = 8 // bits
        for i in range(0, len(pixels), per_byte):
            value = 0
            for j, p in enumerate(pixels[i:i+per_byte]):
                value |= p << (8-bits-bits*j)
            encoded.append(value)
        records.append((code, len(chunk), width, height, left, top, round(font.getlength(ch)), n//group_size))
        chunk.extend(encoded)
        assert len(chunk) <= 6144
    encoded = compress(chunk)
    groups.append((len(data), len(encoded), len(chunk)))
    data.extend(encoded)
    return records, groups, data

def compress(raw):
    out, literals, positions = bytearray(), bytearray(), {}
    def flush():
        while literals:
            count = min(128, len(literals))
            out.append(count-1); out.extend(literals[:count]); del literals[:count]
    i = 0
    while i < len(raw):
        key = bytes(raw[i:i+3]); previous = positions.get(key, -1)
        length = 0
        if len(key) == 3 and previous >= 0 and i-previous <= 65535:
            while length < 130 and i+length < len(raw) and raw[previous+length] == raw[i+length]:
                length += 1
        if length >= 3:
            flush(); out.append(0x80|(length-3)); distance = i-previous
            out.extend((distance & 255, distance >> 8))
            for j in range(length):
                if i+j+3 <= len(raw): positions[bytes(raw[i+j:i+j+3])] = i+j
            i += length
        else:
            positions[key] = i; literals.append(raw[i]); i += 1
            if len(literals) == 128: flush()
    flush(); return out

body, body_groups, body_data = build(16, codes)
# Display numbers must be rasterized at their actual display size, not magnified
# from the 16px body atlas. Four-bit coverage retains clean diagonal/curve edges;
# small groups keep exactly the same bounded 6KB firmware cache.
large_codes = set(range(48, 58)) | {ord(c) for c in "-+.:%"} | {0x00B0, 0x2212}
large, large_groups, large_data = build(64, large_codes, bits=4, group_size=4)
lines = ["// Generated Lingxi Sans AA; Noto CJK derivative, SIL OFL-1.1.",
         "// Source SHA256: " + hashlib.sha256(source.read_bytes()).hexdigest(),
         "enum { AA_BODY_SIZE=16, AA_LARGE_SIZE=64, AA_BODY_BITS=2, AA_LARGE_BITS=4 };",
         "typedef struct { uint16_t code,offset; uint8_t width,height; int8_t left,top; uint8_t advance,group; } aa_glyph_t;",
         "typedef struct { uint32_t offset; uint16_t compressed,raw; } aa_group_t;"]
for name, records, groups, data in [("body", body, body_groups, body_data), ("large", large, large_groups, large_data)]:
    lines.append("static const aa_glyph_t aa_%s_glyphs[] = {" % name)
    lines.extend("{%d,%d,%d,%d,%d,%d,%d,%d}," % item for item in records)
    lines.append("};\nstatic const aa_group_t aa_%s_groups[] = {" % name)
    lines.extend("{%d,%d,%d}," % item for item in groups)
    lines.append("};\nstatic const uint8_t aa_%s_data[] = {" % name)
    for i in range(0, len(data), 32):
        lines.append(",".join(str(b) for b in data[i:i+32]) + ",")
    lines.append("};")
destination.write_text("\n".join(lines) + "\n")
print("AA font: %d body glyphs / %d compressed bytes, %d large bytes, %d index bytes, largest cache %d" %
      (len(body), len(body_data), len(large_data), (len(body)+len(large))*10,
       max(item[2] for item in body_groups+large_groups)))
