// mul_bf16_p2
//
// 2-stage pipelined bf16 * bf16 -> fp32 multiplier. Bit-exact equivalent
// of project/m2/rtl/mul_bf16.sv with the same flush-subnormals, no-NaN-
// propagation, sat-on-overflow semantics; just split across pipeline
// registers so the combinational path between flops fits in a 3.33 ns
// (300 MHz) budget on sky130.
//
// Why an m3-only file: the m2 module is left untouched per the m3
// scope decision in project/m3/scratchpad.md. m2 testbenches keep
// their bit-exact reference; m3 gets its own pipelined sibling.
//
// Stage split:
//   Stage 1 (registered output):
//     - decompose sign / exponent / mantissa
//     - zero detect (subnormal flush)
//     - 8x8 mantissa unsigned multiply (the heavy combinational chunk)
//   Stage 2 (registered output):
//     - normalize mant_prod into a 23-bit fp32 mantissa
//     - 10-bit exponent calc with under/overflow detection
//     - pack into 32-bit fp32 result
//
// Pipeline depth: 2 (latency from inputs to `out` is 2 cycles).
// Throughput: 1 product per cycle.
//
// Reset: synchronous active-high. Reset clears stage registers to 0
// so the first 2 outputs after reset are deterministic zeros.

module mul_bf16_p2 (
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
    logic [15:0] mant_prod_c;
    assign mant_a_full_c = {1'b1, ma_c};
    assign mant_b_full_c = {1'b1, mb_c};
    assign mant_prod_c   = mant_a_full_c * mant_b_full_c;

    // ==================================================================
    // Stage 1 registered
    // ==================================================================
    logic        s1_sign;
    logic        s1_a_zero, s1_b_zero;
    logic [7:0]  s1_ea, s1_eb;
    logic [15:0] s1_mant_prod;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            s1_sign      <= 1'b0;
            s1_a_zero    <= 1'b0;
            s1_b_zero    <= 1'b0;
            s1_ea        <= 8'd0;
            s1_eb        <= 8'd0;
            s1_mant_prod <= 16'd0;
        end else begin
            s1_sign      <= sign_c;
            s1_a_zero    <= a_zero_c;
            s1_b_zero    <= b_zero_c;
            s1_ea        <= ea_c;
            s1_eb        <= eb_c;
            s1_mant_prod <= mant_prod_c;
        end
    end

    // ==================================================================
    // Stage 2 combinational
    // ==================================================================
    logic        exp_adjust_c;
    logic [22:0] mant_norm_c;
    assign exp_adjust_c = s1_mant_prod[15];
    assign mant_norm_c  = s1_mant_prod[15] ? {s1_mant_prod[14:0], 8'd0}
                                            : {s1_mant_prod[13:0], 9'd0};

    logic [9:0] exp_calc_c;
    assign exp_calc_c = {2'b00, s1_ea} + {2'b00, s1_eb}
                      + {9'd0, exp_adjust_c} - 10'd127;

    logic [31:0] out_c;
    always_comb begin
        if (s1_a_zero || s1_b_zero) begin
            out_c = {s1_sign, 31'd0};
        end else if (exp_calc_c[9]) begin
            out_c = {s1_sign, 31'd0};
        end else if (exp_calc_c > 10'd254) begin
            out_c = {s1_sign, 8'hFF, 23'd0};
        end else begin
            out_c = {s1_sign, exp_calc_c[7:0], mant_norm_c};
        end
    end

    // ==================================================================
    // Stage 2 registered
    // ==================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            out <= 32'd0;
        else
            out <= out_c;
    end

endmodule
