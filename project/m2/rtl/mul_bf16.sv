// mul_bf16
//
// Combinational bf16 * bf16 -> fp32 multiplier. Used inside each
// systolic-array PE in compute_core.sv.
//
// -------------------------------------------------------------------
// Numeric format
// -------------------------------------------------------------------
//   bf16 = 1 sign bit + 8 exponent bits (bias 127) + 7 mantissa bits
//          (with an implicit leading 1 when exp != 0)
//   fp32 = 1 sign bit + 8 exponent bits (bias 127) + 23 mantissa bits
//
// Multiplying two bf16 numbers gives a product whose precision fits
// exactly in fp32: 7+7+2 = 16 mantissa bits before normalization, well
// inside fp32's 23-bit mantissa. So the output is the EXACT product
// (no rounding loss) for normal-range inputs.
//
// -------------------------------------------------------------------
// v1 limitations (documented; will be revisited in a precision pass)
// -------------------------------------------------------------------
//   - subnormals on input are flushed to signed zero (treats any input
//     with exp == 0 as zero, regardless of mantissa)
//   - underflow on output flushes to signed zero
//   - overflow on output saturates to signed infinity
//   - Inf/NaN on input do not get IEEE-correct propagation; testbench
//     should avoid these for v1
//
// -------------------------------------------------------------------
// Ports
// -------------------------------------------------------------------
// Name  Dir  Width  Purpose
// ----  ---  -----  -----------------------------------------------
// a     in   16     bf16 operand A
// b     in   16     bf16 operand B
// out   out  32     fp32 product (a * b, exact for normal inputs)
//
// Pure combinational; no clock, no reset.

module mul_bf16 (
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [31:0] out
);

    // -- Field decomposition -------------------------------------------
    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [6:0]  ma, mb;

    assign sa = a[15];
    assign ea = a[14:7];
    assign ma = a[6:0];
    assign sb = b[15];
    assign eb = b[14:7];
    assign mb = b[6:0];

    // -- Zero detection (also flushes subnormals) ---------------------
    logic a_zero, b_zero;
    assign a_zero = (ea == 8'd0);
    assign b_zero = (eb == 8'd0);

    // -- Sign of product ----------------------------------------------
    logic sign;
    assign sign = sa ^ sb;

    // -- Mantissa product (8x8 -> 16 bits) ----------------------------
    // Each operand's full mantissa is "1.<7-bit fraction>" -> 8 bits.
    // The product is in [1.0, 4.0), so its top two bits before the
    // radix point can be either "01" (product < 2) or "1?" (product >= 2).
    logic [7:0]  mant_a_full, mant_b_full;
    logic [15:0] mant_prod;
    assign mant_a_full = {1'b1, ma};
    assign mant_b_full = {1'b1, mb};
    assign mant_prod   = mant_a_full * mant_b_full;

    // -- Normalize ----------------------------------------------------
    // If mant_prod[15] == 1, product >= 2.0: implicit-1 lives at bit 15.
    //   fp32 mantissa = mant_prod[14:0] padded with 8 zeros = 23 bits.
    //   Exponent bumps by +1.
    // Else mant_prod[14] == 1 (always true for non-zero inputs since
    //   each mantissa has its implicit 1): implicit-1 lives at bit 14.
    //   fp32 mantissa = mant_prod[13:0] padded with 9 zeros = 23 bits.
    //   No exponent bump.
    logic        exp_adjust;
    logic [22:0] mant_norm;
    assign exp_adjust = mant_prod[15];
    assign mant_norm  = mant_prod[15] ? {mant_prod[14:0], 8'd0}
                                      : {mant_prod[13:0], 9'd0};

    // -- Exponent ------------------------------------------------------
    // Combine in 10-bit unsigned arithmetic so we can detect underflow
    // (top bit set after the subtract = result went "negative") and
    // overflow (result > 254). Bias of fp32 == bias of bf16 == 127, so
    // exp_calc = ea + eb + exp_adjust - 127.
    logic [9:0] exp_calc;
    assign exp_calc = {2'b00, ea} + {2'b00, eb}
                    + {9'd0, exp_adjust} - 10'd127;

    // -- Pack ----------------------------------------------------------
    always_comb begin
        if (a_zero || b_zero) begin
            // Either operand is zero -> signed zero out.
            out = {sign, 31'd0};
        end else if (exp_calc[9]) begin
            // exp_calc went "negative" -> underflow, flush to signed zero.
            out = {sign, 31'd0};
        end else if (exp_calc > 10'd254) begin
            // Overflow -> saturate to signed infinity.
            out = {sign, 8'hFF, 23'd0};
        end else begin
            out = {sign, exp_calc[7:0], mant_norm};
        end
    end

endmodule
