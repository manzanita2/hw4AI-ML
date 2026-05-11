# CLLM — Hand calculations (Codefest 6, task 5)

Crossbar MAC definition (per handout):

\[
\text{out}[j] = \sum_{i=0}^{3} \text{weight}[i][j] \times \text{in}[i]
\]

Row index \(i\) is the input line; column index \(j\) is the output line.

## Weight matrix \(W[i][j]\)

From the assignment (four rows \(i = 0\ldots 3\), four columns \(j = 0\ldots 3\)):

| \(i\) \\ \(j\) | 0 | 1 | 2 | 3 |
|----------------|---|---|---|---|
| 0 | +1 | −1 | +1 | −1 |
| 1 | +1 | +1 | −1 | −1 |
| 2 | −1 | +1 | +1 | −1 |
| 3 | −1 | −1 | −1 | +1 |

As nested lists (row-major by \(i\)):

`[[1,−1,1,−1], [1,1,−1,−1], [−1,1,1,−1], [−1,−1,−1,1]]`

## Input vector \(\text{in}[i]\)

\[
\text{in} = [10,\ 20,\ 30,\ 40]
\]

So \(\text{in}[0]=10\), \(\text{in}[1]=20\), \(\text{in}[2]=30\), \(\text{in}[3]=40\).

## Column-by-column sums

### \(j = 0\)

\[
\begin{aligned}
\text{out}[0] &= (+1)(10) + (+1)(20) + (−1)(30) + (−1)(40) \\
&= 10 + 20 - 30 - 40 \\
&= -40
\end{aligned}
\]

### \(j = 1\)

\[
\begin{aligned}
\text{out}[1] &= (−1)(10) + (+1)(20) + (+1)(30) + (−1)(40) \\
&= -10 + 20 + 30 - 40 \\
&= 0
\end{aligned}
\]

### \(j = 2\)

\[
\begin{aligned}
\text{out}[2] &= (+1)(10) + (−1)(20) + (+1)(30) + (−1)(40) \\
&= 10 - 20 + 30 - 40 \\
&= -20
\end{aligned}
\]

### \(j = 3\)

\[
\begin{aligned}
\text{out}[3] &= (−1)(10) + (−1)(20) + (−1)(30) + (+1)(40) \\
&= -10 - 20 - 30 + 40 \\
&= -20
\end{aligned}
\]

## Expected outputs (golden vector)

| \(j\) | \(\text{out}[j]\) |
|-------|-------------------|
| 0 | **−40** |
| 1 | **0** |
| 2 | **−20** |
| 3 | **−20** |

These values are what `codefest/cf06/hdl/crossbar_tb.sv` checks after applying the weights and inputs above.
