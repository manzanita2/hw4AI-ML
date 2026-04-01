`timescale 1ns/1ps

module tb_adder4;
  reg  [3:0] a;
  reg  [3:0] b;
  reg        cin;
  wire [3:0] sum;
  wire       cout;

  adder4 dut (
    .a(a),
    .b(b),
    .cin(cin),
    .sum(sum),
    .cout(cout)
  );

  task automatic check;
    input [3:0] aa;
    input [3:0] bb;
    input       cc;
    reg   [4:0] exp;
    begin
      a   = aa;
      b   = bb;
      cin = cc;
      #1;
      exp = {1'b0, aa} + {1'b0, bb} + cc;
      if ({cout, sum} !== exp) begin
        $display("FAIL a=%h b=%h cin=%b -> sum=%h cout=%b (exp sum=%h cout=%b) @t=%0t",
                 a, b, cin, sum, cout, exp[3:0], exp[4], $time);
        $fatal(1);
      end
    end
  endtask

  integer i;
  integer c;
  initial begin
    $display("Starting tb_adder4...");

    // Directed edge cases
    check(4'h0, 4'h0, 1'b0);
    check(4'h0, 4'h0, 1'b1);
    check(4'hF, 4'h0, 1'b0);
    check(4'hF, 4'h0, 1'b1);
    check(4'hF, 4'hF, 1'b0);
    check(4'hF, 4'hF, 1'b1);
    check(4'h8, 4'h8, 1'b0);
    check(4'h8, 4'h8, 1'b1);
    check(4'h7, 4'h1, 1'b0);
    check(4'h7, 4'h1, 1'b1);

    // Exhaustive over cin for all a,b (32*16*16 = 512 checks)
    for (c = 0; c < 2; c = c + 1) begin
      for (i = 0; i < 256; i = i + 1) begin
        check(i[3:0], i[7:4], c[0]);
      end
    end

    // Some randomized vectors
    for (i = 0; i < 200; i = i + 1) begin
      check($random, $random, $random);
    end

    $display("PASS tb_adder4.");
    $finish;
  end
endmodule

