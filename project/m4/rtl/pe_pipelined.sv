// pe_pipelined
//
// Pipelined replacement for project/m2/rtl/pe.sv. Same port shape so it
// drops directly into project/m3/rtl/compute_core_pipelined.sv. Adds
// MAC_LATENCY = 5 cycles of pipeline so the bf16-mul + fp32-add chain
// closes the 10 ns (100 MHz) period on sky130 with margin. m2 PE is
// left untouched.
//
// -------------------------------------------------------------------
// Pipeline structure
// -------------------------------------------------------------------
//
//   act_in -|>act_reg-+-> mul_bf16_p2 (2 stages internal) -+
//                     |                                    v
//                     +-> act_chain[1..4] -|>act_out      add_fp32_p2 (2 stages internal) -|>psum_out
//                                                          ^
//   psum_in -|>psum_chain[0..2] (3 stages) ----------------+
//
// MAC_LATENCY = 1 (act_reg input flop) + 2 (mul stages) + 2 (add stages) = 5
//   - act_in @ cycle T -> act_reg @ T+1 -> mul_s1 @ T+2 -> mul_s2 = product @ T+3
//   - psum_in @ T -> psum_chain[2] @ T+3 (3-deep alignment delay)
//   - add_s1 fires at T+4 with (product @ T+3, psum_chain[2] @ T+3)
//   - add_s2 = psum_out @ T+5
//
// Pipeline-depth history (full ledger in ../../m3/synthesis_notes.md):
// the MAC was deepened across iters 1-7 chasing architecture.md's
// 300 MHz aspiration, peaking at MAC_LATENCY = 8 (mul_bf16_p3, a
// 3-stage B-half radix-4 multiplier, + add_fp32_p4, a 4-stage adder).
// For the M4 16x16 @ 100 MHz scope point the extra stages were not
// needed -- at a 10 ns target the pre-route STA already closed setup
// with margin -- so the pipeline was SHALLOWED back to MAC_LATENCY = 5
// (mul_bf16_p2, a 2-stage multiplier, + add_fp32_p2, a 2-stage adder).
// Fewer flops cut clock-tree load, routing congestion, and PnR
// wall-clock. The deeper p3/p4 files are kept in the tree (not
// instantiated here) for reference; see ../README.md.
//
// Activation forward chain (act_out): (MAC_LATENCY - 1) = 4 extra
// register stages so act_out is act_in delayed by MAC_LATENCY = 5
// cycles. This keeps act-chain rate = MAC latency, which is what
// preserves systolic alignment in compute_core_pipelined. (m2 PE has
// them both at 1 cycle/PE; we move both to 5 cycles/PE.)
//
// -------------------------------------------------------------------
// Reset / clear
// -------------------------------------------------------------------
// rst       : synchronous active-high. Clears weight, act_reg, act_chain,
//             mul / add pipeline regs.
// clr_psum  : synchronous one-cycle clear, asserted by compute_core during
//             LOAD. Clears the *entire* MAC pipeline (mul + add + psum_chain
//             alignment delays) so on COMPUTE entry there's no stale state
//             leaking from a previous tile. Weight register is preserved.
//
// -------------------------------------------------------------------
// Why both add_fp32_p2 AND mul_bf16_p2 take rst|clr_psum on their internal rst:
// each module has a 0-on-reset behavior on every internal pipe stage, so
// asserting rst|clr_psum for >= MAC_LATENCY cycles flushes the pipe. m3
// compute_core holds clr_psum for the full LOAD phase (M*N cycles, always
// >= 16 cycles), so a fresh COMPUTE always starts from zeros.

module pe_pipelined (
    input  logic        clk,
    input  logic        rst,
    input  logic        clr_psum,
    input  logic        wt_load,
    input  logic [15:0] wt_in,
    input  logic [15:0] act_in,
    input  logic [31:0] psum_in,
    output logic [15:0] act_out,
    output logic [31:0] psum_out
);

    // -------------------------------------------------------------------
    // Pipeline-depth localparams. Tightly coupled to mul_bf16_p2 (2 stages)
    // and add_fp32_p2 (2 stages); changing them here without changing the
    // sub-module pipeline depths will mis-align the systolic schedule.
    // -------------------------------------------------------------------
    localparam int MUL_STAGES   = 2;
    localparam int ADD_STAGES   = 2;
    localparam int MAC_LATENCY  = 1 + MUL_STAGES + ADD_STAGES; // = 5

    // act_chain has (MAC_LATENCY - 1) extra register stages after act_reg
    // so act_out is act_in delayed by MAC_LATENCY cycles total.
    localparam int ACT_CHAIN_LEN = MAC_LATENCY - 1; // = 4

    // psum_in alignment delay = MUL_STAGES + 1 stages (1 for act_reg input
    // flop, MUL_STAGES for the multiplier pipe). After the chain, psum is
    // available at the same edge as the multiplier's product.
    localparam int PSUM_CHAIN_LEN = MUL_STAGES + 1; // = 3

    // -------------------------------------------------------------------
    // Weight latch (unchanged from m2 pe.sv semantics)
    // -------------------------------------------------------------------
    logic [15:0] weight;

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            weight <= 16'd0;
        else if (wt_load)
            weight <= wt_in;
    end

    // -------------------------------------------------------------------
    // Activation chain: act_reg + (ACT_CHAIN_LEN) extra stages -> act_out.
    // act_reg is what feeds the multiplier; act_out is the L-cycle-delayed
    // copy that drives the next column's PE.
    // -------------------------------------------------------------------
    logic [15:0] act_reg;
    logic [15:0] act_chain [0:ACT_CHAIN_LEN-1];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            act_reg <= 16'd0;
            for (int i = 0; i < ACT_CHAIN_LEN; i++)
                act_chain[i] <= 16'd0;
        end else begin
            act_reg <= act_in;
            act_chain[0] <= act_reg;
            for (int i = 1; i < ACT_CHAIN_LEN; i++)
                act_chain[i] <= act_chain[i-1];
        end
    end

    assign act_out = act_chain[ACT_CHAIN_LEN-1];

    // -------------------------------------------------------------------
    // Multiplier (2-stage pipelined, 8x8 mantissa multiply). Inputs sample
    // on edge T+1 from act_reg @ T; product registered at edge T+3.
    // Reset = rst | clr_psum so a LOAD-phase clear flushes the pipeline.
    // -------------------------------------------------------------------
    logic [31:0] product;

    mul_bf16_p2 u_mul (
        .clk (clk),
        .rst (rst | clr_psum),
        .a   (act_reg),
        .b   (weight),
        .out (product)
    );

    // -------------------------------------------------------------------
    // Psum_in alignment delay: 3 register stages so psum_chain[2] @ T+3 =
    // psum_in @ T, time-matched to product @ T+3.
    // -------------------------------------------------------------------
    logic [31:0] psum_chain [0:PSUM_CHAIN_LEN-1];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int i = 0; i < PSUM_CHAIN_LEN; i++)
                psum_chain[i] <= 32'd0;
        end else if (clr_psum) begin
            for (int i = 0; i < PSUM_CHAIN_LEN; i++)
                psum_chain[i] <= 32'd0;
        end else begin
            psum_chain[0] <= psum_in;
            for (int i = 1; i < PSUM_CHAIN_LEN; i++)
                psum_chain[i] <= psum_chain[i-1];
        end
    end

    logic [31:0] psum_in_aligned;
    assign psum_in_aligned = psum_chain[PSUM_CHAIN_LEN-1];

    // -------------------------------------------------------------------
    // Adder (2-stage pipelined). Output is the registered psum that drives
    // psum_out (= the PE's "psum_reg" in m2 terminology). add_fp32_p2 has
    // a registered output, so no extra flop is needed at the boundary.
    // -------------------------------------------------------------------
    logic [31:0] sum_out;

    add_fp32_p2 u_add (
        .clk (clk),
        .rst (rst | clr_psum),
        .a   (product),
        .b   (psum_in_aligned),
        .out (sum_out)
    );

    assign psum_out = sum_out;

endmodule
