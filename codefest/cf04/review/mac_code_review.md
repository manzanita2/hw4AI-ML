##### llm choices
LLM A: chatgpt-5.5 "medium"
LLM B: claud Opus4.7 "extra high"

##### compilation
`iverilog -g2012 -s mac "mac_llm_A.v" -o llm_A.out`
no errors
`iverilog -g2012 -s mac "mac_llm_B.v" -o llm_B.out`
no errors

both mac_llm_A.v and mac_llm_B.v compiled, passed testbench, and synthisized first try.
I asked the llms to consider follow up 
    "Check your sensitivity list. Check for sign extension when
multiplying 8-bit signed operands into a 32-bit accumulator. Confirm the module synthesizes with Yosys."
but neither found any real issues.

The biggest difference was that the Opus model used implicit sign extension, relying on verilog to preappend the properly signed bits when casting from 16 -> 32 bit.
I found this to be hard to understand at first, so I think the improvement is to make this clearer. But I didn't like how ugly chatgpt approached the same problem. it used a indexing and bit duplication and too many parenthesis to be nice to read.

so I'll just add a comment to make it clear
mac_llm_B.v:21
``` verilog
out <= out + product;
```
becomes
``` verilog
out <= out + product; // out is signed32, implicit sign extension on product(signed8).
```

I also don't like reading the "end else begin" syntax that chatgpt produced. since the body of the if statement is only one line, a simple if-else block would work fine.
mac_llm_A.v:13
``` verilog
always_ff @(posedge clk) begin
    if (rst) begin
        out <= 32'sd0;
    end else begin
        out <= out + {{16{product[15]}}, product};
    end
end
```
becomes like what opus did
``` verilog
always_ff @(posedge clk) begin
    if (rst)
        out <= 32'sd0;
    else
        out <= out + {{16{product[15]}}, product};
end
```



#### YOSYS OUTPUT (very long)
command:
``` bash
yosys -p 'read_verilog -sv mac_correct.v; synth; stat`
```

**alternatively see synth_build/synth_correct.log which excludes submodules**


output:
```

 /----------------------------------------------------------------------------\
 |  yosys -- Yosys Open SYnthesis Suite                                       |
 |  Copyright (C) 2012 - 2026  Claire Xenia Wolf <claire@yosyshq.com>         |
 |  Distributed under an ISC-like license, type "license" to see terms        |
 \----------------------------------------------------------------------------/
 Yosys 0.63 (git sha1 3bc26ff4d055adfbba8b424508ab4a36405ffc0b, g++ 15.2.1 -O2 -flto=auto -ffat-lto-objects -fexceptions -fstack-protector-strong -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -fPIC -O3)

-- Running command `read_verilog -sv mac_correct.v; synth; stat' --

1. Executing Verilog-2005 frontend: mac_correct.v
Parsing SystemVerilog input from `mac_correct.v' to AST representation.
Generating RTLIL representation for module `\mac'.
Successfully finished Verilog frontend.

2. Executing SYNTH pass.

2.1. Executing HIERARCHY pass (managing design hierarchy).

2.2. Executing PROC pass (convert processes to netlists).

2.2.1. Executing PROC_CLEAN pass (remove empty switches from decision trees).
Cleaned up 0 empty switches.

2.2.2. Executing PROC_RMDEAD pass (remove dead branches from decision trees).
Marked 1 switch rules as full_case in process $proc$mac_correct.v:17$2 in module mac.
Removed a total of 0 dead cases.

2.2.3. Executing PROC_PRUNE pass (remove redundant assignments in processes).
Removed 1 redundant assignment.
Promoted 0 assignments to connections.

2.2.4. Executing PROC_INIT pass (extract init attributes).

2.2.5. Executing PROC_ARST pass (detect async resets in processes).

2.2.6. Executing PROC_ROM pass (convert switches to ROMs).
Converted 0 switches.
<suppressed ~1 debug messages>

2.2.7. Executing PROC_MUX pass (convert decision trees to multiplexers).
Creating decoders for process `\mac.$proc$mac_correct.v:17$2'.
     1/1: $0\out[31:0]

2.2.8. Executing PROC_DLATCH pass (convert process syncs to latches).

2.2.9. Executing PROC_DFF pass (convert process syncs to FFs).
Creating register for signal `\mac.\out' using process `\mac.$proc$mac_correct.v:17$2'.
  created $dff cell `$procdff$7' with positive edge clock.

2.2.10. Executing PROC_MEMWR pass (convert process memory writes to cells).

2.2.11. Executing PROC_CLEAN pass (remove empty switches from decision trees).
Found and cleaned up 1 empty switch in `\mac.$proc$mac_correct.v:17$2'.
Removing empty process `mac.$proc$mac_correct.v:17$2'.
Cleaned up 1 empty switch.

2.2.12. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.3. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..
Removed 0 unused cells and 3 unused wires.
<suppressed ~1 debug messages>

2.5. Executing CHECK pass (checking for obvious problems).
Checking module mac...
Found and reported 0 problems.

2.6. Executing OPT pass (performing simple optimizations).

2.6.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.6.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 4 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.6.3. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \mac..
  Creating internal representation of mux trees.
  Evaluating internal representation of mux trees.
  Analyzing evaluation results.
Removed 0 multiplexer ports.
<suppressed ~2 debug messages>

2.6.4. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \mac.
Performed a total of 0 changes.

2.6.5. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 4 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.6.6. Executing OPT_DFF pass (perform DFF optimizations).

2.6.7. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.6.8. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.6.9. Finished fast OPT passes. (There is nothing left to do.)

2.7. Executing FSM pass (extract and optimize FSM).

2.7.1. Executing FSM_DETECT pass (finding FSMs in design).

2.7.2. Executing FSM_EXTRACT pass (extracting FSM from design).

2.7.3. Executing FSM_OPT pass (simple optimizations of FSMs).

2.7.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.7.5. Executing FSM_OPT pass (simple optimizations of FSMs).

2.7.6. Executing FSM_RECODE pass (re-assigning FSM state encoding).

2.7.7. Executing FSM_INFO pass (dumping all available information on FSM cells).

2.7.8. Executing FSM_MAP pass (mapping FSMs to basic logic).

2.8. Executing OPT pass (performing simple optimizations).

2.8.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.8.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 4 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.8.3. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \mac..
  Creating internal representation of mux trees.
  Evaluating internal representation of mux trees.
  Analyzing evaluation results.
Removed 0 multiplexer ports.
<suppressed ~2 debug messages>

2.8.4. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \mac.
Performed a total of 0 changes.

2.8.5. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 4 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.8.6. Executing OPT_DFF pass (perform DFF optimizations).
Adding SRST signal on $procdff$7 ($dff) from module mac (D = $add$mac_correct.v:21$3_Y, Q = \out, rval = 0).

2.8.7. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..
Removed 1 unused cells and 1 unused wires.
<suppressed ~2 debug messages>

2.8.8. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.8.9. Rerunning OPT passes. (Maybe there is more to do..)

2.8.10. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \mac..
  Creating internal representation of mux trees.
  No muxes found in this module.
Removed 0 multiplexer ports.

2.8.11. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \mac.
Performed a total of 0 changes.

2.8.12. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 3 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.8.13. Executing OPT_DFF pass (perform DFF optimizations).

2.8.14. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.8.15. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.8.16. Finished fast OPT passes. (There is nothing left to do.)

2.9. Executing WREDUCE pass (reducing word size of cells).

2.10. Executing PEEPOPT pass (run peephole optimizers).

2.11. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.12. Executing ALUMACC pass (create $alu and $macc cells).
Extracting $alu and $macc cells in module mac:
  creating $macc model for $add$mac_correct.v:21$3 ($add).
  creating $macc model for $mul$mac_correct.v:15$1 ($mul).
  merging $macc model for $mul$mac_correct.v:15$1 into $add$mac_correct.v:21$3.
  creating $macc cell for $add$mac_correct.v:21$3: $auto$alumacc.cc:382:replace_macc$9
  created 0 $alu and 1 $macc cells.

2.13. Executing SHARE pass (SAT-based resource sharing).

2.14. Executing OPT pass (performing simple optimizations).

2.14.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.14.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 3 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.14.3. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \mac..
  Creating internal representation of mux trees.
  No muxes found in this module.
Removed 0 multiplexer ports.

2.14.4. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \mac.
Performed a total of 0 changes.

2.14.5. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 3 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.14.6. Executing OPT_DFF pass (perform DFF optimizations).

2.14.7. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..
Removed 1 unused cells and 1 unused wires.
<suppressed ~2 debug messages>

2.14.8. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.14.9. Rerunning OPT passes. (Maybe there is more to do..)

2.14.10. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \mac..
  Creating internal representation of mux trees.
  No muxes found in this module.
Removed 0 multiplexer ports.

2.14.11. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \mac.
Performed a total of 0 changes.

2.14.12. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 2 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.14.13. Executing OPT_DFF pass (perform DFF optimizations).

2.14.14. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.14.15. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.14.16. Finished fast OPT passes. (There is nothing left to do.)

2.15. Executing MEMORY pass.

2.15.1. Executing OPT_MEM pass (optimize memories).
Performed a total of 0 transformations.

2.15.2. Executing OPT_MEM_PRIORITY pass (removing unnecessary memory write priority relations).
Performed a total of 0 transformations.

2.15.3. Executing OPT_MEM_FEEDBACK pass (finding memory read-to-write feedback paths).

2.15.4. Executing MEMORY_BMUX2ROM pass (converting muxes to ROMs).

2.15.5. Executing MEMORY_DFF pass (merging $dff cells to $memrd).

2.15.6. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.15.7. Executing MEMORY_SHARE pass (consolidating $memrd/$memwr cells).

2.15.8. Executing OPT_MEM_WIDEN pass (optimize memories where all ports are wide).
Performed a total of 0 transformations.

2.15.9. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.15.10. Executing MEMORY_COLLECT pass (generating $mem cells).

2.16. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.17. Executing OPT pass (performing simple optimizations).

2.17.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.17.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 2 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.17.3. Executing OPT_DFF pass (perform DFF optimizations).

2.17.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.17.5. Finished fast OPT passes.

2.18. Executing MEMORY_MAP pass (converting memories to logic and flip-flops).

2.19. Executing OPT pass (performing simple optimizations).

2.19.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.19.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 2 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.19.3. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \mac..
  Creating internal representation of mux trees.
  No muxes found in this module.
Removed 0 multiplexer ports.

2.19.4. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \mac.
Performed a total of 0 changes.

2.19.5. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 2 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.19.6. Executing OPT_SHARE pass.

2.19.7. Executing OPT_DFF pass (perform DFF optimizations).

2.19.8. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.19.9. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.19.10. Finished fast OPT passes. (There is nothing left to do.)

2.20. Executing TECHMAP pass (map to technology primitives).

2.20.1. Executing Verilog-2005 frontend: /usr/bin/../share/yosys/techmap.v
Parsing Verilog input from `/usr/bin/../share/yosys/techmap.v' to AST representation.
Generating RTLIL representation for module `\_90_simplemap_bool_ops'.
Generating RTLIL representation for module `\_90_simplemap_reduce_ops'.
Generating RTLIL representation for module `\_90_simplemap_logic_ops'.
Generating RTLIL representation for module `\_90_simplemap_compare_ops'.
Generating RTLIL representation for module `\_90_simplemap_various'.
Generating RTLIL representation for module `\_90_simplemap_registers'.
Generating RTLIL representation for module `\_90_shift_ops_shr_shl_sshl_sshr'.
Generating RTLIL representation for module `\_90_shift_shiftx'.
Generating RTLIL representation for module `\_90_fa'.
Generating RTLIL representation for module `\_90_lcu_brent_kung'.
Generating RTLIL representation for module `\_90_alu'.
Generating RTLIL representation for module `\_90_macc'.
Generating RTLIL representation for module `\_90_alumacc'.
Generating RTLIL representation for module `$__div_mod_u'.
Generating RTLIL representation for module `$__div_mod_trunc'.
Generating RTLIL representation for module `\_90_div'.
Generating RTLIL representation for module `\_90_mod'.
Generating RTLIL representation for module `$__div_mod_floor'.
Generating RTLIL representation for module `\_90_divfloor'.
Generating RTLIL representation for module `\_90_modfloor'.
Generating RTLIL representation for module `\_90_pow'.
Generating RTLIL representation for module `\_90_pmux'.
Generating RTLIL representation for module `\_90_demux'.
Generating RTLIL representation for module `\_90_lut'.
Generating RTLIL representation for module `$connect'.
Generating RTLIL representation for module `$input_port'.
Successfully finished Verilog frontend.

2.20.2. Continuing TECHMAP pass.
Using extmapper maccmap for cells of type $macc_v2.
  add \a * \b (8x8 bits, signed)
  add \out (32 bits, signed)
Using extmapper simplemap for cells of type $sdff.
Using template $paramod\_90_fa\WIDTH=32'00000000000000000000000000100000 for cells of type $fa.
Using template $paramod$fbc7873bff55778c0b3173955b7e4bce1d9d6834\_90_alu for cells of type $alu.
Using extmapper simplemap for cells of type $and.
Using extmapper simplemap for cells of type $not.
Using extmapper simplemap for cells of type $or.
Using extmapper simplemap for cells of type $xor.
Using template $paramod\_90_lcu_brent_kung\WIDTH=32'00000000000000000000000000100000 for cells of type $lcu.
Using extmapper simplemap for cells of type $pos.
Using extmapper simplemap for cells of type $mux.
No more expansions possible.
<suppressed ~460 debug messages>

2.21. Executing OPT pass (performing simple optimizations).

2.21.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.
<suppressed ~423 debug messages>

2.21.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 1569 cells of `\mac'.
Finding duplicate cells in `\mac'.
Computing hashes of 1405 cells of `\mac'.
Finding duplicate cells in `\mac'.
Computing hashes of 1302 cells of `\mac'.
Finding duplicate cells in `\mac'.
Computing hashes of 1228 cells of `\mac'.
Finding duplicate cells in `\mac'.
Computing hashes of 1174 cells of `\mac'.
Finding duplicate cells in `\mac'.
Computing hashes of 1157 cells of `\mac'.
Finding duplicate cells in `\mac'.
Computing hashes of 1125 cells of `\mac'.
Finding duplicate cells in `\mac'.
Computing hashes of 1093 cells of `\mac'.
Finding duplicate cells in `\mac'.
Computing hashes of 1077 cells of `\mac'.
Finding duplicate cells in `\mac'.
Computing hashes of 1047 cells of `\mac'.
Finding duplicate cells in `\mac'.
<suppressed ~1566 debug messages>
Removed a total of 522 cells.

2.21.3. Executing OPT_DFF pass (perform DFF optimizations).

2.21.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..
Removed 57 unused cells and 146 unused wires.
<suppressed ~58 debug messages>

2.21.5. Finished fast OPT passes.

2.22. Executing ABC pass (technology mapping using ABC).

2.22.1. Extracting gate netlist of module `\mac' to `<abc-temp-dir>/input.blif'..

2.22.1.1. Executed ABC.
Extracted 958 gates and 1006 wires to a netlist network with 48 inputs and 32 outputs.
Running ABC script: <abc-temp-dir>/abc.script
ABC: ======== ABC command line "source <abc-temp-dir>/abc.script"
ABC: + read_blif <abc-temp-dir>/input.blif 
ABC: + read_library <abc-temp-dir>/stdcells.genlib 
ABC: + strash 
ABC: + dretime 
ABC: + map 
ABC: + write_blif <abc-temp-dir>/output.blif 

2.22.1.2. Re-integrating ABC results.
ABC RESULTS:               AND cells:       46
ABC RESULTS:            ANDNOT cells:      330
ABC RESULTS:               MUX cells:        1
ABC RESULTS:              NAND cells:       32
ABC RESULTS:               NOR cells:       66
ABC RESULTS:               NOT cells:       17
ABC RESULTS:                OR cells:       49
ABC RESULTS:             ORNOT cells:       89
ABC RESULTS:              XNOR cells:       86
ABC RESULTS:               XOR cells:      251
ABC RESULTS:        internal signals:      926
ABC RESULTS:           input signals:       48
ABC RESULTS:          output signals:       32
Removing temp directory.
Removing global temp directory.

2.23. Executing OPT pass (performing simple optimizations).

2.23.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.23.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Computing hashes of 999 cells of `\mac'.
Finding duplicate cells in `\mac'.
Removed a total of 0 cells.

2.23.3. Executing OPT_DFF pass (perform DFF optimizations).

2.23.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..
Removed 0 unused cells and 210 unused wires.
<suppressed ~1 debug messages>

2.23.5. Finished fast OPT passes.

2.24. Executing HIERARCHY pass (managing design hierarchy).

2.25. Printing statistics.

=== mac ===

        +----------Local Count, excluding submodules.
        | 
      946 wires
     1177 wire bits
        5 public wires
       50 public wire bits
        5 ports
       50 port bits
      999 cells
      330   $_ANDNOT_
       46   $_AND_
        1   $_MUX_
       32   $_NAND_
       66   $_NOR_
       17   $_NOT_
       89   $_ORNOT_
       49   $_OR_
       32   $_SDFF_PP0_
       86   $_XNOR_
      251   $_XOR_

2.26. Executing CHECK pass (checking for obvious problems).
Checking module mac...
Found and reported 0 problems.

3. Printing statistics.

=== mac ===

        +----------Local Count, excluding submodules.
        | 
      946 wires
     1177 wire bits
        5 public wires
       50 public wire bits
        5 ports
       50 port bits
      999 cells
      330   $_ANDNOT_
       46   $_AND_
        1   $_MUX_
       32   $_NAND_
       66   $_NOR_
       17   $_NOT_
       89   $_ORNOT_
       49   $_OR_
       32   $_SDFF_PP0_
       86   $_XNOR_
      251   $_XOR_

End of script. Logfile hash: 2b8dba59a9, CPU: user 0.13s system 0.01s, MEM: 20.26 MB peak
Yosys 0.63 (git sha1 3bc26ff4d055adfbba8b424508ab4a36405ffc0b, g++ 15.2.1 -O2 -flto=auto -ffat-lto-objects -fexceptions -fstack-protector-strong -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -fPIC -O3)
Time spent: 53% 1x abc (0 sec), 10% 17x opt_expr (0 sec), ...
```