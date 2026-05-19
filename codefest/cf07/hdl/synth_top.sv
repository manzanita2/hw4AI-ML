// Codefest 6 (ECE 410/510): 4x4 binary-weight crossbar MAC — CLLM task 4.
// Each cycle: out[j] = sum_i weight[i][j] * in[i]; weights are +1 or -1.

`default_nettype none
`timescale 1ns / 1ps

module crossbar_mac (
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic signed [7:0] in [0:3],
    input  wire logic                weight_wen,
    input  wire logic        [1:0]   w_row,
    input  wire logic        [1:0]   w_col,
    input  wire logic signed [7:0] w_val,
    output logic signed [15:0] out [0:3]
);

    logic signed [7:0] weight [0:3][0:3];

    always_ff @(posedge clk) begin
        if (rst) begin
            out[0] <= '0;
            out[1] <= '0;
            out[2] <= '0;
            out[3] <= '0;
        end else begin
            if (weight_wen) begin
                weight[w_row][w_col] <= w_val;
            end
            for (int j = 0; j < 4; j++) begin
                logic signed [15:0] acc;
                acc = 16'sd0;
                for (int i = 0; i < 4; i++) begin
                    // x*±1 without generic multiplier
                    if (weight[i][j] == 8'sd1) begin
                        acc = acc + 16'(in[i]);
                    end else begin
                        acc = acc - 16'(in[i]);
                    end
                end
                out[j] <= acc;
            end
        end
    end

endmodule

`default_nettype wire
