`timescale 1ns / 1ps

/*
TF536 on the Sharp X68000: ATA task file in the card window.

Decodes are idle-high (1 = not this cycle), as in main_top.v.
*/

module x68k_ata (
           input         CLK,
           input         AS,
           input         RW,
           input  [31:0] A,

           output [1:0]  IDECS,
           output        IOR,
           output        IOW,
           output        DTACK,
           output        ACCESS
       );

// Card window $EA8000-$EA9FFF (expansion I/O):
//   $EA8000-$EA801F  ATA task file, CS0 (register n at +4n)
//   $EA8800-$EA887F  boot ROM (x68k.v)
//   $EA9000-$EA901F  ATA task file, CS1
//   rest             not decoded
localparam [15:0] ATA_SEL_HI  = 16'h00EA;
localparam [2:0]  ATA_SEL_MID = 3'b100;
wire ata_decode = ({A[31:16]} != ATA_SEL_HI) | (A[15:13] != ATA_SEL_MID) | (|A[11:5]);

// Strobes in CLKCPU (10 MHz) edges E1, E2, ... after AS falls:
//   data register read   IOR E2 .. AS high   DTACK E3
//   data register write  IOW E2 .. E4        DTACK E4
//   task file read       IOR E4 .. AS high   DTACK E6
//   task file write      IOW E5 .. AS high   DTACK E6
// The data register (CS0 register 0) runs PIO 2 data timing.
// Its write strobe ends on a clock inside the cycle, so the data outlives it (t4).
wire DATAREG = ~A[12] & (A[4:2] == 3'b000);

reg ASDLY = 1'b1;
reg ASDLY2 = 1'b1;
reg ASDLY3 = 1'b1;
reg ASDLY4 = 1'b1;
reg ASDLY5 = 1'b1;
reg DTACK_INT = 1'b1;

reg IOR_INT = 1'b1;
reg IOW_INT = 1'b1;

always @(posedge CLK or posedge AS) begin

    if (AS == 1'b1) begin

        ASDLY <= 1'b1;
        ASDLY2 <= 1'b1;
        ASDLY3 <= 1'b1;
        ASDLY4 <= 1'b1;
        ASDLY5 <= 1'b1;

    end else begin

        ASDLY <= AS;
        ASDLY2 <= ASDLY;
        ASDLY3 <= ASDLY2;
        ASDLY4 <= ASDLY3;
        ASDLY5 <= ASDLY4;

    end

end

always @(posedge CLK or posedge AS) begin

    if (AS == 1'b1) begin

        IOR_INT <= 1'b1;
        IOW_INT <= 1'b1;
        DTACK_INT <= 1'b1;

    end else if (DATAREG) begin

        IOR_INT <= ~RW | ASDLY | ata_decode;
        IOW_INT <=  RW | ASDLY | ~ASDLY3 | ata_decode;
        DTACK_INT <= (RW ? ASDLY2 : ASDLY3) | ata_decode;

    end else begin

        IOR_INT <= ~RW | ASDLY3 | ata_decode;
        IOW_INT <=  RW | ASDLY4 | ata_decode;
        DTACK_INT <=  ASDLY5 | ata_decode;

    end

end

assign IOR = IOR_INT;
assign IOW = IOW_INT;
assign DTACK = DTACK_INT;

assign IDECS = A[12] ? {ata_decode, 1'b1} : {1'b1, ata_decode};
assign ACCESS = ata_decode;

endmodule
