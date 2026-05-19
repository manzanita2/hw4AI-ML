I am currently concerned that my project is too simple. as it is largely just a systolic array.
the current HDL implementation does not have the architecture I want, missing cache and a dedicated state machine block.
I am unsure of my HW/SW boundary, it is currently only one convolution out of the many that RAFT uses, but I think that's acceptable.
I am currently considering the clock layout and weather 300MHz is a reasonable target. In cf07 I encountered issues due to a high clock. I'm concerned this could effect my co-processor design.