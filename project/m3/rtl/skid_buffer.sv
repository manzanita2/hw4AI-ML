// skid_buffer
//
// Two-slot AXI-style register slice. Sits between an upstream
// ready/valid producer (the egress FIFO read port) and a downstream
// ready/valid consumer (the AXIS master output ports), to:
//
//   1. Register `m_*` so that the AXIS output ports are driven from a
//      flop Q instead of from a combinational FIFO output mux. This is
//      what closes the post-resizer WNS path that originally ran from
//      `u_eg_fifo.rd_ptr[0] -> 4:1 read mux -> m_axis_tdata[*] (out)`.
//      See [`project/m3/synth/critical_path.md`](../synth/critical_path.md)
//      Phase-8 walk for the pre-skid path.
//   2. Maintain full throughput: 1 beat / cycle even across a single
//      downstream stall. The skid slot absorbs a beat that the FIFO
//      offers on the cycle the primary slot cannot retire.
//   3. Break any combinational path from `m_ready` back to `s_ready`.
//      `s_ready = !skid_valid` reads only an internal flop output, so
//      the externally-driven AXIS `m_axis_tready` enters the design at
//      a flop D pin (skid_valid update logic) and never propagates
//      forward to drive the FIFO's `rd_ready` combinationally.
//
// Latency: a beat presented at the slave port on cycle T appears at
// the master port no earlier than cycle T+1 (one register stage).
// Capacity: 2 in-flight beats (primary + skid).
//
// State table:
//   primary empty, skid empty   -> s_ready=1, m_valid=0
//   primary full,  skid empty   -> s_ready=1, m_valid=1
//   primary full,  skid full    -> s_ready=0, m_valid=1
//   primary empty, skid full    -> never (skid drains into primary
//                                  on the same edge that frees primary)
//
// Reset is async-high to match the rest of m3/rtl/* per Phase 8.

module skid_buffer #(
    parameter int WIDTH = 1
) (
    input  logic              clk,
    input  logic              rst,

    // Slave port (upstream producer)
    input  logic [WIDTH-1:0]  s_data,
    input  logic              s_valid,
    output logic              s_ready,

    // Master port (downstream consumer)
    output logic [WIDTH-1:0]  m_data,
    output logic              m_valid,
    input  logic              m_ready
);

    // Skid slot (the second-ahead beat held while m_ready is low).
    logic [WIDTH-1:0] skid_data;
    logic             skid_valid;

    // s_ready depends only on skid_valid, an internal flop.
    // No combinational path from m_ready -> s_ready.
    assign s_ready = ~skid_valid;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            m_valid    <= 1'b0;
            m_data     <= '0;
            skid_valid <= 1'b0;
            skid_data  <= '0;
        end else if (!m_valid || m_ready) begin
            // Primary slot can be (re)filled this cycle: it is either
            // empty, or downstream is taking the current beat.
            if (skid_valid) begin
                // Drain skid into primary and free the skid slot.
                m_data     <= skid_data;
                m_valid    <= 1'b1;
                skid_valid <= 1'b0;
            end else if (s_valid) begin
                // Take a fresh beat from upstream into primary.
                m_data     <= s_data;
                m_valid    <= 1'b1;
            end else begin
                // Nothing available; primary becomes/stays empty.
                m_valid    <= 1'b0;
            end
        end else if (s_valid && !skid_valid) begin
            // Primary holds an unconsumed beat AND downstream is
            // stalled this cycle; absorb the upstream beat into the
            // skid so we can keep s_ready=1 the cycle that this beat
            // is actually offered by upstream.
            skid_data  <= s_data;
            skid_valid <= 1'b1;
        end
    end

endmodule
