// interface (M3)
//
// Pure-AXI4-Lite control / status register file for the integrated
// `top.sv` accelerator. Evolution of the M2 interface_module
// (project/m2/rtl/interface.sv): the AXI4-Stream pass-through has
// moved out of this block; in M3 the FIFOs and the LOAD_WEIGHTS-vs-
// COMPUTE demux live in `top.sv` directly, and this module is now
// just the AXI-Lite face of the chip plus the decoded control / status
// signals that the rest of `top.sv` consumes.
//
// -------------------------------------------------------------------
// Why the redesign
// -------------------------------------------------------------------
// M2's interface had `s_axis_*` slave + `m_axis_*` master pins that
// were nothing more than wires to compute_core. Now that the host has
// to disambiguate weight-load beats from activation beats (otherwise
// the on-chip weight cache is meaningless), the interface owns the
// MODE bit but not the AXIS routing -- the routing is a one-mux
// combinational block in top.sv that picks between weight_store's
// write port and the activation FIFO based on cfg_mode.
//
// -------------------------------------------------------------------
// Clock domain
// -------------------------------------------------------------------
// Single domain `clk`. Synchronous active-high `rst`. No CDCs.
//
// -------------------------------------------------------------------
// Ports
// -------------------------------------------------------------------
// clk             in   1                clock
// rst             in   1                synchronous active-high reset
// -- AXI4-Lite slave (config / status) --------------------------------
//   ...full AW/W/B/AR/R bundle, identical wire shape to M2 interface.sv
// -- decoded control out / status in (top.sv internal API) -----------
// cfg_start       out  1                1-cycle pulse on CTRL.START
// cfg_mode        out  1                0=COMPUTE, 1=LOAD_WEIGHTS;
//                                       latched alongside CTRL.START
// status_busy     in   1                compute_core not in IDLE
// status_done     in   1                compute_core 1-cycle DRAIN done
// weights_loaded  in   1                weight_store sticky "loaded"
// load_err        in   1                weight_store sticky "tlast err"
//
// -------------------------------------------------------------------
// AXI4-Lite register map (extended from M2)
// -------------------------------------------------------------------
// Byte  Word  Name     Access  Bit fields
// ----  ----  -------  ------  -----------------------------------------
// 0x00  0     CTRL     W-only  bit 0 = START. Writing 1 fires a one-
//                              cycle pulse on cfg_start AND latches
//                              bits 1/2/3 of the same write into the
//                              cfg_mode / cfg_accum / cfg_hold
//                              registers. Reads of CTRL return 0
//                              (self-clearing strobe).
//                              bit 1 = MODE. 0 = COMPUTE (start a
//                              compute tile, weights replayed from
//                              weight_store by load_seq), 1 =
//                              LOAD_WEIGHTS (route AXIS beats into
//                              weight_store). Latched only on a
//                              CTRL.START write so spurious writes
//                              that don't set START don't reshape the
//                              accelerator's intent.
//                              bit 2 = ACCUM (COMPUTE only). 0 =
//                              overwrite result_buf (first K-tile of a
//                              tiled convolution, or a standalone
//                              GEMM); 1 = add this tile's column sums
//                              into result_buf (cross-tile fp32
//                              accumulation). Latched with START.
//                              bit 3 = HOLD (COMPUTE only). 0 = drain
//                              the N results after capture (last
//                              K-tile / standalone GEMM); 1 = skip
//                              DRAIN and return to IDLE holding the
//                              fp32 partial sums in result_buf for the
//                              next accumulating tile. Latched with
//                              START. Bit-exact rounding to bf16
//                              happens only on the draining tile.
// 0x04  1     STATUS   R-only  bit 0 = BUSY  (combinational mirror of
//                                             status_busy from core)
//                              bit 1 = DONE  (sticky; cleared by
//                                             CTRL.START write or rst)
//                              bit 2 = WEIGHTS_LOADED (combinational
//                                             mirror of weights_loaded
//                                             from weight_store)
//                              bit 3 = LOAD_ERR (combinational mirror
//                                             of load_err from
//                                             weight_store)
//                              bits [31:4] reserved, read 0.
// 0x10  4     SCRATCH  R/W     32-bit storage, no side effects.
//                              Carried forward from M2 unchanged --
//                              tb_top uses it to sanity-check the
//                              regfile path before doing real tiles.
//
// Host usage:
//   1) write CTRL = 0x03 (START + MODE=LOAD_WEIGHTS)
//   2) push BEATS_NEEDED weight beats on AXIS (driven by host master)
//   3) poll STATUS until WEIGHTS_LOADED == 1 (and LOAD_ERR == 0)
//   4) for each compute tile:
//        a) write CTRL = 0x01 (START + MODE=COMPUTE)
//        b) push 1 activation beat (M*DATA_W bits in low lanes)
//        c) drain N result beats
//        d) poll STATUS until DONE = 1, then go back to (a)
//
// -------------------------------------------------------------------
// Synthesizability
// -------------------------------------------------------------------
//   - synchronous active-high reset
//   - no `initial` blocks, no `$display`, no `#` delays
//   - sequential logic in always_ff, combinational in always_comb
//   - `module interface_module` (NOT `module interface`) because
//     `interface` is an IEEE-1800 reserved keyword that iverilog
//     -g2012 refuses to parse alongside other source files. Same
//     deviation as M2; tests reference the top as `interface_module`.

module interface_module #(
    parameter int AXIL_ADDR_W = 8,
    parameter int AXIL_DATA_W = 32
) (
    input  logic                          clk,
    input  logic                          rst,

    // -- AXI4-Lite slave ----------------------------------------------
    input  logic [AXIL_ADDR_W-1:0]        s_axil_awaddr,
    input  logic                          s_axil_awvalid,
    output logic                          s_axil_awready,
    input  logic [AXIL_DATA_W-1:0]        s_axil_wdata,
    input  logic [(AXIL_DATA_W/8)-1:0]    s_axil_wstrb,
    input  logic                          s_axil_wvalid,
    output logic                          s_axil_wready,
    output logic [1:0]                    s_axil_bresp,
    output logic                          s_axil_bvalid,
    input  logic                          s_axil_bready,
    input  logic [AXIL_ADDR_W-1:0]        s_axil_araddr,
    input  logic                          s_axil_arvalid,
    output logic                          s_axil_arready,
    output logic [AXIL_DATA_W-1:0]        s_axil_rdata,
    output logic [1:0]                    s_axil_rresp,
    output logic                          s_axil_rvalid,
    input  logic                          s_axil_rready,

    // -- decoded control / status -------------------------------------
    output logic                          cfg_start,
    output logic                          cfg_mode,
    output logic                          cfg_accum,
    output logic                          cfg_hold,
    input  logic                          status_busy,
    input  logic                          status_done,
    input  logic                          weights_loaded,
    input  logic                          load_err
);

    // ==================================================================
    // Address decode
    // ==================================================================
    localparam logic [AXIL_ADDR_W-1:0] ADDR_CTRL    = 'h00;
    localparam logic [AXIL_ADDR_W-1:0] ADDR_STATUS  = 'h04;
    localparam logic [AXIL_ADDR_W-1:0] ADDR_SCRATCH = 'h10;

    logic [AXIL_ADDR_W-1:0] aw_word_addr;
    logic [AXIL_ADDR_W-1:0] ar_word_addr;
    assign aw_word_addr = {s_axil_awaddr[AXIL_ADDR_W-1:2], 2'b00};
    assign ar_word_addr = {s_axil_araddr[AXIL_ADDR_W-1:2], 2'b00};

    // ==================================================================
    // Register storage
    // ==================================================================
    logic [AXIL_DATA_W-1:0] scratch;
    logic                   done_latch;
    logic [AXIL_DATA_W-1:0] rdata_reg;

    // ==================================================================
    // Write FSM (W_IDLE, W_RESP)
    // ==================================================================
    typedef enum logic [0:0] { W_IDLE, W_RESP } w_state_t;
    w_state_t w_state;

    // CTRL.START detector. Same shape as M2; mode bit added.
    logic ctrl_start_write;
    assign ctrl_start_write = (w_state == W_IDLE)
                              && s_axil_awvalid && s_axil_wvalid
                              && (aw_word_addr == ADDR_CTRL)
                              && s_axil_wstrb[0] && s_axil_wdata[0];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            w_state       <= W_IDLE;
            s_axil_bvalid <= 1'b0;
            cfg_start     <= 1'b0;
            cfg_mode      <= 1'b0;
            cfg_accum     <= 1'b0;
            cfg_hold      <= 1'b0;
            scratch       <= '0;
        end else begin
            cfg_start <= 1'b0;  // pulse default; overridden on CTRL.START

            unique case (w_state)
                W_IDLE: begin
                    if (s_axil_awvalid && s_axil_wvalid) begin
                        if (aw_word_addr == ADDR_CTRL) begin
                            if (s_axil_wstrb[0] && s_axil_wdata[0]) begin
                                cfg_start <= 1'b1;
                                // MODE / ACCUM / HOLD are sampled only
                                // when START fires so that quirky writes
                                // (mode/accum/hold without START) don't
                                // reshape pending intent.
                                cfg_mode  <= s_axil_wdata[1];
                                cfg_accum <= s_axil_wdata[2];
                                cfg_hold  <= s_axil_wdata[3];
                            end
                        end
                        if (aw_word_addr == ADDR_SCRATCH) begin
                            for (int i = 0; i < AXIL_DATA_W/8; i++) begin
                                if (s_axil_wstrb[i])
                                    scratch[i*8 +: 8] <= s_axil_wdata[i*8 +: 8];
                            end
                        end
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
            endcase
        end
    end

    assign s_axil_awready = (w_state == W_IDLE);
    assign s_axil_wready  = (w_state == W_IDLE);
    assign s_axil_bresp   = 2'b00;

    // ==================================================================
    // Read FSM (R_IDLE, R_DATA)
    // ==================================================================
    typedef enum logic [0:0] { R_IDLE, R_DATA } r_state_t;
    r_state_t r_state;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            r_state       <= R_IDLE;
            s_axil_rvalid <= 1'b0;
            rdata_reg     <= '0;
        end else begin
            unique case (r_state)
                R_IDLE: begin
                    if (s_axil_arvalid) begin
                        unique case (ar_word_addr)
                            ADDR_CTRL:    rdata_reg <= '0;
                            ADDR_STATUS:  rdata_reg <= {
                                {(AXIL_DATA_W-4){1'b0}},
                                load_err,
                                weights_loaded,
                                done_latch,
                                status_busy
                            };
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
            endcase
        end
    end

    assign s_axil_arready = (r_state == R_IDLE);
    assign s_axil_rdata   = rdata_reg;
    assign s_axil_rresp   = 2'b00;

    // ==================================================================
    // STATUS.DONE sticky latch
    // ==================================================================
    // Same clear-over-set priority as M2: a CTRL.START in the same
    // cycle as a status_done pulse clears DONE (the START is for the
    // next tile, not the one that happens to be finishing).
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                    done_latch <= 1'b0;
        else if (ctrl_start_write)  done_latch <= 1'b0;
        else if (status_done)       done_latch <= 1'b1;
    end

endmodule
