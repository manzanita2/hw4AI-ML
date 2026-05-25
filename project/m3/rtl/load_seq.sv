// load_seq
//
// Replay sequencer that walks `weight_store` and presents one bf16
// weight per cycle on `wt_data` for compute_core's existing wt_load
// handshake (see project/m2/rtl/compute_core.sv lines 273-275, where
// wt_load_ij = (state == LOAD) && (wt_count == i*N + j)).
//
// Compute_core's LOAD-state schedule is unchanged from M2: it emits
// the same wt_load[i][j] one-hot pattern in row-major order, M*N
// cycles long. M3 simply replaces the source of the bf16 word the PE
// captures: instead of taking it from act_data[DATA_W-1:0], the PE
// gets it from compute_core's new `wt_data_ext` input (selected by
// the compute_core EXTERNAL_WT_SRC parameter), which top.sv wires to
// this module's `wt_data` output.
//
// -------------------------------------------------------------------
// Trigger / cadence
// -------------------------------------------------------------------
// `start` is asserted by interface_module on the same cycle as the
// CTRL.START pulse with cfg_mode == COMPUTE. compute_core's FSM goes
// IDLE -> LOAD on the next clock edge; its wt_count starts at 0 in
// that LOAD cycle and increments through M*N - 1 over the LOAD
// state's life.
//
// load_seq mirrors that schedule. On `start`, it transitions into a
// SEQ state on the next edge with cnt = 0; cnt increments on each
// subsequent edge until cnt == M*N - 1 (one cycle), then returns to
// IDLE. So at every cycle compute_core is in LOAD with wt_count == k,
// load_seq is in SEQ with cnt == k -- each PE captures the right
// weight on its programmed cycle.
//
// -------------------------------------------------------------------
// Ports
// -------------------------------------------------------------------
//   clk      in   1                          clock
//   rst      in   1                          synchronous active-high reset
//   start    in   1                          1-cycle pulse: begin replay
//   rd_addr  out  $clog2(M*N+1)              address into weight_store
//   rd_data  in   DATA_W                     weight_store[rd_addr]
//   wt_data  out  DATA_W                     bf16 weight to PE chain
//   busy     out  1                          high during SEQ

module load_seq #(
    parameter int DATA_W = 16,
    parameter int M      = 48,
    parameter int N      = 48
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       start,

    output logic [$clog2(M*N+1)-1:0]   rd_addr,
    input  logic [DATA_W-1:0]          rd_data,

    output logic [DATA_W-1:0]          wt_data,
    output logic                       busy
);

    localparam int CNT_W = $clog2(M*N + 1);

    typedef enum logic [0:0] { IDLE = 1'b0, SEQ = 1'b1 } state_t;
    state_t state, next_state;

    logic [CNT_W-1:0] cnt;

    // ------------------------------------------------------------------
    // State register and next-state logic
    // ------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end

    always_comb begin
        next_state = state;
        unique case (state)
            IDLE: if (start) next_state = SEQ;
            SEQ:  if (cnt == CNT_W'(M*N - 1)) next_state = IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Counter
    // ------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt <= '0;
        end else begin
            unique case (state)
                IDLE: cnt <= '0;
                SEQ:  cnt <= cnt + 1'b1;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------
    // rd_addr is presented combinationally so weight_store's flat
    // memory read returns the right entry the same cycle. compute_core
    // captures wt_data on its own posedge clk into the per-PE weight
    // register, so wt_data must be valid the cycle wt_count matches.
    assign rd_addr = cnt;
    assign wt_data = rd_data;
    assign busy    = (state == SEQ);

endmodule
