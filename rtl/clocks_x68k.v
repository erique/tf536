`timescale 1ns / 1ps

/*
TF536 on the Sharp X68000: CPU clock.
*/

module clocks_x68k #(
           parameter CLOCK_PHASE=5
       )(
           input      CLK100M,
           input      CLK7M_RAW,
           input      SPEED,
           output     CLKCPU,
           output reg CLK50M,
           output     CLK7M,
           output     CPUSLOW
       );

// The socket clock, CLK7M_RAW, is the X68000's 10MHz host clock.
localparam SYSTEM_CLOCK_MHZ = 10;

// DPLL-based clock reconstruction for X68K.
// Free-running divide-by-10 from 100MHz, phase-locked to baseboard 10MHz.
// Uses negedge sampling for 5ns-precision phase detection.
// CLOCK_PHASE controls the lock point (keep at 5 for symmetry).
// OUT_OFFSET shifts the output toggle points (each step = 10ns earlier).
localparam HALF_PERIOD = 50 / SYSTEM_CLOCK_MHZ;  // 5 for 10MHz
localparam PERIOD = HALF_PERIOD * 2;              // 10 for 10MHz

// Output toggle points, shifted by OUT_OFFSET from default
localparam OUT_OFFSET = CLOCK_PHASE - 5;  // 0 when PHASE=5, +1 when PHASE=6, etc.
localparam RISE_AT = (PERIOD - 1 >= OUT_OFFSET) ?
                     (PERIOD - 1 - OUT_OFFSET) :
                     (PERIOD - 1 - OUT_OFFSET + PERIOD);
localparam FALL_AT = (HALF_PERIOD - 1 >= OUT_OFFSET) ?
                     (HALF_PERIOD - 1 - OUT_OFFSET) :
                     (HALF_PERIOD - 1 - OUT_OFFSET + PERIOD);

reg SPEED_D = 0;
reg CLK50MI = 0;
reg [3:0] phase_cnt = 0;
reg dpll_out = 0;
reg ref_prev = 0;
reg clk_locked = 0;

// Fast CPU clock between host cycles.
//
// The 68030 drives its address bus on every rising edge of CLKCPU, so
// between host cycles the host address lines switch at the fast rate. When
// many address bits switch within about 3ns of the socket clock's rising
// edge, the baseboard's TVRAM refresh sequencer (VICON) loses a 10MHz
// period, a refresh RAS comes out too short and a TVRAM row is destroyed.
//
// At 50MHz one of the five rising edges per 100ns always lands near the
// socket-clock edge. The fast clock is therefore taken from the DPLL
// counter, so its edges keep a fixed phase to the 10MHz, and the rising edge
// after count FAST_SKIP, the one on the socket-clock edge, is dropped:
//
//   ns after socket edge  0   10  20  30  40  50  60  70  80  90  100 110 120
//   CLKCPU                _   _   #   _   #   _   #   _   #   _   _   _   #
//   cycle (ns)                    |--20---|--20---|--20---|------40-------|
//
// Four rising edges per 100ns, none near the socket-clock edge: the same
// work per second as a 40MHz clock, and a 40MHz clock to anything that
// measures it.
localparam FAST_PHASE = 0;  // which of the two 10ns grids the edges use
localparam FAST_SKIP  = 7;  // count whose following rising edge is dropped

// Negedge sampling for 5ns-precision edge detection
reg ref_neg = 0;
always @(negedge CLK100M) begin
    ref_neg <= CLK7M_RAW;
end

// Phase comparison — always locks at cnt=5 for symmetry
localparam LOCK_PHASE = 5;
wire ref_rising = ~ref_prev & CLK7M_RAW;
localparam AMBIG = 0;  // (5+5)%10 = 0
wire is_early = (phase_cnt < LOCK_PHASE - 1) && (phase_cnt != AMBIG);
wire is_late  = (phase_cnt > LOCK_PHASE + 1) && (phase_cnt != AMBIG);

// 5ns-refined correction using negedge sample
wire need_stall   = is_early  || (phase_cnt == LOCK_PHASE - 1 && ref_neg);
wire need_advance = is_late   || (phase_cnt == LOCK_PHASE + 1 && !ref_neg);

always @(posedge CLK100M) begin

    SPEED_D <= SPEED;
    CLK50M <= ~CLK50M;
    ref_prev <= CLK7M_RAW;

    // Free-running divide-by-PERIOD counter with adjustable output phase
    if (phase_cnt == PERIOD - 1) begin
        phase_cnt <= 0;
    end else begin
        phase_cnt <= phase_cnt + 1;
    end

    if (phase_cnt == RISE_AT)
        dpll_out <= 1;
    else if (phase_cnt == FALL_AT)
        dpll_out <= 0;

    // Phase correction on baseboard rising edge
    if (ref_rising) begin
        if (need_stall) begin
            phase_cnt <= phase_cnt;
        end else if (need_advance) begin
            // Skip one count — handle toggle-point safety
            if (phase_cnt == RISE_AT - 1 || (RISE_AT == 0 && phase_cnt == PERIOD - 1)) begin
                // Would skip rising toggle; force it
                phase_cnt <= (RISE_AT + 1 >= PERIOD) ? 0 : RISE_AT + 1;
                dpll_out <= 1;
            end else if (phase_cnt == RISE_AT) begin
                // At rising toggle; advance past it
                phase_cnt <= (RISE_AT + 2 >= PERIOD) ? (RISE_AT + 2 - PERIOD) : RISE_AT + 2;
            end else if (phase_cnt == FALL_AT - 1 || (FALL_AT == 0 && phase_cnt == PERIOD - 1)) begin
                // Would skip falling toggle; force it
                phase_cnt <= (FALL_AT + 1 >= PERIOD) ? 0 : FALL_AT + 1;
                dpll_out <= 0;
            end else if (phase_cnt == FALL_AT) begin
                // At falling toggle; advance past it
                phase_cnt <= (FALL_AT + 2 >= PERIOD) ? (FALL_AT + 2 - PERIOD) : FALL_AT + 2;
            end else if (phase_cnt == PERIOD - 2) begin
                phase_cnt <= 0;
            end else if (phase_cnt == PERIOD - 1) begin
                phase_cnt <= 1;
            end else begin
                phase_cnt <= phase_cnt + 2;
            end
        end
    end

    // CPU clock: glitch-free switch between 50MHz and DPLL 10MHz.
    // Only transition to DPLL when output already matches dpll_out,
    // preventing runt pulses at the switch point.
    if (SPEED_D) begin
        if (clk_locked) begin
            CLK50MI <= dpll_out;
        end else if (CLK50MI == dpll_out) begin
            CLK50MI <= dpll_out;
            clk_locked <= 1;
        end else begin
            CLK50MI <= ~CLK50MI;
        end
    end else begin
        // Fast clock, see FAST_PHASE / FAST_SKIP.
        CLK50MI <= (phase_cnt[0] ^ FAST_PHASE[0]) & (phase_cnt != FAST_SKIP);
        clk_locked <= 0;
    end

end

assign CLKCPU = CLK50MI;
assign CLK7M = dpll_out;
// High only while the CPU is actually being fed the DPLL 10MHz clock.
// CLK100M-domain register; safe to gate host-bus assertion logic with.
assign CPUSLOW = clk_locked;

endmodule
