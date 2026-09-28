#!/usr/bin/env python3
"""Build and check TF536 ATA cards made from SxSI disk images.

The card layout (slots, header fields, overlay blocks, data region, slot
walk) is defined in x68k.i; the constants below mirror it.

card.py build: sources are either a SCSI2SD config XML plus its .ima, one
slot per enabled target with base and length from sdSectorStart and
scsiSectors, or a list of .hda files, length from each file's header. Sizes
always come from the source. The builder alone decides placement: slots back
to back on a 1 MiB grid, each linked to the next by TFSL except the last.
Every slot receives the TF536 overlay (device IPL stage 1, TFIDE, partition
IPL); stage 2 of the device IPL goes to blocks 16-23 of slot 0. With --data
one opaque image is placed after the last slot, on the same grid, as the
data region and described by the TFDR fields in slot 0's header. The output
is one card image, written to the card with dd. --overlay-only writes only
the overlay blocks, the links and the descriptor into a card image or device
laid out by an earlier full build, which updates the firmware without
rewriting partitions or the region; the same --data image must be named,
because it fixes where the region sits.

card.py check: reads a card image or a card dumped with dd and takes
everything from the card itself: the slots from the firmware's slot walk,
the data region from slot 0's TFDR fields. Walks the FAT of every usable
partition (Human68k FAT16 entries are big-endian, FAT12 entries are packed
as in DOS) and compares every file, the FATs and the directories with the
source images, given as for build. With --data it checks the region lies
past the last slot and inside the card, and compares every sector of the
region with the image.

A single .hda gives a single-slot card, as does a raw .hda written with dd.
The card and the CPLD boot ROM go together: the ROM loads block 1, which on
an SxSI disk is SxSI's own device IPL, and that one needs the SCSI IOCS.
"""
import argparse
import os
import struct
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))  # the firmware binaries are built here

SECTOR = 512
BLOCK = 1024
SECTORS_PER_BLOCK = BLOCK // SECTOR
COPY_CHUNK = 64 * 1024 * 1024

SLOT_MAGIC = b'X68SCSI1'
SXSI_MARK = b'SxSI'
SXSI_MARK_OFF = 42
HDR_BYTES_PER_RECORD = 8
HDR_RECORDS_MINUS_ONE = 10
LINK_MAGIC = b'TFSL'
LINK_MAGIC_OFF = 0x3F0
LINK_LBA_OFF = 0x3F4
MAX_SLOTS = 8

# The builder owns the last 32 bytes of every header block.
HDR_BUILDER_OFF = 0x3E0
HDR_BUILDER_END = 0x400
DATA_MAGIC = b'TFDR'
DATA_MAGIC_OFF = 0x3E0
DATA_LBA_OFF = 0x3E4
DATA_SECTORS_OFF = 0x3E8
DATA_RESERVED_OFF = 0x3EC
DATA_RESERVED_LEN = 4

TABLE_MAGIC = b'X68K'
TABLE_FIRST_ENTRY = 16
TABLE_ENTRY = 16
TABLE_ENTRIES = 15
ENTRY_NAME_LEN = 8
ENTRY_FLAGS = 8
ENTRY_START = 9
FLAG_UNUSABLE = 0x01

BLOCK_HEADER = 0
BLOCK_DEVICE_IPL = 1
BLOCK_TABLE = 2
BLOCK_TFIDE = 3
BLOCKS_TFIDE = 13
BLOCK_STAGE2 = 16
BLOCKS_STAGE2 = 8
BLOCK_IPL_PART2 = 24

BPB_OFF = 2
BPB_END = 0x26
BRA_OPCODE = 0x60

SLOT_ALIGN_SECTORS = 2048  # 1 MiB grid, chosen by the builder only

# Human68k BPB inside the partition boot sector.
BPB_BYTES_PER_SECTOR = 0x12
BPB_SECTORS_PER_CLUSTER = 0x14
BPB_FATS = 0x15
BPB_RESERVED = 0x16
BPB_ROOT_ENTRIES = 0x18
BPB_TOTAL_SECTORS = 0x1A
BPB_SECTORS_PER_FAT = 0x1D
BPB_TOTAL_SECTORS_LONG = 0x1E

DIR_ENTRY = 32
DIR_NAME = 0
DIR_EXT = 8
DIR_ATTR = 11
DIR_NAME2 = 12
DIR_CLUSTER = 26
DIR_SIZE = 28
ATTR_DIRECTORY = 0x10
ATTR_VOLUME = 0x08
DIR_FREE = 0x00
DIR_DELETED = 0xE5
FAT12_MAX_CLUSTERS = 4085
FAT12_END = 0xFF8
FAT16_END = 0xFFF8
FIRST_DATA_CLUSTER = 2


def align(sector):
    return (sector + SLOT_ALIGN_SECTORS - 1) // SLOT_ALIGN_SECTORS * SLOT_ALIGN_SECTORS


def image_sectors(path):
    """Length of an image in whole sectors, rounded up.

    Seeks rather than stats, because a block device reports a size of zero
    through os.path.getsize and the card is often a device.
    """
    with open(path, 'rb') as f:
        return (f.seek(0, os.SEEK_END) + SECTOR - 1) // SECTOR


def die(msg):
    sys.exit('card: ' + msg)


def slot_sectors(header):
    """Slot length in 512-byte sectors from an SxSI header block."""
    if header[:len(SLOT_MAGIC)] != SLOT_MAGIC:
        die('header lacks X68SCSI1')
    bpr = struct.unpack('>H', header[HDR_BYTES_PER_RECORD:HDR_BYTES_PER_RECORD + 2])[0]
    records = struct.unpack('>I', header[HDR_RECORDS_MINUS_ONE:HDR_RECORDS_MINUS_ONE + 4])[0] + 1
    if header[SXSI_MARK_OFF:SXSI_MARK_OFF + len(SXSI_MARK)] == SXSI_MARK:
        records *= BLOCK // bpr
    return records * bpr // SECTOR


class Source:
    def __init__(self, path, base_sector, sectors):
        self.path = path
        self.base = base_sector
        self.sectors = sectors

    def read(self, offset, length):
        with open(self.path, 'rb') as f:
            f.seek(self.base * SECTOR + offset)
            data = f.read(length)
        if len(data) != length:
            die('%s: short read at %d' % (self.path, offset))
        return data


def sources_from_hda(paths):
    out = []
    for p in paths:
        with open(p, 'rb') as f:
            hdr = f.read(BLOCK)
        n = slot_sectors(hdr)
        if os.path.getsize(p) < n * SECTOR:
            die('%s is shorter than its header says' % p)
        out.append(Source(p, 0, n))
    return out


def sources_from_scsi2sd(xml_path, ima_path):
    root = ET.parse(xml_path).getroot()
    out = []
    for t in root.iter('SCSITarget'):
        if t.findtext('enabled') != 'true':
            continue
        start = int(t.findtext('sdSectorStart'))
        n = int(t.findtext('scsiSectors'))
        if int(t.findtext('bytesPerSector')) != SECTOR:
            die('target %s: only %d-byte sectors are supported' % (t.get('id'), SECTOR))
        src = Source(ima_path, start, n)
        hdr_n = slot_sectors(src.read(0, BLOCK))
        if hdr_n != n:
            die('target %s: header says %d sectors, config says %d' % (t.get('id'), hdr_n, n))
        out.append(src)
    return out


def table_entries(table):
    """(name, flags, start LBA relative to the slot) of every non-empty entry."""
    if table[:len(TABLE_MAGIC)] != TABLE_MAGIC:
        return []
    out = []
    for i in range(TABLE_ENTRIES):
        e = table[TABLE_FIRST_ENTRY + i * TABLE_ENTRY:TABLE_FIRST_ENTRY + (i + 1) * TABLE_ENTRY]
        if e[0] == 0:
            continue
        start = int.from_bytes(e[ENTRY_START:ENTRY_START + 3], 'big') * SECTORS_PER_BLOCK
        out.append((e[:ENTRY_NAME_LEN].decode('ascii', 'replace').rstrip(), e[ENTRY_FLAGS], start))
    return out


def partitions(table):
    """Start LBA (relative to the slot) of every usable partition."""
    return [start for _, flags, start in table_entries(table) if not flags & FLAG_UNUSABLE]


def copy_range(src, out, out_offset, length):
    with open(src.path, 'rb') as f:
        f.seek(src.base * SECTOR)
        out.seek(out_offset)
        left = length
        while left:
            chunk = f.read(min(COPY_CHUNK, left))
            if not chunk:
                die('%s: short read while copying' % src.path)
            out.write(chunk)
            left -= len(chunk)


errors = 0


def fail(msg):
    global errors
    errors += 1
    print('FAIL: ' + msg)


class Region:
    """A slot-sized window into an image."""

    def __init__(self, path, base_sector):
        self.path = path
        self.base = base_sector
        self.f = open(path, 'rb')

    def read(self, offset, length):
        self.f.seek(self.base * SECTOR + offset)
        data = self.f.read(length)
        if len(data) != length:
            raise EOFError('%s: short read at %d+%d' % (self.path, self.base * SECTOR, offset))
        return data


def walk_card(path):
    """Slot bases per the firmware rule; stops on the same conditions."""
    device_sectors = image_sectors(path)
    slots = []
    base = 0
    with open(path, 'rb') as f:
        while len(slots) < MAX_SLOTS:
            f.seek(base * SECTOR)
            hdr = f.read(BLOCK)
            if hdr[:len(SLOT_MAGIC)] != SLOT_MAGIC:
                break
            slots.append((base, slot_sectors(hdr)))
            if hdr[LINK_MAGIC_OFF:LINK_MAGIC_OFF + 4] != LINK_MAGIC:
                break
            nxt = struct.unpack('>I', hdr[LINK_LBA_OFF:LINK_LBA_OFF + 4])[0]
            if nxt == 0 or nxt <= base or nxt >= device_sectors:
                break
            base = nxt
    return slots


class Fs:
    """Human68k FAT file system of one partition, addressed within a Region."""

    def __init__(self, region, part_sector, name):
        self.r = region
        self.name = name
        self.part = part_sector * SECTOR
        boot = region.read(self.part, BLOCK)
        self.bps = struct.unpack('>H', boot[BPB_BYTES_PER_SECTOR:BPB_BYTES_PER_SECTOR + 2])[0]
        self.spc = boot[BPB_SECTORS_PER_CLUSTER]
        self.fats = boot[BPB_FATS]
        self.reserved = struct.unpack('>H', boot[BPB_RESERVED:BPB_RESERVED + 2])[0]
        self.root_entries = struct.unpack('>H', boot[BPB_ROOT_ENTRIES:BPB_ROOT_ENTRIES + 2])[0]
        total = struct.unpack('>H', boot[BPB_TOTAL_SECTORS:BPB_TOTAL_SECTORS + 2])[0]
        if total == 0:
            total = struct.unpack('>I', boot[BPB_TOTAL_SECTORS_LONG:BPB_TOTAL_SECTORS_LONG + 4])[0]
        self.total = total
        self.spf = boot[BPB_SECTORS_PER_FAT]
        self.fat_start = self.reserved
        self.root_start = self.fat_start + self.fats * self.spf
        self.root_sectors = (self.root_entries * DIR_ENTRY + self.bps - 1) // self.bps
        self.data_start = self.root_start + self.root_sectors
        self.clusters = (self.total - self.data_start) // self.spc
        self.fat12 = self.clusters < FAT12_MAX_CLUSTERS
        self.fat = self.sectors(self.fat_start, self.spf)

    def sectors(self, first, count):
        return self.r.read(self.part + first * self.bps, count * self.bps)

    def fat_entry(self, n):
        if self.fat12:
            i = n * 3 // 2
            v = self.fat[i] | (self.fat[i + 1] << 8)
            return v >> 4 if n & 1 else v & 0xFFF
        return (self.fat[2 * n] << 8) | self.fat[2 * n + 1]  # Human68k FAT16 is big-endian

    def chain(self, first):
        out = []
        c = first
        end = FAT12_END if self.fat12 else FAT16_END
        while FIRST_DATA_CLUSTER <= c < FIRST_DATA_CLUSTER + self.clusters:
            if c in out:
                raise ValueError('cluster loop at %d' % c)
            out.append(c)
            c = self.fat_entry(c)
        if c < end:
            raise ValueError('chain from %d ends in %d' % (first, c))
        return out

    def cluster_offset(self, c):
        return self.part + (self.data_start + (c - FIRST_DATA_CLUSTER) * self.spc) * self.bps

    def read_chain(self, first, size=None):
        parts = []
        for c in self.chain(first):
            parts.append(self.r.read(self.cluster_offset(c), self.spc * self.bps))
        data = b''.join(parts)
        return data if size is None else data[:size]

    def entries(self, data):
        for i in range(0, len(data), DIR_ENTRY):
            e = data[i:i + DIR_ENTRY]
            if e[DIR_NAME] == DIR_FREE:
                break
            if e[DIR_NAME] == DIR_DELETED or e[DIR_ATTR] & ATTR_VOLUME:
                continue
            name = (e[DIR_NAME:DIR_EXT] + e[DIR_NAME2:DIR_NAME2 + 10]).decode('latin-1').rstrip(' \0')
            ext = e[DIR_EXT:DIR_EXT + 3].decode('latin-1').rstrip()
            if ext:
                name += '.' + ext
            if name in ('.', '..'):
                continue
            cluster = struct.unpack('<H', e[DIR_CLUSTER:DIR_CLUSTER + 2])[0]
            size = struct.unpack('<I', e[DIR_SIZE:DIR_SIZE + 4])[0]
            yield name, e[DIR_ATTR], cluster, size


def compare_fs(card, src, dir_cluster=None, path='', stats=None):
    """Walk card's directory tree, compare each file's bytes with src."""
    if stats is None:
        stats = {'files': 0, 'dirs': 0, 'bytes': 0}
    if dir_cluster is None:
        card_dir = card.sectors(card.root_start, card.root_sectors)
        src_dir = src.sectors(src.root_start, src.root_sectors)
    else:
        card_dir = card.read_chain(dir_cluster)
        src_dir = src.read_chain(dir_cluster)
    if card_dir != src_dir:
        fail('%s: directory %s differs' % (card.name, path or '/'))
    for name, attr, first, size in card.entries(card_dir):
        full = path + '/' + name
        if attr & ATTR_DIRECTORY:
            stats['dirs'] += 1
            compare_fs(card, src, first, full, stats)
            continue
        stats['files'] += 1
        stats['bytes'] += size
        if size == 0:
            continue
        try:
            a = card.read_chain(first, size)
            b = src.read_chain(first, size)
        except ValueError as e:
            fail('%s: %s: %s' % (card.name, full, e))
            continue
        if len(a) < size:
            fail('%s: %s: chain holds %d of %d bytes' % (card.name, full, len(a), size))
        if a != b:
            fail('%s: %s differs' % (card.name, full))
    return stats


def check_slot(i, card, src, src_sectors, slots):
    base, n = slots[i]
    if src_sectors != n:
        fail('slot %d: card header says %d sectors, source has %d' % (i, n, src_sectors))
    hdr = card.read(0, BLOCK)
    shdr = src.read(0, BLOCK)
    if hdr[:HDR_BUILDER_OFF] != shdr[:HDR_BUILDER_OFF]:
        fail('slot %d: header differs from source' % i)
    if i and hdr[DATA_MAGIC_OFF:DATA_MAGIC_OFF + 4] == DATA_MAGIC:
        fail('slot %d: TFDR marker outside slot 0' % i)
    linked = hdr[LINK_MAGIC_OFF:LINK_MAGIC_OFF + 4] == LINK_MAGIC
    if linked != (i + 1 < len(slots)):
        fail('slot %d: link marker %s' % (i, 'present on the last slot' if linked else 'missing'))
    devipl = card.read(BLOCK_DEVICE_IPL * BLOCK, BLOCK)
    if devipl[0] != BRA_OPCODE:
        fail('slot %d: block 1 has no device IPL' % i)
    if i == 0:
        slot0_stage2 = card.read(BLOCK_STAGE2 * BLOCK, BLOCKS_STAGE2 * BLOCK)
    elif card.read(BLOCK_STAGE2 * BLOCK, BLOCKS_STAGE2 * BLOCK) != b'\0' * (BLOCKS_STAGE2 * BLOCK):
        fail('slot %d: second-stage blocks are not zero' % i)
    ipl2 = card.read(BLOCK_IPL_PART2 * BLOCK, BLOCK)
    table = card.read(BLOCK_TABLE * BLOCK, BLOCK)
    if table != src.read(BLOCK_TABLE * BLOCK, BLOCK):
        fail('slot %d: partition table differs from source' % i)
    stats_all = []
    for name, flags, start in table_entries(table):
        if flags & FLAG_UNUSABLE:
            print('  slot %d partition %s at %d: unusable, skipped' % (i, name, start))
            continue
        boot = card.read(start * SECTOR, BLOCK)
        sboot = src.read(start * SECTOR, BLOCK)
        if boot[0] != BRA_OPCODE:
            fail('slot %d partition %s: no IPL' % (i, name))
        if boot[BPB_OFF:BPB_END] != sboot[BPB_OFF:BPB_END]:
            fail('slot %d partition %s: BPB differs from source' % (i, name))
        fs_card = Fs(card, start, 'slot %d %s' % (i, name))
        fs_src = Fs(src, start, 'source %d %s' % (i, name))
        for k in range(fs_card.fats):
            if fs_card.sectors(fs_card.fat_start + k * fs_card.spf, fs_card.spf) != fs_src.sectors(fs_src.fat_start + k * fs_src.spf, fs_src.spf):
                fail('slot %d partition %s: FAT %d differs' % (i, name, k))
        st = compare_fs(fs_card, fs_src)
        print('  slot %d partition %s at %d: FAT%d, %d clusters, %d dirs, %d files, %d bytes compared' % (
            i, name, start, 12 if fs_card.fat12 else 16, fs_card.clusters, st['dirs'], st['files'], st['bytes']))
        stats_all.append(st)
    return devipl, ipl2, slot0_stage2 if i == 0 else None


def check_data(card_path, slots, data_path):
    """Descriptor in slot 0's header, placement, and every sector of the region."""
    hdr = Region(card_path, 0).read(0, BLOCK)
    present = hdr[DATA_MAGIC_OFF:DATA_MAGIC_OFF + 4] == DATA_MAGIC
    if not present:
        if data_path:
            fail('slot 0: no TFDR marker, but a data image was given')
        return
    if not data_path:
        fail('slot 0: TFDR marker present, but no data image was given')
        return
    base = struct.unpack('>I', hdr[DATA_LBA_OFF:DATA_LBA_OFF + 4])[0]
    sectors = struct.unpack('>I', hdr[DATA_SECTORS_OFF:DATA_SECTORS_OFF + 4])[0]
    if hdr[DATA_RESERVED_OFF:DATA_RESERVED_OFF + DATA_RESERVED_LEN] != b'\0' * DATA_RESERVED_LEN:
        fail('slot 0: reserved bytes after the TFDR fields are not zero')
    print('data region: base %d, %d sectors, %s' % (base, sectors, data_path))
    slots_end = slots[-1][0] + slots[-1][1]
    if base < slots_end:
        fail('data region starts at %d, inside the slots that end at %d' % (base, slots_end))
    want = image_sectors(data_path)
    if sectors != want:
        fail('data region is %d sectors, %s needs %d' % (sectors, data_path, want))
    card_sectors = image_sectors(card_path)
    if base + sectors > card_sectors:
        fail('data region ends at %d, past the card at %d' % (base + sectors, card_sectors))
        return
    left = os.path.getsize(data_path)
    with open(card_path, 'rb') as c, open(data_path, 'rb') as d:
        c.seek(base * SECTOR)
        offset = 0
        while left:
            n = min(COPY_CHUNK, left)
            a = c.read(n)
            b = d.read(n)
            if len(a) != n or len(b) != n:
                fail('data region: short read at %d' % offset)
                return
            if a != b:
                fail('data region differs from %s at byte %d of the image' % (data_path, offset))
                return
            offset += n
            left -= n
    print('  data region: %d bytes compared' % offset)


def build(args, srcs):

    devipl = open(args.devipl, 'rb').read()
    tfide = open(args.tfide, 'rb').read()
    ipl = open(args.partipl, 'rb').read()
    if devipl[0] != BRA_OPCODE:
        die('device IPL does not start with a bra')
    if len(devipl) > (1 + BLOCKS_STAGE2) * BLOCK:
        die('device IPL is %d bytes, at most %d fit' % (len(devipl), (1 + BLOCKS_STAGE2) * BLOCK))
    if len(tfide) > BLOCKS_TFIDE * BLOCK:
        die('TFIDE is %d bytes, at most %d fit' % (len(tfide), BLOCKS_TFIDE * BLOCK))
    if len(ipl) != 2 * BLOCK or ipl[0] != BRA_OPCODE:
        die('partition IPL must be 2048 bytes starting with a bra')
    stage1 = devipl[:BLOCK].ljust(BLOCK, b'\0')
    stage2 = devipl[BLOCK:].ljust(BLOCKS_STAGE2 * BLOCK, b'\0')

    # Placement: back to back on the alignment grid.
    bases = []
    base = 0
    for s in srcs:
        bases.append(base)
        base += s.sectors
        base = align(base)
    total = bases[-1] + srcs[-1].sectors

    data_base = data_sectors = 0
    if args.data:
        data_base = align(total)
        data_sectors = image_sectors(args.data)
        total = data_base + data_sectors

    with open(args.output, 'r+b' if args.overlay_only else 'wb') as out:
        if not args.overlay_only:
            out.truncate(total * SECTOR)
        for i, (s, b) in enumerate(zip(srcs, bases)):
            slot = b * SECTOR
            if args.overlay_only:
                out.seek(slot)
                if out.read(len(SLOT_MAGIC)) != SLOT_MAGIC:
                    die('%s: no slot header at sector %d, run a full build first' % (args.output, b))
            else:
                copy_range(s, out, b * SECTOR, s.sectors * SECTOR)

            header = bytearray(s.read(0, BLOCK))
            if header[HDR_BUILDER_OFF:HDR_BUILDER_END] != b'\0' * (HDR_BUILDER_END - HDR_BUILDER_OFF):
                die('%s: header bytes $%X-$%X are not free for the builder fields'
                    % (s.path, HDR_BUILDER_OFF, HDR_BUILDER_END - 1))
            if i == 0 and data_sectors:
                header[DATA_MAGIC_OFF:DATA_MAGIC_OFF + 4] = DATA_MAGIC
                header[DATA_LBA_OFF:DATA_LBA_OFF + 4] = struct.pack('>I', data_base)
                header[DATA_SECTORS_OFF:DATA_SECTORS_OFF + 4] = struct.pack('>I', data_sectors)
            if i + 1 < len(srcs):
                header[LINK_MAGIC_OFF:LINK_MAGIC_OFF + 4] = LINK_MAGIC
                header[LINK_LBA_OFF:LINK_LBA_OFF + 4] = struct.pack('>I', bases[i + 1])
            out.seek(slot + BLOCK_HEADER * BLOCK)
            out.write(header)

            out.seek(slot + BLOCK_DEVICE_IPL * BLOCK)
            out.write(stage1)
            out.seek(slot + BLOCK_TFIDE * BLOCK)
            out.write(tfide.ljust(BLOCKS_TFIDE * BLOCK, b'\0'))
            out.seek(slot + BLOCK_STAGE2 * BLOCK)
            out.write(stage2 if i == 0 else b'\0' * (BLOCKS_STAGE2 * BLOCK))
            out.seek(slot + BLOCK_IPL_PART2 * BLOCK)
            out.write(ipl[BLOCK:])

            table = s.read(BLOCK_TABLE * BLOCK, BLOCK)
            parts = partitions(table)
            for p in parts:
                boot = s.read(p * SECTOR, BLOCK)
                if boot[0] != BRA_OPCODE:
                    die('%s: partition at LBA %d has no boot sector' % (s.path, p))
                part_ipl = bytearray(ipl[:BLOCK])
                part_ipl[BPB_OFF:BPB_END] = boot[BPB_OFF:BPB_END]
                out.seek(slot + p * SECTOR)
                out.write(part_ipl)
            print('slot %d: base %d, %d sectors, %d partition(s), %s' % (i, b, s.sectors, len(parts), s.path))

        if data_sectors:
            if args.overlay_only:
                out.seek(0, os.SEEK_END)
                if out.tell() < total * SECTOR:
                    die('%s holds %d sectors, the data region needs %d, run a full build first'
                        % (args.output, out.tell() // SECTOR, total))
            else:
                copy_range(Source(args.data, 0, data_sectors), out, data_base * SECTOR,
                           os.path.getsize(args.data))
            print('data region: base %d, %d sectors, %s' % (data_base, data_sectors, args.data))
    print('%s %s: %d sectors (%.1f MiB)' % ('overlaid' if args.overlay_only else 'wrote', args.output, total, total * SECTOR / 2**20))


def check(args, srcs):

    slots = walk_card(args.card)
    print('card %s: %d slot(s) found by the link walk' % (args.card, len(slots)))
    if len(slots) != len(srcs):
        fail('walk found %d slots, %d sources given' % (len(slots), len(srcs)))
    overlays = []
    for i, (base, n) in enumerate(slots):
        if i >= len(srcs):
            break
        print('slot %d: base %d, %d sectors' % (i, base, n))
        card = Region(args.card, base)
        src = Region(srcs[i].path, srcs[i].base)
        try:
            overlays.append(check_slot(i, card, src, srcs[i].sectors, slots))
        except (EOFError, ValueError) as e:
            fail('slot %d: %s' % (i, e))
    if overlays and any(o[0] != overlays[0][0] or o[1] != overlays[0][1] for o in overlays[1:]):
        fail('overlay blocks differ between slots')
    if slots:
        check_data(args.card, slots, args.data)
    if errors:
        die('%d error(s)' % errors)
    print('OK')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='command', required=True)

    bp = sub.add_parser('build', help='write a card image or overlay a card')
    bp.add_argument('-o', '--output', required=True, help='card image or device to write')
    bp.add_argument('--devipl', default=os.path.join(HERE, 'ata_devipl.bin'), help='device IPL binary (first 1024 bytes to block 1, rest to blocks 16-23 of slot 0)')
    bp.add_argument('--tfide', default=os.path.join(HERE, 'tfide.bin'), help='TFIDE driver binary (blocks 3-15)')
    bp.add_argument('--partipl', default=os.path.join(HERE, 'ata_partipl.bin'), help='partition IPL binary (2048 bytes: partition start and block 24)')
    bp.add_argument('--overlay-only', action='store_true', help='write only the overlay blocks and links into an existing card image or device laid out by an earlier full build')

    cp = sub.add_parser('check', help='compare a card image or dumped card with its sources')
    cp.add_argument('card', help='card image or dumped card')

    for p in (bp, cp):
        p.add_argument('--scsi2sd', nargs=2, metavar=('CONFIG.xml', 'IMAGE.ima'), help='SCSI2SD config and card image')
        p.add_argument('--data', metavar='IMAGE', help='data region image, after the last slot and described by TFDR in slot 0')
        p.add_argument('hda', nargs='*', help='.hda images, one slot each')

    args = ap.parse_args()
    if bool(args.scsi2sd) == bool(args.hda):
        die('give either --scsi2sd XML IMA or a list of .hda files')
    srcs = sources_from_scsi2sd(*args.scsi2sd) if args.scsi2sd else sources_from_hda(args.hda)
    if args.command == 'build':
        build(args, srcs)
    else:
        check(args, srcs)


if __name__ == '__main__':
    main()
