; TF536 on the X68000: the ATA task file in the card window ($EA8000) and
; the layout of the ATA card that the boot chain and TFIDE read.

; ------------------------------------------------------------------ task file
; Register n of a chip select is at +4n; 8-bit registers are on the even
; byte (D15-D8), A1 is not decoded.

ATA_CS0         equ     $00EA8000
ATA_CS1         equ     $00EA9000

ATA_OFF_DATA    equ     $00     ; 16 bit
ATA_OFF_ERROR   equ     $04     ; write: features
ATA_OFF_COUNT   equ     $08
ATA_OFF_LBA0    equ     $0C
ATA_OFF_LBA1    equ     $10
ATA_OFF_LBA2    equ     $14
ATA_OFF_DEVHEAD equ     $18
ATA_OFF_STATUS  equ     $1C     ; write: command
ATA_OFF_DEVCTL  equ     $18     ; CS1: alternate status / device control

ATA_MASTER      equ     $E0     ; device/head: master, LBA addressing
ATA_MASTER_CHS  equ     $A0     ; device/head: master, as for IDENTIFY
ATA_SLAVE_BIT   equ     4

ATA_CMD_READ    equ     $20
ATA_CMD_WRITE   equ     $30
ATA_CMD_IDENTIFY equ    $EC

ATA_ATF_ERR     equ     0
ATA_ATF_DRQ     equ     3
ATA_ATF_DF      equ     5
ATA_ATF_DRDY    equ     6
ATA_ATF_BSY     equ     7
ATA_ATF_BAD     equ     (1<<ATA_ATF_ERR)|(1<<ATA_ATF_DF)

; ------------------------------------------------------------------ card
; The card is modelled on SCSI2SD, which carries several SCSI targets on
; one SD card and keeps each target's start and length (sdSectorStart,
; scsiSectors) in the board's configuration flash. The CPLD has no place
; for such a table, so the card carries it itself: each virtual disk
; ("slot") is a complete SxSI disk image, and the part of its header block
; that the SxSI layout leaves free holds the link to the next slot. The
; slots form a chain from LBA 0, and a SCSI2SD card converts directly, one
; slot per enabled target (card.py). Sector numbers are ATA
; LBAs of 512 bytes (LBA28); a block is 1024 bytes as SxSI counts them, so
; block n of a slot is LBA base+2n and base+2n+1. Multi-byte fields are
; big-endian. A card holding one slot is an ordinary SxSI disk image with
; the TF536 overlay; any slot written alone at LBA 0 is a valid card.
;
; Slot contents, in blocks from the slot base:
;   0       header (SxSI), see HDR_*
;   1       device IPL stage 1, ata_devipl.asm, runs at $2000
;   2       X68K partition table, see TABLE_*; never written by TF536 code
;   3-15    TFIDE, tfide.asm
;   16-23   device IPL stage 2, slot 0 only, zero elsewhere
;   24      partition IPL second half, ata_partipl.asm
;   p       partition IPL first half at each partition start
; Blocks 16-24 are unused filler in the SxSI layout. Every slot gets the
; same overlay (card.py).

SECTORS_PER_BLOCK equ   2

BLOCK_DEVIPL    equ     1
BLOCK_TABLE     equ     2
BLOCK_TFIDE     equ     3
BLOCK_STAGE2    equ     16
BLOCK_IPL_PART2 equ     24

; Slot header, block 0. Slot length in sectors = (record count + 1) *
; bytes per record / 512, doubled when the SxSI marker is present.
HDR_MAGIC0      equ     'X68S'  ; +0, 8 bytes "X68SCSI1"
HDR_MAGIC1      equ     'CSI1'
HDR_BYTES_PER_RECORD equ 8      ; .w, $0200 in the images in use
HDR_RECORDS_MINUS_ONE equ 10    ; .l
HDR_VENDOR      equ     16      ; up to 40 bytes, NUL terminated: slot name
HDR_SXSI_MARK   equ     42      ; SXSI_MARK here: records are 1024 bytes and
SXSI_MARK       equ     'SxSI'  ; the vendor string ends before it

; The last 32 bytes of the header block, $3E0-$3FF, belong to the card
; builder; the rest of the block is the source image's.
; Data region descriptor, slot 0 only. The region is a run of sectors
; after the last slot holding one foreign image verbatim (the AmigaOS port
; keeps its RDB disk there). The boot chain and TFIDE never read outside a
; slot, so the region is opaque to them. A reader takes its place from
; these fields, never from the end of the slot chain, and adds the region's
; first LBA to every sector number of the image inside. No DATA_MAGIC means
; no region; a slot lifted off a card never claims one.
HDR_DATA_MAGIC  equ     $3E0
HDR_DATA_LBA    equ     $3E4    ; .l first sector of the region
HDR_DATA_SECTORS equ    $3E8    ; .l region length
DATA_MAGIC      equ     'TFDR'  ; $3EC is reserved, zero
; Link to the next slot. Without LINK_MAGIC this slot is the last one.
; The builder places slots freely; nothing assumes an alignment.
HDR_LINK_MAGIC  equ     $3F0
HDR_LINK_LBA    equ     $3F4    ; .l LBA of the next slot's header
LINK_MAGIC      equ     'TFSL'

; Slot walk, the same rule in the device IPL and in TFIDE: start at LBA 0,
; slot 0. Read the header; stop unless it starts with X68SCSI1. Take the
; slot. Stop without LINK_MAGIC, or when the link LBA is zero, not above
; the current base, or at or beyond the device size from IDENTIFY DEVICE.
; Stop after MAX_SLOTS. A read error ends the walk. A slot whose table
; lacks TABLE_MAGIC is listed but offers no partitions.
MAX_SLOTS       equ     8

; Partition table, block 2: TABLE_MAGIC at +0, TABLE_ENTRIES entries of
; TABLE_ENTRY bytes from TABLE_FIRST. An entry with a zero first name byte
; is empty. Flags as SxSI's device IPL reads them: bit FLAG_UNUSABLE set is
; skipped everywhere, $00 is auto-start, $02 is usable without auto-start.
TABLE_MAGIC     equ     'X68K'
TABLE_FIRST     equ     16
TABLE_ENTRY     equ     16
TABLE_ENTRIES   equ     15
ENTRY_NAME_LEN  equ     8       ; +0, space padded
ENTRY_FLAGS     equ     8       ; .b
ENTRY_START     equ     9       ; 3 bytes, blocks from the slot base
ENTRY_LENGTH    equ     12      ; .l blocks
FLAG_UNUSABLE   equ     0

; ------------------------------------------------------------------ boot
; CPLD boot ROM (bootrom.asm, rtl/bootrom_x68k.v) -> device IPL (ata_devipl.asm) -> partition
; IPL (ata_partipl.asm) -> HUMAN.SYS with TFIDE (tfide.asm) installed.
;
; Handoff from the device IPL to the partition IPL at PART_IPL_ADDR, SR
; $2700, on the IPLROM's stack, so a plain rts returns to the ROM:
;   d5.l  slot base, LBA of the booted slot's header
;   d6.l  partition start, absolute LBA
;   d7.w  booted slot index
; The partition IPL writes d6 into TFIDE's header at TFIDE_BOOT_PART
; (after the driver name) before init, so TFIDE registers it first.
;
; RAM during boot: $2000 device IPL stage 1; $2400 stage 2, later the
; partition IPL; $2C00 directory buffer; $4400-$47FF device IPL stack;
; $4800 up device IPL buffers; $6800 HUMAN.SYS. Everything from $2400 is
; scratch until HUMAN.SYS loads. Nothing may use the IPLROM's stack below
; $2000: on a 68030 the IPLROM's page table sits at $1F90, just below it.
DEVIPL_ADDR     equ     $2000
PART_IPL_ADDR   equ     $2400
TFIDE_BOOT_PART equ     22      ; .l
