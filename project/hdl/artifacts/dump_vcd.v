module dump_vcd();
initial begin
    $dumpfile("artifacts/compute_core.vcd");
    $dumpvars(0, compute_core);
end
endmodule
