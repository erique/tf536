; Serial console for boot-chain diagnostics: SCC channel A (the RS-232C
; port), 9600 baud 8N1, polled.

; ---------------------------------------------------------------- SCC

SCC_A_CMD       equ     $E98005         ; channel A command / register pointer
SCC_A_DATA      equ     $E98007         ; channel A data

; write registers, each followed by the value loaded into it
SCC_WR3         equ     $03             ; receive parameters
SCC_WR3_RX8     equ     $C1             ;   8 bits, receiver on
SCC_WR4         equ     $04             ; clock mode and framing
SCC_WR4_X16N1   equ     $44             ;   x16 clock, 1 stop bit, no parity
SCC_WR5         equ     $05             ; transmit parameters
SCC_WR5_TX8     equ     $EA             ;   8 bits, transmitter on, DTR, RTS
SCC_WR9         equ     $09             ; master interrupt control
SCC_WR9_HWRESET equ     $C0             ;   hardware reset
SCC_WR11        equ     $0B             ; clock source
SCC_WR11_BRG    equ     $50             ;   baud rate generator for both directions
SCC_WR12        equ     $0C             ; baud rate time constant, low byte
SCC_BRG_LO      equ     14              ;   9600 baud
SCC_WR13        equ     $0D             ; baud rate time constant, high byte
SCC_BRG_HI      equ     0
SCC_WR14        equ     $0E             ; baud rate generator control
SCC_WR14_PCLK   equ     $03             ;   PCLK source, generator on

SCC_RR0_TXBE    equ     2               ; RR0: transmit buffer empty

; ---------------------------------------------------------------- misc

SR_IPL_MASK     equ     $0700           ; SR interrupt mask, all levels
CR              equ     13
LF              equ     10

; ---------------------------------------------------------------- code

scc_init:
        move.l  a1,-(sp)
        lea     SCC_A_CMD,a1
        move.b  #SCC_WR9,(a1)
        move.b  #SCC_WR9_HWRESET,(a1)
        move.b  #SCC_WR4,(a1)
        move.b  #SCC_WR4_X16N1,(a1)
        move.b  #SCC_WR11,(a1)
        move.b  #SCC_WR11_BRG,(a1)
        move.b  #SCC_WR12,(a1)
        move.b  #SCC_BRG_LO,(a1)
        move.b  #SCC_WR13,(a1)
        move.b  #SCC_BRG_HI,(a1)
        move.b  #SCC_WR14,(a1)
        move.b  #SCC_WR14_PCLK,(a1)
        move.b  #SCC_WR3,(a1)
        move.b  #SCC_WR3_RX8,(a1)
        move.b  #SCC_WR5,(a1)
        move.b  #SCC_WR5_TX8,(a1)
        move.l  (sp)+,a1
        rts

; a0 = NUL string. Trashes a0.
scc_puts:
        move.l  d0,-(sp)
.lp:
        move.b  (a0)+,d0
        beq.s   .done
        bsr     scc_putc
        bra.s   .lp
.done:
        move.l  (sp)+,d0
        rts

; d0.b = char
; Interrupts are masked while touching the SCC: the IOCS mouse handler
; shares the SCC register pointer.
scc_putc:
        move.w  sr,-(sp)
        ori.w   #SR_IPL_MASK,sr
.wait:
        btst    #SCC_RR0_TXBE,SCC_A_CMD
        beq.s   .wait
        move.b  d0,SCC_A_DATA
        move.w  (sp)+,sr
        rts

; d0 = value, printed as 8, 4, 2 or 1 hex digits; each routine falls
; through into the next one down.
scc_puthex32:
        move.l  d0,-(sp)
        swap    d0
        bsr     scc_puthex16
        move.l  (sp)+,d0

scc_puthex16:
        move.w  d0,-(sp)
        lsr.w   #8,d0
        bsr     scc_puthex8
        move.w  (sp)+,d0

scc_puthex8:
        move.b  d0,-(sp)
        lsr.b   #4,d0
        bsr     scc_nibble
        move.b  (sp)+,d0

scc_nibble:
        andi.b  #$0F,d0
        cmp.b   #9,d0
        bls.s   .dec
        addq.b  #'A'-10-'0',d0
.dec:
        add.b   #'0',d0
        bra     scc_putc

; CR LF
scc_putnl:
        move.b  #CR,d0
        bsr     scc_putc
        move.b  #LF,d0
        bra     scc_putc

; a0 = label, d0.l = value (32-bit hex), then newline
scc_tag32:
        move.l  d0,-(sp)
        bsr     scc_puts
        move.l  (sp)+,d0
        bsr     scc_puthex32
        bra     scc_putnl

; a0 = label, d0.b = value (8-bit hex), then newline
scc_tag8:
        move.l  d0,-(sp)
        bsr     scc_puts
        move.l  (sp)+,d0
        bsr     scc_puthex8
        bra     scc_putnl
