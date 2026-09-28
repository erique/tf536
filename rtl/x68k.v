`timescale 1ns / 1ps

/*
TF536 on the Sharp X68000: the card's address map.

Address decodes are idle-high (1 = not this cycle), as in main_top.v.

  $00000000-$00FFFFFF  host bus (24-bit); main RAM $000000-$BFFFFF and the
                       ROMs $F00000-$FFFFFF are cacheable (host_cacheable)
  $00E8E00A-$00E8E00B  CPU ID read (sysport_decode)
  $00EA8000-$00EA9FFF  card window: ATA task file (x68k_ata.v), boot ROM at
                       $EA8800 (bootrom_decode, bootrom_x68k.v)
  $00ED000C-$00ED000F  SRAM overlay: ROM-boot handle (reads only)
  $00ED0018-$00ED0019  SRAM overlay: boot device (reads only)
  $01000000-$0FFFFFFF  read-only mirror of the 24-bit host bus
  $10000000-$13FFFFFF  SDRAM (ram_decode)
  $14000000-$FFFFFFFF  read-only mirror of the 24-bit host bus

The card window sits in the expansion I/O area clear of Sharp's boards
(SCSI at $EA0000-$EA1FFF; MIDI, RS-232C, GP-IB and the others from $EAF900;
the extended area set at $EAFF80). The user I/O area from $EC0000 is left
free for boards such as the 64180 board, AWESOME-X, X68K-PPI and ZUSB.
*/

module x68k (
           input         CLK,
           input         AS,
           input         RW,
           input  [31:0] A,

           output        ram_decode,
           output        rom_decode,
           output [15:0] rom_dout,
           output        host_cacheable,
           output        host_read_widen,

           output [1:0]  IDECS,
           output        IOR,
           output        IOW,
           output        DTACK_IDE,
           output        GAYLE_IDE
       );

// SDRAM $10000000-$13FFFFFF. Human68k passes flags in the top byte of
// pointers ($03xxxxxx for _EXEC) and dereferences them unmasked, so nothing
// may be decoded in $01000000-$0FFFFFFF.
localparam SDRAM_WINDOW = 6'b000100;
assign ram_decode = ~(A[31:26] == SDRAM_WINDOW);

// Read-only 24-bit mirror above 16 MB (outside the SDRAM window): reads are
// punted to the host, as Human68k's flag-byte pointers require; writes are
// terminated here and dropped.
wire mirror_write_decode = ~((|A[31:24]) & ram_decode & ~RW);

// Sysport: CPU ID at $E8E00B (CPUTYPE=$D, CPUCLK=$9)
localparam [15:0] SYSPORT_CPU_ID = 16'h00D9;
wire sysport_decode = ({A[31:16]} != 16'h00E8) | (A[15:8] != 8'hE0) | (A[7:1] != 7'h05);

// Host RAM and ROM are cacheable for all accesses. On a cachable read the
// 68030 fills a whole long word and expects a 16-bit port to drive the full
// word regardless of the requested size (MC68030UM 6.1.3.1), so byte reads
// to host RAM assert both strobes (see UDS_D/LDS_D in main_top.v). The ROM
// pair drives both bytes on its own. I/O keeps byte-exact strobes and stays
// inhibited.
localparam HOST_RAM_TOP_MB = 4'hC;
localparam HOST_ROM_MB     = 4'hF;
wire host_ram = (A[31:24] == 8'h00) & (A[23:20] < HOST_RAM_TOP_MB);
assign host_cacheable = (A[31:24] == 8'h00) &
                        ((A[23:20] < HOST_RAM_TOP_MB) | (A[23:20] == HOST_ROM_MB));
// Reads from host RAM always drive both bytes so the cache fill is valid.
assign host_read_widen = host_ram & RW;

// Boot ROM at $EA8800-$EA887F (128 bytes), inside the card window, which
// x68k_ata.v narrows to the task-file registers.
localparam [15:0] BOOTROM_HI = 16'h00EA;
localparam [15:0] BOOTROM_LO = 16'h8800;
wire bootrom_decode = ({A[31:16]} != BOOTROM_HI) | (A[15:7] != BOOTROM_LO[15:7]);

// IPL reads $ED0018 (boot device) and $ED000C (ROM handle). On reads only,
// return ROM-boot $A000 / handle BOOTROM_HI:BOOTROM_LO so IPL JSRs the ROM.
localparam SRAM_OVL_PAGE      = 16'h00ED;
localparam SRAM_OVL_ROMH_HI   = 15'h0006;
localparam SRAM_OVL_ROMH_LO   = 15'h0007;
localparam SRAM_OVL_BOOTDEV   = 15'h000C;
localparam SRAM_OVL_HANDLE_HI = BOOTROM_HI;
localparam SRAM_OVL_HANDLE_LO = BOOTROM_LO;
localparam SRAM_OVL_BOOT_W    = 16'hA000;

wire sram_ovl_hit = (A[31:16] == SRAM_OVL_PAGE) & RW &
                   ((A[15:1] == SRAM_OVL_ROMH_HI) |
                    (A[15:1] == SRAM_OVL_ROMH_LO) |
                    (A[15:1] == SRAM_OVL_BOOTDEV));
wire sram_ovl_decode = ~sram_ovl_hit;
wire [15:0] sram_ovl_dout = (A[15:1] == SRAM_OVL_BOOTDEV) ? SRAM_OVL_BOOT_W :
                       (A[15:1] == SRAM_OVL_ROMH_HI) ? SRAM_OVL_HANDLE_HI :
                       (A[15:1] == SRAM_OVL_ROMH_LO) ? SRAM_OVL_HANDLE_LO :
                       16'h0000;

wire [15:0] bootrom_dout;

bootrom_x68k ROM (
        .clk     ( CLK         ),
        .address ( {A[7:1]}    ),
        .data    ( bootrom_dout )
    );

// Every cycle the card answers itself: boot ROM, CPU ID and SRAM overlay
// reads, and the dropped mirror writes, which drive no data.
assign rom_decode = bootrom_decode & sysport_decode & sram_ovl_decode & mirror_write_decode;
assign rom_dout = ~bootrom_decode ? bootrom_dout :
                  ~sysport_decode ? SYSPORT_CPU_ID :
                  sram_ovl_dout;

// ATA task file in the card window. Host/IO cycle: DSACK from DTACK_IDE on
// the slow CLKCPU, not SDRAM STERM.
x68k_ata ATA (
        .CLK    ( CLK       ),
        .AS     ( AS        ),
        .RW     ( RW        ),
        .A      ( A         ),
        .IDECS  ( IDECS     ),
        .IOR    ( IOR       ),
        .IOW    ( IOW       ),
        .DTACK  ( DTACK_IDE ),
        .ACCESS ( GAYLE_IDE )
    );

endmodule
