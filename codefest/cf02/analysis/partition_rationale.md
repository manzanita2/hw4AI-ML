### a)
The target kernel for the RAFT optical flow detection model I chose is the Conv2D layer with:
- Input shape: `[4, 64, 260, 480]`
- Output shape: `[4, 64, 260, 480]`
- Parameters: `36,928`
- Mult-Adds: `18,434,457,600`
as convolutions take up 53% of CPU time and this particular layer operation is repeated many times.
This kernel has an algorithmic intensity of 144 FLOPs/byte.
On my hardware (ridge point = ~11 FLOPs/byte), this puts the target kernel well into the compute-bound region by an order of magnitude.
This presents great opportunity for performance gains with more specialized compute for this task, from 380 GFLOPs/sec to around 1 TFLOP/sec, around a 3x improvement.

### b)
I do not plan on accelerating any other part of the algorithm other than this kernel.
The software will continue to handle loading images from the proper source and other logic.
If improving the speed of this kernel isn't enough I might consider adding other layers to the kernel.

### c)
Given the performance target of about 1 TFLOP/sec, and with my algorithm's AI of 144,
the minimum memory bandwidth required is about (1024GFLOP/s)/(144FLOPS/Byte) = 7.11 GB/sec.
This data rate is achievable with AXI4-Stream, and will not be interface bound.

### d)
The kernel is currently under the "compute-bound" region of the roofline plot, but it's so far from the top it's hard to actually call it compute-bound.
I expect my accelerator design to improve performance greatly and bring it closer to the roofline; however, I still don't expect it to be completely compute-bound.
There will likely still be some room to improve even after the accelerator is implemented.


### host platform
the host is intended to be some kind of embedded system, single board computer system that requires dedicated and efficient processing for computer vision purposes.