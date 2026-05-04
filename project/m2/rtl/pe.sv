// pe
//
// One processing element of the weight-stationary systolic array.
//
// Each PE:
//   - latches one bf16 weight at LOAD time and holds it for the tile
//   - registers its activation input each cycle and forwards the
//     registered copy to the PE on its right (act_reg -> act_out)
//   - computes the bf16 product (act_reg * weight) and adds it to the
//     fp32 partial sum coming from the PE above (psum_in), registering
//     the result on its way down to the PE below (psum_reg -> psum_out)
//
// This is "Design B" weight-stationary: there is no per-PE running
// accumulator. The partial sum FLOWS through the column, accumulating
// one term per row. The bottom-row PE's psum_reg holds the final dot
// product for one cycle (then gets clobbered as activations stop).
// compute_core.sv captures into result_buf at exactly the right cycle.
//
// Pipeline depth per PE: 1 cycle (act_in -> act_out via act_reg, and
// psum_in -> psum_out via psum_reg).
//
// -------------------------------------------------------------------
// Clock / reset
// -------------------------------------------------------------------
// Single clock domain (clk). Synchronous active-high reset (rst)
// clears weight, act_reg, psum_reg. Synchronous clr_psum clears
// psum_reg only (used by the FSM during LOAD to ensure entry to
// COMPUTE starts from psum = 0 without disturbing the latched weight).
//
// -------------------------------------------------------------------
// Ports
// -------------------------------------------------------------------
// Name      Dir   Width   Purpose
// --------  ----  ------  ----------------------------------------------
// clk       in    1       clock
// rst       in    1       synchronous active-high reset
// clr_psum  in    1       synchronous clear of psum_reg (keeps weight)
// wt_load   in    1       this cycle, latch wt_in into the weight reg
// wt_in     in    16      bf16 weight value to latch
// act_in    in    16      bf16 activation entering from the left
// psum_in   in    32      fp32 partial sum entering from above
// act_out   out   16      registered copy of act_in (1-cycle latency)
// psum_out  out   32      registered psum_in + (act_reg * weight)

module pe (
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

    // -- Per-PE state --------------------------------------------------
    logic [15:0] weight;
    logic [15:0] act_reg;
    logic [31:0] psum_reg;

    // -- Combinational product: act_reg (registered) * weight ---------
    // act_reg is the value sampled on the previous edge, so the product
    // here is the product for THIS cycle. mul_bf16 is bf16 -> fp32, so
    // no precision loss before the accumulation step.
    logic [31:0] product;
    mul_bf16 u_mul (
        .a   (act_reg),
        .b   (weight),
        .out (product)
    );

    // -- Combinational fp32 add: psum_in (from PE above) + product ----
    logic [31:0] psum_sum;
    add_fp32 u_add (
        .a   (psum_in),
        .b   (product),
        .out (psum_sum)
    );

    // -- Sequential: register weight, act, psum -----------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            weight   <= 16'd0;
            act_reg  <= 16'd0;
            psum_reg <= 32'd0;
        end else begin
            // weight only changes when wt_load is asserted; otherwise it
            // is stationary for the rest of the tile.
            if (wt_load)
                weight <= wt_in;

            // act_reg always tracks act_in with one cycle of delay.
            act_reg <= act_in;

            // psum_reg latches the new partial sum unless clr_psum is
            // high (reset to 0 entering COMPUTE from LOAD).
            if (clr_psum)
                psum_reg <= 32'd0;
            else
                psum_reg <= psum_sum;
        end
    end

    assign act_out  = act_reg;
    assign psum_out = psum_reg;

endmodule
