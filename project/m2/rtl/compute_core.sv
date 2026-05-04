// compute_core
//
// Compute-fabric top for the systolic-array core that targets
// `aten::mkldnn_convolution` in RAFT. Sibling top to interface.sv:
// owns the FSM, the M x N weight-stationary PE grid, the activation
// feeder, and the result drain. Has NO bus ports -- talks only the
// simplified internal API exposed by interface.sv.
//
// -------------------------------------------------------------------
// Clock domain
// -------------------------------------------------------------------
// Single clock domain, named `clk`. Target operating frequency
// 300 MHz (per project/architecture.md). No clock-domain crossings
// inside this module; all sequential logic samples on `posedge clk`.
//
// -------------------------------------------------------------------
// Reset
// -------------------------------------------------------------------
// Synchronous, active-high, named `rst`. Sampled on `posedge clk` at
// the head of every `always_ff` block. When asserted: FSM returns to
// IDLE, all per-PE accumulators clear to zero, all internal-API
// outputs drop to their idle values. No asynchronous resets anywhere.
//
// -------------------------------------------------------------------
// Ports
// -------------------------------------------------------------------
// Name            Dir   Width            Purpose
// --------------  ----  ---------------- ---------------------------------
// clk             in    1                clock, single domain, 300 MHz target
// rst             in    1                synchronous active-high reset
// act_data        in    DATA_W*LANES     activation/weight stream payload
//                                        (LOAD: low DATA_W bits = next weight;
//                                         COMPUTE: low M*DATA_W bits = one
//                                         element per array row, in row order)
// act_valid       in    1                act_data is valid this cycle
// act_last        in    1                last beat of an activation tile
// act_ready       out   1                compute_core can consume act_data
//                                        this cycle (high during LOAD and
//                                        the first cycle of COMPUTE)
// res_data        out   OUT_W*LANES      result stream payload (low OUT_W
//                                        bits = one drained column per cycle;
//                                        upper lanes = 0 in v1)
// res_valid       out   1                res_data is valid this cycle
// res_last        out   1                final result beat for this tile
// res_ready       in    1                downstream can accept res_data
// cfg_start       in    1                pulse (>= 1 cycle) to begin
//                                        LOAD -> COMPUTE -> DRAIN sequence
// status_busy     out   1                FSM is not in IDLE
// status_done     out   1                pulse for one cycle when DRAIN
//                                        finishes and FSM returns to IDLE
//
// -------------------------------------------------------------------
// Decisions captured in project/architecture.md
// -------------------------------------------------------------------
//   * datapath:    bfloat16 multiply, fp32 accumulate, bfloat16 output
//   * fabric:      M x N weight-stationary systolic array
//                  (architecture.md plans 48x48; v1 defaults M=N=4 per
//                  the line 222 prototyping recommendation)
//   * mapping:     im2col -> GEMM (im2col staging in interface.sv,
//                  not in compute_core)
//   * v1 op:       single fixed-shape vector-matrix product
//                  y[N] = x[K] * B[K][N] with K = M = N = 4. Multi-tile
//                  GEMM and arbitrary K-tiling deferred.
//
// -------------------------------------------------------------------
// Synthesizability constraints (per codefest 4 conventions)
// -------------------------------------------------------------------
//   - synchronous, active-high reset (see Reset section above)
//   - no `initial` blocks, no `$display`, no `#` delays
//   - sequential logic in `always_ff`, combinational in `always_comb`
//   - parameterized widths so the same RTL can shrink for prototyping
//     and grow to full 48 x 48 by parameter override

module compute_core #(
    // -- datapath widths ------------------------------------------------
    parameter int DATA_W      = 16,    // bfloat16 operand width
    parameter int ACC_W       = 32,    // fp32 accumulator width
    parameter int OUT_W       = 16,    // bfloat16 output width

    // -- systolic array shape ------------------------------------------
    // v1 defaults to 4x4 per architecture.md line 222. Bump to 48 for
    // the headline 1.024 TFLOP/s target. K (the reduction dimension)
    // equals M for this dataflow; v1 supports a single K-tile per call.
    parameter int M           = 4,     // array rows / K (reduction)
    parameter int N           = 4,     // array cols / output cols

    // -- internal-API lane count --------------------------------------
    // Must match the interface.sv instance these wires connect to at
    // the future top-level wrapper. Default = 16 lanes of bf16 = 256 b
    // (matches AXIS_DATA_W / DATA_W in interface.sv).
    parameter int LANES       = 16
) (
    // -- clock / reset --------------------------------------------------
    input  logic                          clk,
    input  logic                          rst,

    // -- internal API from interface.sv -------------------------------
    //    activation/weight stream in (handshake-stripped)
    input  logic [DATA_W*LANES-1:0]       act_data,
    input  logic                          act_valid,
    input  logic                          act_last,
    output logic                          act_ready,
    //    result stream out
    output logic [OUT_W*LANES-1:0]        res_data,
    output logic                          res_valid,
    output logic                          res_last,
    input  logic                          res_ready,
    //    decoded config / status
    input  logic                          cfg_start,
    output logic                          status_busy,
    output logic                          status_done
);

    // ==================================================================
    // FSM
    // ==================================================================
    //
    // Per-tile sequence:
    //   IDLE     -> wait for cfg_start
    //   LOAD     -> latch M*N weights, one per cycle, from act_data[15:0]
    //   COMPUTE  -> latch M activations from act_data, then row-skew them
    //               into the array. Per-column captures of the bottom-row
    //               psum into result_buf as each y[n] settles.
    //   DRAIN    -> serialize result_buf onto res_data, one bf16 per cycle
    //
    // Cycle accounting (with M = N = K):
    //   LOAD    : M*N cycles
    //   COMPUTE : 1 (act-latch) + M (inject) + (N-1) (pipeline drain to
    //             last column) + 1 (last-column capture) = M + N + 1 cycles
    //             -> compute_cycle counter goes 0 .. M+N+1, total M+N+2
    //   DRAIN   : N cycles (one per output column)
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE    = 2'd0,
        LOAD    = 2'd1,
        COMPUTE = 2'd2,
        DRAIN   = 2'd3
    } state_t;

    state_t state, next_state;

    // Counters. Sized so the bigger M = N = 48 array still fits.
    localparam int WT_CNT_W      = $clog2(M*N + 1);
    localparam int COMPUTE_CNT_W = $clog2(M + N + 3);
    localparam int DRAIN_CNT_W   = $clog2(N + 1);

    logic [WT_CNT_W-1:0]      wt_count;
    logic [COMPUTE_CNT_W-1:0] compute_cycle;
    logic [DRAIN_CNT_W-1:0]   drain_cycle;

    // ==================================================================
    // State register and next-state combinational
    // ==================================================================
    always_ff @(posedge clk) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE:    if (cfg_start)                                   next_state = LOAD;
            LOAD:    if (wt_count == WT_CNT_W'(M*N - 1))              next_state = COMPUTE;
            COMPUTE: if (compute_cycle == COMPUTE_CNT_W'(M + N + 1))  next_state = DRAIN;
            DRAIN:   if (drain_cycle == DRAIN_CNT_W'(N - 1) &&
                         res_ready)                                   next_state = IDLE;
            default:                                                  next_state = IDLE;
        endcase
    end

    // ==================================================================
    // Counters
    // ==================================================================
    always_ff @(posedge clk) begin
        if (rst)
            wt_count <= '0;
        else if (state == LOAD)
            wt_count <= wt_count + 1'b1;
        else
            wt_count <= '0;
    end

    always_ff @(posedge clk) begin
        if (rst)
            compute_cycle <= '0;
        else if (state == COMPUTE)
            compute_cycle <= compute_cycle + 1'b1;
        else
            compute_cycle <= '0;
    end

    always_ff @(posedge clk) begin
        if (rst)
            drain_cycle <= '0;
        else if (state == DRAIN && res_ready)
            drain_cycle <= drain_cycle + 1'b1;
        else if (state != DRAIN)
            drain_cycle <= '0;
    end

    // ==================================================================
    // Activation buffer
    // ==================================================================
    //
    // At compute_cycle == 0, act_data carries the M-element activation
    // tile in its low M*DATA_W bits. Latch into act_buf so subsequent
    // compute cycles can inject one element per row with a row skew.
    // ------------------------------------------------------------------
    logic [DATA_W-1:0] act_buf [0:M-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < M; i++)
                act_buf[i] <= '0;
        end else if (state == COMPUTE && compute_cycle == '0) begin
            for (int i = 0; i < M; i++)
                act_buf[i] <= act_data[i*DATA_W +: DATA_W];
        end
    end

    // ==================================================================
    // Activation feed (row skew)
    // ==================================================================
    //
    // Row i sees its activation x[i] = act_buf[i] exactly once during
    // COMPUTE, at compute_cycle == i + 1. All other cycles see 0. This
    // skew is what makes the partial-sum chain in column n produce the
    // correct y[n] = sum_k x[k] * B[k][n] at the bottom-row register.
    // ------------------------------------------------------------------
    logic [DATA_W-1:0] row_act_feed [0:M-1];

    always_comb begin
        for (int i = 0; i < M; i++)
            row_act_feed[i] = '0;
        if (state == COMPUTE) begin
            for (int i = 0; i < M; i++) begin
                if (compute_cycle == COMPUTE_CNT_W'(i + 1))
                    row_act_feed[i] = act_buf[i];
            end
        end
    end

    // ==================================================================
    // PE grid (M rows x N cols)
    // ==================================================================
    //
    // Wiring:
    //   PE[i][0].act_in   = row_act_feed[i]
    //   PE[i][j>0].act_in = PE[i][j-1].act_out         (registered, 1 cyc)
    //   PE[0][n].psum_in  = 32'd0
    //   PE[i>0][n].psum_in = PE[i-1][n].psum_out       (registered, 1 cyc)
    //
    // Weights are loaded one-PE-per-cycle during LOAD, using wt_count
    // decoded into (row, col) in row-major order:
    //   wt_load[i][j] = (state == LOAD) && (wt_count == i*N + j)
    //
    // psum_reg in every PE is force-cleared during LOAD via clr_psum so
    // entry to COMPUTE always starts from a clean partial sum, even
    // across consecutive tiles.
    // ------------------------------------------------------------------
    logic [DATA_W-1:0] pe_act_out  [0:M-1][0:N-1];
    logic [31:0]       pe_psum_out [0:M-1][0:N-1];

    genvar gi, gj;
    generate
        for (gi = 0; gi < M; gi++) begin: g_row
            for (gj = 0; gj < N; gj++) begin: g_col
                logic                 wt_load_ij;
                logic [DATA_W-1:0]    pe_act_in_ij;
                logic [31:0]          pe_psum_in_ij;

                assign wt_load_ij = (state == LOAD) &&
                                    (wt_count == WT_CNT_W'(gi*N + gj));

                if (gj == 0)
                    assign pe_act_in_ij  = row_act_feed[gi];
                else
                    assign pe_act_in_ij  = pe_act_out[gi][gj-1];

                if (gi == 0)
                    assign pe_psum_in_ij = 32'd0;
                else
                    assign pe_psum_in_ij = pe_psum_out[gi-1][gj];

                pe u_pe (
                    .clk      (clk),
                    .rst      (rst),
                    .clr_psum (state == LOAD),
                    .wt_load  (wt_load_ij),
                    .wt_in    (act_data[DATA_W-1:0]),
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
    // ==================================================================
    //
    // y[n] = sum_k x[k] * B[k][n] settles in PE[M-1][n].psum_reg at
    // compute_cycle == M + 2 + n, then gets clobbered the cycle after
    // (zeros propagating down). Capture each column at its own cycle.
    // ------------------------------------------------------------------
    logic [31:0] result_buf [0:N-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int n = 0; n < N; n++)
                result_buf[n] <= '0;
        end else if (state == COMPUTE) begin
            for (int n = 0; n < N; n++) begin
                if (compute_cycle == COMPUTE_CNT_W'(M + 2 + n))
                    result_buf[n] <= pe_psum_out[M-1][n];
            end
        end
    end

    // ==================================================================
    // Drain serializer
    // ==================================================================
    //
    // During DRAIN, present one bf16-rounded result per cycle on
    // res_data's low OUT_W bits (upper lanes stay at 0 in v1). Honor
    // res_ready: drain_cycle only advances when downstream accepts.
    // ------------------------------------------------------------------
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
    // ==================================================================
    //
    // act_ready: high while compute_core is consuming from act_data.
    //   - LOAD: every cycle (one weight per cycle).
    //   - COMPUTE cycle 0: yes (consumes activation tile).
    //   - Otherwise: no.
    //
    // status_busy: anything but IDLE.
    // status_done: 1-cycle pulse on the cycle DRAIN accepts its last word.
    // ------------------------------------------------------------------
    assign act_ready   = (state == LOAD) ||
                         ((state == COMPUTE) && (compute_cycle == '0));

    assign status_busy = (state != IDLE);
    assign status_done = (state == DRAIN) &&
                         (drain_cycle == DRAIN_CNT_W'(N - 1)) &&
                         res_ready;

endmodule
