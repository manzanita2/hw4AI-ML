Codefest 6
##cman
A) ideal I_col0 calculation

Current through col0 is 1v over 1kohms.
Current flows from row0 to col1 but nothing comes back into col0, so it's ignored here.
This becomes 1v / 1kohm = 1mA

The current through col0 for an ideal case is 1mA

B) sneak path read

Tow with col1 and row1 floating, the current through the sneak path is considerable.
the current becomes 1v across the 1k in parralel with the series combination of the other resistors = 2+2+1=5k.
This comes out to 1v/1kohm + 1v/5kohm = 1.2mA.
This can be used to find the voltages for col1 and row1.

Vcol1 = Vcol0 - VR[0][1]
VR[0][1] = 0.2mA * 2kohm = 0.4V
Vcol1 = Vcol0 - 0.4V = 0.6V

Vrow1 = Vcol1 - VR[1][1]
VR[1][1] = 0.2mA * 1kohm = 0.2V
Vro1 = 0.6V - 0.2V = 0.4V

The floating voltages settle at 0.6V for col1 and 0.4V for row1.
This agrees with KVL aswell (0.6 + 0.4 = 1.0).

C) explaination

The sneak path causes un-intended current to flow. this current reflects the architecture of the array and not the intended matrix operation, This leads to small inaccuracies.