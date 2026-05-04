"""cocotb harness for `mul_bf16.sv` (combinational bf16 * bf16 -> fp32).

Hand-picked edge cases. Each one names the SV branch it exercises so a
future RTL change either keeps the case green or produces a clear, named
failure. No generic Python emulator -- expected outputs come from Python
`struct` arithmetic on exactly-representable inputs (no rounding fires)
plus hard-coded sentinel words for the subnormal / overflow / underflow
paths.

Branches covered (mul_bf16.sv lines 100-113):
    out = signed_zero        when a_zero || b_zero      (lines 101-103)
    out = signed_zero        when exp_calc[9]           (lines 104-106, underflow)
    out = signed_inf         when exp_calc > 254        (lines 107-109, overflow)
    out = packed normal      otherwise                  (lines 110-112)

Plus the two `mant_norm` paths in mul_bf16.sv lines 86-88:
    mant_prod[15] == 0  ->  shift left 9, no exp bump
    mant_prod[15] == 1  ->  shift left 8, exp bumps by 1

Run:
    make TEST=mul_bf16
"""

import struct

import cocotb
from cocotb.triggers import Timer


def f32_bits(x: float) -> int:
    """Pack a Python float as fp32 bits."""
    return struct.unpack("<I", struct.pack("<f", x))[0]


def bf16_bits(x: float) -> int:
    """bf16 = upper 16 bits of fp32 (truncation, matches DUT's fp32_to_bf16)."""
    return f32_bits(x) >> 16


# Sentinel fp32 bit patterns used by branches that don't agree with the
# Python helper (signed inf, signed zero from sign-XOR of operands, etc.)
F32_POS_INF  = 0x7F800000
F32_NEG_INF  = 0xFF800000
F32_POS_ZERO = 0x00000000
F32_NEG_ZERO = 0x80000000


# bf16 sentinels.
BF16_MAX_NORMAL_POS = 0x7F7F   # +(1 + 127/128) * 2^127
BF16_MAX_NORMAL_NEG = 0xFF7F   # -(1 + 127/128) * 2^127
BF16_MIN_NORMAL_POS = 0x0080   # +1.0 * 2^-126
BF16_SUBNORMAL_TINY = 0x0001   # exp=0, mant=1 -- treated as +0 by mul_bf16


# Each entry: (label, a_bits, b_bits, expected_out_bits)
CASES = [
    # ---------- normal product, mant_prod[15] == 0 path -------------------
    ("2.0 * 3.0 = 6.0  [normal, no exp bump]",
     bf16_bits(2.0), bf16_bits(3.0), f32_bits(6.0)),

    ("1.5 * 2.5 = 3.75  [normal, no exp bump]",
     bf16_bits(1.5), bf16_bits(2.5), f32_bits(3.75)),

    # ---------- mantissa overflow normalize, mant_prod[15] == 1 path ------
    # 1.5 * 1.5 = 2.25 crosses the 2.0 boundary, so mant_prod top bit is
    # set and the SV bumps the exponent (mul_bf16.sv lines 86-88).
    ("1.5 * 1.5 = 2.25  [mant_prod[15]==1, exp bumps +1]",
     bf16_bits(1.5), bf16_bits(1.5), f32_bits(2.25)),

    # ---------- sign matrix -----------------------------------------------
    # Verifies sign = sa XOR sb.
    ("(+1.5) * (+2.5) = +3.75",
     bf16_bits(+1.5), bf16_bits(+2.5), f32_bits(+3.75)),
    ("(-1.5) * (+2.5) = -3.75",
     bf16_bits(-1.5), bf16_bits(+2.5), f32_bits(-3.75)),
    ("(+1.5) * (-2.5) = -3.75",
     bf16_bits(+1.5), bf16_bits(-2.5), f32_bits(-3.75)),
    ("(-1.5) * (-2.5) = +3.75",
     bf16_bits(-1.5), bf16_bits(-2.5), f32_bits(+3.75)),

    # ---------- signed zero handling --------------------------------------
    # a_zero || b_zero branch. Sign of result is sa XOR sb regardless of
    # which side is zero.
    ("(+0) * 5.0 = +0",
     0x0000, bf16_bits(5.0), F32_POS_ZERO),
    ("(-0) * 5.0 = -0",
     0x8000, bf16_bits(5.0), F32_NEG_ZERO),
    ("5.0 * (+0) = +0",
     bf16_bits(5.0), 0x0000, F32_POS_ZERO),
    ("5.0 * (-0) = -0",
     bf16_bits(5.0), 0x8000, F32_NEG_ZERO),

    # ---------- subnormal flush on input ----------------------------------
    # bf16 with exp == 0 and mant != 0 is a subnormal. The SV's a_zero /
    # b_zero gates (lines 59-60) ignore the mantissa and treat any
    # exp-zero operand as zero.
    ("subnormal(0x0001) * 2.0 = +0  [subnormal flush]",
     BF16_SUBNORMAL_TINY, bf16_bits(2.0), F32_POS_ZERO),

    # ---------- overflow saturate to signed inf ---------------------------
    # max-normal-bf16 * 2.0 -> exp_calc = 254 + 128 - 127 = 255 > 254,
    # so the SV takes the overflow branch (lines 107-109) and outputs
    # signed inf with sign = sa XOR sb.
    ("max-normal * 2.0 = +inf  [overflow saturate]",
     BF16_MAX_NORMAL_POS, bf16_bits(2.0), F32_POS_INF),
    ("(-max-normal) * 2.0 = -inf",
     BF16_MAX_NORMAL_NEG, bf16_bits(2.0), F32_NEG_INF),

    # ---------- underflow flush to signed zero ----------------------------
    # min-normal-bf16 = 2^-126. Squaring gives exp_calc = 1 + 1 - 127 =
    # -125, top bit set after the 10-bit subtract -> SV flushes to signed
    # zero via the exp_calc[9] branch (lines 104-106).
    ("min-normal * min-normal = +0  [underflow flush]",
     BF16_MIN_NORMAL_POS, BF16_MIN_NORMAL_POS, F32_POS_ZERO),
]


@cocotb.test()
async def mul_bf16_edge_cases(dut):
    """Drive each edge case, settle combinationally, compare bit-exact."""
    fails = []

    for label, a, b, expected in CASES:
        dut.a.value = a
        dut.b.value = b
        await Timer(1, unit="ns")
        got = int(dut.out.value)

        if got == expected:
            dut._log.info(
                f"  OK   {label}  "
                f"a=0x{a:04X} b=0x{b:04X} -> 0x{got:08X}"
            )
        else:
            fails.append((label, a, b, got, expected))
            dut._log.error(
                f"  MISS {label}\n"
                f"        a=0x{a:04X}  b=0x{b:04X}\n"
                f"        got     =0x{got:08X}\n"
                f"        expected=0x{expected:08X}"
            )

    total = len(CASES)
    if fails:
        dut._log.error(f"FAIL: {len(fails)} of {total} mul_bf16 cases failed")
        assert False, f"{len(fails)} mul_bf16 case(s) mismatched; see log"

    dut._log.info(f"PASS: all {total} mul_bf16 edge cases matched bit-exact")
