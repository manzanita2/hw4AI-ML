// Codefest 6 — CLLM task 5: stimulus + golden check for crossbar_mac.

`default_nettype none
`timescale 1ns / 1ps

module crossbar_tb;

    logic clk;
    logic rst;
    logic signed [7:0] in_arr[0:3];
    logic weight_wen;
    logic [1:0] w_row, w_col;
    logic signed [7:0] w_val;
    logic signed [15:0] out_arr[0:3];

    localparam int CLK_HALF = 5;

    crossbar_mac dut (
        .clk(clk),
        .rst(rst),
        .in(in_arr),
        .weight_wen(weight_wen),
        .w_row(w_row),
        .w_col(w_col),
        .w_val(w_val),
        .out(out_arr)
    );

    always #(CLK_HALF) clk = ~clk;

    task static load_weight(input int r, input int c, input int v);
        @(negedge clk);
        weight_wen = 1'b1;
        w_row = r[1:0];
        w_col = c[1:0];
        w_val = v[7:0];
        @(negedge clk);
        weight_wen = 1'b0;
        w_val = 8'sd0;
    endtask

    initial begin
        int errors;
        clk = 1'b0;
        rst = 1'b1;
        weight_wen = 1'b0;
        w_row = '0;
        w_col = '0;
        w_val = 8'sd0;
        in_arr[0] = 8'sd0;
        in_arr[1] = 8'sd0;
        in_arr[2] = 8'sd0;
        in_arr[3] = 8'sd0;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Weights from PDF: [[1,-1,1,-1],[1,1,-1,-1],[-1,1,1,-1],[-1,-1,-1,1]]
        load_weight(0, 0, 1);
        load_weight(0, 1, -1);
        load_weight(0, 2, 1);
        load_weight(0, 3, -1);
        load_weight(1, 0, 1);
        load_weight(1, 1, 1);
        load_weight(1, 2, -1);
        load_weight(1, 3, -1);
        load_weight(2, 0, -1);
        load_weight(2, 1, 1);
        load_weight(2, 2, 1);
        load_weight(2, 3, -1);
        load_weight(3, 0, -1);
        load_weight(3, 1, -1);
        load_weight(3, 2, -1);
        load_weight(3, 3, 1);

        // Activations [10, 20, 30, 40] — hold stable, then sample after posedge.
        @(negedge clk);
        in_arr[0] = 8'sd10;
        in_arr[1] = 8'sd20;
        in_arr[2] = 8'sd30;
        in_arr[3] = 8'sd40;
        @(posedge clk);
        #1;

        errors = 0;
        $display("crossbar_tb: outputs after one compute cycle:");
        $display("  out[0]=%0d (expect -40)", out_arr[0]);
        $display("  out[1]=%0d (expect 0)", out_arr[1]);
        $display("  out[2]=%0d (expect -20)", out_arr[2]);
        $display("  out[3]=%0d (expect -20)", out_arr[3]);

        if (out_arr[0] !== -40) errors++;
        if (out_arr[1] !== 16'sd0) errors++;
        if (out_arr[2] !== -20) errors++;
        if (out_arr[3] !== -20) errors++;

        if (errors == 0) begin
            $display("PASS: hand-calculated MVM matches simulation.");
        end else begin
            $display("FAIL: %0d output(s) mismatch.", errors);
        end
        $finish;
    end

endmodule

`default_nettype wire
