### ResNet18 Analysis

##### 5 most MAC intensive layers 

after the first `Conv2d`, many subsequent layers are tied for the next most MAC operations at 115 Mega Macs. I opted to order them by depth and idx to match how they were displayed by `torchinfo`.

| Layer (depth-idx) | Operation | \#Mac operations | \#Parameters |
| ----------------- | --------- | ---------------- | ------------ |
| 1-1               | Conv2d    | 118 Mega         | 9,408        |
| 3-1               | Conv2d    | 115 Mega         | 36,864       |
| 3-4               | Conv2d    | 115 Mega         | 36,864       |
| 3-7               | Conv2d    | 115 Mega         | 36,864       |
| 3-10              | Conv2d    | 115 Mega         | 36,864       |


##### arithmetic intensity of 1-1

`FLOPs = 2 × MACs = 2 × 118 Mega Macs = 236 Mega FLOPs`

assuming 32 bit floats
Bytes = `4 × (input_elements + weight_elements + output_elements)`

`input = 150,528 elements`
`output = 802,816 elements`
`weights = 9,408 elements`
total floats = `962,752`

Bytes = `floats * 4 = 3,851,008`


AI = `FLOPs / Bytes = 61.3 FLOPs/Byte`

***AI = 61.3 FLOPs/Byte***


