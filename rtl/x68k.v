`timescale 1ns / 1ps

/*
TF536 on the Sharp X68000: the card's address map.

Address decodes are idle-high (1 = not this cycle), as in main_top.v.

  $00000000-$00FFFFFF  host bus (24-bit); main RAM $000000-$BFFFFF and the
                       ROMs $F00000-$FFFFFF are cacheable (host_cacheable)
  $00E8E00A-$00E8E00B  CPU ID read (sysport_decode)
  $01000000-$0FFFFFFF  read-only mirror of the 24-bit host bus
  $10000000-$13FFFFFF  SDRAM (ram_decode)
  $14000000-$FFFFFFFF  read-only mirror of the 24-bit host bus
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

// Every cycle the card answers itself: CPU ID reads, and the dropped
// mirror writes, which drive no data.
assign rom_decode = sysport_decode & mirror_write_decode;
assign rom_dout = SYSPORT_CPU_ID;

// No ATA task file.
assign IDECS = 2'b11;
assign IOR = 1'b1;
assign IOW = 1'b1;
assign DTACK_IDE = 1'b1;
assign GAYLE_IDE = 1'b1;

endmodule
