1. What are you trying to do? Articulate your objectives using absolutely no jargon.

Design hardware for the RAFT optical flow algorithm, targeting aten::mkldnn_convolution (and possbily aten::mul and  aten::cat) as the kernel. The goal of accelerating this algorithm is to help make robots understand their environment better, faster - specifically to aid the object recognition needed for pathfinding, spatial awareness, and navigation.


2. How is it done today, and what are the limits of current practice?



SLAM is a very well researched field, thus many hardware accelerators and FPGA configurations exist to make SLAM faster and more efficient. Examples are Apple VR headsets, eSLAM, Navion, HERO, and Intel RealSense t265. These are all hardware implementations aimed at making SLAM faster with less power on custom hardware. Yet, more intelligent pathfinding and awareness can be gained by integrating deep learning into SLAM algorithms, which these implementations cannot support. Currently no specialized accelerators exist to support deep learning SLAM which means general purpose compute must be used, which isn't an option in edge applications.

Current approaches (my cpu benchmark) take approximately 5.3s to estimate optical flow from 2 frames, far too slow for real time. The kernel in question takes approximately 2.8S of that time. with another 204ms taken by aten::mul and 244ms taken by aten::cat respectively.

3. What is new in your approach and why do you think it will be successful?

A deep learning SLAM accelerator is likely to succeed because there is no competition. classical SLAM accelerators exist, but learned SLAM front-ends are increasingly replacing hand-crafted ones, yet no dedicated hardware exists for them. A Dedicated accelerator for this model could provide orders of magnitude improved performance, possibly real-time.

Through profiling I observed that over 50% of processor time was spend on one type of convolution operation. There is a lot of room to make this faster, which could change what robotics applications this is a viable option for. the ulitmate goal is to reduce execution of the algorithm to under 1/60th of a second for realtime operation.
The arithmetic intensity of my kernel is 144, and currently prerforms at 380 GFLOPs/sec. There is lots of room for improvement to bring this up to the theoretical limit of 1,002GFLOPs/sec.