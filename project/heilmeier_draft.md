1. What are you trying to do? Articulate your objectives using absolutely no jargon.

Design hardware to make robots understand their environment better, faster - specifically the object recognition needed for pathfinding, spatial awareness, and navigation.


2. How is it done today, and what are the limits of current practice?

SLAM is a very well researched field, thus many hardware accelerators and FPGA configurations exist to make SLAM faster and more efficient. Examples are Apple VR headsets, eSLAM, Navion, HERO, and Intel RealSense t265. These are all hardware implementations aimed at making SLAM faster with less power on custom hardware. Yet, more intelligent pathfinding and awareness can be gained by integrating deep learning into SLAM algorithms, which these implementations cannot support. Currently no specialized accelerators exist to support deep learning SLAM which means general purpose compute must be used, which isn't an option in edge applications.


3. What is new in your approach and why do you think it will be successful?

A deep learning SLAM accelerator is likely to succeed because there is no competition. classical SLAM accelerators exist, but learned SLAM front-ends are increasingly replacing hand-crafted ones, yet no dedicated hardware exists for them.