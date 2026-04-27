module mac (
    input  logic                clk,
    input  logic                rst,
    input  logic signed [7:0]  a,
    input  logic signed [7:0]  b,
    output logic signed [31:0] out
);

    logic signed [15:0] product;

    assign product = a * b;

    always_ff @(posedge clk) begin
        if (rst) begin
            out <= 32'sd0;
        end else begin
            out <= out + {{16{product[15]}}, product};
        end
    end

endmodule
