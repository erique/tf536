; IPL ROM-boot handle at $EA8800, in the card's ATA window.
; Tries the master, then the slave: loads the device IPL, block 1
; (LBA 2-3), to $2000 and jumps to it if it starts with a BRA.
; When neither drive has one, returns to the IPLROM,
; which continues with its standard boot order.

        include x68k.i

BOOTROM_BASE    equ     $00EA8800

DEV_IPL_LBA     equ     BLOCK_DEVIPL*SECTORS_PER_BLOCK
DEV_IPL_SECTORS equ     2

LOAD_ADDR       equ     $2000
BRA_OPCODE      equ     $60    ; $60xx = bra
WORD_PER_SECTOR equ     256


        org     BOOTROM_BASE
        dc.l    start

start:  lea     ATA_CS0,a0
        moveq   #ATA_MASTER-$100,d6

try:    lea     LOAD_ADDR.w,a1
        movea.l a1,a2

        if      DEV_IPL_SECTORS-DEV_IPL_LBA
        fail    "LBA offset must match length"
        endif

        moveq   #DEV_IPL_SECTORS,d0
        move.b  d0,ATA_OFF_COUNT(a0)
        move.b  d0,ATA_OFF_LBA0(a0)
        clr.b   ATA_OFF_LBA1(a0)
        clr.b   ATA_OFF_LBA2(a0)
        move.b  d6,ATA_OFF_DEVHEAD(a0)

        moveq   #ATA_ATF_DRDY,d1
        bsr.s   wait

        move.b  #ATA_CMD_READ,ATA_OFF_STATUS(a0)

        moveq   #ATA_ATF_DRQ,d1
        bsr.s   wait

        move.w  #WORD_PER_SECTOR*DEV_IPL_SECTORS-1,d7
.copyw: move.w  ATA_OFF_DATA(a0),(a2)+
        dbf     d7,.copyw

        cmpi.b  #BRA_OPCODE,(a1)
        bne.s   next
        jmp     (a1)

next:   bchg    #ATA_SLAVE_BIT,d6
        beq.s   try
ret:    rts

; d1 = status bit to wait for.
wait:   moveq   #-1,d7

.poll:  move.b  ATA_OFF_STATUS(a0),d2
        btst    d1,d2
        dbne    d7,.poll
        bne.s   ret

        addq.l  #4,sp
        bra.s   next

        dc.b    0,"$V="
        incbin  "version.inc"

        if      *-BOOTROM_BASE>128
        fail    "boot ROM exceeds the 128-byte CPLD window"
        endif
        CNOP    0,128
