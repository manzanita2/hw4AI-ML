module dump_vcd();
initial begin
    $dumpfile("artifacts/top.vcd");
    $dumpvars(0, top);
end
endmodule
