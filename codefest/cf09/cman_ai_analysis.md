

dominant kernel is standard Conv2d

choosing input `[4, 64, 260, 480]` output `[4, 64, 260, 480]` params `36,928` MACS `18,434,457,600`

`my accelerator uses brainfloat16`



FLOPS = 2 x MACS = $2 * 18,434,457,600 = 36.869GFLOPS  
not sure what you mean by "designs operating point", above is the hot kernel from the RAFT algorithm



input numbers = MACs = 18.434 billion  
weight numbers = MACs = 18.434 billion  
output numbers = 4  *64*  260  *480 = 32.949 million*  
*total numbers = 18.434e9 + 18.434e9 + 32.949e6 = 36.901e9 numbers*  
*(I'm using bfloat16, as my design does, 2 bytes per number)*  
*total bytes = $numbers*  2 = 73.802 Gb

standard convolution has GEMM-style weight re-use, so bytes can be calculated by using input/output/weight dimensions.

inputs bytes = N*C_{in}H_{in}W_{in} 2= 464260480*2=63.898Mbweights = (C_{out}*C_{in}k_HK_W+bias)2=(6464*3*3+64)2=73.727kboutput bytes = NC_{out}H_{out}W_{out}2=464260480*2=63.898Mbtotal bytes with reuse = input + weights + output = 63.898Mb + 73.727kb + 63.898Mbtotal=127.87Mb



AI*{no_reuse} = flops / bytes = 36.869GFLOPs / 73.802 Gbytes = 0.49957 flops/byte*  
*AI*{with_reuse} = flops/bytes = 36.869GFLOPs / 127.87Mb = 288 flops/byte (has increased since earlier calculation due to switching to bf16, was 144)

currently targeting 16x16 compute core dimensions  
16x16 = 256 MACs/cycle = 512 FLOP/s cycle  
I have achieved 220MHz with yosys at least.  
512 * 220e6 = 112.64 GFLOP/sec



- Is your design currently limited by your hardware interface bandwidth, on-chip memory bandwidth, or compute units?  
if I implement cache and re-use I will be squarely in the compute-bound region. my compute is currently heavily limited by the number of compute units, as I don't think I can increase frequency further. I have revised my compute unit dimensions from 48x48 to 16x16
- What is the single highest-leverage change to improve performance at this point?  
increasing compute units would be the most straight forward way.

