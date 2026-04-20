FP32 = 4bytes , N=32


Tasks
1. Naive triple loop (ijk order): for computing one output element C[i][j] = Σ A[i][k]×B[k][j], how many times is each element of B accessed? Across the full N×N output, how many total element accesses are made to A and B? Compute total DRAM traffic in bytes for the full matrix multiply, assuming every element access goes to DRAM (no data reuse).

each element of B is accessed N times = 32 times
total element accesses for A and B are both N per element, times N^2 elements = N^3 accesses = 32^3 = 32768.
a full matrix multiply has N^3 acceses for A, N^3 acceses for B, and only N^2 for C since each element is only written to once.
so 2N^3+N^2 is the total element acceses, so total traffic is 2(32)^3  = 65536 numbers * 4 bytes/number = 262144 bytes = 262Kb


2. Tiled loop (tile size T=8): the computation is blocked into T×T tiles. Compute the number of DRAM loads for A and B tiles across the full computation. Compute total DRAM traffic in bytes.

each element of A and B is loaded only once, so total reads from A and B are both N^2 so total is 2N^2 = 2*(32)^2 = 2048 accesses -> 2048 * 4 bytes/number = 8192 bytes

3. Compute the ratio of naive DRAM traffic to tiled DRAM traffic. Explain in one sentence why this ratio equals N/T.

ratio of naive to tiled 262144 / 8192 = 32.
since each element is naively accessed N times, accessing each element only once, with tiling, the traffic reduces by a factor of N (=32) 

4. If DRAM bandwidth is 320 GB/s and compute is 10 TFLOPS, compute execution time for the naive case (memory-bound) and the tiled case. For each, state whether the bottleneck is compute or memory

ridge point = (FLOPs/sec)/(Bytes/sec) = 10,000Gflops/320Gb = 31.25

naive:
	FLOPS = $2N^3 = 2*32^3 = 65536$ FLOPs 
	Bytes = $3*N^2 * 4 = 3*(32)^2*4 =12,288$ bytes
	AI = $\frac{65536FLOPs}{262144 bytes} = 0.25$ Flops/byte
	memory limited because AI < 31.25
	performance = 0.25Flops/byte * 320GB/s = 80 GFLOPs/sec
	execution time = bytes / performance = 65536 Flops / 80 GFlops/sec = 819.2 micro seconds


Tiled
	FLOPS = $2N^3 = 65536$ FLOPs     // I think?
	Bytes = 8192 bytes
	AI = $\frac{65536 FLOPs}{8192 bytes} = 8$ Flops/byte
	more compute than memory, still memory bound because less than 31.25 FLOPS/byte.
	perfromance = 8 Flops/byte * 320GB/s = 2560 GFLOPs/sec
	execution time = bytes / performance = 65536 Flops / 2560 Gflops/sec = 25.6 micro seconds

