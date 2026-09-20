`timescale 1ns / 1ps

/*
TF536 on the Sharp X68000: the card's address map.

Address decodes are idle-high (1 = not this cycle), as in main_top.v.

  $00000000-$00FFFFFF  host bus (24-bit)
  $00E8E00A-$00E8E00B  CPU ID read (sysport_decode)
*/

module x68k (
           input         CLK,
           input         AS,
           input         RW,
           input  [31:0] A,

           output        ram_decode,
           output        rom_decode,
           output [15:0] rom_dout,

           output [1:0]  IDECS,
           output        IOR,
           output        IOW,
           output        DTACK_IDE,
           output        GAYLE_IDE
       );

// No SDRAM: every cycle outside the card's own registers goes to the host.
assign ram_decode = 1'b1;

// Sysport: CPU ID at $E8E00B (CPUTYPE=$D, CPUCLK=$9)
localparam [15:0] SYSPORT_CPU_ID = 16'h00D9;
wire sysport_decode = ({A[31:16]} != 16'h00E8) | (A[15:8] != 8'hE0) | (A[7:1] != 7'h05);

// The reads the card answers itself: the CPU ID.
assign rom_decode = sysport_decode;
assign rom_dout = SYSPORT_CPU_ID;

// No ATA task file.
assign IDECS = 2'b11;
assign IOR = 1'b1;
assign IOW = 1'b1;
assign DTACK_IDE = 1'b1;
assign GAYLE_IDE = 1'b1;

endmodule
