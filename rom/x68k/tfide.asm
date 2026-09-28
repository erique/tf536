; Headerless Human68k block driver (SCSI $C00 style). The partition IPL
; relocates strategy/interrupt at +6 and +10 and writes the booted
; partition's start LBA at +TFIDE_BOOT_PART. Init walks the slot chain
; (x68k.i) and registers one unit per usable partition, at most MAX_UNITS,
; the drive letters C to Z:
;   1. the booted partition, found by its start LBA, so it is always C:
;   2. the other usable partitions of the booted slot, table order
;   3. the usable partitions of the other slots, by slot index, table order
; Drive letters follow card order, not SCSI ID order as in the SCSI ROM.
; Each unit keeps its absolute start LBA and a shift from the BPB's bytes
; per sector: a Human68k logical sector n is ATA sector start + n << shift.
; The unit BPB comes from the partition's boot sector. A slot that fails a
; check, or a partition whose boot sector cannot be read, is skipped.
; LBA28 addressing covers cards up to 128 GB.
        org     0

        include x68k.i

; ---------------------------------------------------------------- ATA

; Polled-loop limits, counted down as longwords. One iteration is one
; status read over the card's bus, so at roughly a microsecond each these
; are budgets of a few seconds. The card behind the bridge is an SD or CF
; card whose program/erase cycle routinely stalls for hundreds of
; milliseconds; a 16-bit dbf counter expires inside that window and turns
; a busy device into a reported write error, which leaves the file system
; holding data it believes was written.
ATA_POLLS_PER_SEC equ     1000000
; BSY clear and DRDY before a command, spanning the previous program cycle
ATA_TIMEOUT_READY equ     5*ATA_POLLS_PER_SEC
; data asked for or offered
ATA_TIMEOUT_DRQ equ     2*ATA_POLLS_PER_SEC
; BSY clear after the last data word: on a write, the program cycle itself
ATA_TIMEOUT_DONE equ     5*ATA_POLLS_PER_SEC

IDENT_LBA28_SECTORS equ     120         ; IDENTIFY DEVICE: LBA28 capacity, bytes 120-123

SECTOR_SHIFT    equ     9
SECTOR_WORDS    equ     (1<<SECTOR_SHIFT)/2

; Data-register words moved per loop pass. 16 moves plus the dbf are 36
; bytes, at most four 16-byte lines of a 68030's instruction cache; each
; loop starts on a longword boundary and is entered only by a branch.
ATA_UNROLL      equ     16
        ifne    SECTOR_WORDS-(SECTOR_WORDS/ATA_UNROLL)*ATA_UNROLL
        fail    ATA_UNROLL must divide SECTOR_WORDS
        endc

; ---------------------------------------------------------------- units

MAX_UNITS       equ     24              ; drive letters C to Z

BPB_OFF         equ     $12             ; BPB in the partition boot sector
BPB_LEN         equ     16
BPB_BPS         equ     0               ; bytes per sector, within the BPB

; scratch during init, free below HUMAN.SYS
INIT_SCRATCH    equ     $3000
SCR_HDR         equ     INIT_SCRATCH
SCR_TABLE       equ     SCR_HDR+1024
SCR_BOOT        equ     SCR_TABLE+1024
SCR_IDENT       equ     SCR_BOOT+1024
SCR_SCAN        equ     SCR_IDENT+512   ; units in walk order

; unit entry
UN_START        equ     0               ; .l partition start, absolute LBA
UN_SHIFT        equ     4               ; .w logical sector to ATA sector shift
UN_SLOT         equ     6               ; .b slot index
UN_BPB          equ     8               ; Human68k BPB
UN_SIZE         equ     UN_BPB+BPB_LEN

; ---------------------------------------------------------------- Human68k

; device driver request packet
REQ_UNIT        equ     1
REQ_CMD         equ     2
REQ_ERR_LO      equ     3
REQ_ERR_HI      equ     4
REQ_UNITS       equ     13              ; init: number of units
REQ_STATUS      equ     13              ; drive control: status
REQ_END         equ     14              ; init: end of the driver
REQ_BUFFER      equ     14
REQ_CHANGE      equ     14              ; media check: result
REQ_BPBTAB      equ     18              ; init: BPB pointer table
REQ_COUNT       equ     18
REQ_DRIVE       equ     22              ; init: first drive number
REQ_SECTOR      equ     22

; commands
CMD_INIT_REQ    equ     0
CMD_MEDIA_CHK   equ     1
CMD_BPB_REQ     equ     2
CMD_INPUT       equ     4
CMD_DRVCTRL     equ     5
CMD_OUTPUT      equ     8
CMD_OUTPUT_VFY  equ     9

; results
ERR_READ_FAULT  equ     2
ERR_UNKNOWN_CMD equ     3
DRVSTAT_MEDIA_IN equ     $02
MEDIA_UNCHANGED equ     $01

DEV_LAST        equ     -1              ; header: no further driver in the chain
DEV_ATTR_BLOCK  equ     $0000           ; header: block device

; ---------------------------------------------------------------- trace

IOCS_ONTIME     equ     $7F
DRV_LOG_FIRST   equ     16
DRV_LOG_EVERY   equ     64
HSEC_WORDS_SHIFT equ     9              ; words in a 1024-byte Human68k sector

; ---------------------------------------------------------------- code

; device driver header
        dc.l    DEV_LAST
        dc.w    DEV_ATTR_BLOCK
        dc.l    strategy
        dc.l    interrupt
        dc.b    'TFIDE   '

boot_part:
        dc.l    0

req     dc.l    0
nunits  dc.w    0

strategy:
        move.l  a0,-(sp)
        lea     req(pc),a0
        move.l  a5,(a0)
        move.l  (sp)+,a0
        rts

interrupt:
        movem.l d0-d5/a0-a3/a5,-(sp)
        lea     req(pc),a0
        move.l  (a0),a5
        clr.b   REQ_ERR_LO(a5)
        clr.b   REQ_ERR_HI(a5)
        move.b  REQ_CMD(a5),d0
        beq     cmd_init
        cmp.b   #CMD_MEDIA_CHK,d0
        beq.s   cmd_media
        cmp.b   #CMD_BPB_REQ,d0
        beq.s   cmd_bpb
        cmp.b   #CMD_INPUT,d0
        beq.s   cmd_read
        cmp.b   #CMD_DRVCTRL,d0
        beq.s   cmd_drvctrl
        cmp.b   #CMD_OUTPUT,d0
        beq.s   cmd_write
        cmp.b   #CMD_OUTPUT_VFY,d0
        beq.s   cmd_write
        move.b  #ERR_UNKNOWN_CMD,REQ_ERR_LO(a5)

done:
        movem.l (sp)+,d0-d5/a0-a3/a5
        rts

cmd_media:
        move.b  #MEDIA_UNCHANGED,REQ_CHANGE(a5)
        bra.s   done

cmd_drvctrl:
        move.b  #DRVSTAT_MEDIA_IN,REQ_STATUS(a5)
        IFD     TFIDE_TRACE
        bsr     trace_drvctrl
        ENDC
        bra.s   done

cmd_bpb:
        moveq   #0,d0
        move.b  REQ_UNIT(a5),d0
        lsl.w   #2,d0
        lea     bpbptr(pc),a0
        add.w   d0,a0
        move.l  a0,REQ_BPBTAB(a5)
        bra.s   done

cmd_read:
        moveq   #ATA_CMD_READ,d2
        bra.s   xfer

cmd_write:
        moveq   #ATA_CMD_WRITE,d2

xfer:
        bsr.s   unit
        move.w  UN_SHIFT(a2),d3
        move.l  REQ_SECTOR(a5),d0
        lsl.l   d3,d0
        add.l   UN_START(a2),d0
        move.l  REQ_COUNT(a5),d1
        lsl.l   d3,d1
        move.l  REQ_BUFFER(a5),a1
        lea     ATA_CS0,a0
        bsr     ata_xfer
        IFD     TFIDE_TRACE
        bsr     trace_xfer
        ENDC
        tst.b   d2
        beq     done
        move.b  #ERR_READ_FAULT,REQ_ERR_LO(a5)
        bra     done

; a2 = unit entry of the request
unit:
        moveq   #0,d0
        move.b  REQ_UNIT(a5),d0
        mulu.w  #UN_SIZE,d0
        lea     units(pc),a2
        add.l   d0,a2
        rts

; Slot walk and unit table. Units are collected in walk order at
; SCR_SCAN, then copied so the booted partition comes first, its slot's
; other partitions next, then the remaining slots.
cmd_init:
        bsr     identify
        lea     SCR_SCAN,a2             ; a2 = next scan entry
        moveq   #0,d3                   ; d3 = slot base
        moveq   #0,d4                   ; d4 = slot index
.slot:
        move.l  d3,d0
        moveq   #SECTORS_PER_BLOCK,d1
        lea     SCR_HDR,a1
        bsr     read
        bne     .walked
        cmpi.l  #HDR_MAGIC0,(a1)
        bne     .walked
        cmpi.l  #HDR_MAGIC1,4(a1)
        bne     .walked
        move.l  d3,d0
        addq.l  #BLOCK_TABLE*SECTORS_PER_BLOCK,d0
        lea     SCR_TABLE,a1
        bsr     read
        bne     .walked
        cmpi.l  #TABLE_MAGIC,(a1)
        bne.s   .link
        lea     TABLE_FIRST(a1),a0
        moveq   #TABLE_ENTRIES-1,d5
.entry:
        tst.b   (a0)
        beq.s   .next
        btst    #FLAG_UNUSABLE,ENTRY_FLAGS(a0)
        bne.s   .next
        moveq   #0,d0
        move.b  ENTRY_START(a0),d0
        swap    d0
        move.w  ENTRY_START+1(a0),d0
        add.l   d0,d0
        add.l   d3,d0
        move.l  d0,UN_START(a2)
        move.b  d4,UN_SLOT(a2)
        moveq   #SECTORS_PER_BLOCK,d1
        lea     SCR_BOOT,a1
        bsr     read
        bne.s   .next                   ; unreadable partition: skipped
        lea     BPB_OFF(a1),a1
        lea     UN_BPB(a2),a3
        moveq   #BPB_LEN-1,d0
.bpb:
        move.b  (a1)+,(a3)+
        dbf     d0,.bpb
        move.w  UN_BPB+BPB_BPS(a2),d0
        moveq   #SECTOR_SHIFT,d1
        lsr.w   d1,d0                   ; ATA sectors per logical sector
        moveq   #-1,d1
.log2:
        addq.w  #1,d1
        lsr.w   #1,d0
        bne.s   .log2
        move.w  d1,UN_SHIFT(a2)
        lea     UN_SIZE(a2),a2
.next:
        lea     TABLE_ENTRY(a0),a0
        dbf     d5,.entry
.link:
        lea     SCR_HDR,a1
        cmpi.l  #LINK_MAGIC,HDR_LINK_MAGIC(a1)
        bne     .walked
        move.l  HDR_LINK_LBA(a1),d0
        beq     .walked
        cmp.l   d3,d0
        bls     .walked
        cmp.l   device_sectors(pc),d0
        bhs     .walked
        move.l  d0,d3
        addq.w  #1,d4
        cmp.w   #MAX_SLOTS,d4
        blo     .slot
.walked:
        move.l  a2,a3                   ; a3 = end of the scan list
        lea     units(pc),a1            ; a1 = next unit
        moveq   #-1,d4                  ; d4 = booted slot, none yet
        lea     SCR_SCAN,a2
.booted:
        cmp.l   a3,a2
        bhs.s   .slotrest
        move.l  boot_part(pc),d0
        cmp.l   UN_START(a2),d0
        beq.s   .isboot
        lea     UN_SIZE(a2),a2
        bra.s   .booted
.isboot:
        move.b  UN_SLOT(a2),d4
        bsr.s   emit
.slotrest:
        lea     SCR_SCAN,a2
.same:
        cmp.l   a3,a2
        bhs.s   .others
        move.l  boot_part(pc),d0
        cmp.l   UN_START(a2),d0
        beq.s   .samenext
        cmp.b   UN_SLOT(a2),d4
        bne.s   .samenext
        bsr.s   emit
.samenext:
        lea     UN_SIZE(a2),a2
        bra.s   .same
.others:
        lea     SCR_SCAN,a2
.other:
        cmp.l   a3,a2
        bhs.s   .table
        cmp.b   UN_SLOT(a2),d4
        beq.s   .othernext
        bsr.s   emit
.othernext:
        lea     UN_SIZE(a2),a2
        bra.s   .other
.table:
        lea     units(pc),a0
        move.l  a1,d1
        sub.l   a0,d1
        divu.w  #UN_SIZE,d1
        lea     nunits(pc),a2
        move.w  d1,(a2)
        move.b  d1,REQ_UNITS(a5)
        lea     bpbptr(pc),a2
        lea     UN_BPB(a0),a0
        move.w  d1,d0
        beq.s   .noptr
        subq.w  #1,d0
.ptr:
        move.l  a0,(a2)+
        lea     UN_SIZE(a0),a0
        dbf     d0,.ptr
.noptr:
        lea     bpbptr(pc),a0
        move.l  a0,REQ_BPBTAB(a5)
        lea     drv_end(pc),a0
        move.l  a0,REQ_END(a5)
        addq.b  #1,REQ_DRIVE(a5)
        bra     done

; a2 = scan entry, a1 = next unit. Copies unless the table is full.
emit:
        lea     units+MAX_UNITS*UN_SIZE(pc),a0
        cmp.l   a0,a1
        bhs.s   .full
        move.l  a2,a0
        moveq   #UN_SIZE-1,d0
.copy:
        move.b  (a0)+,(a1)+
        dbf     d0,.copy
.full:
        rts

; d0 = LBA, d1 = count, a1 = destination. Z=1 on success.
read:
        movem.l d0-d2/a0-a1,-(sp)
        moveq   #ATA_CMD_READ,d2
        lea     ATA_CS0,a0
        bsr.s   ata_xfer
        tst.b   d2
        movem.l (sp)+,d0-d2/a0-a1
        rts

; d0=LBA, d1=512-byte count, d2=command, a0=ATA, a1=buf
; One command per ATA sector: the FC-1307 keeps DRQ asserted across
; sector boundaries of a multi-sector transfer, so per-sector commands
; with a fresh DRDY/DRQ wait are the only form proven on the hardware.
; Each sector ends with a BSY wait and a status check, so a write is
; reported complete only once the card has programmed it.
ata_xfer:
        movem.l d0-d1/d4/d7/a1,-(sp)
        tst.l   d1
        beq     .ok
.sector:
        move.b  #1,ATA_OFF_COUNT(a0)
        move.l  d0,d4
        move.b  d4,ATA_OFF_LBA0(a0)
        lsr.l   #8,d4
        move.b  d4,ATA_OFF_LBA1(a0)
        lsr.l   #8,d4
        move.b  d4,ATA_OFF_LBA2(a0)
        lsr.l   #8,d4
        or.b    #ATA_MASTER,d4
        move.b  d4,ATA_OFF_DEVHEAD(a0)
        move.l  #ATA_TIMEOUT_READY,d7
.w1:
        move.b  ATA_OFF_STATUS(a0),d4
        btst    #ATA_ATF_BSY,d4
        bne.s   .w1n
        btst    #ATA_ATF_DRDY,d4
        bne.s   .do
.w1n:
        subq.l  #1,d7
        bne.s   .w1
        bra     .err
.do:
        move.b  d2,ATA_OFF_STATUS(a0)
        tst.b   ATA_OFF_STATUS(a0)      ; the first status read after a command
        ; is not guaranteed valid; one bus
        ; cycle covers the 400 ns the device
        ; needs to raise BSY
        move.l  #ATA_TIMEOUT_DRQ,d7
.w2:
        move.b  ATA_OFF_STATUS(a0),d4
        btst    #ATA_ATF_BSY,d4
        bne.s   .w2n
        btst    #ATA_ATF_DRQ,d4
        bne.s   .go
        and.b   #ATA_ATF_BAD,d4         ; not busy and no data: rejected outright
        bne     .err
.w2n:
        subq.l  #1,d7
        bne.s   .w2
        bra     .err
.go:
        move.w  #SECTOR_WORDS/ATA_UNROLL-1,d7
        cmp.b   #ATA_CMD_READ,d2
        bne.s   .wr
        bra.s   .rd                     ; both loops are entered by branch, so
        cnop    0,4                     ; no alignment padding is ever executed
.rd:
        rept    ATA_UNROLL
        move.w  (a0),(a1)+
        endr
        dbf     d7,.rd
        bra.s   .wait
        cnop    0,4
.wr:
        rept    ATA_UNROLL
        move.w  (a1)+,(a0)
        endr
        dbf     d7,.wr
.wait:
        ; The sector is not done when the last word has moved: on a write
        ; the device is still programming it. Wait out BSY and only then
        ; believe the status, so a failure is reported instead of a success
        ; the caller would build a file system on.
        move.l  #ATA_TIMEOUT_DONE,d7
.w3:
        move.b  ATA_OFF_STATUS(a0),d4
        btst    #ATA_ATF_BSY,d4
        beq.s   .chk
        subq.l  #1,d7
        bne.s   .w3
        bra.s   .err
.chk:
        and.b   #ATA_ATF_BAD,d4
        bne.s   .err
.nx:
        addq.l  #1,d0
        subq.l  #1,d1
        bne     .sector
.ok:
        movem.l (sp)+,d0-d1/d4/d7/a1
        moveq   #0,d2
        rts
.err:
        movem.l (sp)+,d0-d1/d4/d7/a1
        moveq   #1,d2
        rts

; IDENTIFY DEVICE: device size in sectors, LBA28 field; zero on failure,
; which ends the walk after slot 0.
identify:
        lea     ATA_CS0,a0
        move.b  #ATA_MASTER_CHS,ATA_OFF_DEVHEAD(a0)
        move.l  #ATA_TIMEOUT_READY,d7
.w1:
        move.b  ATA_OFF_STATUS(a0),d4
        btst    #ATA_ATF_DRDY,d4
        bne.s   .do
        subq.l  #1,d7
        bne.s   .w1
        rts
.do:
        move.b  #ATA_CMD_IDENTIFY,ATA_OFF_STATUS(a0)
        tst.b   ATA_OFF_STATUS(a0)
        move.l  #ATA_TIMEOUT_DRQ,d7
.w2:
        move.b  ATA_OFF_STATUS(a0),d4
        btst    #ATA_ATF_DRQ,d4
        bne.s   .go
        subq.l  #1,d7
        bne.s   .w2
        rts
.go:
        lea     SCR_IDENT,a1
        move.w  #SECTOR_WORDS-1,d7
.rd:
        move.w  (a0),(a1)+
        dbf     d7,.rd
        bsr     ident_report
        move.l  SCR_IDENT+IDENT_LBA28_SECTORS,d0
        ror.w   #8,d0
        swap    d0
        ror.w   #8,d0
        lea     device_sectors(pc),a0
        move.l  d0,(a0)
        rts

device_sectors:
        dc.l    0

; Serial line with the IDENTIFY words that say which PIO timing the device
; takes: 49 capabilities (bit 11 IORDY supported), 51 PIO mode (high byte),
; 53 field validity (bit 1: 64-70 valid), 64 advanced PIO modes (bit 0 PIO 3,
; bit 1 PIO 4), 67/68 minimum PIO cycle in ns without/with IORDY, 88 UDMA.
; The words arrive byte-swapped; each is printed as the device means it.
IDENT_REPORT_WORDS equ     7

ident_report:
        movem.l d0-d1/a0-a2,-(sp)
        lea     msg_ident(pc),a0
        bsr     scc_puts
        lea     ident_words(pc),a2
        moveq   #IDENT_REPORT_WORDS-1,d1
.word:
        move.b  #' ',d0
        bsr     scc_putc
        moveq   #0,d0
        move.w  (a2)+,d0
        move.l  d0,-(sp)
        bsr     put_dec
        move.b  #'=',d0
        bsr     scc_putc
        move.l  (sp)+,d0
        add.l   d0,d0
        lea     SCR_IDENT,a1
        move.w  0(a1,d0.l),d0
        ror.w   #8,d0
        bsr     scc_puthex16
        dbf     d1,.word
        bsr     scc_putnl
        movem.l (sp)+,d0-d1/a0-a2
        rts

; d0.w = 0-99, printed in decimal
put_dec:
        ext.l   d0
        divu    #10,d0
        tst.w   d0
        beq.s   .units
        add.b   #'0',d0
        bsr     scc_putc
.units:
        swap    d0
        add.b   #'0',d0
        bra     scc_putc

ident_words:
        dc.w    49,51,53,64,67,68,88

msg_ident:
        dc.b    'IDENT',0
        even

; Serial trace (assemble with -DTFIDE_TRACE): 'R'/'W' sector/count=checksum
; (sum of words), or 'E'.
        IFD     TFIDE_TRACE

trace_xfer:
        movem.l d0-d3/a0-a1,-(sp)
        move.l  d2,d3
        move.b  #'R',d0
        cmp.b   #CMD_INPUT,REQ_CMD(a5)
        beq.s   .tag
        move.b  #'W',d0
.tag:
        bsr     scc_putc
        move.l  REQ_SECTOR(a5),d0
        bsr     scc_puthex32
        move.b  #'/',d0
        bsr     scc_putc
        move.l  REQ_COUNT(a5),d0
        bsr     scc_puthex8
        tst.b   d3
        beq.s   .sum
        move.b  #'E',d0
        bsr     scc_putc
        bra.s   .nl
.sum:
        move.b  #'=',d0
        bsr     scc_putc
        move.l  REQ_COUNT(a5),d1
        moveq   #HSEC_WORDS_SHIFT,d0
        lsl.l   d0,d1
        move.l  REQ_BUFFER(a5),a1
        moveq   #0,d0
.add:
        add.w   (a1)+,d0
        subq.l  #1,d1
        bne.s   .add
        bsr     scc_puthex16
.nl:
        bsr     scc_putnl
        movem.l (sp)+,d0-d3/a0-a1
        rts

; 'D<count>:<ontime>' for the first DRV_LOG_FIRST drive-control calls and
; then every DRV_LOG_EVERY-th one; ontime is IOCS _ONTIME (1/100 s).
trace_drvctrl:
        movem.l d0-d1/a0-a1,-(sp)
        lea     drv_count(pc),a0
        addq.l  #1,(a0)
        move.l  (a0),d1
        cmp.l   #DRV_LOG_FIRST,d1
        bls.s   .log
        and.l   #DRV_LOG_EVERY-1,d1
        bne.s   .out
.log:
        move.b  #'D',d0
        bsr     scc_putc
        move.l  (a0),d0
        bsr     scc_puthex32
        move.b  #':',d0
        bsr     scc_putc
        moveq   #IOCS_ONTIME,d0
        trap    #15
        bsr     scc_puthex32
        bsr     scc_putnl
.out:
        movem.l (sp)+,d0-d1/a0-a1
        rts

drv_count:
        dc.l    0
        ENDC

        include scc.i

        even

bpbptr:
        ds.l    MAX_UNITS

units:
        ds.b    MAX_UNITS*UN_SIZE

drv_end:
