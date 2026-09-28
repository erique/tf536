#!/usr/bin/env python3
"""Convert an ANSI-art text (ESC[38;5;Nm colours) into the device IPL's
text-art format for draw_art in ata_devipl.asm.

Output: rows.b, cols.b, then per row a list of segments
(attribute.b, length.b, characters...) ended by a zero attribute; an
attribute of ART_SKIP (255) advances the column without drawing.
The 256-colour indices map onto the IOCS text attributes (colour 1-3,
bit 2 bold), non-ASCII glyphs onto ASCII look-alikes.
"""
import re
import sys

ART_SKIP = 255
CYAN, YELLOW, WHITE, BOLD = 1, 2, 3, 4
ATTR = {
    238: CYAN, 239: CYAN, 240: CYAN, 243: CYAN,          # greys
    138: WHITE, 143: WHITE, 144: WHITE, 174: WHITE, 179: WHITE, 180: WHITE,      # tan
    101: YELLOW, 137: YELLOW, 216: YELLOW, 222: YELLOW, 227: YELLOW,  # orange, brown
    228: BOLD + YELLOW, 11: BOLD + YELLOW,               # bright yellow
    231: BOLD + WHITE, 255: BOLD + WHITE,                # white
}
GLYPH = {'¦': '|', '¸': ',', '¹': "'", 'ƒ': 'f', '—': '-', '„': ',', '¬': '-', '†': '+'}


def main():
    src, dst = sys.argv[1], sys.argv[2]
    rows = []
    for line in open(src, encoding='utf-8').read().split('\n'):
        cells = []
        attr = WHITE
        for tok in re.split(r'(\x1b\[[0-9;]*m)', line):
            m = re.match(r'\x1b\[38;5;(\d+)m', tok)
            if m:
                attr = ATTR[int(m.group(1))]
                continue
            if tok.startswith('\x1b'):
                continue
            for ch in tok:
                cells.append((attr, GLYPH.get(ch, ch)))
        while cells and cells[-1][1] == ' ':
            cells.pop()
        if cells:
            rows.append(cells)
    cols = max(len(r) for r in rows)
    out = bytearray((len(rows), cols))
    for cells in rows:
        i = 0
        while i < len(cells):
            attr, ch = cells[i]
            if ch == ' ':
                n = 0
                while i + n < len(cells) and cells[i + n][1] == ' ':
                    n += 1
                out += bytes((ART_SKIP, n))
            else:
                n = 0
                while i + n < len(cells) and cells[i + n][1] != ' ' and cells[i + n][0] == attr and n < 255:
                    n += 1
                out += bytes((attr, n)) + ''.join(c for _, c in cells[i:i + n]).encode('ascii')
            i += n
        out.append(0)
    open(dst, 'wb').write(out)
    print('%s: %d rows, %d cols, %d bytes' % (dst, len(rows), cols, len(out)))


if __name__ == '__main__':
    main()
