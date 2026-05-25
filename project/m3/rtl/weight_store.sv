// weight_store
//
// On-chip M*N-entry bf16 weight memory between the AXI4-Stream slave
// (when interface_module's cfg_mode == LOAD_WEIGHTS) and the
// compute_core PE grid (read sequentially by load_seq at the start of
// each COMPUTE tile).
//
// -------------------------------------------------------------------
// Why this block exists
// -------------------------------------------------------------------
// In M2 the host had to re-stream M*N bf16 weights on every cfg_start
// because compute_core consumed them straight off act_data[DATA_W-1:0]
// during its LOAD state. Adding a weight cache lets the host load
// weights once and run many compute tiles against them -- which is
// what real weight-stationary inference actually wants. The host
// distinguishes the two operations via the CTRL.MODE bit (see
// interface.sv).
//
// -------------------------------------------------------------------
// Geometry
// -------------------------------------------------------------------
// Storage is M*N bf16 entries arranged in a flat row-major array:
//   mem[i*N + j] = B[i][j]
// Matches the existing wt_count == i*N + j decode in
// project/m2/rtl/compute_core.sv line 275 so the load sequencer can
// drive PE wt_load with the same row-major schedule M2 already used.
//
// -------------------------------------------------------------------
// Write port (from ingress FIFO during LOAD_WEIGHTS mode)
// -------------------------------------------------------------------
// Each accepted AXIS beat carries `LANES` bf16 lanes packed into
// `WIDTH = DATA_W*LANES` bits. One beat fills `LANES` consecutive
// memory slots starting at slot index (beat_count * LANES).
//
// For the bring-up shape M = N = LANES = 4, beats_needed = 1: the host
// pushes one beat with tlast and the entire 16-entry weight matrix is
// resident.
//
// At M = N = 48 with LANES = 16, beats_needed = 144.
//
// `wr_full` (= "weights loaded") is a sticky output that latches when
// the final expected beat arrives with tlast asserted. It is wired
// straight into interface.sv's STATUS.WEIGHTS_LOADED bit.
//
// `wr_err` is a sticky output that latches if tlast arrives at the
// wrong beat (early or late) or if a partial run is detected. The host
// can poll it via STATUS.LOAD_ERR; clearing requires a CTRL.START
// pulse with mode = LOAD_WEIGHTS (which restarts the beat counter).
//
// -------------------------------------------------------------------
// Read port (to load_seq)
// -------------------------------------------------------------------
// Combinational read: presenting `rd_addr` on this cycle yields
// `rd_data` = mem[rd_addr] this cycle. load_seq holds rd_addr stable
// for the cycle compute_core's wt_count matches it, so the PE captures
// the correct weight on the next clock edge.
//
// -------------------------------------------------------------------
// Reset
// -------------------------------------------------------------------
// Synchronous active-high `rst` clears beat_count, wr_full, wr_err.
// Memory contents are NOT reset (treated as don't-care until the host
// loads them; matches typical SRAM macro behavior so the same module
// shape can later swap in an OpenRAM / sky130 1RW SRAM macro).

module weight_store #(
    parameter int DATA_W = 16,
    parameter int M      = 48,
    parameter int N      = 48,
    parameter int LANES  = 16,
    parameter int WIDTH  = DATA_W * LANES
) (
    input  logic                clk,
    input  logic                rst,
    // Synchronous clear pulse: top.sv asserts this on a CTRL.START
    // write with mode == LOAD_WEIGHTS so the host can reload weights
    // for a fresh kernel without first holding the global rst high.
    // Without this clr, wr_full is sticky and wr_ready stays low,
    // which silently backpressures any second weight stream.
    input  logic                clr,

    // -- write port (AXIS beat sourced from interface demux) --------
    input  logic [WIDTH-1:0]    wr_data,
    input  logic                wr_valid,
    input  logic                wr_last,
    output logic                wr_ready,
    output logic                wr_full,    // sticky: weights resident
    output logic                wr_err,     // sticky: tlast misalignment

    // -- read port (load_seq) ---------------------------------------
    input  logic [$clog2(M*N+1)-1:0] rd_addr,
    output logic [DATA_W-1:0]        rd_data
);

    localparam int DEPTH        = M * N;
    localparam int BEATS_NEEDED = (DEPTH + LANES - 1) / LANES;
    localparam int BEAT_CNT_W   = (BEATS_NEEDED <= 1) ? 1 :
                                  $clog2(BEATS_NEEDED + 1);

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    // ------------------------------------------------------------------
    // Beat counter + sticky status
    // ------------------------------------------------------------------
    logic [BEAT_CNT_W-1:0] beat_count;
    logic                  beat_accept;

    // We sink every beat the host offers (single-cycle write).
    // Backpressure isn't useful here: weight_store is faster than the
    // bus so wr_ready can stay 1 unless we already finished loading,
    // in which case extra beats become errors.
    assign wr_ready    = ~wr_full;
    assign beat_accept = wr_valid && wr_ready;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            beat_count <= '0;
            wr_full    <= 1'b0;
            wr_err     <= 1'b0;
        end else if (clr) begin
            beat_count <= '0;
            wr_full    <= 1'b0;
            wr_err     <= 1'b0;
        end else if (beat_accept) begin
            // Write `LANES` bf16 lanes into mem starting at
            // (beat_count * LANES). For BEATS_NEEDED == 1 this is just
            // mem[0..DEPTH-1] = wr_data sliced.
            for (int l = 0; l < LANES; l++) begin
                if (beat_count * LANES + l < DEPTH) begin
                    mem[beat_count * LANES + l]
                        <= wr_data[l*DATA_W +: DATA_W];
                end
            end

            if (beat_count == BEAT_CNT_W'(BEATS_NEEDED - 1)) begin
                if (wr_last) begin
                    wr_full <= 1'b1;
                end else begin
                    wr_err  <= 1'b1;  // expected tlast on final beat
                end
                beat_count <= '0;
            end else begin
                if (wr_last) begin
                    wr_err     <= 1'b1;  // tlast asserted too early
                    beat_count <= '0;
                end else begin
                    beat_count <= beat_count + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Registered read for load_seq.
    //
    // Phase 10: was `assign rd_data = mem[rd_addr]` (combinational). The
    // iter-5 violator class B path
    //   u_lseq.cnt[1] -> rd_addr -> ws.mem mux -> ls_wt_data
    //                 -> wt_data_ext -> wt_data_ext_d/D
    // crossed three module boundaries between cnt's flop Q and the
    // capturing flop D pin in compute_core, slack -1.333 ns. Iter 6
    // moves that capturing flop here (rd_data_q, immediately after the
    // mem mux) and removes the symmetric wt_data_ext_d flop in
    // compute_core. Net flop count on the load_seq -> PE path is
    // unchanged (1 flop either way); the long combinational chain is
    // cut into two halves, with no module-boundary wiring on the
    // critical half.
    //
    // No rst on rd_data_q: it follows the same lazy-mem convention as
    // mem itself (line 64 comment); compute_core gates the captured
    // weight on wt_load_reg, which is rst-aware, so any startup x at
    // rd_data_q is ignored until the first wt_load fires.
    // ------------------------------------------------------------------
    logic [DATA_W-1:0] rd_data_q;

    always_ff @(posedge clk) begin
        rd_data_q <= mem[rd_addr];
    end

    assign rd_data = rd_data_q;

endmodule
