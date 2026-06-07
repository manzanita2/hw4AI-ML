// fifo_sync
//
// Synchronous flop-array FIFO with ready/valid handshakes on both
// ports. Used by `top.sv` to decouple the AXI4-Stream slave from the
// compute-core ingress path (depth 4 skid) and the compute-core drain
// from the AXI4-Stream master (depth N to hold one tile of results).
//
// -------------------------------------------------------------------
// Why flop-based, not an SRAM macro
// -------------------------------------------------------------------
// M3/M4 target sky130 via OpenLane 2. At the current scope M = N = 16,
// the egress FIFO is N = 16 entries x ~257 bits (~4 kilobit) and the
// ingress FIFO is 16 x ~257 bits (~4 kilobit). Both are well under the
// area threshold where a real SRAM macro starts to pay off, and
// avoiding macro instantiation keeps the LibreLane / OpenLane flow
// self-contained (no OpenRAM step). For an M = N = 48 override this
// would want a 1RW SRAM macro instead -- documented in
// project/m3/synthesis_notes.md as an M4 follow-up.
//
// -------------------------------------------------------------------
// Ports
// -------------------------------------------------------------------
//   clk      in   1        clock
//   rst      in   1        synchronous active-high reset
//   wr_data  in   WIDTH    payload to push
//   wr_valid in   1        asserted when wr_data is valid
//   wr_ready out  1        FIFO has room (== !full)
//   rd_data  out  WIDTH    head-of-queue payload
//   rd_valid out  1        rd_data is valid (== !empty)
//   rd_ready in   1        downstream consumes rd_data this cycle
//
// Handshake: a beat is transferred on the cycle (wr_valid && wr_ready)
// for the write side, (rd_valid && rd_ready) for the read side.

module fifo_sync #(
    parameter int WIDTH = 256,
    parameter int DEPTH = 4
) (
    input  logic              clk,
    input  logic              rst,
    // Synchronous pointer reset (does not touch mem contents).
    input  logic              clr,

    input  logic [WIDTH-1:0]  wr_data,
    input  logic              wr_valid,
    output logic              wr_ready,

    output logic [WIDTH-1:0]  rd_data,
    output logic              rd_valid,
    input  logic              rd_ready
);

    // Pointer width: one extra MSB to disambiguate full from empty.
    localparam int PTR_W = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [PTR_W:0]   wr_ptr;
    logic [PTR_W:0]   rd_ptr;

    // full / empty derived from the wrap-bit comparison trick.
    logic full;
    logic empty;
    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[PTR_W] != rd_ptr[PTR_W]) &&
                   (wr_ptr[PTR_W-1:0] == rd_ptr[PTR_W-1:0]);

    assign wr_ready = ~full;
    assign rd_valid = ~empty;
    assign rd_data  = mem[rd_ptr[PTR_W-1:0]];

    // ------------------------------------------------------------------
    // Pointer block: rst-bearing. Maps to dfrtp_2 (async-reset DFF).
    // ------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else if (clr) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (wr_valid && wr_ready) wr_ptr <= wr_ptr + 1'b1;
            if (rd_valid && rd_ready) rd_ptr <= rd_ptr + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Mem block: clock-only, NO rst in sensitivity.
    //
    // Phase 9 of synthesis_notes.md showed that putting mem in the same
    // always_ff as the rst-bearing pointers forced yosys to synthesize
    // an OR4 + repeater + MUX2 hold-mux network on every mem flop's D
    // pin (to honor the @(posedge rst) sensitivity even though mem has
    // no reset assignment). That hold-mux network was iter-5's WNS
    // critical path: rst -> ~ 8 buffer hops -> or4_4 -> 5-stage repeater
    // chain -> mux2_1/S -> mem[i]/D, slack -1.500 ns at 3.333 ns target.
    //
    // Splitting mem into its own clock-only block deletes the entire
    // network: yosys generates plain dfxtp_2 cells with D = wr_data
    // through a single write-enable mux. mem's reset behavior is
    // unchanged (it was "hold previous value" before, it is "hold
    // previous value" now -- mem entries that haven't been written
    // remain x at startup, exactly matching the existing convention
    // and the SRAM-macro substitution path documented at line 64).
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (wr_valid && wr_ready)
            mem[wr_ptr[PTR_W-1:0]] <= wr_data;
    end

endmodule
