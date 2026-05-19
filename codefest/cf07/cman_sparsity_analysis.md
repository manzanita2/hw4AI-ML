a) four expressions for dense and sparse compute/memory;
    Dense MVM compute: $2N^2$
    dense memory bytes: $4N^2$
    sparse compute: $(1-s)*2*N^2$
    sparse memory bytes: $(1-s)*N^2*8+4*(N+1)$

(b) FLOPs speedup expression and s for 2× speedup;

    $2=x=\frac{2(512)^2}{2(512)^2*(1-s)}=\frac{1}{1-s}
    solving for s:
    $s=0.5$ when the speedup $x=2$
    
(c) memory breakeven sparsity with derivation;

    set dense bytes equal to sparse bytes
    $4*512^2=(1-s)*512^2*8+4*513$
    solve for s
    $1-s=\frac{4*512^2-4*513}{512^2*8}=0.499$
    evaluate
    $s=0.501$

(d) end-to-end speedup at s=0.9 for memory-bound case

    without sparsity:
    $4*512^2 = 1048576 bytes$
    @320GB/sec
   
    t = bytes / bandwidth = 3.2768us
    
    with sparsity:
    $(1-0.9)*512^2*8+4*513 = 211767.2 bytes$
    t = bytes / bandwidth = 662ns

    speedup ratio = slow/fast = 3.27us/662ns ~= 4.94 times improvement
