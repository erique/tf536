; TF536 device IPL, two stages; card layout, slot walk and handoff in x68k.i.
; Stage 1, block 1 of slot 0, loaded to $2000 by the CPLD boot ROM: runs
; IDENTIFY, loads stage 2 from blocks 16-23 of
; slot 0 to $2400 and checks its TFS2 marker, and holds the ATA reader and
; the final handoff: it reads the first 1024 bytes of the chosen partition
; over the dead stage 2, checks for a bra and jumps to it. Without stage 2,
; or when the partition IPL cannot be read, it shows a message and returns
; to the IPLROM.
; The IPLROM's stack below $2000 sits right above its 68030 page table,
; so the device IPL moves to its own stack, carrying the ROM's return.
;
; Stage 2 walks the slots, reads each usable partition's boot sector and
; root directory, and draws the list in the layout of the SxSI Disk IPL
; MENU next to the text art (logo.ansi via ansi2bin.py): a bold title and
; subtitle, one bold line per slot (index, size in MB), one line per
; non-empty partition table entry (name and size in white, volume label in
; yellow, status in cyan: Auto, Manual, Hidden when flagged unusable, No
; system when HUMAN.SYS is not among the first N_ROOT_SCAN root entries,
; the scan the partition IPL performs), then a hint row and the countdown.
; Every slot and entry is listed, so the screen doubles as a view of the
; card. The selected line is white in reverse video; only bootable lines
; can be selected.
;
; Bootable candidates are usable partitions holding HUMAN.SYS. The first
; one is selected, or the first auto-start one of the same slot.
;   none   message for COUNTDOWN_NONE seconds, back to the IPLROM
;   one    full list, COUNTDOWN_ONE second, then boot
;   more   COUNTDOWN_MANY seconds as a digit and a bar losing a cell per
;          quarter second, then boot the selection. Any key stops the
;          countdown and acts at once: Up/Down move over bootable lines,
;          Return or tenkey Enter boots, other keys only stop it.
; Keys come from the IOCS as SxSI's menu reads them (_BITSNS during the
; countdown, _B_KEYINP in the menu), so interrupts are enabled while the
; menu runs; time is counted in vertical blanks from the MFP. The menu
; never writes to the card and nothing is remembered between boots.
        include x68k.i

        org     DEVIPL_ADDR

; boot chain
BRA_OPCODE      equ     $60
STAGE2_SECTORS  equ     16
STAGE2_MAGIC    equ     'TFS2'
PART_IPL_SECTORS equ     2

; ATA IDENTIFY DEVICE reply
IDENT_LBA28_SECTORS equ     120
IDENT_MODEL     equ     54              ; words 27-46, two characters per word, high byte first
IDENT_MODEL_LEN equ     40
MB_SHIFT        equ     11              ; 512-byte sectors to MB

; Human68k BPB in the partition boot sector, and root directory entries
BPB_BPS         equ     $12
BPB_FATS        equ     $15
BPB_RESERVED    equ     $16
BPB_SPF         equ     $1D
SECTOR_SHIFT    equ     9
DIR_ENT         equ     32
DIR_ATTR        equ     11
ATTR_VOLUME     equ     3
N_ROOT_SCAN     equ     32              ; entries the partition IPL scans too
ROOT_SECTORS    equ     N_ROOT_SCAN*DIR_ENT/512
LABEL_LEN       equ     11              ; volume label

; RAM: stage 2 image $2400-$43FF, stack below STACK_TOP, then the buffers.
; Everything above $2400 is scratch, overwritten once the partition IPL
; and HUMAN.SYS load.
STAGE2_ADDR     equ     $2400
STAGE2_END      equ     STAGE2_ADDR+STAGE2_SECTORS*512
STACK_TOP       equ     STAGE2_END+$400
HDR_BUF         equ     STACK_TOP       ; 1024
TAB_BUF         equ     HDR_BUF+1024    ; 1024
IDENT_BUF       equ     TAB_BUF+1024    ; 512
BOOT_BUF        equ     IDENT_BUF+512   ; 1024
ROOT_BUF        equ     BOOT_BUF+1024   ; ROOT_SECTORS*512
LINES           equ     ROOT_BUF+ROOT_SECTORS*512
LINE_BUF        equ     LINES+MAX_SLOTS*(1+TABLE_ENTRIES)*LN_SIZE

; menu line entry
LN_LBA          equ     0               ; .l partition start (absolute) or slot base
LN_MB           equ     4               ; .l size in MB
LN_SLOT         equ     8               ; .b slot index
LN_FLAGS        equ     9               ; .b LNF_*
LN_ROW          equ     10              ; .b screen row
LN_NAME         equ     12              ; 8 bytes, partition name
LN_LABEL        equ     20              ; volume label, LABEL_LEN bytes
LN_SIZE         equ     32
LNF_BOOT        equ     0               ; bootable candidate
LNF_AUTO        equ     1               ; auto-start partition
LNF_SLOTLINE    equ     2               ; slot header line
LNF_NOSYS       equ     3               ; usable but no HUMAN.SYS
LNF_HIDDEN      equ     4               ; flagged unusable

; IOCS
IOCS_B_KEYINP   equ     $00
IOCS_BITSNS     equ     $04
IOCS_B_CUROFF   equ     $1E
IOCS_B_PRINT    equ     $21
IOCS_B_COLOR    equ     $22
IOCS_B_LOCATE   equ     $23
IOCS_B_CLR_ST   equ     $2A
CLR_ALL         equ     2

; text colours; the selected line is all white in reverse video
COLOR_CYAN      equ     1
COLOR_YELLOW    equ     2
COLOR_WHITE     equ     3
COLOR_BOLD      equ     4
COLOR_REVERSE   equ     8
COL_TITLE       equ     COLOR_BOLD+COLOR_WHITE
COL_SUBTITLE    equ     COLOR_WHITE
COL_SLOT        equ     COLOR_BOLD+COLOR_WHITE
COL_NAME        equ     COLOR_WHITE     ; partition name and size
COL_VOLUME      equ     COLOR_YELLOW
COL_STATUS      equ     COLOR_CYAN
COL_SELECTED    equ     COLOR_REVERSE+COLOR_WHITE
COL_TEXT        equ     COLOR_WHITE     ; hint, countdown, messages

; keys, as _BITSNS and _B_KEYINP report them
KEY_GROUPS      equ     15
KEY_UP          equ     $3C             ; scan codes, bits 8-15 of the key data
KEY_DOWN        equ     $3E
KEY_RETURN      equ     $1D
KEY_TENKEY_ENTER equ     $4E
KEY_CODE_SHIFT  equ     8

; timing: seconds counted in vertical blanks from the MFP
MFP_GPIP        equ     $E88001
GPIP_VDISP      equ     4
VBLANKS_PER_SECOND equ     60
COUNTDOWN_MANY  equ     5
COUNTDOWN_ONE   equ     1
COUNTDOWN_NONE  equ     5

; status register
SR_SUPER_IRQ_ON equ     $2000
SR_SUPER_IRQ_OFF equ     $2700

; version string of the boot code, in the CPLD ROM or the SRAM boot stub
BOOTROM_BASE    equ     $00EA8800       ; CPLD boot ROM window
BOOTROM_SIZE    equ     128
SRAM_STUB_BASE  equ     $00ED0100       ; SRAM boot stub, MAME's stand-in
SRAM_STUB_SIZE  equ     768
VERSION_TAG     equ     '$V='
VERSION_TAG_LEN equ     3
VERSION_LEN     equ     26              ; characters after the tag

; screen layout, SxSI style: the text art on the left, the menu in the
; columns to its right, titles and messages centred over the menu
SCREEN_COLS     equ     96
SCREEN_ROWS     equ     31
VERSION_ROW     equ     SCREEN_ROWS-1
VERSION_COL     equ     SCREEN_COLS-VERSION_LEN
DEVICE_ROW      equ     SCREEN_ROWS-1   ; IDENTIFY model and capacity, bottom left
DEVICE_COL      equ     1
ART_ROW         equ     3
ART_COL         equ     1
ART_SKIP        equ     255             ; segment attribute: advance only
TEXT_COL        equ     42              ; menu area
TEXT_COLS       equ     SCREEN_COLS-TEXT_COL
TITLE_ROW       equ     6
SUBTITLE_ROW    equ     7
LIST_COL        equ     TEXT_COL
FIRST_ROW       equ     10
HINT_ROW        equ     25
COUNT_ROW       equ     27
COUNT_COL       equ     TEXT_COL+(TEXT_COLS-(BAR_CELLS+2+9))/2
BAR_COL         equ     COUNT_COL+10
BAR_STEP        equ     4               ; bar cells per second
BAR_CELLS       equ     COUNTDOWN_MANY*BAR_STEP

; characters
CR              equ     13
LF              equ     10

; ------------------------------------------------------------------ stage 1
        bra.s   start
        dc.b    'TFDI'

start:
        move.l  sp,rom_sp               ; the IPLROM's stack, restored at every exit
        lea     STACK_TOP,sp
        move.w  #SR_SUPER_IRQ_ON,sr
        bsr     identify
        moveq   #BLOCK_STAGE2*SECTORS_PER_BLOCK,d0
        moveq   #STAGE2_SECTORS,d1
        lea     STAGE2_ADDR,a1
        bsr     ata_read
        bne.s   .nostage
        cmpi.l  #STAGE2_MAGIC,(a1)
        bne.s   .nostage
        jmp     stage2
.nostage:
        lea     msg_nostage(pc),a1

give_up:
        moveq   #IOCS_B_PRINT,d0
        trap    #15
        moveq   #COUNTDOWN_NONE,d3
        bsr.s   wait_seconds
        move.l  rom_sp,sp
        rts                             ; back to the IPLROM

; d5 = slot base, d6 = partition start, d7 = slot index. Loads the
; partition IPL over stage 2 and jumps to it on the IPLROM's stack, so
; its own failure exit is a plain rts; on failure here returns to the
; IPLROM after a message. Entered with jmp.
boot_partition:
        move.l  d6,d0
        moveq   #PART_IPL_SECTORS,d1
        lea     PART_IPL_ADDR,a1
        bsr     ata_read
        bne.s   .bad
        cmpi.b  #BRA_OPCODE,(a1)
        bne.s   .bad
        move.w  #SR_SUPER_IRQ_OFF,sr
        move.l  rom_sp,sp
        jmp     (a1)
.bad:
        lea     msg_bootfail(pc),a1
        bra.s   give_up

; d3 = seconds
wait_seconds:
        moveq   #VBLANKS_PER_SECOND-1,d2
.tick:
        bsr.s   wait_vblank
        dbf     d2,.tick
        subq.w  #1,d3
        bne.s   wait_seconds
        rts

; One vertical blank: VDISP low, then high again.
wait_vblank:
.disp:
        btst    #GPIP_VDISP,MFP_GPIP
        bne.s   .disp
.blank:
        btst    #GPIP_VDISP,MFP_GPIP
        beq.s   .blank
        rts

; d0 = LBA, d1 = count, a1 = destination. Z=1 on success.
ata_read:
        movem.l d0-d1/d3/d7/a0-a1,-(sp)
        lea     ATA_CS0,a0
.next:
        move.l  d0,d3
        move.b  #1,ATA_OFF_COUNT(a0)
        move.b  d3,ATA_OFF_LBA0(a0)
        lsr.l   #8,d3
        move.b  d3,ATA_OFF_LBA1(a0)
        lsr.l   #8,d3
        move.b  d3,ATA_OFF_LBA2(a0)
        lsr.l   #8,d3
        or.b    #ATA_MASTER,d3
        move.b  d3,ATA_OFF_DEVHEAD(a0)
        moveq   #ATA_ATF_DRDY,d3
        bsr.s   ata_wait
        beq.s   .bad
        move.b  #ATA_CMD_READ,ATA_OFF_STATUS(a0)
        moveq   #ATA_ATF_DRQ,d3
        bsr.s   ata_wait
        beq.s   .bad
        move.w  #(1<<SECTOR_SHIFT)/2-1,d7
.copy:
        move.w  (a0),(a1)+
        dbf     d7,.copy
        addq.l  #1,d0
        subq.w  #1,d1
        bne.s   .next
        moveq   #0,d2
        bra.s   .out
.bad:
        moveq   #1,d2
.out:
        movem.l (sp)+,d0-d1/d3/d7/a0-a1
        tst.b   d2
        rts

; d3 = status bit. Z=0 when set, Z=1 on timeout.
ata_wait:
        moveq   #-1,d7
.poll:
        move.b  ATA_OFF_STATUS(a0),d2
        btst    d3,d2
        dbne    d7,.poll
        rts

; IDENTIFY DEVICE: device size in sectors, LBA28 field. Zero when the
; command fails, which ends the walk after slot 0.
identify:
        lea     ATA_CS0,a0
        move.b  #ATA_MASTER_CHS,ATA_OFF_DEVHEAD(a0)
        moveq   #ATA_ATF_DRDY,d3
        bsr.s   ata_wait
        beq.s   .done
        move.b  #ATA_CMD_IDENTIFY,ATA_OFF_STATUS(a0)
        moveq   #ATA_ATF_DRQ,d3
        bsr.s   ata_wait
        beq.s   .done
        lea     IDENT_BUF,a1
        move.w  #(1<<SECTOR_SHIFT)/2-1,d7
.copy:
        move.w  (a0),(a1)+
        dbf     d7,.copy
        move.l  IDENT_BUF+IDENT_LBA28_SECTORS,d0
        ror.w   #8,d0
        swap    d0
        ror.w   #8,d0
        move.l  d0,device_sectors
.done:
        rts

device_sectors:
        dc.l    0

rom_sp:
        dc.l    0

msg_nostage:
        dc.b    'TF536: device IPL second stage missing, returning to ROM',CR,LF,0

msg_bootfail:
        dc.b    'TF536: partition IPL read failed, returning to ROM',CR,LF,0
        even

stage1_end:
        cnop    0,1024

; ------------------------------------------------------------------ stage 2
stage2_magic:
        dc.l    STAGE2_MAGIC

stage2:
        moveq   #IOCS_B_CLR_ST,d0
        moveq   #CLR_ALL,d1
        trap    #15
        moveq   #IOCS_B_CUROFF,d0
        trap    #15
        moveq   #COL_TITLE,d1
        bsr     color
        move.w  #TEXT_COL+(TEXT_COLS-(msg_title_end-msg_title-1))/2,d1
        moveq   #TITLE_ROW,d2
        lea     msg_title(pc),a1
        bsr     print_at
        moveq   #COL_SUBTITLE,d1
        bsr     color
        move.w  #TEXT_COL+(TEXT_COLS-(msg_subtitle_end-msg_subtitle-1))/2,d1
        moveq   #SUBTITLE_ROW,d2
        lea     msg_subtitle(pc),a1
        bsr     print_at
        bsr     draw_art
        bsr     show_version
        bsr     show_device

        lea     LINES,a4                ; a4 = next line entry
        moveq   #0,d3                   ; d3 = slot base
        moveq   #0,d4                   ; d4 = slot index
        moveq   #FIRST_ROW,d5           ; d5 = next screen row
        moveq   #0,d6                   ; d6 = candidate count

slot_loop:
        move.l  d3,d0
        moveq   #SECTORS_PER_BLOCK,d1
        lea     HDR_BUF,a1
        bsr     ata_read
        bne     list_done
        cmpi.l  #HDR_MAGIC0,(a1)
        bne     list_done
        cmpi.l  #HDR_MAGIC1,4(a1)
        bne     list_done
        bsr     add_line
        move.l  d3,LN_LBA(a2)
        bset    #LNF_SLOTLINE,LN_FLAGS(a2)
        bsr     slot_mb
        move.l  d0,LN_MB(a2)
        bsr     draw_line

        move.l  d3,d0
        addq.l  #BLOCK_TABLE*SECTORS_PER_BLOCK,d0
        moveq   #SECTORS_PER_BLOCK,d1
        lea     TAB_BUF,a1
        bsr     ata_read
        bne     list_done
        cmpi.l  #TABLE_MAGIC,(a1)
        beq.s   table_ok
        moveq   #COL_STATUS,d1
        bsr     color
        moveq   #LIST_COL,d1
        move.w  d5,d2
        lea     msg_notable(pc),a1
        bsr     print_at
        addq.w  #1,d5
        bra     next_slot

table_ok:
        lea     TABLE_FIRST(a1),a3
        moveq   #TABLE_ENTRIES-1,d7

entry_loop:
        tst.b   (a3)
        beq     entry_next
        bsr     add_line
        moveq   #0,d0
        move.b  ENTRY_START(a3),d0
        swap    d0
        move.w  ENTRY_START+1(a3),d0
        add.l   d0,d0                   ; blocks to sectors
        add.l   d3,d0
        move.l  d0,LN_LBA(a2)
        move.l  ENTRY_LENGTH(a3),d0
        add.l   d0,d0
        moveq   #MB_SHIFT,d1
        lsr.l   d1,d0
        move.l  d0,LN_MB(a2)
        lea     LN_NAME(a2),a0
        moveq   #ENTRY_NAME_LEN-1,d0
.name:
        move.b  (a3,d0.w),(a0,d0.w)
        dbf     d0,.name
        btst    #FLAG_UNUSABLE,ENTRY_FLAGS(a3)
        beq.s   .usable
        bset    #LNF_HIDDEN,LN_FLAGS(a2)
        bra.s   .draw
.usable:
        tst.b   ENTRY_FLAGS(a3)
        bne.s   .scan
        bset    #LNF_AUTO,LN_FLAGS(a2)
.scan:
        bsr     scan_root               ; label and HUMAN.SYS presence
        bne.s   .nosys
        bset    #LNF_BOOT,LN_FLAGS(a2)
        addq.w  #1,d6
        bra.s   .draw
.nosys:
        bset    #LNF_NOSYS,LN_FLAGS(a2)
.draw:
        bsr     draw_line

entry_next:
        lea     TABLE_ENTRY(a3),a3
        dbf     d7,entry_loop

next_slot:
        lea     HDR_BUF,a1
        cmpi.l  #LINK_MAGIC,HDR_LINK_MAGIC(a1)
        bne.s   list_done
        move.l  HDR_LINK_LBA(a1),d0
        beq.s   list_done
        cmp.l   d3,d0
        bls.s   list_done
        cmp.l   device_sectors(pc),d0
        bhs.s   list_done
        move.l  d0,d3
        addq.w  #1,d4
        cmp.w   #MAX_SLOTS,d4
        blo     slot_loop

list_done:
        moveq   #COL_TEXT,d1
        bsr     color
        tst.w   d6
        bne.s   have_candidates
        move.w  #TEXT_COL+(TEXT_COLS-(msg_none_end-msg_none-1))/2,d1
        moveq   #HINT_ROW,d2
        lea     msg_none(pc),a1
        bsr     print_at
        moveq   #COUNTDOWN_NONE,d3
        bsr     wait_seconds
        move.l  rom_sp,sp
        rts                             ; back to the IPLROM

; Initial selection: first bootable line; the first auto-start bootable
; line of the same slot when the slot has one.
have_candidates:
        move.w  #TEXT_COL+(TEXT_COLS-(msg_hint_end-msg_hint-1))/2,d1
        moveq   #HINT_ROW,d2
        lea     msg_hint(pc),a1
        bsr     print_at
        lea     LINES,a2
.first:
        btst    #LNF_BOOT,LN_FLAGS(a2)
        bne.s   .found
        lea     LN_SIZE(a2),a2
        bra.s   .first
.found:
        move.l  a2,a3
        move.b  LN_SLOT(a2),d0
.auto:
        cmp.b   LN_SLOT(a3),d0
        bne.s   .chosen
        btst    #LNF_BOOT,LN_FLAGS(a3)
        beq.s   .autonext
        btst    #LNF_AUTO,LN_FLAGS(a3)
        bne.s   .take
.autonext:
        lea     LN_SIZE(a3),a3
        cmp.l   a4,a3
        blo.s   .auto
        bra.s   .chosen
.take:
        move.l  a3,a2
.chosen:
        move.l  a2,selected
        bsr     draw_selected

        moveq   #COUNTDOWN_ONE,d3
        cmp.w   #1,d6
        beq.s   .count
        moveq   #COUNTDOWN_MANY,d3
.count:
        bsr     countdown
        beq     boot                    ; expired
        bsr     key_wait                ; the key that stopped it acts as well
        bra.s   menu_key

menu:
        bsr     key_wait

menu_key:
        cmp.b   #KEY_RETURN,d0
        beq.s   boot
        moveq   #LN_SIZE,d1
        cmp.b   #KEY_DOWN,d0
        beq.s   .move
        cmp.b   #KEY_UP,d0
        bne.s   menu
        moveq   #-LN_SIZE,d1
.move:
        move.l  selected(pc),a2
.step:
        add.l   d1,a2
        cmp.l   #LINES,a2
        blo.s   menu
        cmp.l   a4,a2
        bhs.s   menu
        btst    #LNF_BOOT,LN_FLAGS(a2)
        beq.s   .step
        move.l  a2,a3
        move.l  selected(pc),a2
        bsr     draw_line               ; unmark the old line
        move.l  a3,selected
        move.l  a3,a2
        bsr     draw_selected
        bra.s   menu

boot:
        moveq   #COL_TEXT,d1
        bsr     color
        moveq   #COUNT_COL,d1
        moveq   #COUNT_ROW,d2
        lea     msg_booting(pc),a1
        bsr     print_at
        move.l  selected(pc),a2
        move.l  LN_LBA(a2),d6
        moveq   #0,d7
        move.b  LN_SLOT(a2),d7
        lea     LINES,a3
.base:
        cmp.b   LN_SLOT(a3),d7
        bne.s   .basenext
        btst    #LNF_SLOTLINE,LN_FLAGS(a3)
        bne.s   .found
.basenext:
        lea     LN_SIZE(a3),a3
        bra.s   .base
.found:
        move.l  LN_LBA(a3),d5
        jmp     boot_partition

; Appends a blank line entry for the current slot at the next row;
; a2 = the entry, d5 advanced.
add_line:
        move.l  a4,a2
        moveq   #LN_SIZE/4-1,d0
.clear:
        clr.l   (a4)+
        dbf     d0,.clear
        move.b  d4,LN_SLOT(a2)
        move.b  d5,LN_ROW(a2)
        addq.w  #1,d5
        rts

; d0 = slot size in MB from the header at HDR_BUF: records * bytes/record.
slot_mb:
        lea     HDR_BUF,a1
        move.l  HDR_RECORDS_MINUS_ONE(a1),d0
        addq.l  #1,d0
        moveq   #0,d1
        move.w  HDR_BYTES_PER_RECORD(a1),d1
        cmpi.l  #SXSI_MARK,HDR_SXSI_MARK(a1)
        bne.s   .scale
        move.w  #SECTORS_PER_BLOCK<<SECTOR_SHIFT,d1 ; record count in 1024-byte units
.scale:
        moveq   #SECTOR_SHIFT,d2
        lsr.w   d2,d1                   ; sectors per record, a power of two
.mul:
        lsr.w   #1,d1
        beq.s   .mb
        add.l   d0,d0
        bra.s   .mul
.mb:
        moveq   #MB_SHIFT,d1
        lsr.l   d1,d0
        rts

; a2 = line entry of a usable partition. Reads its boot sector and the
; first root directory sectors, copies the volume label into the entry.
; Z=1 when HUMAN.SYS is among the first N_ROOT_SCAN entries.
scan_root:
        movem.l d0-d3/a0-a1,-(sp)
        move.l  LN_LBA(a2),d0
        moveq   #SECTORS_PER_BLOCK,d1
        lea     BOOT_BUF,a1
        bsr     ata_read
        bne     .fail
        move.w  BPB_BPS(a1),d1
        moveq   #SECTOR_SHIFT,d2
        lsr.w   d2,d1                   ; ATA sectors per logical sector
        moveq   #0,d2
        move.b  BPB_SPF(a1),d2
        moveq   #0,d3
        move.b  BPB_FATS(a1),d3
        mulu.w  d3,d2
        add.w   BPB_RESERVED(a1),d2     ; root directory, logical sector
        mulu.w  d1,d2                   ; to ATA sectors
        add.l   d2,d0
        moveq   #ROOT_SECTORS,d1
        lea     ROOT_BUF,a1
        bsr     ata_read
        bne     .fail
        moveq   #N_ROOT_SCAN-1,d3
        moveq   #0,d2                   ; 1 once HUMAN.SYS is seen
.entry:
        tst.b   (a1)
        beq.s   .scanned
        btst    #ATTR_VOLUME,DIR_ATTR(a1)
        beq.s   .notlabel
        lea     LN_LABEL(a2),a0
        moveq   #LABEL_LEN-1,d0
.label:
        move.b  (a1,d0.w),(a0,d0.w)
        dbf     d0,.label
        bra.s   .next
.notlabel:
        cmpi.l  #'HUMA',(a1)
        bne.s   .next
        cmpi.l  #'N   ',4(a1)
        bne.s   .next
        cmpi.w  #'SY',8(a1)
        bne.s   .next
        cmpi.b  #'S',10(a1)
        bne.s   .next
        moveq   #1,d2
.next:
        lea     DIR_ENT(a1),a1
        dbf     d3,.entry
.scanned:
        subq.w  #1,d2                   ; Z=1 when found
        bra.s   .out
.fail:
        moveq   #1,d2
.out:
        movem.l (sp)+,d0-d3/a0-a1
        rts

; a2 = line entry. Draws it, each element in its colour; draw_selected
; draws every element white in reverse video.
draw_line:
        moveq   #0,d0                   ; 0: element colours
        bra.s   draw_with

draw_selected:
        moveq   #COL_SELECTED,d0

draw_with:
        movem.l d3-d4/a3,-(sp)
        move.w  d0,d3
        bsr     format_line
        tst.w   d3
        beq.s   .elements
        move.b  #' ',LINE_BUF+SEG_LABEL-1 ; join the segments into one bar
        move.b  #' ',LINE_BUF+SEG_STATUS-1
        move.w  d3,d1
        bsr     color
        moveq   #LIST_COL+PART_INDENT,d1 ; the bar starts at the name
        moveq   #0,d2
        move.b  LN_ROW(a2),d2
        lea     LINE_BUF+PART_INDENT,a1
        bsr     print_at
        bra.s   .done
.elements:
        lea     seg_table(pc),a3
        moveq   #SEGMENTS-1,d4
.seg:
        moveq   #0,d1
        move.b  (a3)+,d1                ; colour
        bsr     color
        moveq   #0,d1
        move.b  (a3)+,d1                ; column within the line
        lea     LINE_BUF,a1
        add.w   d1,a1
        add.w   #LIST_COL,d1
        moveq   #0,d2
        move.b  LN_ROW(a2),d2
        bsr     print_at
        ; the joining columns were part of the bar when the line was selected:
        ; the later segments start one column early, over a space
        move.b  #' ',LINE_BUF+SEG_LABEL-1
        move.b  #' ',LINE_BUF+SEG_STATUS-1
        dbf     d4,.seg
.done:
        movem.l (sp)+,d3-d4/a3
        rts

; a2 = line entry. Builds its text in LINE_BUF as NUL-separated segments
; and their colours and columns in seg_table:
; slot:      Slot n     nnnnn MB (bold)
; partition:   name       nnnnn MB   label         Auto|Manual|Hidden|No system
; Each segment is padded with spaces to the byte before the next one, which
; holds its NUL, so the selected line can be joined into one bar.
SEGMENTS        equ     3
PART_INDENT     equ     2               ; partition lines under their slot
SEG_NAME        equ     0
SEG_LABEL       equ     SEG_NAME+22
SEG_STATUS      equ     SEG_LABEL+LABEL_LEN+3
STATUS_WIDTH    equ     9               ; 'No system'
SEG_END         equ     SEG_STATUS+STATUS_WIDTH

format_line:
        lea     seg_table(pc),a3
        lea     LINE_BUF,a0
        btst    #LNF_SLOTLINE,LN_FLAGS(a2)
        beq.s   .part
        move.b  #COL_SLOT,(a3)+
        move.b  #SEG_NAME,(a3)+
        lea     msg_slot(pc),a1
        bsr     put_str
        moveq   #0,d0
        move.b  LN_SLOT(a2),d0
        add.b   #'0',d0
        move.b  d0,(a0)+
        moveq   #4,d0
        bsr     put_spaces
        bra.s   .size
.part:
        move.b  #COL_NAME,(a3)+
        move.b  #SEG_NAME,(a3)+
        moveq   #PART_INDENT,d0
        bsr     put_spaces
        lea     LN_NAME(a2),a1
        moveq   #ENTRY_NAME_LEN,d0
        bsr     put_fixed
.size:
        move.l  LN_MB(a2),d0
        bsr     put_dec
        lea     msg_mb(pc),a1
        bsr     put_str
        lea     LINE_BUF+SEG_LABEL-1,a1
        bsr     pad_to
        move.b  #COL_VOLUME,(a3)+
        move.b  #SEG_LABEL-1,(a3)+
        lea     LN_LABEL(a2),a1
        moveq   #LABEL_LEN,d0
        bsr     put_fixed
        lea     LINE_BUF+SEG_STATUS-1,a1
        bsr     pad_to
        move.b  #COL_STATUS,(a3)+
        move.b  #SEG_STATUS-1,(a3)+
        lea     msg_empty(pc),a1
        btst    #LNF_SLOTLINE,LN_FLAGS(a2)
        bne.s   .status
        lea     msg_hidden(pc),a1
        btst    #LNF_HIDDEN,LN_FLAGS(a2)
        bne.s   .status
        lea     msg_nosys(pc),a1
        btst    #LNF_NOSYS,LN_FLAGS(a2)
        bne.s   .status
        lea     msg_auto(pc),a1
        btst    #LNF_AUTO,LN_FLAGS(a2)
        bne.s   .status
        lea     msg_manual(pc),a1
.status:
        bsr     put_str
        lea     LINE_BUF+SEG_END,a1
        bsr     pad_to
        rts

; Fills (a0) with spaces up to a1, writes the NUL there, a0 = a1+1.
pad_to:
        cmp.l   a1,a0
        bhs.s   .end
        move.b  #' ',(a0)+
        bra.s   pad_to
.end:
        clr.b   (a1)+
        move.l  a1,a0
        rts

seg_table:
        ds.b    SEGMENTS*2

; Prints the ATA device's model string and capacity from the IDENTIFY
; reply in the lower left corner. The model's characters come two per
; word with the first in the high byte, which this bus delivers second.
; Nothing is printed when IDENTIFY failed (device size zero).
show_device:
        tst.l   device_sectors
        beq.s   .none
        lea     IDENT_BUF+IDENT_MODEL,a0
        lea     LINE_BUF,a1
        moveq   #IDENT_MODEL_LEN/2-1,d0
.pair:
        move.b  1(a0),(a1)+
        move.b  (a0),(a1)+
        addq.l  #2,a0
        dbf     d0,.pair
.trim:
        cmpi.b  #' ',-(a1)              ; drop the trailing padding
        beq.s   .trim
        addq.l  #1,a1
        move.b  #' ',(a1)+
        move.b  #' ',(a1)+
        move.l  a1,a0
        move.l  device_sectors,d0
        moveq   #MB_SHIFT,d1
        lsr.l   d1,d0
        bsr     put_dec
        lea     msg_mb(pc),a1
        bsr     put_str
        clr.b   (a0)
        moveq   #COL_TEXT,d1
        bsr     color
        moveq   #DEVICE_COL,d1
        moveq   #DEVICE_ROW,d2
        lea     LINE_BUF,a1
        bra     print_at
.none:
        rts

; Prints the boot code's version string, the VERSION_LEN characters after
; '$V=' in the CPLD ROM window or, failing that, in the SRAM boot stub,
; in the lower right corner. Nothing is printed when the tag is absent.
show_version:
        lea     BOOTROM_BASE,a0
        move.w  #BOOTROM_SIZE-VERSION_TAG_LEN-VERSION_LEN,d0
        bsr.s   find_tag
        beq.s   .found
        lea     SRAM_STUB_BASE,a0
        move.w  #SRAM_STUB_SIZE-VERSION_TAG_LEN-VERSION_LEN,d0
        bsr.s   find_tag
        bne.s   .none
.found:
        lea     VERSION_TAG_LEN(a0),a0
        lea     LINE_BUF,a1
        moveq   #VERSION_LEN-1,d0
.copy:
        move.b  (a0)+,(a1)+
        dbf     d0,.copy
        clr.b   (a1)
        moveq   #COL_TEXT,d1
        bsr     color
        moveq   #VERSION_COL,d1
        moveq   #VERSION_ROW,d2
        lea     LINE_BUF,a1
        bra     print_at
.none:
        rts

; a0 = start, d0 = bytes to scan. Z=1 with a0 at the tag when found.
find_tag:
        cmpi.b  #'$',(a0)
        bne.s   .next
        cmpi.b  #'V',1(a0)
        bne.s   .next
        cmpi.b  #'=',2(a0)
        beq.s   .done
.next:
        addq.l  #1,a0
        dbf     d0,find_tag
        moveq   #1,d0                   ; Z=0: not found
.done:
        rts

; Draws the text art at ART_ROW/ART_COL: rows of (attribute, length,
; characters) segments, see ansi2bin.py.
draw_art:
        lea     art(pc),a0
        moveq   #0,d4
        move.b  (a0)+,d4                ; rows
        addq.l  #1,a0                   ; columns, unused
        moveq   #ART_ROW,d5             ; row
.row:
        moveq   #ART_COL,d6             ; column
.segment:
        moveq   #0,d1
        move.b  (a0)+,d1                ; attribute
        beq.s   .rowdone
        moveq   #0,d3
        move.b  (a0)+,d3                ; length
        cmp.w   #ART_SKIP,d1
        bne.s   .text
        add.w   d3,d6
        bra.s   .segment
.text:
        bsr     color
        lea     LINE_BUF,a1
        move.w  d3,d0
        subq.w  #1,d0
.copy:
        move.b  (a0)+,(a1)+
        dbf     d0,.copy
        clr.b   (a1)
        move.w  d6,d1
        move.w  d5,d2
        lea     LINE_BUF,a1
        bsr     print_at
        add.w   d3,d6
        bra.s   .segment
.rowdone:
        addq.w  #1,d5
        subq.w  #1,d4
        bne.s   .row
        rts

; a1 = NUL string -> (a0)+
put_str:
        move.b  (a1)+,(a0)+
        bne.s   put_str
        subq.l  #1,a0
        rts

; a1 = text, d0 = length -> (a0)+, NULs shown as spaces
put_fixed:
        subq.w  #1,d0
.copy:
        move.b  (a1)+,d1
        bne.s   .put
        moveq   #' ',d1
.put:
        move.b  d1,(a0)+
        dbf     d0,.copy
        rts

; d0 = count of spaces -> (a0)+
put_spaces:
        subq.w  #1,d0
.put:
        move.b  #' ',(a0)+
        dbf     d0,.put
        rts

; d0.l = value -> (a0)+, six characters, right aligned
put_dec:
        movem.l d1-d3/a1,-(sp)
        lea     dec_powers(pc),a1
        moveq   #0,d3                   ; digits started
.power:
        move.l  (a1)+,d1
        beq.s   .units
        moveq   #'0'-1,d2
.count:
        addq.b  #1,d2
        sub.l   d1,d0
        bcc.s   .count
        add.l   d1,d0
        cmp.b   #'0',d2
        bne.s   .digit
        tst.w   d3
        bne.s   .digit
        moveq   #' ',d2
        bra.s   .emit
.digit:
        moveq   #1,d3
.emit:
        move.b  d2,(a0)+
        bra.s   .power
.units:
        add.b   #'0',d0
        move.b  d0,(a0)+
        movem.l (sp)+,d1-d3/a1
        rts

dec_powers:
        dc.l    100000,10000,1000,100,10,0

; d1 = colour
color:
        moveq   #IOCS_B_COLOR,d0
        trap    #15
        rts

; d1 = column, d2 = row, a1 = string
print_at:
        move.l  a1,-(sp)
        moveq   #IOCS_B_LOCATE,d0
        trap    #15
        move.l  (sp)+,a1
        moveq   #IOCS_B_PRINT,d0
        trap    #15
        rts

; d3 = seconds. Shows "Boot in n" and a bar shrinking one cell every
; quarter second on COUNT_ROW. Z=1 when it expired, Z=0 when a key was
; pressed (left in the buffer).
countdown:
        moveq   #COL_TEXT,d1
        bsr     color
        moveq   #COUNT_COL,d1
        moveq   #COUNT_ROW,d2
        lea     msg_bootin(pc),a1
        bsr.s   print_at
        move.w  d3,d4
        mulu.w  #BAR_STEP,d4            ; d4 = cells left
        bsr.s   draw_bar
.second:
        move.b  d3,d0
        add.b   #'0',d0
        lea     msg_digit(pc),a1
        move.b  d0,(a1)
        moveq   #COUNT_COL+8,d1
        moveq   #COUNT_ROW,d2
        bsr.s   print_at
.cell:
        moveq   #VBLANKS_PER_SECOND/BAR_STEP-1,d2
.tick:
        bsr     any_key
        bne.s   .key
        bsr     wait_vblank
        dbf     d2,.tick
        subq.w  #1,d4
        bsr.s   draw_bar
        move.w  d4,d0
        and.w   #BAR_STEP-1,d0
        bne.s   .cell
        subq.w  #1,d3
        bne.s   .second
        rts
.key:
        moveq   #COUNT_COL,d1
        moveq   #COUNT_ROW,d2
        lea     msg_blank(pc),a1
        bsr.s   print_at
        moveq   #1,d0
        rts

; d4 = cells lit of BAR_CELLS
draw_bar:
        lea     LINE_BUF,a0
        moveq   #BAR_CELLS,d0
        move.b  #'[',(a0)+
.cells:
        moveq   #'=',d1
        cmp.w   d4,d0
        bls.s   .put
        moveq   #' ',d1
.put:
        move.b  d1,(a0)+
        subq.w  #1,d0
        bne.s   .cells
        move.b  #']',(a0)+
        clr.b   (a0)
        moveq   #BAR_COL,d1
        moveq   #COUNT_ROW,d2
        lea     LINE_BUF,a1
        bra     print_at

; Z=0 when any key is down, from the IOCS key bitmap as SxSI reads it.
any_key:
        moveq   #KEY_GROUPS-1,d1
.group:
        moveq   #IOCS_BITSNS,d0
        trap    #15
        tst.b   d0
        bne.s   .down
        dbf     d1,.group
.down:
        rts

; Waits for a key; d0.b = its scan code, tenkey Enter counted as Return.
key_wait:
        moveq   #IOCS_B_KEYINP,d0
        trap    #15
        lsr.w   #KEY_CODE_SHIFT,d0
        cmp.b   #KEY_TENKEY_ENTER,d0
        bne.s   .done
        moveq   #KEY_RETURN,d0
.done:
        rts

selected:
        dc.l    0

msg_title:
        dc.b    'TerribleFire  TF536',0

msg_title_end:

msg_subtitle:
        dc.b    'ATA Disk IPL Menu',0

msg_subtitle_end:

msg_empty:
        dc.b    0

msg_slot:
        dc.b    'Slot ',0

msg_mb:
        dc.b    ' MB',0

msg_notable:
        dc.b    '  (no partition table)',0

msg_hidden:
        dc.b    'Hidden',0

msg_nosys:
        dc.b    'No system',0

msg_auto:
        dc.b    'Auto',0

msg_manual:
        dc.b    'Manual',0

msg_hint:
        dc.b    'Select with cursor keys, boot with Return',0

msg_hint_end:

msg_none:
        dc.b    'No bootable partition, returning to ROM',0

msg_none_end:

msg_bootin:
        dc.b    'Boot in ',0

msg_digit:
        dc.b    '0',0

msg_blank:
        dc.b    '                                        ',0

msg_booting:
        dc.b    'Booting...                              ',0
        even

art:
        incbin  "logo.bin"
