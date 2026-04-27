## CMAN -- int8 symmetric quantization
1) find scale factor
$$
S = max(abs(W)) / 127
$$
$$
W = 
\begin{bmatrix}
 0.85 & -1.20 & 0.34 & 2.10 \\
 -0.07 & 0.91 & -1.88 & 0.12 \\
 1.55 & 0.03 & -0.44 & -2.31 \\
 -0.18 & 1.03 & 0.77 & 0.55
\end{bmatrix}
$$
largest val of W is $-2.31$ so
$$S = 2.31/127 = 0.01819$$
2) Quantize
$$ W_q = round(W/S) $$ and clamp values between −128 and 127. \
Qunatized matrix is:
$$
W_q =
\begin{bmatrix}
47	&-66&	19&	115 \\
-4	&50&	-103&	7 \\
85	&2	&-24&	-127 \\
-10	&57&	42&	30 \\
\end{bmatrix}
$$
3) Dequantize

dequantized matrix is
$$
W_{deq} =
\begin{bmatrix}
0.85493	&-1.20054&	0.34561&	2.09185 \\
-0.07276&	0.9095&	-1.87357&	0.12733 \\
1.54615&	0.03638&	-0.43656&	-2.31013 \\
-0.1819&	1.03683&	0.76398&	0.5457
\end{bmatrix}
$$
4) Error Analysis

find error for each element with $|W-W_{deq}|$
$$
W_{err} =
\begin{bmatrix}
-0.00493	&0.00054&	-0.00561&	0.00815 \\
0.00276	&0.0005	&-0.00643	&-0.00733 \\
0.00385	&-0.00638	&-0.00344	&0.00013 \\
0.0019&	-0.00683&	0.00602&	0.0043
\end{bmatrix}
$$
largest error is 0.00815 which had the value of 2.1 in the first row and last column \

MAE(mean absolute error) equation:
$$
MAE = \frac{1}{n}\sum_{k=1}^{n}{|y_k-\hat{y_k}|}
$$
with n = 16
the total is $$ MAE = 0.0043188 $$

5) bad scale experiment

repeat previous steps for $S_{bad}=0.01$ (too small)

$$
W_{q\ bad} =
\begin{bmatrix}
85	&-120&	34&	127 \\
-7	&91&	-128&	12 \\
127	&3&	-44&	-128 \\
-18	&103&	77	&55
\end{bmatrix}
$$
$$
W_{descaled\ bad} =
\begin{bmatrix}
0.85	&-1.20&	0.34&	1.27 \\
-0.07	&0.91	&-1.28&	0.12 \\
1.27	&0.03	&-0.44	&-1.28 \\
-0.18	&1.03	&0.77&	0.55 \\
\end{bmatrix}
$$
$$
W_{err\ bad} =
\begin{bmatrix}
0.00	&0.00&	0.00&	0.83 \\
0.00	&0.00	&-0.60&	0.00 \\
0.28	&0.00&	0.00&	-1.03 \\
0.00	&0.00	&0.00&	0.00
\end{bmatrix}
$$
$$ MAE = 0.17125 $$
When the scaling factor is too small, it causes the quantized values to grow too large and get clamped. This causes large error.s