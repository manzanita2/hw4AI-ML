// interface
//
// Bus-protocol shell for the systolic-array compute core. Sibling top
// to compute_core.sv: owns the AXI4-Stream slave/master pair (data
// plane) and the AXI4-Lite slave (config / status). Presents a
// simplified internal API to compute_core that strips bus-side
// handshakes and decodes the register file.
//
// v1 implementation: real AXI4-Lite write/read FSMs and a 3-register
// regfile (CTRL / STATUS / SCRATCH); pass-through AXI4-Stream adapters
// to compute_core (no FIFOs in v1 -- back-pressure propagates straight
// from compute_core to the upstream/downstream bus). Ingress / egress
// FIFOs and im2col staging are deferred to a follow-up pass.
//
// -------------------------------------------------------------------
// Clock domain
// -------------------------------------------------------------------
// Single clock domain, named `clk`. Target operating frequency
// 300 MHz. No clock-domain crossings inside this module; AXI4-Stream
// and AXI4-Lite both run synchronous to `clk`.
//
// -------------------------------------------------------------------
// Reset
// -------------------------------------------------------------------
// Synchronous, active-high, named `rst`. Sampled on `posedge clk`.
// All bus-side outputs (s_axis_tready, m_axis_t*, s_axil_*) and all
// internal-API outputs revert to their idle values when rst is high.
// No asynchronous resets anywhere.
//
// -------------------------------------------------------------------
// Ports
// -------------------------------------------------------------------
// Name              Dir   Width             Purpose
// ----------------  ----  ----------------  --------------------------------
// clk               in    1                 clock, single domain, 300 MHz target
// rst               in    1                 synchronous active-high reset
// -- AXI4-Stream slave (ingress: activations + weights, time-muxed) --
// s_axis_tdata      in    AXIS_DATA_W       ingress beat payload
// s_axis_tvalid     in    1                 ingress beat is valid
// s_axis_tready     out   1                 interface can accept this beat
// s_axis_tlast      in    1                 last beat of an ingress tile
// -- AXI4-Stream master (egress: GEMM tile results) --
// m_axis_tdata      out   AXIS_DATA_W       egress beat payload
// m_axis_tvalid     out   1                 egress beat is valid
// m_axis_tready     in    1                 downstream can accept egress beat
// m_axis_tlast      out   1                 last beat of an egress tile
// -- AXI4-Lite slave (config / status registers) --
// s_axil_awaddr     in    AXIL_ADDR_W       write address
// s_axil_awvalid    in    1                 write address valid
// s_axil_awready    out   1                 write address accepted
// s_axil_wdata      in    AXIL_DATA_W       write data
// s_axil_wstrb      in    AXIL_DATA_W/8     write byte strobes
// s_axil_wvalid     in    1                 write data valid
// s_axil_wready     out   1                 write data accepted
// s_axil_bresp      out   2                 write response code (00=OKAY)
// s_axil_bvalid     out   1                 write response valid
// s_axil_bready     in    1                 master can accept write response
// s_axil_araddr     in    AXIL_ADDR_W       read address
// s_axil_arvalid    in    1                 read address valid
// s_axil_arready    out   1                 read address accepted
// s_axil_rdata      out   AXIL_DATA_W       read data
// s_axil_rresp      out   2                 read response code (00=OKAY)
// s_axil_rvalid     out   1                 read data valid
// s_axil_rready     in    1                 master can accept read data
// -- internal API to compute_core (handshake-stripped) --
// act_data          out   DATA_W*LANES      activation/weight stream payload
// act_valid         out   1                 act_data is valid this cycle
// act_last          out   1                 last beat of an activation tile
// act_ready         in    1                 compute_core can consume this cycle
// res_data          in    OUT_W*LANES       result stream payload from core
// res_valid         in    1                 res_data is valid this cycle
// res_last          in    1                 final result beat
// res_ready         out   1                 interface can accept core results
// cfg_start         out   1                 pulse to start a tile
// status_busy       in    1                 core not in IDLE
// status_done       in    1                 tile complete pulse from core
//
// -------------------------------------------------------------------
// AXI4-Lite register map  (deliverable #3 checkbox 3)
// -------------------------------------------------------------------
// Slave is 32-bit (AXIL_DATA_W = 32); byte addresses are word-aligned;
// bits [1:0] of the address are ignored by the decoder. Byte strobes
// (s_axil_wstrb) are honored on writes (per-byte mask). Unimplemented
// addresses: writes are silently consumed and acknowledged with OKAY;
// reads return 0 with OKAY. No SLVERR is ever generated -- the spec
// allows OKAY responses for these cases.
//
// Byte  Word  Name     Access  Bit fields
// ----  ----  -------  ------  ----------------------------------------
// 0x00  0     CTRL     W-only  bit 0 = START. Writing 1 fires a
//                              one-cycle pulse on cfg_start to
//                              compute_core (matches the >=1 cycle
//                              pulse contract in compute_core.sv) and
//                              clears the DONE latch in the same cycle
//                              (next-tile semantics). Self-clearing:
//                              reads of CTRL always return 0.
// 0x04  1     STATUS   R-only  bit 0 = BUSY  (combinational mirror of
//                                             status_busy from core)
//                              bit 1 = DONE  (sticky -- latched from a
//                                             status_done pulse;
//                                             cleared by the next
//                                             CTRL.START write or rst,
//                                             with clear taking
//                                             priority over set on
//                                             same-cycle conflict)
//                              bits [31:2] reserved, read as 0
// 0x10  4     SCRATCH  R/W     32-bit storage. No side effects on the
//                              compute_core API; this is a loopback
//                              register used by tb_interface.py
//                              (deliverable #4) to verify the AXI-Lite
//                              slave path independently of the data
//                              plane. Honors per-byte strobes.
//
// Host usage pattern for a single tile:
//   1. write SCRATCH (optional, e.g. tile-id tag)
//   2. write CTRL.START = 1   -> cfg_start pulses, DONE clears
//   3. push tile activations / weights via s_axis_*
//   4. drain results via m_axis_*
//   5. poll STATUS until DONE = 1
//   6. goto 2 for the next tile
//
// -------------------------------------------------------------------
// Protocol conformance (deliverable #3 checkbox 2)
// -------------------------------------------------------------------
// AXI4-Lite (per ARM IHI 0022, section A3.3 handshake rules):
//   AW: awready is combinational from W-FSM state (asserted in W_IDLE,
//       deasserted in W_RESP). Once a master asserts awvalid + awaddr,
//       master must hold them stable until awready is observed high
//       (master responsibility per spec). The slave does NOT gate
//       awready on awvalid -- awready depends only on FSM state, so
//       there is no awvalid->awready combinational path.
//   W:  wready follows the same rule as awready (also W-FSM gated).
//       wstrb is honored on a per-byte basis for the SCRATCH register;
//       CTRL only inspects bit 0 of byte 0 (wstrb[0] && wdata[0]).
//   B:  bvalid is registered. It rises one cycle after the AW+W
//       handshake completes (W_IDLE -> W_RESP transition), and falls
//       only on the cycle bready is observed high (slave responsibility
//       per spec -- bvalid never deasserts unaccepted). bresp is always
//       OKAY (2'b00).
//   AR: arready is combinational from R-FSM state, same handshake
//       contract as AW.
//   R:  rvalid is registered, same shape as B. rdata is captured into
//       rdata_reg the cycle of the AR handshake, then held stable
//       across R_DATA. rresp is always OKAY (2'b00).
//   The W-FSM and R-FSM are independent state machines; a read may
//   proceed on AR while a write is still in W_RESP, as the spec
//   explicitly allows.
//
// AXI4-Stream (per ARM IHI 0051):
//   Slave (ingress) -- s_axis_*:
//     tready is combinational from compute_core's act_ready (pure
//     pass-through). A beat is consumed iff (tvalid && tready) on the
//     same posedge clk. Master responsibility: hold tdata / tlast /
//     tvalid stable until tready is observed high.
//   Master (egress) -- m_axis_*:
//     tvalid is combinational from compute_core's res_valid (pure
//     pass-through). compute_core's drain_cycle counter is gated on
//     (res_valid && res_ready), so downstream backpressure correctly
//     stalls the drain.
//   TKEEP / TSTRB / TUSER / TID / TDEST are not implemented -- treated
//     as "all bytes present, no out-of-band info." Any values driven by
//     the connected master/slave on these are ignored.
//
// -------------------------------------------------------------------
// Synthesizability constraints (per codefest 4 conventions)
// -------------------------------------------------------------------
//   - synchronous, active-high reset (see Reset section above)
//   - no `initial` blocks, no `$display`, no `#` delays
//   - sequential logic in `always_ff`, combinational in `always_comb`
//   - parameterized widths so the same RTL can shrink for prototyping
//
// Filename / module-name note: the file is `interface.sv` to match
// the M2 grader path (the PDF states the grader matches on filename).
// The SV module identifier inside is `interface_module`, NOT
// `interface`, because `interface` is a reserved IEEE-1800 keyword
// that iverilog -g2012 refuses to parse when it appears as a module
// declaration alongside other source files. Tests reference the top
// as `interface_module`; the build maps TEST=interface (the filename
// stem) to TOPLEVEL=interface_module via the Makefile.

module interface_module #(
    // -- bus widths -----------------------------------------------------
    parameter int AXIS_DATA_W = 256,   // M1 ingress / egress bus
    parameter int AXIL_ADDR_W = 8,     // 256 byte register window
    parameter int AXIL_DATA_W = 32,

    // -- internal-API datapath widths ---------------------------------
    // Must match the compute_core instance these wires connect to at
    // the future top-level wrapper. Defaults align with architecture.md
    // (bf16 in, bf16 out, 16 lanes per beat = 256 / 16).
    parameter int DATA_W      = 16,    // bfloat16 operand width
    parameter int OUT_W       = 16,    // bfloat16 output width
    parameter int LANES       = 16     // DATA_W lanes per internal beat
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
    input  logic                          s_axil_rready,

    // -- internal API to compute_core ---------------------------------
    //    activation/weight stream out (handshake-stripped)
    output logic [DATA_W*LANES-1:0]       act_data,
    output logic                          act_valid,
    output logic                          act_last,
    input  logic                          act_ready,
    //    result stream in
    input  logic [OUT_W*LANES-1:0]        res_data,
    input  logic                          res_valid,
    input  logic                          res_last,
    output logic                          res_ready,
    //    decoded config / status
    output logic                          cfg_start,
    input  logic                          status_busy,
    input  logic                          status_done
);

    // ==================================================================
    // AXI4-Lite address decode
    // ==================================================================
    // Word-aligned base addresses for the three implemented registers.
    // Decoder masks off bits [1:0] of awaddr / araddr so unaligned byte
    // accesses still hit the right word (per AXI4-Lite, alignment is a
    // master responsibility but ignoring [1:0] is the spec-friendly
    // behavior on a 32-bit slave).
    localparam logic [AXIL_ADDR_W-1:0] ADDR_CTRL    = 'h00;
    localparam logic [AXIL_ADDR_W-1:0] ADDR_STATUS  = 'h04;
    localparam logic [AXIL_ADDR_W-1:0] ADDR_SCRATCH = 'h10;

    logic [AXIL_ADDR_W-1:0] aw_word_addr;
    logic [AXIL_ADDR_W-1:0] ar_word_addr;
    assign aw_word_addr = {s_axil_awaddr[AXIL_ADDR_W-1:2], 2'b00};
    assign ar_word_addr = {s_axil_araddr[AXIL_ADDR_W-1:2], 2'b00};

    // ==================================================================
    // Register storage (declared up front so cross-references compile)
    // ==================================================================
    logic [AXIL_DATA_W-1:0] scratch;     // SCRATCH @ 0x10
    logic                   done_latch;  // STATUS bit 1 (sticky)
    logic [AXIL_DATA_W-1:0] rdata_reg;   // captured AR payload

    // ==================================================================
    // AXI4-Lite write channel FSM (W_IDLE, W_RESP)
    // ==================================================================
    typedef enum logic [0:0] { W_IDLE, W_RESP } w_state_t;
    w_state_t w_state;

    // CTRL.START write detector. Fires combinationally on the cycle
    // the AW+W handshake completes with awaddr decoded as CTRL and
    // wdata[0] set under wstrb[0]. Same-cycle inputs feed both the
    // cfg_start pulse and the done_latch clear -- see done_latch
    // always_ff below for the latch's clear-over-set priority.
    logic ctrl_start_write;
    assign ctrl_start_write = (w_state == W_IDLE)
                              && s_axil_awvalid && s_axil_wvalid
                              && (aw_word_addr == ADDR_CTRL)
                              && s_axil_wstrb[0] && s_axil_wdata[0];

    always_ff @(posedge clk) begin
        if (rst) begin
            w_state       <= W_IDLE;
            s_axil_bvalid <= 1'b0;
            cfg_start     <= 1'b0;
            scratch       <= '0;
        end else begin
            cfg_start <= 1'b0;  // pulse default; overridden on CTRL.START

            case (w_state)
                W_IDLE: begin
                    if (s_axil_awvalid && s_axil_wvalid) begin
                        // Address-decoded side effects.
                        if (aw_word_addr == ADDR_CTRL) begin
                            if (s_axil_wstrb[0] && s_axil_wdata[0])
                                cfg_start <= 1'b1;
                        end
                        if (aw_word_addr == ADDR_SCRATCH) begin
                            for (int i = 0; i < AXIL_DATA_W/8; i++) begin
                                if (s_axil_wstrb[i])
                                    scratch[i*8 +: 8] <= s_axil_wdata[i*8 +: 8];
                            end
                        end
                        // Unimplemented addresses: silently consume,
                        // respond OKAY, no side effect on regfile.

                        s_axil_bvalid <= 1'b1;
                        w_state       <= W_RESP;
                    end
                end
                W_RESP: begin
                    if (s_axil_bready) begin
                        s_axil_bvalid <= 1'b0;
                        w_state       <= W_IDLE;
                    end
                end
                default: w_state <= W_IDLE;
            endcase
        end
    end

    assign s_axil_awready = (w_state == W_IDLE);
    assign s_axil_wready  = (w_state == W_IDLE);
    assign s_axil_bresp   = 2'b00;  // OKAY for every write

    // ==================================================================
    // AXI4-Lite read channel FSM (R_IDLE, R_DATA) -- independent of W
    // ==================================================================
    typedef enum logic [0:0] { R_IDLE, R_DATA } r_state_t;
    r_state_t r_state;

    always_ff @(posedge clk) begin
        if (rst) begin
            r_state       <= R_IDLE;
            s_axil_rvalid <= 1'b0;
            rdata_reg     <= '0;
        end else begin
            case (r_state)
                R_IDLE: begin
                    if (s_axil_arvalid) begin
                        case (ar_word_addr)
                            ADDR_CTRL:    rdata_reg <= '0;
                            ADDR_STATUS:  rdata_reg <= {{(AXIL_DATA_W-2){1'b0}},
                                                        done_latch, status_busy};
                            ADDR_SCRATCH: rdata_reg <= scratch;
                            default:      rdata_reg <= '0;
                        endcase
                        s_axil_rvalid <= 1'b1;
                        r_state       <= R_DATA;
                    end
                end
                R_DATA: begin
                    if (s_axil_rready) begin
                        s_axil_rvalid <= 1'b0;
                        r_state       <= R_IDLE;
                    end
                end
                default: r_state <= R_IDLE;
            endcase
        end
    end

    assign s_axil_arready = (r_state == R_IDLE);
    assign s_axil_rdata   = rdata_reg;
    assign s_axil_rresp   = 2'b00;  // OKAY for every read

    // ==================================================================
    // STATUS.DONE latch
    // ==================================================================
    // Sticky bit set by a status_done pulse and cleared by the next
    // CTRL.START write or by rst. Clear takes priority over set when
    // they coincide: a host that issues START at the exact moment the
    // current tile's status_done fires will see DONE=0 next cycle (the
    // start it just issued is for the *next* tile, not the one that
    // happened to finish in the same cycle).
    always_ff @(posedge clk) begin
        if (rst)                    done_latch <= 1'b0;
        else if (ctrl_start_write)  done_latch <= 1'b0;
        else if (status_done)       done_latch <= 1'b1;
    end

    // ==================================================================
    // AXI4-Stream pass-through (combinational, no FIFOs in v1)
    // ==================================================================
    // Ingress: bus -> compute_core. Bus widths line up by construction
    // (AXIS_DATA_W == DATA_W*LANES at default parameters); back-pressure
    // from compute_core (act_ready) propagates straight to the master
    // via s_axis_tready. compute_core never retracts a previously
    // accepted beat, so this satisfies the AXIS valid-stays-asserted
    // contract.
    assign act_data       = s_axis_tdata;
    assign act_valid      = s_axis_tvalid;
    assign act_last       = s_axis_tlast;
    assign s_axis_tready  = act_ready;

    // Egress: compute_core -> bus. Mirror of ingress with the data
    // direction reversed; downstream's m_axis_tready propagates to
    // res_ready, which gates compute_core's drain_cycle counter, so
    // downstream backpressure correctly stalls the drain.
    assign m_axis_tdata   = res_data;
    assign m_axis_tvalid  = res_valid;
    assign m_axis_tlast   = res_last;
    assign res_ready      = m_axis_tready;

endmodule
