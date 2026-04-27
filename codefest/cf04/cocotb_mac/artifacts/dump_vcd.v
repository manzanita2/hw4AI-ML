module dump_vcd();
initial begin
    $dumpfile("artifacts/mac.vcd");
    $dumpvars(0, mac);
end
endmodule
