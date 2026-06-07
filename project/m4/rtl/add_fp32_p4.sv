// add_fp32_p4
//
// NOT INSTANTIATED in the M4 16x16 @ 100 MHz design -- both the PE
// accumulator and the result-stage adder use the shallower add_fp32_p2
// (MAC_LATENCY = 5, ADD_STAGES = 2). This 4-stage variant is kept in
// the tree for reference; it was the adder used during the deeper-
// pipeline 300 MHz timing-closure work (see ../README.md and
// ../../m3/synthesis_notes.md). config.json does not list this file.
//
// 4-stage pipelined fp32 + fp32 -> fp32 adder. Bit-exact equivalent of
// add_fp32 in project/m2/rtl/acc_fp32.sv (round-toward-zero, flush
// subnormals, sat-on-overflow). Replaces add_fp32_p3.sv after the
// post-CTS critical-path analysis on the 300 MHz / sky130 attempt
// revealed that the old stage-1 (decompose + a >= b + big/small mux +
// exp_diff + 27-bit variable-right-shift align) was the bottleneck:
// project/m3/synth/runs/RUN_2026-05-24_00-24-39/36-openroad-stamidpnr-1
// /max.rpt
//
// Stage split (path budget ~3.33 ns / stage on sky130):
//   Stage 1 (registered output):
//     - decompose: sa, sb, ea, eb, ma, mb
//     - zero detect (subnormal flush)
//     - a >= b (28-bit compare)
//     - big/small mux selection
//     - exp_diff = exp_big - exp_small
//   Stage 2 (registered output):
//     - mant_big_align = {mant_big_full, 3'd0}
//     - mant_small_align = ({mant_small_full, 3'd0}) >> exp_diff
//       (the 27-bit variable right-shifter -- the heavy combinational
//        block that broke 300 MHz at p3)
//   Stage 3 (registered output):
//     - same-sign add or different-sign subtract on 27-bit aligned mants
//     - 27-way leading-zero count
//   Stage 4 (registered output):
//     - normalize via left/right shift based on lz / mant_sum[27]
//     - exp_norm with under/overflow detection
//     - pack to fp32
//
// Pipeline depth: 4 (latency = 4 cycles). Throughput: 1 sum / cycle.
// Reset: synchronous active-high; clears all stage registers to 0.

module add_fp32_p4 (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] out
);

    // ==================================================================
    // Stage 1 combinational: decompose / a_ge_b / big-small / exp_diff
    // ==================================================================
    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [22:0] ma, mb;
    assign sa = a[31]; assign ea = a[30:23]; assign ma = a[22:0];
    assign sb = b[31]; assign eb = b[30:23]; assign mb = b[22:0];

    logic a_zero_c, b_zero_c;
    assign a_zero_c = (ea == 8'd0);
    assign b_zero_c = (eb == 8'd0);

    logic a_ge_b_c;
    assign a_ge_b_c = (ea > eb) || ((ea == eb) && (ma >= mb));

    logic        sign_big_c, sign_small_c;
    logic [7:0]  exp_big_c, exp_small_c;
    logic [23:0] mant_big_full_c, mant_small_full_c;

    always_comb begin
        if (a_ge_b_c) begin
            sign_big_c        = sa;
            exp_big_c         = ea;
            mant_big_full_c   = a_zero_c ? 24'd0 : {1'b1, ma};
            sign_small_c      = sb;
            exp_small_c       = eb;
            mant_small_full_c = b_zero_c ? 24'd0 : {1'b1, mb};
        end else begin
            sign_big_c        = sb;
            exp_big_c         = eb;
            mant_big_full_c   = b_zero_c ? 24'd0 : {1'b1, mb};
            sign_small_c      = sa;
            exp_small_c       = ea;
            mant_small_full_c = a_zero_c ? 24'd0 : {1'b1, ma};
        end
    end

    logic [7:0] exp_diff_c;
    assign exp_diff_c = exp_big_c - exp_small_c;

    // ==================================================================
    // Stage 1 registered
    // ==================================================================
    logic        s1_sign_big, s1_sign_small;
    logic [7:0]  s1_exp_big;
    logic [23:0] s1_mant_big_full;
    logic [23:0] s1_mant_small_full;
    logic [7:0]  s1_exp_diff;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            s1_sign_big        <= 1'b0;
            s1_sign_small      <= 1'b0;
            s1_exp_big         <= 8'd0;
            s1_mant_big_full   <= 24'd0;
            s1_mant_small_full <= 24'd0;
            s1_exp_diff        <= 8'd0;
        end else begin
            s1_sign_big        <= sign_big_c;
            s1_sign_small      <= sign_small_c;
            s1_exp_big         <= exp_big_c;
            s1_mant_big_full   <= mant_big_full_c;
            s1_mant_small_full <= mant_small_full_c;
            s1_exp_diff        <= exp_diff_c;
        end
    end

    // ==================================================================
    // Stage 2 combinational: align (variable right-shift)
    // ==================================================================
    logic [26:0] mant_big_align_c;
    logic [26:0] mant_small_align_c;

    assign mant_big_align_c = {s1_mant_big_full, 3'd0};

    always_comb begin
        if (s1_exp_diff >= 8'd27)
            mant_small_align_c = 27'd0;
        else
            mant_small_align_c = ({s1_mant_small_full, 3'd0}) >> s1_exp_diff;
    end

    // ==================================================================
    // Stage 2 registered
    // ==================================================================
    logic        s2_sign_big, s2_sign_small;
    logic [7:0]  s2_exp_big;
    logic [26:0] s2_mant_big_align;
    logic [26:0] s2_mant_small_align;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            s2_sign_big         <= 1'b0;
            s2_sign_small       <= 1'b0;
            s2_exp_big          <= 8'd0;
            s2_mant_big_align   <= 27'd0;
            s2_mant_small_align <= 27'd0;
        end else begin
            s2_sign_big         <= s1_sign_big;
            s2_sign_small       <= s1_sign_small;
            s2_exp_big          <= s1_exp_big;
            s2_mant_big_align   <= mant_big_align_c;
            s2_mant_small_align <= mant_small_align_c;
        end
    end

    // ==================================================================
    // Stage 3 combinational: signed add/sub + LZC
    // ==================================================================
    logic [27:0] mant_sum_c;
    logic        sign_out_c;

    always_comb begin
        if (s2_sign_big == s2_sign_small) begin
            mant_sum_c = {1'b0, s2_mant_big_align} + {1'b0, s2_mant_small_align};
        end else begin
            mant_sum_c = {1'b0, s2_mant_big_align} - {1'b0, s2_mant_small_align};
        end
        sign_out_c = s2_sign_big;
    end

    logic [4:0] lz_c;
    always_comb begin
        if      (mant_sum_c[26]) lz_c = 5'd0;
        else if (mant_sum_c[25]) lz_c = 5'd1;
        else if (mant_sum_c[24]) lz_c = 5'd2;
        else if (mant_sum_c[23]) lz_c = 5'd3;
        else if (mant_sum_c[22]) lz_c = 5'd4;
        else if (mant_sum_c[21]) lz_c = 5'd5;
        else if (mant_sum_c[20]) lz_c = 5'd6;
        else if (mant_sum_c[19]) lz_c = 5'd7;
        else if (mant_sum_c[18]) lz_c = 5'd8;
        else if (mant_sum_c[17]) lz_c = 5'd9;
        else if (mant_sum_c[16]) lz_c = 5'd10;
        else if (mant_sum_c[15]) lz_c = 5'd11;
        else if (mant_sum_c[14]) lz_c = 5'd12;
        else if (mant_sum_c[13]) lz_c = 5'd13;
        else if (mant_sum_c[12]) lz_c = 5'd14;
        else if (mant_sum_c[11]) lz_c = 5'd15;
        else if (mant_sum_c[10]) lz_c = 5'd16;
        else if (mant_sum_c[9])  lz_c = 5'd17;
        else if (mant_sum_c[8])  lz_c = 5'd18;
        else if (mant_sum_c[7])  lz_c = 5'd19;
        else if (mant_sum_c[6])  lz_c = 5'd20;
        else if (mant_sum_c[5])  lz_c = 5'd21;
        else if (mant_sum_c[4])  lz_c = 5'd22;
        else if (mant_sum_c[3])  lz_c = 5'd23;
        else if (mant_sum_c[2])  lz_c = 5'd24;
        else if (mant_sum_c[1])  lz_c = 5'd25;
        else if (mant_sum_c[0])  lz_c = 5'd26;
        else                     lz_c = 5'd27;
    end

    // ==================================================================
    // Stage 3 registered
    // ==================================================================
    logic        s3_sign_out;
    logic [7:0]  s3_exp_big;
    logic [27:0] s3_mant_sum;
    logic [4:0]  s3_lz;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            s3_sign_out <= 1'b0;
            s3_exp_big  <= 8'd0;
            s3_mant_sum <= 28'd0;
            s3_lz       <= 5'd0;
        end else begin
            s3_sign_out <= sign_out_c;
            s3_exp_big  <= s2_exp_big;
            s3_mant_sum <= mant_sum_c;
            s3_lz       <= lz_c;
        end
    end

    // ==================================================================
    // Stage 4 combinational: normalize + pack
    // ==================================================================
    logic [27:0] mant_norm_c;
    logic [8:0]  exp_norm_c;

    always_comb begin
        if (s3_mant_sum[27]) begin
            mant_norm_c = s3_mant_sum >> 1;
            exp_norm_c  = {1'b0, s3_exp_big} + 9'd1;
        end else if (s3_lz == 5'd27) begin
            mant_norm_c = 28'd0;
            exp_norm_c  = 9'd0;
        end else begin
            mant_norm_c = s3_mant_sum << s3_lz;
            exp_norm_c  = {1'b0, s3_exp_big} - {4'd0, s3_lz};
        end
    end

    logic result_is_zero_c;
    assign result_is_zero_c = (s3_lz == 5'd27) && !s3_mant_sum[27];

    logic [31:0] out_c;
    always_comb begin
        if (result_is_zero_c) begin
            out_c = 32'd0;
        end else if (exp_norm_c[8]) begin
            out_c = {s3_sign_out, 31'd0};
        end else if (exp_norm_c > 9'd254) begin
            out_c = {s3_sign_out, 8'hFF, 23'd0};
        end else begin
            out_c = {s3_sign_out, exp_norm_c[7:0], mant_norm_c[25:3]};
        end
    end

    // ==================================================================
    // Stage 4 registered
    // ==================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            out <= 32'd0;
        else
            out <= out_c;
    end

endmodule
