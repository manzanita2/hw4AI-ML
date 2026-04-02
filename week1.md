#### wed Apr 1st 2026

## CMAN

$W_{layer-layer} = i*h_1 + \sum_{k=1}^{n-1}(h_k*h_{k+1})$
first layer


##### a)
For each layer, compute the number of multiply-accumulate operations (MACs). Show the formula
and the substituted values.

| layer number | layer size in neurons | \#input connections |
| ------------ | --------------------- | ------------------- |
| 1            | 784                   | 0                   |
| 2            | 256                   | 784\*256            |
| 3            | 128                   | 256*128             |
| 4            | 10                    | 128\*10             |
| total        | 1178                  | 234752              |
32 bytes to store values in each neuron

##### b)
\#macs for oneward pass = \#inter-layer connections = 234752 macs
##### c)
\#trainable = \#inter-layer connections = 234752 params
##### d)
\#bytes ~ \#inter-layer connections * 4 bytes/weight = 939008 bytes
##### e)
memory to store all layer inputs and outputs	mem = \#neurons * 4 bytes = 1178 * 4 = 4712 bytes
##### f)
$$
\frac{2*{macs}}{{weights}*4 + neurons * 4}
= \frac{2*{234752}}{{234752}*4 + 4712 * 4}
= 0.497503497
$$
*in flops/byte*

## CLLM


