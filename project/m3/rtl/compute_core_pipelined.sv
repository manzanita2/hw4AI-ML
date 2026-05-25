// compute_core_pipelined
//
// M3 timing-target replacement for project/m2/rtl/compute_core.sv. Same
// FSM and dataflow; differences are:
//
//   1. Instantiates project/m3/rtl/pe_pipelined.sv (MAC_LATENCY = 8)
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
// Capture-cycle derivation (full proof inline; the m2 schedule does
// NOT generalize cleanly because m2 has chain-rate=1 but MAC-latency=2,
// whereas pe_pipelined deliberately matches act-chain-rate to MAC
// latency so the systolic alignment holds):
//
//   ACT_BEATS    = ceil(M / LANES)                    (AXIS beats to fill act_buf)
//   inj_i        = ACT_BEATS + i * MAC_LATENCY        (row i act injection)
//   ts[i][n]     = ACT_BEATS + (i + n + 1) * MAC_LATENCY
//   capture cycle for column n:
//       compute_cycle == ACT_BEATS + (M + n) * MAC_LATENCY
//   COMPUTE-exit at last capture (same cycle as the n=N-1 capture):
//       compute_cycle == ACT_BEATS + (M + N - 1) * MAC_LATENCY
//
// For M = N = 4, LANES = 16, MAC_LATENCY = 8: ACT_BEATS = 1, captures
// land at compute_cycle = 33, 41, 49, 57. COMPUTE-exit at 57, then DRAIN.
//
// For M = N = 48, LANES = 16, MAC_LATENCY = 8: ACT_BEATS = 3, captures
// land at compute_cycle = 779, 787, ... ; COMPUTE-exit at 803, then DRAIN.
//
// LOAD-broadcast staging (added after the 300 MHz post-CTS attempt at
// project/m3/synth/runs/RUN_2026-05-24_01-01-50/ pinned u_core.state[1]
// as the global startpoint of every top-12 worst path; that combinational
// fanout from the FSM register to all M*N PEs' clr_psum + wt_load decode
// took 8+ sky130 buffer hops of wire delay):
//
//   wt_load_reg[i][j] <= (state == LOAD) && (wt_count == i*N + j)
//   clr_psum_reg[i][j] <= (state == LOAD)
//   wt_data_ext_d     <= wt_data_ext
//
// Each PE consumes its own dedicated 1-bit flop, so synthesis can place
// these flops near their consumer instead of routing one combinational
// net to all M*N PEs. The LOAD-side schedule slips by exactly 1 cycle:
//
//   Old: PE[i][j] sampled wt_data on cycle i*N + j + 1 (during LOAD).
//   New: PE[i][j] samples wt_data_ext_d on cycle i*N + j + 2 (last load
//        for PE[M-1][N-1] now lands on COMPUTE cycle 0, the act_buf
//        latch cycle, which is many cycles before that PE's MAC actually
//        reads its weight at compute_cycle ~ 1 + i*MAC_LATENCY + 1).
//
// Activation-side schedule is untouched (act_buf latch + row_act_feed
// + result capture timing all unchanged from the pre-staging design).

module compute_core_pipelined #(
    parameter int DATA_W      = 16,
    parameter int ACC_W       = 32,
    parameter int OUT_W       = 16,

    parameter int M           = 48,
    parameter int N           = 48,

    parameter int LANES       = 16,

    // Total cycles from PE input to PE psum_reg becoming valid. Tightly
    // coupled to project/m3/rtl/pe_pipelined.sv's internal pipeline depth
    // (1 + MUL_STAGES + ADD_STAGES). With mul_bf16_p3 (3 stages) and
    // add_fp32_p4 (4 stages), MAC_LATENCY = 8 (Phase 11). Was 7 in iter 6
    // (mul_bf16_p2 + add_fp32_p4); was 6 in the depth-6 attempt.
    // Override only if the PE module itself is rebuilt with different
    // depths, and remember pe_pipelined.sv's localparam MUL_STAGES is a
    // separate manual contract (not parameter pass-through) -- keep the
    // two in sync by hand.
    parameter int MAC_LATENCY = 8
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
        COMPUTE = 2'd2,
        DRAIN   = 2'd3
    } state_t;

    state_t state, next_state;

    localparam int WT_CNT_W      = $clog2(M*N + 1);
    // AXIS carries LANES bf16 lanes per beat; M may exceed LANES (48x48
    // with LANES=16 needs 3 beats to fill act_buf before MAC starts).
    localparam int ACT_BEATS     = (M + LANES - 1) / LANES;
    // COMPUTE counts up to ACT_BEATS + (M + N - 1)*MAC_LATENCY inclusive
    // (the last result capture cycle); add slack so the compare doesn't
    // roll over at the boundary.
    localparam int COMPUTE_MAX   = ACT_BEATS + (M + N - 1) * MAC_LATENCY;
    localparam int COMPUTE_CNT_W = $clog2(COMPUTE_MAX + 2);
    localparam int DRAIN_CNT_W   = $clog2(N + 1);

    logic [WT_CNT_W-1:0]      wt_count;
    logic [COMPUTE_CNT_W-1:0] compute_cycle;
    logic [DRAIN_CNT_W-1:0]   drain_cycle;
    localparam int ACT_BEAT_CNT_W = (ACT_BEATS <= 1) ? 1 : $clog2(ACT_BEATS + 1);
    logic [ACT_BEAT_CNT_W-1:0] act_beat_cnt;
    logic                        act_load_done;

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
            COMPUTE: if (compute_cycle == COMPUTE_CNT_W'(COMPUTE_MAX))       next_state = DRAIN;
            DRAIN:   if (drain_cycle == DRAIN_CNT_W'(N - 1) && res_ready)    next_state = IDLE;
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

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            act_beat_cnt <= '0;
        else if (state != COMPUTE)
            act_beat_cnt <= '0;
        else if (act_valid && act_ready)
            act_beat_cnt <= act_beat_cnt + 1'b1;
    end

    assign act_load_done = (act_beat_cnt == ACT_BEAT_CNT_W'(ACT_BEATS));

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            drain_cycle <= '0;
        else if (state == DRAIN && res_ready)
            drain_cycle <= drain_cycle + 1'b1;
        else if (state != DRAIN)
            drain_cycle <= '0;
    end

    // ==================================================================
    // Activation buffer (filled one AXIS beat per successful handshake)
    // ==================================================================
    logic [DATA_W-1:0] act_buf [0:M-1];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int i = 0; i < M; i++)
                act_buf[i] <= '0;
        end else if (state == COMPUTE && act_valid && act_ready) begin
            for (int l = 0; l < LANES; l++) begin
                int idx;
                idx = act_beat_cnt * LANES + l;
                if (idx < M)
                    act_buf[idx] <= act_data[l*DATA_W +: DATA_W];
            end
        end
    end

    // ==================================================================
    // Activation feed (row-skewed by MAC_LATENCY)
    //
    // Row i sees x[i] exactly once during COMPUTE, at compute_cycle
    // == 1 + i * MAC_LATENCY. All other cycles see 0. With MAC_LATENCY
    // = 1 this collapses to the m2 schedule (compute_cycle == i + 1).
    // ==================================================================
    logic [DATA_W-1:0] row_act_feed [0:M-1];

    always_comb begin
        for (int i = 0; i < M; i++)
            row_act_feed[i] = '0;
        if (state == COMPUTE) begin
            for (int i = 0; i < M; i++) begin
                if (compute_cycle == COMPUTE_CNT_W'(ACT_BEATS + i * MAC_LATENCY))
                    row_act_feed[i] = act_buf[i];
            end
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
    // PE grid (M rows x N cols), pipelined
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
    // Result capture
    //
    // y[n] is valid in PE[M-1][n].psum_out from compute_cycle
    //   ts = 1 + (M + n) * MAC_LATENCY
    // We sample at edge end of compute_cycle == ts so result_buf[n]
    // holds y[n] from compute_cycle == ts + 1 onward.
    // ==================================================================
    logic [31:0] result_buf [0:N-1];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int n = 0; n < N; n++)
                result_buf[n] <= '0;
        end else if (state == COMPUTE) begin
            for (int n = 0; n < N; n++) begin
                if (compute_cycle == COMPUTE_CNT_W'(ACT_BEATS + (M + n) * MAC_LATENCY))
                    result_buf[n] <= pe_psum_out[M-1][n];
            end
        end
    end

    // ==================================================================
    // Drain serializer (unchanged)
    // ==================================================================
    logic [OUT_W-1:0] drain_word;

    fp32_to_bf16 u_drain (
        .in  (result_buf[drain_cycle]),
        .out (drain_word)
    );

    always_comb begin
        res_data = '0;
        if (state == DRAIN)
            res_data[OUT_W-1:0] = drain_word;
    end

    assign res_valid = (state == DRAIN);
    assign res_last  = (state == DRAIN) &&
                       (drain_cycle == DRAIN_CNT_W'(N - 1));

    // ==================================================================
    // Internal-API status / handshake
    //
    // act_ready: m3 always uses external weights, so LOAD does not
    // consume from act_data; assert during the first ACT_BEATS cycles of
    // COMPUTE to fill act_buf from the ingress FIFO (one AXIS beat per
    // cycle when the host has data ready).
    // ==================================================================
    assign act_ready   = (state == COMPUTE) && !act_load_done;

    assign status_busy = (state != IDLE);
    assign status_done = (state == DRAIN) &&
                         (drain_cycle == DRAIN_CNT_W'(N - 1)) &&
                         res_ready;

endmodule
