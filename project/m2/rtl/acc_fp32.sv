// acc_fp32.sv
//
// Three modules used together by the systolic-array PE:
//
//   - add_fp32      combinational fp32 + fp32 -> fp32 adder
//   - acc_fp32      registered fp32 accumulator (wraps add_fp32)
//   - fp32_to_bf16  combinational fp32 -> bf16 rounder for drain
//
// One file because they are co-versioned: any precision tweak in the
// adder (rounding mode, subnormal handling) affects both acc_fp32 and
// fp32_to_bf16 in lockstep.
//
// fp32 = 1 sign bit + 8 exp bits (bias 127) + 23 mantissa bits.
//
// v1 limitations:
//   - subnormals on input flushed to zero (treats inputs with exp == 0
//     as +/- 0 regardless of mantissa)
//   - rounding mode for the add: round-toward-zero (truncate guard bits)
//   - rounding mode for fp32 -> bf16: round-toward-zero (truncate)
//   - underflow on output flushes to signed zero
//   - overflow on output saturates to signed infinity
//   - Inf / NaN on input do not get IEEE-correct propagation; the
//     testbench should avoid these for v1

// ====================================================================
// add_fp32 -- combinational fp32 + fp32 -> fp32
// ====================================================================
//
// Algorithm:
//   1) decompose both into sign / exp / mantissa, recover the implicit 1
//   2) pick the operand with larger magnitude as "big", the other "small"
//   3) right-shift small's aligned mantissa by (exp_big - exp_small)
//   4) add or subtract aligned mantissas based on whether signs match
//   5) normalize: if sum overflowed bit 27, shift right and bump exp;
//      otherwise count leading zeros and shift left, dropping exp
//   6) pack result; flush underflow, saturate overflow
//
// Aligned mantissa width is 27 bits = 24 (with implicit 1) + 3 guard.
// The 3 guard bits give us a little extra precision before the final
// truncation to 23 mantissa bits and don't blow up the area.

module add_fp32 (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] out
);

    // -- Field decomposition -------------------------------------------
    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [22:0] ma, mb;
    assign sa = a[31]; assign ea = a[30:23]; assign ma = a[22:0];
    assign sb = b[31]; assign eb = b[30:23]; assign mb = b[22:0];

    logic a_zero, b_zero;
    assign a_zero = (ea == 8'd0);
    assign b_zero = (eb == 8'd0);

    // -- Pick big / small by |a| vs |b| -------------------------------
    // Larger exponent wins; ties broken by larger mantissa. Including
    // the implicit-1 bit doesn't change the comparison since both have
    // the same implicit-1 weight.
    logic a_ge_b;
    assign a_ge_b = (ea > eb) || ((ea == eb) && (ma >= mb));

    logic        sign_big, sign_small;
    logic [7:0]  exp_big, exp_small;
    logic [23:0] mant_big_full, mant_small_full;

    always_comb begin
        if (a_ge_b) begin
            sign_big        = sa;
            exp_big         = ea;
            mant_big_full   = a_zero ? 24'd0 : {1'b1, ma};
            sign_small      = sb;
            exp_small       = eb;
            mant_small_full = b_zero ? 24'd0 : {1'b1, mb};
        end else begin
            sign_big        = sb;
            exp_big         = eb;
            mant_big_full   = b_zero ? 24'd0 : {1'b1, mb};
            sign_small      = sa;
            exp_small       = ea;
            mant_small_full = a_zero ? 24'd0 : {1'b1, ma};
        end
    end

    // -- Align small's mantissa ---------------------------------------
    // 27-bit aligned (24 + 3 guard). Cap shift at 27; anything beyond
    // shifts the small operand entirely out of range.
    logic [7:0]  exp_diff;
    logic [26:0] mant_big_align;
    logic [26:0] mant_small_align;

    assign exp_diff       = exp_big - exp_small;
    assign mant_big_align = {mant_big_full, 3'd0};

    always_comb begin
        if (exp_diff >= 8'd27)
            mant_small_align = 27'd0;
        else
            mant_small_align = ({mant_small_full, 3'd0}) >> exp_diff;
    end

    // -- Add or subtract ----------------------------------------------
    // 28-bit result so a same-sign add can carry into bit 27. Sign of
    // the result is always sign_big because |big| >= |small|.
    logic [27:0] mant_sum;
    logic        sign_out;

    always_comb begin
        if (sign_big == sign_small) begin
            mant_sum = {1'b0, mant_big_align} + {1'b0, mant_small_align};
        end else begin
            mant_sum = {1'b0, mant_big_align} - {1'b0, mant_small_align};
        end
        sign_out = sign_big;
    end

    // -- Leading-zero count over bits [26:0] of mant_sum --------------
    // Used to renormalize after a subtract that cancelled high bits.
    // Returns 27 when the result is exactly zero.
    logic [4:0] lz;
    always_comb begin
        if      (mant_sum[26]) lz = 5'd0;
        else if (mant_sum[25]) lz = 5'd1;
        else if (mant_sum[24]) lz = 5'd2;
        else if (mant_sum[23]) lz = 5'd3;
        else if (mant_sum[22]) lz = 5'd4;
        else if (mant_sum[21]) lz = 5'd5;
        else if (mant_sum[20]) lz = 5'd6;
        else if (mant_sum[19]) lz = 5'd7;
        else if (mant_sum[18]) lz = 5'd8;
        else if (mant_sum[17]) lz = 5'd9;
        else if (mant_sum[16]) lz = 5'd10;
        else if (mant_sum[15]) lz = 5'd11;
        else if (mant_sum[14]) lz = 5'd12;
        else if (mant_sum[13]) lz = 5'd13;
        else if (mant_sum[12]) lz = 5'd14;
        else if (mant_sum[11]) lz = 5'd15;
        else if (mant_sum[10]) lz = 5'd16;
        else if (mant_sum[9])  lz = 5'd17;
        else if (mant_sum[8])  lz = 5'd18;
        else if (mant_sum[7])  lz = 5'd19;
        else if (mant_sum[6])  lz = 5'd20;
        else if (mant_sum[5])  lz = 5'd21;
        else if (mant_sum[4])  lz = 5'd22;
        else if (mant_sum[3])  lz = 5'd23;
        else if (mant_sum[2])  lz = 5'd24;
        else if (mant_sum[1])  lz = 5'd25;
        else if (mant_sum[0])  lz = 5'd26;
        else                   lz = 5'd27;
    end

    // -- Normalize ----------------------------------------------------
    // After this block, mant_norm has the implicit-1 sitting at bit 26
    // (or zero if the sum was zero), and exp_norm is the result exp in
    // 9-bit signed-ish form (bit 8 set means underflow).
    logic [27:0] mant_norm;
    logic [8:0]  exp_norm;

    always_comb begin
        if (mant_sum[27]) begin
            // Same-sign carry into bit 27; shift right and bump exp.
            mant_norm = mant_sum >> 1;
            exp_norm  = {1'b0, exp_big} + 9'd1;
        end else if (lz == 5'd27) begin
            // Result is exactly zero.
            mant_norm = 28'd0;
            exp_norm  = 9'd0;
        end else begin
            // Renormalize after cancellation.
            mant_norm = mant_sum << lz;
            exp_norm  = {1'b0, exp_big} - {4'd0, lz};
        end
    end

    // -- Pack ---------------------------------------------------------
    // mant_norm[26] is the implicit 1 (not stored); mant_norm[25:3] are
    // the 23 explicit fp32 mantissa bits; mant_norm[2:0] are guard bits
    // we drop (round-toward-zero).
    logic result_is_zero;
    assign result_is_zero = (lz == 5'd27) && !mant_sum[27];

    always_comb begin
        if (result_is_zero) begin
            out = 32'd0;
        end else if (exp_norm[8]) begin
            // Underflow: top bit of 9-bit exp is set after subtract -> negative.
            out = {sign_out, 31'd0};
        end else if (exp_norm > 9'd254) begin
            // Saturate to signed infinity.
            out = {sign_out, 8'hFF, 23'd0};
        end else begin
            out = {sign_out, exp_norm[7:0], mant_norm[25:3]};
        end
    end

endmodule


// ====================================================================
// acc_fp32 -- registered fp32 accumulator
// ====================================================================
//
// Each clock edge:
//   if (rst || clr): out <= 0   (synchronous, active-high)
//   else:            out <= out + addend   (fp32 add)
//
// `clr` lets the upstream FSM zero the accumulator between tiles
// without dragging the global rst. Useful because the v1 FSM
// re-initialises every PE accumulator on the LOAD->COMPUTE transition.
//
// Ports:
//   clk      in   1    clock
//   rst      in   1    synchronous active-high reset
//   clr      in   1    synchronous clear (one-cycle pulse)
//   addend   in   32   fp32 value to add
//   out      out  32   fp32 running sum

module acc_fp32 (
    input  logic        clk,
    input  logic        rst,
    input  logic        clr,
    input  logic [31:0] addend,
    output logic [31:0] out
);

    logic [31:0] sum;

    add_fp32 u_add (
        .a   (out),
        .b   (addend),
        .out (sum)
    );

    always_ff @(posedge clk) begin
        if (rst || clr)
            out <= 32'd0;
        else
            out <= sum;
    end

endmodule


// ====================================================================
// fp32_to_bf16 -- combinational fp32 -> bf16 rounder
// ====================================================================
//
// bf16 is fp32 with the low 16 mantissa bits truncated. Round-toward-
// zero is just taking the upper half of the fp32 word; that's the v1
// rounder. Round-to-nearest-even would add a sticky-or-bit and an
// adjusted increment; deferred to a precision pass.
//
// Ports:
//   in    in   32   fp32 value
//   out   out  16   bf16 rounded value

module fp32_to_bf16 (
    input  logic [31:0] in,
    output logic [15:0] out
);
    assign out = in[31:16];
endmodule
