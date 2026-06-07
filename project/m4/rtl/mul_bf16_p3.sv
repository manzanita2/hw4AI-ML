// mul_bf16_p3
//
// NOT INSTANTIATED in the M4 16x16 @ 100 MHz design -- the PE uses the
// shallower mul_bf16_p2 (MAC_LATENCY = 5). This 3-stage variant is kept
// in the tree for reference; it was the multiplier used during the
// deeper-pipeline 300 MHz timing-closure work (see ../README.md and
// ../../m3/synthesis_notes.md). config.json does not list this file.
//
// 3-stage pipelined bf16 * bf16 -> fp32 multiplier. Bit-exact replacement
// for project/m3/rtl/mul_bf16_p2.sv (and, transitively, the m2 reference
// project/m2/rtl/mul_bf16.sv): same flush-subnormals / no-NaN-propagation
// / saturate-on-overflow semantics; just split across one more pipeline
// register so the heavy 8x8 mantissa multiply itself fits in a 3.33 ns
// (300 MHz) sky130 budget.
//
// -------------------------------------------------------------------
// Why a 3rd stage exists at all
// -------------------------------------------------------------------
//
// Iter 6's post-resizer WNS path (see project/m3/synth/critical_path.md
// from RUN_2026-05-24_16-50-18) was ~ 14 sky130 cell levels of
// partial-product AND + reduce + sum/carry inside mul_bf16_p2 stage 1,
// from u_pe.act_reg[i]/Q -> u_pe.u_mul.s1_mant_prod[k]/D, slack
// -1.207 ns. The control / FSM / FIFO refactors had taken everything
// they could; what was left was the arithmetic-depth limit of an
// 8x8 -> 16-bit unsigned multiply on this PDK.
//
// The fix is a "B-half radix-4 split":
//
//   (a_hi << 4 + a_lo) * b
//     == (a_hi * b) << 4 + (a_lo * b)              [distributive law]
//
// Two 4 x 8 -> 12-bit sub-multiplies in parallel, registered, then a
// single 16-bit add with a 4-bit shift in the next stage. Each 4 x 8
// has roughly half the partial-product reduce depth of the original
// 8 x 8, and the final compress is now its own short stage.
//
// -------------------------------------------------------------------
// Stage split
// -------------------------------------------------------------------
//
//   Stage 1 (registered output):
//     - decompose sign / exponent / mantissa
//     - zero detect (subnormal flush)
//     - two 4x8 mantissa sub-multiplies in parallel:
//         prod_lo = mant_a[3:0] * mant_b   (12-bit)
//         prod_hi = mant_a[7:4] * mant_b   (12-bit)
//     - stage budget: ~3-4 sky130 cell levels (PP-gen + 1-level reduce
//       per half) on the heaviest path. Comfortably under 3.33 ns.
//
//   Stage 2 (registered output):  *** NEW vs mul_bf16_p2 ***
//     - combine the two halves: mant_prod = prod_lo + (prod_hi << 4),
//       a 16-bit CPA over a 12-bit operand and a shifted 12-bit operand
//     - stage budget: ~4-5 sky130 cell levels (a single CPA), well
//       inside 3.33 ns.
//
//   Stage 3 (registered output):  (was Stage 2 in mul_bf16_p2)
//     - normalize mant_prod into a 23-bit fp32 mantissa
//     - 10-bit exponent calc with under/overflow detection
//     - pack into 32-bit fp32 result
//
// -------------------------------------------------------------------
// Bit-exact equivalence to mul_bf16_p2
// -------------------------------------------------------------------
//
// (a_hi << 4 + a_lo) * b is exactly mant_a_full * mant_b (the m2/p2
// 8x8 multiply). The radix-4 split distributes over the multiply
// without loss because both operands are 8-bit unsigned and the
// product fits in 16 bits (max 255*255 = 65025 < 2^16). The 4-bit
// left-shift of a 12-bit prod_hi slots it cleanly into bits [15:4]
// of the 16-bit accumulator with no carry out. Cocotb's bit-exact
// reference is the m2 module; if any test changes its golden value
// vector when this module is wired in, the proof above is broken.
//
// -------------------------------------------------------------------
// Pipeline depth & latency
// -------------------------------------------------------------------
//
// Pipeline depth: 3 (latency from inputs to `out` is 3 cycles).
// Throughput:     1 product per cycle.
//
// pe_pipelined.sv must set MUL_STAGES = 3 so MAC_LATENCY = 1+3+4 = 8
// and PSUM_CHAIN_LEN = 4. compute_core_pipelined.sv's MAC_LATENCY
// parameter must also bump to 8 (it is a separate parameter, not
// hooked to pe_pipelined's localparam by parameter pass-through;
// keeping them in sync is a pre-existing manual contract).
//
// -------------------------------------------------------------------
// Reset
// -------------------------------------------------------------------
// Asynchronous active-high (sky130 m3 convention since Phase 8 -- see
// synthesis_notes.md). Reset clears all 3 stage registers to 0 so the
// first 3 outputs after reset are deterministic zeros.

module mul_bf16_p3 (
    input  logic        clk,
    input  logic        rst,
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [31:0] out
);

    // ==================================================================
    // Stage 1 combinational
    // ==================================================================
    logic        sa_c, sb_c;
    logic [7:0]  ea_c, eb_c;
    logic [6:0]  ma_c, mb_c;

    assign sa_c = a[15];
    assign ea_c = a[14:7];
    assign ma_c = a[6:0];
    assign sb_c = b[15];
    assign eb_c = b[14:7];
    assign mb_c = b[6:0];

    logic        a_zero_c, b_zero_c;
    assign a_zero_c = (ea_c == 8'd0);
    assign b_zero_c = (eb_c == 8'd0);

    logic        sign_c;
    assign sign_c = sa_c ^ sb_c;

    logic [7:0]  mant_a_full_c, mant_b_full_c;
    assign mant_a_full_c = {1'b1, ma_c};
    assign mant_b_full_c = {1'b1, mb_c};

    // B-half radix-4 split: two parallel 4 x 8 -> 12-bit sub-multiplies.
    // Each is roughly half the partial-product reduce depth of the
    // original 8 x 8, and they execute in parallel within the same
    // pipeline stage.
    logic [11:0] prod_lo_c;
    logic [11:0] prod_hi_c;
    assign prod_lo_c = mant_a_full_c[3:0] * mant_b_full_c;
    assign prod_hi_c = mant_a_full_c[7:4] * mant_b_full_c;

    // ==================================================================
    // Stage 1 registered
    // ==================================================================
    logic        s1_sign;
    logic        s1_a_zero, s1_b_zero;
    logic [7:0]  s1_ea, s1_eb;
    logic [11:0] s1_prod_lo, s1_prod_hi;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            s1_sign    <= 1'b0;
            s1_a_zero  <= 1'b0;
            s1_b_zero  <= 1'b0;
            s1_ea      <= 8'd0;
            s1_eb      <= 8'd0;
            s1_prod_lo <= 12'd0;
            s1_prod_hi <= 12'd0;
        end else begin
            s1_sign    <= sign_c;
            s1_a_zero  <= a_zero_c;
            s1_b_zero  <= b_zero_c;
            s1_ea      <= ea_c;
            s1_eb      <= eb_c;
            s1_prod_lo <= prod_lo_c;
            s1_prod_hi <= prod_hi_c;
        end
    end

    // ==================================================================
    // Stage 2 combinational  *** NEW vs mul_bf16_p2 ***
    //
    // Combine the two registered half-products into the full 16-bit
    // mantissa product. The 4-bit left-shift of prod_hi puts it in
    // bits [15:4] of the accumulator; prod_lo stays in [11:0].
    // ==================================================================
    logic [15:0] mant_prod_c;
    assign mant_prod_c = {4'd0, s1_prod_lo} + ({4'd0, s1_prod_hi} << 4);

    // ==================================================================
    // Stage 2 registered  *** NEW vs mul_bf16_p2 ***
    // ==================================================================
    logic        s2_sign;
    logic        s2_a_zero, s2_b_zero;
    logic [7:0]  s2_ea, s2_eb;
    logic [15:0] s2_mant_prod;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            s2_sign      <= 1'b0;
            s2_a_zero    <= 1'b0;
            s2_b_zero    <= 1'b0;
            s2_ea        <= 8'd0;
            s2_eb        <= 8'd0;
            s2_mant_prod <= 16'd0;
        end else begin
            s2_sign      <= s1_sign;
            s2_a_zero    <= s1_a_zero;
            s2_b_zero    <= s1_b_zero;
            s2_ea        <= s1_ea;
            s2_eb        <= s1_eb;
            s2_mant_prod <= mant_prod_c;
        end
    end

    // ==================================================================
    // Stage 3 combinational  (was Stage 2 in mul_bf16_p2)
    // ==================================================================
    logic        exp_adjust_c;
    logic [22:0] mant_norm_c;
    assign exp_adjust_c = s2_mant_prod[15];
    assign mant_norm_c  = s2_mant_prod[15] ? {s2_mant_prod[14:0], 8'd0}
                                            : {s2_mant_prod[13:0], 9'd0};

    logic [9:0] exp_calc_c;
    assign exp_calc_c = {2'b00, s2_ea} + {2'b00, s2_eb}
                      + {9'd0, exp_adjust_c} - 10'd127;

    logic [31:0] out_c;
    always_comb begin
        if (s2_a_zero || s2_b_zero) begin
            out_c = {s2_sign, 31'd0};
        end else if (exp_calc_c[9]) begin
            out_c = {s2_sign, 31'd0};
        end else if (exp_calc_c > 10'd254) begin
            out_c = {s2_sign, 8'hFF, 23'd0};
        end else begin
            out_c = {s2_sign, exp_calc_c[7:0], mant_norm_c};
        end
    end

    // ==================================================================
    // Stage 3 registered
    // ==================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            out <= 32'd0;
        else
            out <= out_c;
    end

endmodule
