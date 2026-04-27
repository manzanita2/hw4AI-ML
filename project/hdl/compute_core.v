// compute_core
//
// Top-level shell for the systolic-array compute core that targets
// `aten::mkldnn_convolution` in RAFT. This file is the v0 skeleton --
// port list, parameters, and reset plumbing only. Internal datapath
// (systolic array, AXIS DMA, AXI-Lite register file) lands later.
//
// Decisions captured in `project/architecture.md`:
//   * datapath:    bfloat16 multiply, fp32 accumulate, bfloat16 output
//   * fabric:      48 x 48 weight-stationary systolic array
//   * mapping:     im2col -> GEMM
//   * clock:       300 MHz, single domain
//   * data plane:  AXI4-Stream (256 bit @ 300 MHz from M1)
//   * control:     AXI4-Lite for config + status
//
// Synthesizability constraints (per codefest 4 conventions):
//   - synchronous, active-high reset
//   - no `initial` blocks, no `$display`, no `#` delays
//   - sequential logic in `always_ff`, combinational in `always_comb`
//   - parameterized widths so the same RTL can shrink for prototyping
//     (e.g. M = N = 4 for early bring-up)

module compute_core #(
    // -- datapath widths ------------------------------------------------
    parameter int DATA_W      = 16,    // bfloat16 operand width
    parameter int ACC_W       = 32,    // fp32 accumulator width
    parameter int OUT_W       = 16,    // bfloat16 output width

    // -- systolic array shape ------------------------------------------
    parameter int M           = 48,    // array rows  (output channels)
    parameter int N           = 48,    // array cols  (input channels)

    // -- bus widths ----------------------------------------------------
    parameter int AXIS_DATA_W = 256,   // M1 ingress / egress bus
    parameter int AXIL_ADDR_W = 8,     // 256 byte register window
    parameter int AXIL_DATA_W = 32
) (
    // -- clock / reset --------------------------------------------------
    input  logic                          clk,
    input  logic                          rst,

    // -- AXI4-Stream slave (ingress: activations + weights, time-muxed)
    input  logic [AXIS_DATA_W-1:0]        s_axis_tdata,
    input  logic                          s_axis_tvalid,
    output logic                          s_axis_tready,
    input  logic                          s_axis_tlast,

    // -- AXI4-Stream master (egress: GEMM tile results) ---------------
    output logic [AXIS_DATA_W-1:0]        m_axis_tdata,
    output logic                          m_axis_tvalid,
    input  logic                          m_axis_tready,
    output logic                          m_axis_tlast,

    // -- AXI4-Lite slave (config / status registers) ------------------
    //    write address channel
    input  logic [AXIL_ADDR_W-1:0]        s_axil_awaddr,
    input  logic                          s_axil_awvalid,
    output logic                          s_axil_awready,
    //    write data channel
    input  logic [AXIL_DATA_W-1:0]        s_axil_wdata,
    input  logic [(AXIL_DATA_W/8)-1:0]    s_axil_wstrb,
    input  logic                          s_axil_wvalid,
    output logic                          s_axil_wready,
    //    write response channel
    output logic [1:0]                    s_axil_bresp,
    output logic                          s_axil_bvalid,
    input  logic                          s_axil_bready,
    //    read address channel
    input  logic [AXIL_ADDR_W-1:0]        s_axil_araddr,
    input  logic                          s_axil_arvalid,
    output logic                          s_axil_arready,
    //    read data channel
    output logic [AXIL_DATA_W-1:0]        s_axil_rdata,
    output logic [1:0]                    s_axil_rresp,
    output logic                          s_axil_rvalid,
    input  logic                          s_axil_rready
);

    // ------------------------------------------------------------------
    // Top-level FSM state. The full sequence will be:
    //   IDLE    -> wait for "start" write to the AXI-Lite control reg
    //   LOAD    -> stream weights into the array (weight-stationary)
    //   COMPUTE -> stream activations through, accumulate in PE acc regs
    //   DRAIN   -> shift out fp32 accumulators, round to bf16, push to
    //              egress AXIS
    // For now only the register exists; transitions are stubbed.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE    = 2'd0,
        LOAD    = 2'd1,
        COMPUTE = 2'd2,
        DRAIN   = 2'd3
    } state_t;

    state_t state, next_state;

    always_ff @(posedge clk) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end

    always_comb begin
        // Placeholder: hold IDLE until ingress / control plumbing exists.
        next_state = state;
    end

    // ------------------------------------------------------------------
    // Stub tie-offs. Each block below will be replaced by a real
    // submodule as that subsystem comes online. They exist now so the
    // module synthesizes cleanly with no inferred latches and so a
    // testbench can wire it up without leaving inputs floating.
    // ------------------------------------------------------------------

    // Ingress AXIS slave: not yet ready to accept data.
    assign s_axis_tready  = 1'b0;

    // Egress AXIS master: not yet producing data.
    assign m_axis_tdata   = '0;
    assign m_axis_tvalid  = 1'b0;
    assign m_axis_tlast   = 1'b0;

    // AXI4-Lite slave: minimum legal "always idle" responder so a
    // connected master sees back-pressure rather than X's.
    assign s_axil_awready = 1'b0;
    assign s_axil_wready  = 1'b0;
    assign s_axil_bresp   = 2'b00;     // OKAY
    assign s_axil_bvalid  = 1'b0;
    assign s_axil_arready = 1'b0;
    assign s_axil_rdata   = '0;
    assign s_axil_rresp   = 2'b00;     // OKAY
    assign s_axil_rvalid  = 1'b0;

endmodule
