1) 

$R = 1024*50 = 51200 \frac{spike}{sec}$



$B = 51200 * 20 = 1024000 \frac{bits}{sec}$

$MB/s = \frac{1024000}{10^6} = 1.024



all three interfaces would work,

SPI is the lowest complexity to implement.

I2C is the least bandwidth.  



$25% * B = 5120 bits$

instantaneous:

\frac{25%*B}{0.001sec} = 5120000\frac{bits}{sec} = 5.12MB/sec$

5.12MB/sec > 3.4MB/s so i2C won't work.

min buffer depth is the difference between the  max instantaneous BW and the interfaces instantaneous BW.  
interface max inst BW:  
3.4MB/s for 1ms = 3400 Bytes

5100 - 3400 = 1720 bytes required for buffer.  

burst to mean ratio = $\frac{5.12}{1.024} = 5$

i2c cannot handle the burst without buffering.  



frame-based:

bits/sec = $N*F*1 = 1024 **10^3 * 1 = 1.024MB/sec$

AER based:

bits/sec = 1.024MB/sec as caclulated above

ratio = $\frac{1.024MB/sec}{1.024MB/sec} = 1 times ratio$

setting the rates equal:

$N*F_{aer}20 = NF_{crossover}20$ *  
*$F_{aer} = 50hz$ given*  
*$F_{crossover} = \frac{N50hz*20}{N*20}$    
$F_{crossover} = 50hz$  
  
the current frequency is correct, both bandwidths are equal