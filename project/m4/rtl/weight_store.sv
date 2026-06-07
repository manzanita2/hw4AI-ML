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
// For the current scope M = N = LANES = 16, beats_needed = M*N / LANES
// = 256 / 16 = 16: the host pushes 16 beats (the last with tlast) and
// the entire 256-entry weight matrix is resident.
//
// At the aspirational M = N = 48 with LANES = 16, beats_needed = 144.
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
    //
    // Row-banked 2D layout: mem[i][j] holds the linear entry i*N + j (the
    // same row-major mapping as the old flat mem[i*N+j]). Banking by row
    // lets the sequential read decompose into M independent N:1 muxes
    // (one per bank) instead of one global M*N:1 mux -- see the read
    // section below for why that matters for routing.
    // ------------------------------------------------------------------
    localparam int BANK_SEL_W = (M <= 1) ? 1 : $clog2(M);
    localparam int BANK_OFF_W = (N <= 1) ? 1 : $clog2(N);

    logic [DATA_W-1:0] mem [0:M-1][0:N-1];

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
                int s;
                s = beat_count * LANES + l;
                if (s < DEPTH) begin
                    mem[s / N][s % N] <= wr_data[l*DATA_W +: DATA_W];
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
    // Registered, row-banked read for load_seq.
    //
    // Phase 10: was `assign rd_data = mem[rd_addr]` (combinational). The
    // iter-5 violator class B path
    //   u_lseq.cnt[1] -> rd_addr -> ws.mem mux -> ls_wt_data
    //                 -> wt_data_ext -> wt_data_ext_d/D
    // crossed three module boundaries between cnt's flop Q and the
    // capturing flop D pin in compute_core, slack -1.333 ns. Iter 6
    // moved that capturing flop here (immediately after the mem mux) and
    // removed the symmetric wt_data_ext_d flop in compute_core.
    //
    // Routing pass: that single registered read was `rd_data_q <=
    // mem[rd_addr]`, a flat M*N:1 mux whose fan-in pulled every entry to
    // one point -- the `u_wstore.mem` net that bombed global routing /
    // antenna repair. It is now split into M per-bank N:1 reads, each
    // registered into bank_q[b], plus a small final M:1 mux selected by
    // the (registered) bank index i_q. Read latency is unchanged at 1
    // cycle: bank_q[b] and i_q both register the SAME rd_addr decode, so
    //   rd_data = bank_q[i_q] = mem[i_prev][j_prev] = mem[rd_addr_prev]
    // -- bit-identical to the old flat read. The per-bank register is
    // what forces synthesis to keep the banks as M local muxes (the
    // placer clusters each around its bank_q[b] flop) instead of
    // flattening back into one global cone.
    //
    // No rst on bank_q / i_q: same lazy-mem convention as mem itself
    // (line 64 comment); compute_core gates the captured weight on
    // wt_load_reg, which is rst-aware, so any startup x is ignored until
    // the first wt_load fires.
    // ------------------------------------------------------------------
    logic [BANK_SEL_W-1:0] rd_bank;
    logic [BANK_OFF_W-1:0] rd_off;
    assign rd_bank = BANK_SEL_W'(rd_addr / N);
    assign rd_off  = BANK_OFF_W'(rd_addr % N);

    logic [DATA_W-1:0]     bank_q [0:M-1];
    logic [BANK_SEL_W-1:0] i_q;

    always_ff @(posedge clk) begin
        for (int b = 0; b < M; b++)
            bank_q[b] <= mem[b][rd_off];
        i_q <= rd_bank;
    end

    assign rd_data = bank_q[i_q];

endmodule
