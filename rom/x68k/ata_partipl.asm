; Partition IPL at $2400: the first 1024 bytes sit at the partition start,
; the second half in block 24 of the slot. Entered from the device IPL with
; d5 = slot base, d6 = partition start (absolute LBA), d7 = slot index
; (handoff in x68k.i). Keep the BPB at +$12.
; The handoff registers and the BPB-derived values are stored in the first
; 1024 bytes, because the second half then loads over $2800.
; Loads HUMAN.SYS (X, base $6800, contiguous) via ATA, jmp $6800. All reads
; use the slot base from the handoff. On any failure before HUMAN runs (no
; HUMAN.SYS among the first N_ROOT_SCAN root entries, a read error) it
; shows a message for FAIL_SECONDS and returns to the IPLROM.
; Install: copy TFIDE from block 3 of the slot into a1 (Human68k
; SCSI-style) and tell it the booted partition.
        include x68k.i

        org     PART_IPL_ADDR

; card and boot layout (x68k.i)
BRA_OPCODE      equ     $60
IPL_PART2_LBA   equ     BLOCK_IPL_PART2*SECTORS_PER_BLOCK
IPL_PART2_ADDR  equ     $2800
IPL_PART2_SECTORS equ     2
TFIDE_LBA       equ     BLOCK_TFIDE*SECTORS_PER_BLOCK
TFIDE_SECTS     equ     26
ROOT_BUF        equ     $2C00
HUMAN_BASE      equ     $6800
X_HEADER        equ     64
FAIL_SECONDS    equ     5

; Human68k BPB and root directory
BPB_BPS         equ     $12
BPB_SPC         equ     $14
BPB_FATS        equ     $15
BPB_RESERVED    equ     $16
BPB_ROOT_ENTRIES equ     $18
BPB_SPF         equ     $1D
SECTOR_SHIFT    equ     9
DIR_ENT         equ     32
DIR_ENT_SHIFT   equ     5
DIR_CLUSTER     equ     $1A
DIR_SIZE        equ     $1C
FIRST_CLUSTER   equ     2
N_ROOT_SCAN     equ     32

; IOCS
IOCS_B_PRINT    equ     $21
IOCS_B_SUPER    equ     $81
IOCS_BOOTINF    equ     $8E
IOCS_ROMVER     equ     $8F
IOCS_SYS_STAT   equ     $AC
IOCS_OS_CUROF   equ     $AF
SYS_STAT_SET_CACHE equ     4
CACHE_BOTH_ON   equ     3
ROMVER_030      equ     $13
IOCS_MPU_TYPE   equ     $CBC
IOCS_CLK_10     equ     100
MPU_68010       equ     1

; 68030 vectors, SR and exception frames
TRAP15_VEC      equ     $BC
VEC_BUSERR      equ     $8
SR_SUPER        equ     $2000
SR_SUPER_BIT    equ     13
SR_USER_MASK    equ     $DFFF
SR_SUPER_IRQ_ON equ     $2000
SR_SUPER_IRQ_OFF equ     $2700
FRAME_SR        equ     0
FRAME_PC        equ     2
FRAME_FMT       equ     6
BERR_FRAME_PC   equ     2
BERR_FRAME_FAULT equ     $10

; Human68k 3.02: patch sites, their original bytes, entry points
HU_EXEC_ARGS    equ     $9424
HU_EXEC_SIG0    equ     $225EB27C
HU_EXEC_SIG1    equ     $0004
HU_TYPE_A       equ     $9526
HU_TYPE_B       equ     $9638
HU_TYPE_SIG0    equ     $2009E198
HU_TYPE_SIG1    equ     $4A00
OP_JSR_ABSL     equ     $4EB9
EXEC_MODE_EXEC  equ     4
ADDR_MASK_24    equ     $00FFFFFF
SDRAM_OLD_WINDOW equ     $01000000
HU_MPU_PROBE    equ     $6874
HU_OS_CUROF     equ     $78FC
HU_WORK_INIT    equ     $7902
HU_DRV_TABLE    equ     $8290
HU_INSTALL      equ     $7E70
HU_AFTER_INS    equ     $68BA

; hardware
MFP_GPIP        equ     $E88001
GPIP_VDISP      equ     4
VBLANKS_PER_SECOND equ     60

; debug: marker written when TFIDE is installed
INSTALL_PROBE   equ     $4000

; ---------------------------------------------------------------- code

        bra.s   start
        dcb.b   $26-2,0

start:
        move.w  #SR_SUPER_IRQ_OFF,sr
        move.l  d5,slot_base
        move.l  d6,part_start
        move.w  d7,slot_index
        move.l  d5,d0
        add.l   #IPL_PART2_LBA,d0
        moveq   #IPL_PART2_SECTORS,d1
        lea     IPL_PART2_ADDR,a1
        bsr     ata_read
        bne     ipl_fail
        bsr     scc_init
        lea     msg_ipl(pc),a0
        bsr     scc_puts
        moveq   #IOCS_BOOTINF-$100,d0
        trap    #15
        lea     msg_binf(pc),a0
        bsr     scc_tag32
        bsr     ata_identify
        lea     PART_IPL_ADDR,a6
        move.w  BPB_BPS(a6),d0
        lea     msg_bps(pc),a0
        bsr     scc_tag32
        moveq   #0,d0
        move.b  BPB_SPC(a6),d0
        lea     msg_spc(pc),a0
        bsr     scc_tag8
        move.l  part_start(pc),d0
        lea     msg_pstart(pc),a0
        bsr     scc_tag32
        lea     ATA_CS0,a0
        moveq   #0,d0
        move.w  BPB_BPS(a6),d0
        moveq   #SECTOR_SHIFT,d1
        lsr.w   d1,d0                   ; ATA sectors per logical sector
        moveq   #-1,d1
.log2:
        addq.w  #1,d1
        lsr.w   #1,d0
        bne.s   .log2
        move.w  d1,sector_shift         ; logical sector to ATA sector shift
        moveq   #0,d0
        move.w  BPB_RESERVED(a6),d0
        moveq   #0,d1
        move.b  BPB_FATS(a6),d1
        moveq   #0,d2
        move.b  BPB_SPF(a6),d2
        mulu.w  d2,d1
        add.l   d1,d0
        move.l  d0,d3                   ; d3 = root directory, logical sector
        moveq   #0,d1
        move.w  BPB_ROOT_ENTRIES(a6),d1
        lsr.w   #DIR_ENT_SHIFT,d1
        move.l  d3,d4
        add.l   d1,d4                   ; d4 = data area, logical sector
        move.l  d3,d0
        move.w  sector_shift(pc),d1
        lsl.l   d1,d0
        add.l   part_start(pc),d0
        move.l  d0,-(sp)
        lea     msg_rlba(pc),a0
        bsr     scc_tag32
        move.l  (sp)+,d0
        moveq   #2,d1
        lea     ROOT_BUF,a1
        lea     ATA_CS0,a0
        bsr     ata_read
        bne     do_fail
        lea     msg_root(pc),a0
        bsr     scc_puts
        lea     ROOT_BUF,a1
        moveq   #N_ROOT_SCAN-1,d7
.find:
        cmp.l   #'HUMA',(a1)
        bne.s   .next
        cmp.l   #'N   ',4(a1)
        bne.s   .next
        cmp.w   #'SY',8(a1)
        bne.s   .next
        cmp.b   #'S',10(a1)
        beq.s   .got
.next:
        lea     DIR_ENT(a1),a1
        dbf     d7,.find
        lea     msg_nohum(pc),a0
        bsr     scc_puts
        jmp     ipl_fail
.got:
        moveq   #0,d5
        move.w  DIR_CLUSTER(a1),d5
        ror.w   #8,d5
        subq.l  #FIRST_CLUSTER,d5
        moveq   #0,d1
        move.b  BPB_SPC(a6),d1
        mulu.w  d1,d5
        add.l   d4,d5
        move.w  sector_shift(pc),d1
        lsl.l   d1,d5
        add.l   part_start(pc),d5
        move.l  DIR_SIZE(a1),d1
        ror.w   #8,d1
        swap    d1
        ror.w   #8,d1
        add.l   #(1<<SECTOR_SHIFT)-1,d1
        moveq   #SECTOR_SHIFT,d0
        lsr.l   d0,d1
        move.l  d5,d0
        lea     msg_human(pc),a0
        bsr     scc_puts
        move.l  d5,d0
        bsr     scc_puthex32
        lea     msg_sp(pc),a0
        bsr     scc_puts
        move.l  d1,d0
        bsr     scc_puthex32
        lea     msg_nl(pc),a0
        bsr     scc_puts
        move.l  d5,d0
        lea     HUMAN_BASE-X_HEADER,a1
        lea     ATA_CS0,a0
        bsr     ata_read
        bne     do_fail
        move.w  HUMAN_BASE-X_HEADER,d0
        lea     msg_hu(pc),a0
        bsr     scc_tag32
        cmp.w   #'HU',HUMAN_BASE-X_HEADER
        bne     do_fail
        bsr     human_patch
        moveq   #IOCS_ROMVER-$100,d0
        trap    #15
        swap    d0
        lsr.w   #8,d0
        move.b  d0,rom_version
        cmp.b   #ROMVER_030,d0
        blo.s   .nocache
        moveq   #IOCS_SYS_STAT-$100,d0
        moveq   #SYS_STAT_SET_CACHE,d1
        moveq   #CACHE_BOTH_ON,d2
        trap    #15
.nocache:
        move.l  TRAP15_VEC.w,iocs_old
        lea     iocs_hook(pc),a0
        move.l  a0,TRAP15_VEC.w
        move.l  VEC_BUSERR.w,ber_old
        lea     ber_hook(pc),a0
        move.l  a0,VEC_BUSERR.w
        jmp     human_wrap

do_fail:
        jmp     ipl_fail

; Handoff and BPB-derived values, stored before the second half is loaded
; over $2800, so they must stay in the first half.
slot_base:
        dc.l    0

part_start:
        dc.l    0

slot_index:
        dc.w    0

sector_shift:
        dc.w    0

; Any failure before HUMAN runs: message on screen and serial, then back
; to the IPLROM, whose return address is still on the stack.
ipl_fail:
        lea     msg_fail(pc),a0
        move.b  d2,d0
        bsr     scc_tag8
        lea     msg_screen_fail(pc),a1
        moveq   #IOCS_B_PRINT,d0
        trap    #15
        moveq   #FAIL_SECONDS,d3
.second:
        moveq   #VBLANKS_PER_SECOND-1,d2
.disp:
        btst    #GPIP_VDISP,MFP_GPIP
        bne.s   .disp
.blank:
        btst    #GPIP_VDISP,MFP_GPIP
        beq.s   .blank
        dbf     d2,.disp
        subq.w  #1,d3
        bne.s   .second
        rts

; d0=LBA, d1=count (1-255), a1=dest, a0=ATA_CS0
; Z=1 ok, d2=status
ata_read:
        movem.l d0-d1/d3/d7/a0-a1,-(sp)
        lea     ATA_CS0,a0
.nx:
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
        moveq   #-1,d7
.wr:
        move.b  ATA_OFF_STATUS(a0),d2
        btst    #ATA_ATF_DRDY,d2
        bne.s   .cmd
        dbf     d7,.wr
        bra.s   .bad
.cmd:
        move.b  #ATA_CMD_READ,ATA_OFF_STATUS(a0)
        moveq   #-1,d7
.wd:
        move.b  ATA_OFF_STATUS(a0),d2
        btst    #ATA_ATF_DRQ,d2
        bne.s   .cp
        dbf     d7,.wd
        bra.s   .bad
.cp:
        move.w  #(1<<SECTOR_SHIFT)/2-1,d7
.c1:
        move.w  (a0),(a1)+
        dbf     d7,.c1
        addq.l  #1,d0
        subq.w  #1,d1
        bne.s   .nx
        movem.l (sp)+,d0-d1/d3/d7/a0-a1
        moveq   #0,d2
        rts
.bad:
        move.l  d2,-(sp)
        lea     msg_ataf(pc),a0
        move.b  d2,d0
        bsr     scc_tag8
        move.l  (sp)+,d2
        movem.l (sp)+,d0-d1/d3/d7/a0-a1
        moveq   #1,d2
        rts

msg_fail:
        dc.b    'FAIL ST=',0

msg_screen_fail:
        dc.b    'TF536: this partition cannot be booted (no HUMAN.SYS or read error), returning to ROM',CR,LF,0

msg_ataf:
        dc.b    'ATAF=',0
        even
        include scc.i

first_half_end:

Install:
        tst.b   installed
        bne.s   .again
        st      installed
        movem.l d0-d2/a0-a2,-(sp)
        move.w  #INSTALL_PROBE,INSTALL_PROBE.w
        lea     msg_inst(pc),a0
        move.l  a1,d0
        bsr     scc_tag32
        lea     ATA_CS0,a0
        move.l  a1,a2
        move.l  slot_base(pc),d0
        add.l   #TFIDE_LBA,d0
        moveq   #TFIDE_SECTS,d1
        bsr     ata_read
        tst.b   d2
        bne.s   .insbad
        move.l  a2,d0
        add.l   d0,6(a2)
        add.l   d0,10(a2)
        move.l  part_start(pc),TFIDE_BOOT_PART(a2)
        lea     msg_tfide(pc),a0
        bsr     scc_puts
        bra.s   .insout
.insbad:
        lea     msg_insf(pc),a0
        bsr     scc_puts
.insout:
        movem.l (sp)+,d0-d2/a0-a2
        rts
.again:
        moveq   #-1,d2
        rts

installed:
        dc.b    0
        even

iocs_old:
        dc.l    0

ber_old:
        dc.l    0

human_wrap:
        move.w  #SR_SUPER_IRQ_ON,sr
        movea.l #HUMAN_BASE,sp
        bsr     scc_init
        jsr     HU_MPU_PROBE
        move.b  IOCS_MPU_TYPE.w,d0
        lea     msg_cbc(pc),a0
        bsr     scc_tag8
        jsr     HU_OS_CUROF
        jsr     HU_WORK_INIT
        jsr     HU_DRV_TABLE
        jsr     HU_INSTALL
        lea     msg_w6(pc),a0
        bsr     scc_puts
        movem.l d0-d1/a0-a1,-(sp)
        lea     msg_screen(pc),a1
        moveq   #IOCS_B_PRINT,d0
        trap    #15
        movem.l (sp)+,d0-d1/a0-a1
        jmp     HU_AFTER_INS

ber_hook:
        move.w  #SR_SUPER_IRQ_OFF,sr
        move.l  BERR_FRAME_PC(sp),d0
        lea     msg_bpc(pc),a0
        bsr     scc_tag32
        move.l  BERR_FRAME_FAULT(sp),d0
        lea     msg_bfa(pc),a0
        bsr     scc_tag32
.hang:
        bra.s   .hang

; _BOOTINF is always answered here (ROM handle in RAM). _SYS_STAT,
; _OS_CUROF and _B_SUPER are only supplied for ROM IOCS older than 1.3;
; later ROMs implement them for the 68030 themselves.
iocs_hook:
        cmp.b   #IOCS_BOOTINF,d0
        beq.s   .bootinf
        cmp.b   #ROMVER_030,rom_version
        bhs.s   .passthru
        cmp.b   #IOCS_B_SUPER,d0
        beq.s   .super
        cmp.b   #IOCS_SYS_STAT,d0
        beq.s   .sysstat
        cmp.b   #IOCS_OS_CUROF,d0
        beq.s   .curof
.passthru:
        move.l  iocs_old(pc),-(sp)
        rts
.bootinf:
        lea     boot_handle(pc),a0
        move.l  a0,d0
        rte
; _B_SUPER for the 68030 frame layout (SR, PC, format word). ROM IOCS
; before 1.3 copies a 68000 frame and returns to a wrong PC on a 68030.
; a1 = 0: enter supervisor mode, continue on the user stack, d0 = old frame
; end for the matching exit call. a1 = that value: return to user mode.
.super:
        cmp.b   #MPU_68010,IOCS_MPU_TYPE.w
        bls.s   .superrom
        move.l  a1,d0
        beq.s   .superin
        move.w  FRAME_FMT(sp),-(a1)
        move.l  FRAME_PC(sp),-(a1)
        move.w  FRAME_SR(sp),-(a1)
        and.w   #SR_USER_MASK,(a1)
        moveq   #0,d0
        movea.l a1,sp
        rte
.superin:
        moveq   #-1,d0
        btst    #SR_SUPER_BIT-8,FRAME_SR(sp)
        bne.s   .superdone
        move.l  usp,a1
        move.l  sp,d0
        addq.l  #FRAME_FMT+2,d0
        move.w  FRAME_FMT(sp),-(a1)
        move.l  FRAME_PC(sp),-(a1)
        move.w  FRAME_SR(sp),-(a1)
        or.w    #SR_SUPER,(a1)
        movea.l a1,sp
.superdone:
        rte
.superrom:
        move.l  iocs_old(pc),-(sp)
        rts
.sysstat:
        cmp.w   #1,d1
        beq.s   .cache
        moveq   #0,d0
        move.b  IOCS_MPU_TYPE.w,d0
        or.l    #IOCS_CLK_10<<16,d0
        rte
.cache:
        moveq   #0,d0
        rte
.curof:
        moveq   #0,d0
        rte

;  HUMAN 3.02 passes the _EXEC file type in the top byte of the file-name
;  pointer and uses the pointer unmasked, which only works where A24-A31
;  are not decoded. A CPLD that still maps SDRAM at $01000000 is detected
;  by that address not mirroring address 0. The _EXEC argument fetch
;  is redirected to a stub that saves the type byte and masks the pointer
;  to 24 bits; the two places that read the type byte get it from the
;  saved copy. Each site is verified against its original bytes.
human_patch:
        movem.l d0/a0-a1,-(sp)
        move.l  SDRAM_OLD_WINDOW,d0
        cmp.l   0.w,d0
        beq.s   .pdone
        lea     HU_EXEC_ARGS,a0
        cmp.l   #HU_EXEC_SIG0,(a0)
        bne.s   .nopatch
        cmp.w   #HU_EXEC_SIG1,4(a0)
        bne.s   .nopatch
        lea     HU_TYPE_A,a0
        bsr.s   .chktype
        bne.s   .nopatch
        lea     HU_TYPE_B,a0
        bsr.s   .chktype
        bne.s   .nopatch
        lea     HU_EXEC_ARGS,a0
        lea     exec_args_stub(pc),a1
        bsr.s   .jsr
        lea     HU_TYPE_A,a0
        lea     exec_type_stub(pc),a1
        bsr.s   .jsr
        lea     HU_TYPE_B,a0
        lea     exec_type_stub(pc),a1
        bsr.s   .jsr
        lea     msg_patch(pc),a0
        bsr     scc_puts
        bra.s   .pdone
.nopatch:
        lea     msg_nopatch(pc),a0
        bsr     scc_puts
.pdone:
        movem.l (sp)+,d0/a0-a1
        rts
.chktype:
        cmp.l   #HU_TYPE_SIG0,(a0)
        bne.s   .ct
        cmp.w   #HU_TYPE_SIG1,4(a0)
.ct:
        rts
.jsr:
        move.w  #OP_JSR_ABSL,(a0)+
        move.l  a1,(a0)
        rts

; Replaces: movea.l (a6)+,a1 / cmp.w #EXEC_MODE_EXEC,d1
exec_args_stub:
        movea.l (a6)+,a1
        movem.l d0,-(sp)
        move.l  a1,d0
        rol.l   #8,d0
        move.b  d0,exec_type
        move.l  a1,d0
        and.l   #ADDR_MASK_24,d0
        movea.l d0,a1
        movem.l (sp)+,d0
        cmp.w   #EXEC_MODE_EXEC,d1
        rts

; Replaces: move.l a1,d0 / rol.l #8,d0 / tst.b d0
exec_type_stub:
        moveq   #0,d0
        move.b  exec_type(pc),d0
        rts

exec_type:
        dc.b    0

rom_version:
        dc.b    0
        even

msg_patch:
        dc.b    'HUPATCH OK',CR,LF,0

msg_nopatch:
        dc.b    'HUPATCH NO',CR,LF,0
        even


; ROM-boot handle in RAM, laid out like a SCSI board ROM or SxSI's SRAM
; program: the routine pointer, then the 16 bytes HUMAN reads back from the
; routine's start - install pointer, parameter, 'Human68k' - so it jsr's
; Install. _BOOTINF returns this handle, not the CPLD boot ROM's.
boot_handle:
        dc.l    boot_handle_routine
        dc.l    Install
        dc.l    0
        dc.b    'Human68k'

boot_handle_routine:
        rts

msg_ipl:
        dc.b    'IPL $2400',CR,LF,0

msg_binf:
        dc.b    'BINF=',0

msg_bps:
        dc.b    'BPS=',0

msg_spc:
        dc.b    'SPC=',0

msg_pstart:
        dc.b    'PSTART=',0

msg_rlba:
        dc.b    'RLBA=',0

msg_root:
        dc.b    'ROOT OK',CR,LF,0

msg_nohum:
        dc.b    'NO HUMAN.SYS',CR,LF,0

msg_human:
        dc.b    'HUMAN LBA=',0

msg_hu:
        dc.b    'HU=',0

msg_cbc:
        dc.b    'CBC=',0

msg_bpc:
        dc.b    'BERR PC=',0

msg_bfa:
        dc.b    'FA=',0

msg_screen:
        dc.b    'TF536 ATA boot: TFIDE installed',CR,LF,0

msg_w6:
        dc.b    'W6 OK',CR,LF,0

msg_nl:
        dc.b    CR,LF,0

msg_sp:
        dc.b    ' N=',0

msg_tfide:
        dc.b    'TFIDE OK',CR,LF,0

msg_inst:
        dc.b    'INST A1=',0

msg_insf:
        dc.b    'TFIDE FAIL',CR,LF,0

msg_idfail:
        dc.b    'IDENTIFY FAIL',CR,LF,0

msg_idst:
        dc.b    'IDST=',0
        even

; IDENTIFY DEVICE $EC -> ROOT_BUF, dump W0, W49, max LBA, model.
ata_identify:
        movem.l d0-d2/d7/a0-a1,-(sp)
        lea     ATA_CS0,a0
        move.b  #ATA_MASTER_CHS,ATA_OFF_DEVHEAD(a0)
        moveq   #-1,d7
.wr:
        move.b  ATA_OFF_STATUS(a0),d2
        btst    #ATA_ATF_DRDY,d2
        bne.s   .cmd
        dbf     d7,.wr
        lea     msg_idfail(pc),a0
        bra     .idout
.cmd:
        move.b  #ATA_CMD_IDENTIFY,ATA_OFF_STATUS(a0)
        moveq   #-1,d7
.wd:
        move.b  ATA_OFF_STATUS(a0),d2
        btst    #ATA_ATF_DRQ,d2
        bne.s   .cp
        dbf     d7,.wd
        lea     msg_idfail(pc),a0
        bra     .idout
.cp:
        lea     ROOT_BUF,a1
        move.w  #(1<<SECTOR_SHIFT)/2-1,d7
.c1:
        move.w  (a0),(a1)+
        dbf     d7,.c1
        bra.s   .iddone
.idout:
        bsr     scc_puts
        move.b  d2,d0
        lea     msg_idst(pc),a0
        bsr     scc_tag8
.iddone:
        movem.l (sp)+,d0-d2/d7/a0-a1
        rts

        dcb.b   $2C00-*,0
