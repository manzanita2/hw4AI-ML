// INT8 multiply-accumulate unit
// 8-bit signed * 8-bit signed -> 16-bit signed product
// Accumulated into a 32-bit signed register with synchronous reset.

module mac (
    input  logic               clk,
    input  logic               rst,
    input  logic signed [7:0]  a,
    input  logic signed [7:0]  b,
    output logic signed [31:0] out
);

    logic signed [15:0] product;

    assign product = a * b;

    always_ff @(posedge clk) begin
        if (rst)
            out <= '0;
        else
            out <= out + product;
    end

endmodule
