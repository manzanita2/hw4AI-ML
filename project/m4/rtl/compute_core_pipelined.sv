// compute_core_pipelined
//
// M3 timing-target replacement for project/m2/rtl/compute_core.sv. Same
// FSM and dataflow; differences are:
//
//   1. Instantiates project/m3/rtl/pe_pipelined.sv (MAC_LATENCY = 5)
//      instead of project/m2/rtl/pe.sv (MAC_LATENCY = 1, the m2 default).
//   2. Drops the M3-only EXTERNAL_WT_SRC parameter mux. The m3 datapath
//      always feeds weights via wt_data_ext from project/m3/rtl/load_seq.
//      The m2 file's M2-vs-M3 backwards-compat conditional was only
//      needed to keep tb_compute_core.py passing on the m2 PE; that
//      file stays unchanged (project/m2/ is a frozen graded artifact).
//   3. Row-injection schedule and result-capture cycle are scaled by
//      MAC_LATENCY so the systolic alignment holds when each PE has L
//      cycles of internal pipeline (and L cycles of activation forward
//      delay) instead of 1.
//
// -------------------------------------------------------------------
// M4 streaming extension (PIX_BLOCK)
// -------------------------------------------------------------------
// The M3 core processed ONE activation column per COMPUTE: it paid the
// full M*N-cycle LOAD (load_seq replays weight_store into the PE array)
// plus the (M+N-1)*MAC_LATENCY pipeline fill to produce a single N-wide
// result vector. For a tiled convolution that reloads weights on every
// K-tile, that fixed overhead is amortized over exactly one pixel -- the
// reload pathology that pinned the design at ~0.2% of peak (see
// ../bench/benchmark.py and ../README.md).
//
// M4 streams a BLOCK of up to PIX_BLOCK pixel columns through the
// resident weights in a single COMPUTE. The PE array is UNCHANGED -- it
// is already a true weight-stationary systolic fabric (activations flow
// left->right one column-hop per MAC_LATENCY, psums accumulate down each
// column at the matched rate), so at steady state it absorbs one new
// pixel column per cycle and the bottom of each column emits one pixel's
// partial sum per cycle. Only the control + buffer depth changed:
//
//   - act_buf[M]        -> act_block[PIX_BLOCK][M]   (B columns resident)
//   - result_buf[N]     -> result_buf[PIX_BLOCK][N]  (B pixels' fp32 partials)
//   - the single-shot row feed / single capture cycle became a per-column
//     stream indexed off compute_cycle (one column injected per cycle).
//
// cfg_pix_count (1..PIX_BLOCK) is the runtime block length, so the host
// can issue a short final block for the P % PIX_BLOCK tail. With
// cfg_pix_count == 1 every schedule below collapses bit-exactly to the
// M3 single-column behavior (the streaming generalizations are written so
// the c == 0 case is the original expression), which is the regression
// firewall: all M3 cocotb tests must still pass.
//
// Capture-cycle derivation (full proof inline; the m2 schedule does
// NOT generalize cleanly because m2 has chain-rate=1 but MAC-latency=2,
// whereas pe_pipelined deliberately matches act-chain-rate to MAC
// latency so the systolic alignment holds). Let c = pixel-column index
// within the block (0..cfg_pix_count-1):
//
//   ACT_BEATS    = ceil(M / LANES)                    (AXIS beats per column)
//   inj_i(c)     = ACT_BEATS + c + i * MAC_LATENCY    (row i, column c injection)
//   column-n psum for pixel c valid at:
//       compute_cycle == ACT_BEATS + c + (M + n) * MAC_LATENCY
//   result_buf[c][n] written ADD_STAGES later (the cross-tile accumulate
//   adder, add_fp32_p2, sits between pe_psum_out[M-1][n] and result_buf):
//       compute_cycle == ACT_BEATS + c + (M + n) * MAC_LATENCY + ADD_STAGES
//   STREAM-exit at the last writeback (c = cfg_pix_count-1, n = N-1):
//       compute_cycle == ACT_BEATS + (cfg_pix_count-1)
//                        + (M + N - 1) * MAC_LATENCY + ADD_STAGES
//
// For M = N = 16, LANES = 16, MAC_LATENCY = 5, ADD_STAGES = 2,
// cfg_pix_count = 1: ACT_BEATS = 1, last psum at 1 + (16+15)*5 = 156, last
// result_buf write at 158 -- identical to the M3 COMPUTE_MAX. For
// cfg_pix_count = B the stream simply runs B-1 cycles longer.
//
// LOAD-broadcast staging (added after the 300 MHz post-CTS attempt at
// project/m3/synth/runs/RUN_2026-05-24_01-01-50/ pinned u_core.state[1]
// as the global startpoint of every top-12 worst path; that combinational
// fanout from the FSM register to all M*N PEs' clr_psum + wt_load decode
// took 8+ sky130 buffer hops of wire delay):
//
//   wt_load_reg[i][j] <= (state == LOAD) && (wt_count == i*N + j)
//   clr_psum_reg[i][j] <= (state == LOAD)
//
// Each PE consumes its own dedicated 1-bit flop, so synthesis can place
// these flops near their consumer instead of routing one combinational
// net to all M*N PEs. The LOAD-side schedule slips by exactly 1 cycle:
//
//   Old: PE[i][j] sampled wt_data on cycle i*N + j + 1 (during LOAD).
//   New: PE[i][j] samples wt_data_ext on cycle i*N + j + 2 (last load
//        for PE[M-1][N-1] now lands on STREAM cycle 0, the act-load
//        cycle, which is many cycles before that PE's MAC actually reads
//        its weight at compute_cycle ~ 1 + i*MAC_LATENCY + 1).
//
// Activation-side schedule is untouched in shape (act-load latch +
// row_act_feed + result capture timing all generalize the pre-staging
// design over the pixel-column index c).

module compute_core_pipelined #(
    parameter int DATA_W      = 16,
    parameter int ACC_W       = 32,
    parameter int OUT_W       = 16,

    parameter int M           = 48,
    parameter int N           = 48,

    parameter int LANES       = 16,

    // Total cycles from PE input to PE psum_reg becoming valid. Tightly
    // coupled to project/m3/rtl/pe_pipelined.sv's internal pipeline depth
    // (1 + MUL_STAGES + ADD_STAGES). With mul_bf16_p2 (2 stages) and
    // add_fp32_p2 (2 stages), MAC_LATENCY = 5 for the M4 16x16 @ 100 MHz
    // scope. (History: the pipeline peaked at 8 with mul_bf16_p3 +
    // add_fp32_p4 chasing 300 MHz, then was shallowed to 5 once the
    // 100 MHz target left slack -- see ../../m3/synthesis_notes.md.)
    // Override only if the PE module itself is rebuilt with different
    // depths, and remember pe_pipelined.sv's localparam MUL_STAGES is a
    // separate manual contract (not parameter pass-through) -- keep the
    // two in sync by hand.
    parameter int MAC_LATENCY = 5,

    // M4 streaming block depth: the maximum number of pixel columns
    // streamed through the resident weights per COMPUTE. Sizes act_block
    // (PIX_BLOCK*M bf16) and result_buf (PIX_BLOCK*N fp32). PIX_BLOCK = 1
    // recovers the exact M3 single-column core. Larger PIX_BLOCK amortizes
    // the M*N-cycle weight reload + pipeline fill over more pixels (see
    // header) at the cost of register area -- the dominant flop-growth
    // knob, deliberately a parameter so it can be dialed for P&R.
    parameter int PIX_BLOCK   = 32
) (
    input  logic                          clk,
    input  logic                          rst,

    input  logic [DATA_W*LANES-1:0]       act_data,
    input  logic                          act_valid,
    input  logic                          act_last,
    output logic                          act_ready,

    output logic [OUT_W*LANES-1:0]        res_data,
    output logic                          res_valid,
    output logic                          res_last,
    input  logic                          res_ready,

    input  logic                          cfg_start,

    // Cross-tile accumulation control (COMPUTE only; latched by
    // interface_module on CTRL.START, stable for the whole tile):
    //   cfg_accum = 0 -> overwrite result_buf with this tile's column
    //                    sums (first K-tile, or a standalone GEMM).
    //   cfg_accum = 1 -> add this tile's column sums into result_buf
    //                    (subsequent K-tiles of a tiled convolution).
    //   cfg_hold  = 0 -> drain the results after capture (last
    //                    K-tile / standalone GEMM).
    //   cfg_hold  = 1 -> skip DRAIN, return to IDLE holding the fp32
    //                    partials in result_buf for the next tile.
    input  logic                          cfg_accum,
    input  logic                          cfg_hold,

    // Streaming block length for THIS COMPUTE (1..PIX_BLOCK). Held stable
    // by the host (written before CTRL.START); clamped internally so an
    // out-of-range value can never index past the buffers.
    input  logic [15:0]                   cfg_pix_count,

    output logic                          status_busy,
    output logic                          status_done,

    input  logic [DATA_W-1:0]             wt_data_ext
);

    // ==================================================================
    // FSM
    // ==================================================================
    typedef enum logic [1:0] {
        IDLE    = 2'd0,
        LOAD    = 2'd1,
        COMPUTE = 2'd2,   // streams cfg_pix_count columns (M4) / 1 column (M3)
        DRAIN   = 2'd3
    } state_t;

    state_t state, next_state;

    localparam int WT_CNT_W      = $clog2(M*N + 1);
    // AXIS carries LANES bf16 lanes per beat; M may exceed LANES (48x48
    // with LANES=16 needs 3 beats to fill one column before MAC starts).
    localparam int ACT_BEATS     = (M + LANES - 1) / LANES;
    // Latency of the result-stage accumulate adder (add_fp32_p2 has 2
    // pipeline stages). Column n's psum is valid at compute_cycle ts[c][n];
    // the accumulate result lands in result_buf ADD_STAGES cycles later.
    // Keep in sync with project/m3/rtl/add_fp32_p2.sv's stage count.
    localparam int ADD_STAGES    = 2;

    // Pixel-block counter width (holds 0..PIX_BLOCK).
    localparam int PIX_CNT_W     = (PIX_BLOCK <= 1) ? 1 : $clog2(PIX_BLOCK + 1);

    // STREAM runs up to the LAST result-capture write. The worst case
    // (for sizing compute_cycle) is a full PIX_BLOCK block:
    //   ACT_BEATS + (PIX_BLOCK-1) + (M+N-1)*MAC_LATENCY + ADD_STAGES
    localparam int STREAM_MAX_MAX = ACT_BEATS + (PIX_BLOCK - 1)
                                    + (M + N - 1) * MAC_LATENCY + ADD_STAGES;
    localparam int COMPUTE_CNT_W  = $clog2(STREAM_MAX_MAX + 2);
    // Drain walks cfg_pix_count * N beats; column index is 0..N-1.
    localparam int DRAIN_COL_W    = (N <= 1) ? 1 : $clog2(N);

    logic [WT_CNT_W-1:0]      wt_count;
    logic [COMPUTE_CNT_W-1:0] compute_cycle;

    // Activation-load sub-phase counters (replace the M3 flat act_beat_cnt
    // so B columns load without a runtime divide): act_col selects the
    // column being filled, act_beat_in_col walks the ACT_BEATS beats of
    // that column.
    localparam int ACT_BEAT_CNT_W = (ACT_BEATS <= 1) ? 1 : $clog2(ACT_BEATS + 1);
    logic [PIX_CNT_W-1:0]      act_col;
    logic [ACT_BEAT_CNT_W-1:0] act_beat_in_col;
    logic                      act_load_done;

    // Drain counters (pixel-major, column-minor).
    logic [PIX_CNT_W-1:0]   drain_pix;
    logic [DRAIN_COL_W-1:0] drain_col;

    // ------------------------------------------------------------------
    // Clamp cfg_pix_count to [1, PIX_BLOCK] so a stray host value cannot
    // index past act_block / result_buf. 0 is treated as 1.
    // ------------------------------------------------------------------
    logic [PIX_CNT_W-1:0] eff_pix_count;
    always_comb begin
        if (cfg_pix_count == 16'd0)
            eff_pix_count = PIX_CNT_W'(1);
        else if (cfg_pix_count > 16'(PIX_BLOCK))
            eff_pix_count = PIX_CNT_W'(PIX_BLOCK);
        else
            eff_pix_count = cfg_pix_count[PIX_CNT_W-1:0];
    end

    // STREAM-exit cycle for this block (runtime; depends on eff_pix_count).
    logic [COMPUTE_CNT_W-1:0] stream_max;
    always_comb begin
        stream_max = COMPUTE_CNT_W'(ACT_BEATS + (int'(eff_pix_count) - 1)
                     + (M + N - 1) * MAC_LATENCY + ADD_STAGES);
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE:    if (cfg_start)                                          next_state = LOAD;
            LOAD:    if (wt_count == WT_CNT_W'(M*N - 1))                     next_state = COMPUTE;
            // cfg_hold: intermediate K-tile -> skip DRAIN, hold partials
            // in result_buf and return to IDLE for the next accumulating
            // tile. cfg_hold = 0: drain (last K-tile / standalone GEMM).
            COMPUTE: if (compute_cycle == stream_max) begin
                         if (cfg_hold) next_state = IDLE;
                         else          next_state = DRAIN;
                     end
            DRAIN:   if (drain_pix == PIX_CNT_W'(int'(eff_pix_count) - 1)
                         && drain_col == DRAIN_COL_W'(N - 1)
                         && res_ready)                                       next_state = IDLE;
            default:                                                         next_state = IDLE;
        endcase
    end

    // ==================================================================
    // Counters
    // ==================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            wt_count <= '0;
        else if (state == LOAD)
            wt_count <= wt_count + 1'b1;
        else
            wt_count <= '0;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            compute_cycle <= '0;
        else if (state == COMPUTE && act_load_done)
            compute_cycle <= compute_cycle + 1'b1;
        else if (state != COMPUTE)
            compute_cycle <= '0;
    end

    // Activation-load counters: walk ACT_BEATS beats per column, advancing
    // act_col after each full column, until all eff_pix_count columns are
    // resident. act_ready drops the moment act_load_done asserts, so the
    // counters never run past the block.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            act_col         <= '0;
            act_beat_in_col <= '0;
        end else if (state != COMPUTE) begin
            act_col         <= '0;
            act_beat_in_col <= '0;
        end else if (act_valid && act_ready) begin
            if (act_beat_in_col == ACT_BEAT_CNT_W'(ACT_BEATS - 1)) begin
                act_beat_in_col <= '0;
                act_col         <= act_col + 1'b1;
            end else begin
                act_beat_in_col <= act_beat_in_col + 1'b1;
            end
        end
    end

    assign act_load_done = (act_col == eff_pix_count);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            drain_pix <= '0;
            drain_col <= '0;
        end else if (state == DRAIN && res_ready) begin
            if (drain_col == DRAIN_COL_W'(N - 1)) begin
                drain_col <= '0;
                drain_pix <= drain_pix + 1'b1;
            end else begin
                drain_col <= drain_col + 1'b1;
            end
        end else if (state != DRAIN) begin
            drain_pix <= '0;
            drain_col <= '0;
        end
    end

    // ==================================================================
    // Activation block buffer (PIX_BLOCK columns x M rows)
    //
    // Filled one AXIS beat per successful handshake during the COMPUTE
    // load sub-phase: beat (act_col, act_beat_in_col) writes LANES bf16
    // lanes into column act_col at row offset act_beat_in_col*LANES. For
    // the 16x16 design (ACT_BEATS = 1) each beat is one full column.
    // ==================================================================
    logic [DATA_W-1:0] act_block [0:PIX_BLOCK-1][0:M-1];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int c = 0; c < PIX_BLOCK; c++)
                for (int i = 0; i < M; i++)
                    act_block[c][i] <= '0;
        end else if (state == COMPUTE && act_valid && act_ready) begin
            for (int l = 0; l < LANES; l++) begin
                int idx;
                idx = int'(act_beat_in_col) * LANES + l;
                if (idx < M)
                    act_block[act_col][idx] <= act_data[l*DATA_W +: DATA_W];
            end
        end
    end

    // ==================================================================
    // Activation feed (row-skewed by MAC_LATENCY, column-streamed)
    //
    // Row i sees pixel-column c at compute_cycle == ACT_BEATS + c +
    // i*MAC_LATENCY. Equivalently, at a given compute_cycle the column
    // index presented to row i is c_i = compute_cycle - ACT_BEATS -
    // i*MAC_LATENCY; when that is in [0, eff_pix_count) row i is fed
    // act_block[c_i][i], else 0. With eff_pix_count = 1 the only in-range
    // case is c_i == 0 at compute_cycle == ACT_BEATS + i*MAC_LATENCY --
    // the exact M3 single-column schedule.
    // ==================================================================
    logic [DATA_W-1:0] row_act_feed [0:M-1];

    always_comb begin
        for (int i = 0; i < M; i++)
            row_act_feed[i] = '0;
        // c_i is assigned unconditionally on every loop iteration (the COMPUTE
        // gate is folded into the read condition below), so the static loop
        // temp is always written before it is read. That prevents an inferred
        // latch -- the prior form assigned c_i only inside `if (state ==
        // COMPUTE)`, leaving it unwritten (hence latched) on the other path.
        // SystemVerilog `automatic` is avoided here because Icarus (the co-sim
        // simulator) does not support overriding the default variable lifetime
        // on procedural block temps.
        for (int i = 0; i < M; i++) begin
            int c_i;
            c_i = int'(compute_cycle) - ACT_BEATS - i * MAC_LATENCY;
            if (state == COMPUTE && c_i >= 0 && c_i < int'(eff_pix_count))
                row_act_feed[i] = act_block[c_i][i];
        end
    end

    // ==================================================================
    // LOAD-broadcast staging
    //
    // wt_load_reg[*][*], clr_psum_reg[*][*] are dedicated 1-bit flops
    // that decouple the FSM register from the M*N PE consumers (see
    // header comment for the post-CTS rationale). Each PE binds to its
    // own local flop instead of a many-leaf combinational fanout from
    // u_core.state[*].
    //
    // wt_load_reg[i][j] siblings each have a unique D (different
    // comparator constant) so they survive yosys / opt_merge as 16
    // distinct flops automatically. clr_psum_reg[i][j] siblings would
    // all share the same D = (state == LOAD), so without intervention
    // librelane's repeated opt_merge passes (synthesize.py:113-129)
    // collapse them back into one register and re-create the global
    // broadcast cone (observed in run RUN_2026-05-24_01-36-54). The
    // (* keep = "true" *) attribute on a SV `logic` declaration only
    // attaches to the wire, not the flop cell, and opt_merge consults
    // \keep on cells, so it does not help here either.
    //
    // The trick used below instead: include wt_load_reg[i][j] as a
    // disjunct in clr_psum_reg[i][j]'s D. By the LOAD/COMPUTE schedule,
    // wt_load_reg[i][j] can only be 1 when (state == LOAD) is also 1,
    // so "(state == LOAD) | wt_load_reg[i][j]" equals "(state == LOAD)"
    // on every cycle (cycle-by-cycle equivalence, easy to prove). But
    // the textual D-input expression is now unique per (i, j) and
    // opt_merge does syntactic matching, not SAT, so it cannot merge.
    // See synthesis_notes.md "Phase 4 + 5" for the discovery and the
    // post-fix critical-path walk.
    //
    // Phase 10 / iter 6 note: the wt_data_ext_d flop that used to live
    // here has been moved into weight_store as `rd_data_q` -- right
    // after the mem mux instead of right before the PE port. Net flop
    // count on the load_seq -> PE path is unchanged (1 flop either
    // way); the long combinational chain (cnt -> rd_addr -> ws.mem mux
    // -> ls_wt_data -> wt_data_ext -> wt_data_ext_d/D) is cut into two
    // halves with no module-boundary buffering on the critical half.
    // PE.wt_in is now driven directly from wt_data_ext.
    // ==================================================================
    logic              wt_load_reg  [0:M-1][0:N-1];
    logic              clr_psum_reg [0:M-1][0:N-1];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int i = 0; i < M; i++) begin
                for (int j = 0; j < N; j++) begin
                    wt_load_reg[i][j]  <= 1'b0;
                    clr_psum_reg[i][j] <= 1'b0;
                end
            end
        end else begin
            for (int i = 0; i < M; i++) begin
                for (int j = 0; j < N; j++) begin
                    wt_load_reg[i][j]  <= (state == LOAD) &&
                                          (wt_count == WT_CNT_W'(i*N + j));
                    clr_psum_reg[i][j] <= (state == LOAD) |
                                          wt_load_reg[i][j];
                end
            end
        end
    end

    // ==================================================================
    // PE grid (M rows x N cols), pipelined -- UNCHANGED from M3.
    // ==================================================================
    logic [DATA_W-1:0] pe_act_out  [0:M-1][0:N-1];
    logic [31:0]       pe_psum_out [0:M-1][0:N-1];

    genvar gi, gj;
    generate
        for (gi = 0; gi < M; gi++) begin: g_row
            for (gj = 0; gj < N; gj++) begin: g_col
                logic [DATA_W-1:0]    pe_act_in_ij;
                logic [31:0]          pe_psum_in_ij;

                if (gj == 0)
                    assign pe_act_in_ij  = row_act_feed[gi];
                else
                    assign pe_act_in_ij  = pe_act_out[gi][gj-1];

                if (gi == 0)
                    assign pe_psum_in_ij = 32'd0;
                else
                    assign pe_psum_in_ij = pe_psum_out[gi-1][gj];

                pe_pipelined u_pe (
                    .clk      (clk),
                    .rst      (rst),
                    .clr_psum (clr_psum_reg[gi][gj]),
                    .wt_load  (wt_load_reg[gi][gj]),
                    .wt_in    (wt_data_ext),
                    .act_in   (pe_act_in_ij),
                    .psum_in  (pe_psum_in_ij),
                    .act_out  (pe_act_out[gi][gj]),
                    .psum_out (pe_psum_out[gi][gj])
                );
            end
        end
    endgenerate

    // ==================================================================
    // Result capture + cross-tile accumulate (streamed over the block)
    //
    // The bottom PE of column n emits a STREAM of column sums, one pixel
    // per cycle: pe_psum_out[M-1][n] carries pixel c at
    //   compute_cycle == ACT_BEATS + c + (M + n)*MAC_LATENCY            (ts)
    // The per-column adder (add_fp32_p2, ADD_STAGES = 2) reads the matching
    // running partial and writes it back ADD_STAGES later:
    //
    //   c_rd(n) = compute_cycle - ACT_BEATS - (M+n)*MAC_LATENCY   (read idx)
    //   acc_a[n] = (cfg_accum && c_rd in [0,cnt)) ? result_buf[c_rd][n] : 0
    //   acc_out[n] = acc_a[n] + pe_psum_out[M-1][n]   (2-cycle pipeline)
    //   c_wr(n) = c_rd(n) - ADD_STAGES                           (write idx)
    //   result_buf[c_wr][n] <= acc_out[n]   when c_wr in [0,cnt)
    //
    // cfg_accum = 0 makes the add "0 + psum = psum" (overwrite, bit-exact
    // -- the zero operand contributes a zero mantissa, so the sum is the
    // other operand verbatim). cfg_accum = 1 sums this K-tile into the
    // resident fp32 partial for the SAME pixel -- true fp32 cross-tile
    // accumulation, bf16 rounding deferred to the draining tile.
    //
    // No read/write hazard on result_buf[c][n]: within one STREAM each
    // (c,n) is read exactly once (at ts) and written exactly once (at
    // ts+ADD_STAGES); consecutive cycles on a column touch consecutive c
    // (different addresses), so the per-column adder never reads and
    // writes the same entry, and the cfg_accum read always sees the prior
    // K-tile's value (this K-tile's write to that entry is ADD_STAGES
    // later). Across K-tiles the gap is the whole LOAD (M*N cycles) +
    // fill, so the prior partial is long settled. result_buf is reset-only
    // (NOT cleared on COMPUTE entry) so partials persist across K-tiles.
    // With eff_pix_count = 1 this is the M3 single-pixel capture verbatim
    // (c_rd == 0 at ts, c_wr == 0 at ts+ADD_STAGES).
    // ==================================================================
    logic [31:0] result_buf [0:PIX_BLOCK-1][0:N-1];
    logic [31:0] acc_a      [0:N-1];
    logic [31:0] acc_out    [0:N-1];

    genvar gn;
    generate
        for (gn = 0; gn < N; gn++) begin: g_acc
            always_comb begin
                int c_rd;
                c_rd = int'(compute_cycle) - ACT_BEATS - (M + gn) * MAC_LATENCY;
                if (cfg_accum && c_rd >= 0 && c_rd < int'(eff_pix_count))
                    acc_a[gn] = result_buf[c_rd][gn];
                else
                    acc_a[gn] = 32'd0;
            end

            add_fp32_p2 u_acc (
                .clk (clk),
                .rst (rst),
                .a   (acc_a[gn]),
                .b   (pe_psum_out[M-1][gn]),
                .out (acc_out[gn])
            );
        end
    endgenerate

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int c = 0; c < PIX_BLOCK; c++)
                for (int n = 0; n < N; n++)
                    result_buf[c][n] <= '0;
        end else if (state == COMPUTE) begin
            for (int n = 0; n < N; n++) begin
                int c_wr;
                c_wr = int'(compute_cycle) - ACT_BEATS
                       - (M + n) * MAC_LATENCY - ADD_STAGES;
                if (c_wr >= 0 && c_wr < int'(eff_pix_count))
                    result_buf[c_wr][n] <= acc_out[n];
            end
        end
    end

    // ==================================================================
    // Drain serializer: walk result_buf pixel-major, column-minor, one
    // bf16 result per accepted beat (eff_pix_count * N beats total). With
    // eff_pix_count = 1 this is the M3 N-beat drain verbatim.
    // ==================================================================
    logic [OUT_W-1:0] drain_word;

    fp32_to_bf16 u_drain (
        .in  (result_buf[drain_pix][drain_col]),
        .out (drain_word)
    );

    always_comb begin
        res_data = '0;
        if (state == DRAIN)
            res_data[OUT_W-1:0] = drain_word;
    end

    assign res_valid = (state == DRAIN);
    assign res_last  = (state == DRAIN) &&
                       (drain_pix == PIX_CNT_W'(int'(eff_pix_count) - 1)) &&
                       (drain_col == DRAIN_COL_W'(N - 1));

    // ==================================================================
    // Internal-API status / handshake
    //
    // act_ready: m3/m4 always use external weights, so LOAD does not
    // consume from act_data; assert through the COMPUTE load sub-phase to
    // fill act_block from the ingress FIFO (one AXIS beat per cycle when
    // the host has data ready), dropping once all eff_pix_count columns
    // are resident.
    // ==================================================================
    assign act_ready   = (state == COMPUTE) && !act_load_done;

    assign status_busy = (state != IDLE);
    assign status_done = (state == DRAIN) &&
                         (drain_pix == PIX_CNT_W'(int'(eff_pix_count) - 1)) &&
                         (drain_col == DRAIN_COL_W'(N - 1)) &&
                         res_ready;

endmodule
