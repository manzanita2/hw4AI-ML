// CVFPU minimal compile-order list for direct fpnew_fma_multi instantiation.
//
// Goal: bring up just the FMA unit (fpnew_fma_multi) so we can wrap it inside
// project/m3/rtl/pe_fpnew.sv. Skip fpnew_top + opgroup_block since those drag
// in DIVSQRT, NONCOMP and CAST sources we don't need for the systolic PE.
//
// Order matters: package files first, then their consumers.
//
// Include path needed at compile time:
//   -Iproject/external/cvfpu/src/common_cells/include
// (fma_multi & friends use `include "common_cells/registers.svh")
//
// All paths are relative to the repo root (project/).

project/external/cvfpu/src/common_cells/src/cf_math_pkg.sv
project/external/cvfpu/src/common_cells/src/lzc.sv
project/external/cvfpu/src/fpnew_pkg.sv
project/external/cvfpu/src/fpnew_classifier.sv
project/external/cvfpu/src/fpnew_rounding.sv
project/external/cvfpu/src/fpnew_fma_multi.sv
