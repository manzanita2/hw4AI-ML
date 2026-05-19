I am not happy with the current layout of my HDL for my co-processor so I decided to synthisize the fallback from cf06.
I plan on attempting synthesis for M3 ASAP, however I have a lot to get through this week and may not be able to until friday.
when designing my co-processor I was hoping for a fast clock of about 300MHz to allow for high datarates and a realtime video processing so I initially tried that speed for the crossbar, however it failed so I had to reduce the speed.
I am concerned this will be an issue for my larger design.
I might have misunderstood the clock requirments for processing vs interface speed. I may have to use clock dividers to manage this, not sure yet.