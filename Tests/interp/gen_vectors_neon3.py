#!/usr/bin/env python3
"""NebulaDex NEON 浮点三同 / 跨通道归约 / 按元素 指令黄金向量生成器。

流程与 gen_vectors_neon.py 一致：clang 交叉汇编单条指令 -> unicorn 注入 128 位
向量初值并模拟 -> 记录执行后的全寄存器期望值，作为 Swift 解释器的黄金对照。

数值全部选取二进制精确可表示的浮点数（1.5 / 2.25 / 0.5 等），避免 Swift 侧
以 Double 计算再截断到单精度时引入双舍入偏差，保证对拍结论只反映指令语义本身。

用法: python3 gen_vectors_neon3.py
输出: vectors_neon3.json
"""

import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_vectors_neon as base  # noqa: E402  复用 assemble / golden / 常量

OUT_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors_neon3.json")
CASES = []


# ---------------------------------------------------------------- 数值构造

def f32(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def f64(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def lanes(bits_vals, esize):
    """按元素位宽打包 128 位通道（元素 0 在最低位）。"""
    lo = hi = 0
    mask = (1 << esize) - 1
    for i, v in enumerate(bits_vals):
        pos = i * esize
        if pos < 64:
            lo |= (v & mask) << pos
        else:
            hi |= (v & mask) << (pos - 64)
    return lo, hi


def conv(vals, esize):
    f = f32 if esize == 32 else f64
    return [f(x) for x in vals]


# 浮点数值池（二进制精确）
F32A = [1.5, -2.25, 3.0, 0.5]
F32B = [2.0, 4.0, -1.0, 8.0]
F32D = [0.25, 1.0, -0.5, 2.5]
F64A = [1.5, -2.25]
F64B = [2.0, -4.0]
F64D = [0.5, 1.25]

# 整数数值池（覆盖符号差异）
I32A = [7, -3, 2147483000, -2000000000]
I32B = [2, 5, -6, 3]
I16A = [300, -7, 12345, -30000, 1, -1, 20000, -2]
I16B = [3, 4, 5, -6, 7, 8, 9, 10]
I8A = [3, 255, 1, 128, 7, 200, 0, 250,
       16, 32, 64, 100, 5, 9, 11, 13]


def add_case(name, desc, insns, init):
    CASES.append({"name": name, "desc": desc, "insns": insns, "init": init})


def fp_three(insn, esize, name, desc, a=None, b=None, d=None):
    A = F32A if esize == 32 else F64A
    B = F32B if esize == 32 else F64B
    D = F32D if esize == 32 else F64D
    init = {3: lanes(conv(D if d is None else d, esize), esize),
            5: lanes(conv(A if a is None else a, esize), esize),
            7: lanes(conv(B if b is None else b, esize), esize)}
    add_case(name, desc, [insn], init)


def reduce_case(insn, esize, vals, name, desc):
    out = [(255 if esize == 8 else 0) for _ in range(16)]
    _ = out
    init = {5: lanes(vals, esize),
            3: lanes([0xDEADBEEF] * (128 // 32), 32)}
    add_case(name, desc, [insn], init)


def by_element(insn, esize, name, desc, a=None, b=None, d=None, kind="fp"):
    if kind == "fp":
        A = F32A if esize == 32 else F64A
        B = F32B if esize == 32 else F64B
        D = F32D if esize == 32 else F64D
        init = {3: lanes(conv(D if d is None else d, esize), esize),
                5: lanes(conv(A if a is None else a, esize), esize),
                7: lanes(conv(B if b is None else b, esize), esize)}
    else:
        A = {32: I32A, 16: I16A}[esize]
        B = {32: I32B, 16: I16B}[esize]
        init = {3: lanes(A, esize), 5: lanes(A, esize), 7: lanes(B, esize)}
    add_case(name, desc, [insn], init)


# ---------------------------------------------------------------- A. 浮点三同 / pairwise

FP4S = [
    ("fadd v3.4s, v5.4s, v7.4s", "浮点三同：fadd 4S"),
    ("fsub v3.4s, v5.4s, v7.4s", "浮点三同：fsub 4S"),
    ("fmul v3.4s, v5.4s, v7.4s", "浮点三同：fmul 4S"),
    ("fdiv v3.4s, v5.4s, v7.4s", "浮点三同：fdiv 4S"),
    ("fmax v3.4s, v5.4s, v7.4s", "浮点三同：fmax 4S"),
    ("fmin v3.4s, v5.4s, v7.4s", "浮点三同：fmin 4S"),
    ("fmaxnm v3.4s, v5.4s, v7.4s", "浮点三同：fmaxnm 4S"),
    ("fminnm v3.4s, v5.4s, v7.4s", "浮点三同：fminnm 4S"),
    ("fabd v3.4s, v5.4s, v7.4s", "浮点三同：fabd 4S"),
    ("fmla v3.4s, v5.4s, v7.4s", "浮点三同：fmla 4S"),
    ("fmls v3.4s, v5.4s, v7.4s", "浮点三同：fmls 4S"),
    ("fcmeq v3.4s, v5.4s, v7.4s", "浮点三同：fcmeq 4S"),
    ("fcmge v3.4s, v5.4s, v7.4s", "浮点三同：fcmge 4S"),
    ("fcmgt v3.4s, v5.4s, v7.4s", "浮点三同：fcmgt 4S"),
    ("facge v3.4s, v5.4s, v7.4s", "浮点三同：facge 4S"),
    ("facgt v3.4s, v5.4s, v7.4s", "浮点三同：facgt 4S"),
    ("frecps v3.4s, v5.4s, v7.4s", "浮点三同：frecps 4S"),
    ("frsqrts v3.4s, v5.4s, v7.4s", "浮点三同：frsqrts 4S"),
    ("faddp v3.4s, v5.4s, v7.4s", "浮点 pairwise：faddp 4S"),
    ("fmaxp v3.4s, v5.4s, v7.4s", "浮点 pairwise：fmaxp 4S"),
    ("fminp v3.4s, v5.4s, v7.4s", "浮点 pairwise：fminp 4S"),
    ("fmaxnmp v3.4s, v5.4s, v7.4s", "浮点 pairwise：fmaxnmp 4S"),
    ("fminnmp v3.4s, v5.4s, v7.4s", "浮点 pairwise：fminnmp 4S"),
]

FP2D = [
    ("fadd v3.2d, v5.2d, v7.2d", "浮点三同：fadd 2D"),
    ("fsub v3.2d, v5.2d, v7.2d", "浮点三同：fsub 2D"),
    ("fmul v3.2d, v5.2d, v7.2d", "浮点三同：fmul 2D"),
    ("fdiv v3.2d, v5.2d, v7.2d", "浮点三同：fdiv 2D"),
    ("fmax v3.2d, v5.2d, v7.2d", "浮点三同：fmax 2D"),
    ("fmin v3.2d, v5.2d, v7.2d", "浮点三同：fmin 2D"),
    ("fabd v3.2d, v5.2d, v7.2d", "浮点三同：fabd 2D"),
    ("fmla v3.2d, v5.2d, v7.2d", "浮点三同：fmla 2D"),
    ("fmls v3.2d, v5.2d, v7.2d", "浮点三同：fmls 2D"),
    ("fcmeq v3.2d, v5.2d, v7.2d", "浮点三同：fcmeq 2D"),
    ("fcmgt v3.2d, v5.2d, v7.2d", "浮点三同：fcmgt 2D"),
    ("facgt v3.2d, v5.2d, v7.2d", "浮点三同：facgt 2D"),
    ("frecps v3.2d, v5.2d, v7.2d", "浮点三同：frecps 2D"),
    ("frsqrts v3.2d, v5.2d, v7.2d", "浮点三同：frsqrts 2D"),
    ("faddp v3.2d, v5.2d, v7.2d", "浮点 pairwise：faddp 2D"),
    ("fmaxp v3.2d, v5.2d, v7.2d", "浮点 pairwise：fmaxp 2D"),
    ("fminnmp v3.2d, v5.2d, v7.2d", "浮点 pairwise：fminnmp 2D"),
]

for insn, desc in FP4S:
    nm = insn.split()[0] + "_4s"
    fp_three(insn, 32, nm, desc)
for insn, desc in FP2D:
    nm = insn.split()[0] + "_2d"
    fp_three(insn, 64, nm, desc)

fp_three("fadd v3.2s, v5.2s, v7.2s", 32, "fadd_2s",
         "浮点三同：fadd 2S（Q=0 高位清零）", a=F32A[:2], b=F32B[:2], d=F32D[:2])
fp_three("fmul v3.2s, v5.2s, v7.2s", 32, "fmul_2s",
         "浮点三同：fmul 2S（Q=0 高位清零）", a=F32A[:2], b=F32B[:2], d=F32D[:2])

# ---------------------------------------------------------------- B. 跨通道归约 / 标量 pairwise

REDUCE = [
    ("addv s3, v5.4s", 32, I32A, "addv_4s", "归约：addv 4S（32 位求和）"),
    ("addv h3, v5.8h", 16, I16A, "addv_8h", "归约：addv 8H（16 位求和）"),
    ("addv b3, v5.16b", 8, I8A, "addv_16b", "归约：addv 16B（8 位求和）"),
    ("smaxv s3, v5.4s", 32, I32A, "smaxv_4s", "归约：smaxv 4S（有符号最大）"),
    ("sminv s3, v5.4s", 32, I32A, "sminv_4s", "归约：sminv 4S（有符号最小）"),
    ("umaxv s3, v5.4s", 32, I32A, "umaxv_4s", "归约：umaxv 4S（无符号最大）"),
    ("uminv s3, v5.4s", 32, I32A, "uminv_4s", "归约：uminv 4S（无符号最小）"),
    ("smaxv h3, v5.8h", 16, I16A, "smaxv_8h", "归约：smaxv 8H（有符号最大）"),
    ("sminv h3, v5.8h", 16, I16A, "sminv_8h", "归约：sminv 8H（有符号最小）"),
    ("umaxv b3, v5.16b", 8, I8A, "umaxv_16b", "归约：umaxv 16B（无符号最大）"),
    ("uminv b3, v5.16b", 8, I8A, "uminv_16b", "归约：uminv 16B（无符号最小）"),
]
for insn, esize, vals, nm, desc in REDUCE:
    reduce_case(insn, esize, vals, nm, desc)

FP_REDUCE = [
    ("fmaxv s3, v5.4s", "fmaxv_4s", "归约：fmaxv 4S", 32),
    ("fminv s3, v5.4s", "fminv_4s", "归约：fminv 4S", 32),
    ("fmaxnmv s3, v5.4s", "fmaxnmv_4s", "归约：fmaxnmv 4S", 32),
    ("fminnmv s3, v5.4s", "fminnmv_4s", "归约：fminnmv 4S", 32),
    ("faddp s3, v5.2s", "faddp_scalar_2s", "标量 pairwise：faddp 2S", 32),
    ("faddp d3, v5.2d", "faddp_scalar_2d", "标量 pairwise：faddp 2D", 64),
    ("fmaxp s3, v5.2s", "fmaxp_scalar_2s", "标量 pairwise：fmaxp 2S", 32),
    ("fminp s3, v5.2s", "fminp_scalar_2s", "标量 pairwise：fminp 2S", 32),
    ("fmaxnmp s3, v5.2s", "fmaxnmp_scalar_2s", "标量 pairwise：fmaxnmp 2S", 32),
    ("fminnmp s3, v5.2s", "fminnmp_scalar_2s", "标量 pairwise：fminnmp 2S", 32),
    ("fmaxnmp d3, v5.2d", "fmaxnmp_scalar_2d", "标量 pairwise：fmaxnmp 2D", 64),
    ("fminnmp d3, v5.2d", "fminnmp_scalar_2d", "标量 pairwise：fminnmp 2D", 64),
]
for insn, nm, desc, esize in FP_REDUCE:
    fp_three(insn, esize, nm, desc)

# NaN 语义对照：FMAX / FMAXV（NaN 传播）与 FMAXNM / FMAXNMV（NaN 忽略）
NAN_A = [float("nan"), -2.25, 3.0, 0.5]
fp_three("fmax v3.4s, v5.4s, v7.4s", 32, "fmax_4s_qnan",
         "NaN 语义：fmax 4S 遇 quiet NaN 应传播", a=NAN_A)
fp_three("fmaxnm v3.4s, v5.4s, v7.4s", 32, "fmaxnm_4s_qnan",
         "NaN 语义：fmaxnm 4S 应忽略 quiet NaN", a=NAN_A)
fp_three("fmaxv s3, v5.4s", 32, "fmaxv_4s_qnan",
         "NaN 语义：fmaxv 4S 遇 quiet NaN 应传播", a=NAN_A)
fp_three("fmaxnmv s3, v5.4s", 32, "fmaxnmv_4s_qnan",
         "NaN 语义：fmaxnmv 4S 应忽略 quiet NaN", a=NAN_A)
fp_three("fmaxp v3.2s, v5.2s, v7.2s", 32, "fmaxp_vec_2s_qnan",
         "NaN 语义：fmaxp 2S 遇 quiet NaN 应传播",
         a=[float("nan"), -2.25], b=[3.0, 0.5])
fp_three("fmaxnmp v3.2s, v5.2s, v7.2s", 32, "fmaxnmp_vec_2s_qnan",
         "NaN 语义：fmaxnmp 2S 应忽略 quiet NaN",
         a=[float("nan"), -2.25], b=[3.0, 0.5])

# 向量 pairwise 的 2S 形式（Q = 0，高位应清零）
fp_three("faddp v3.2s, v5.2s, v7.2s", 32, "faddp_vec_2s",
         "浮点 pairwise：faddp 2S（Q=0 高位清零）", a=F32A[:2], b=F32B[:2])

# ---------------------------------------------------------------- C. 按元素（by element）

BY_ELEM_FP = [
    ("fmul v3.4s, v5.4s, v7.s[1]", 32, "fmul_by_s1", "按元素：fmul 4S x s[1]"),
    ("fmul v3.4s, v5.4s, v7.s[2]", 32, "fmul_by_s2", "按元素：fmul 4S x s[2]"),
    ("fmul v3.4s, v5.4s, v7.s[3]", 32, "fmul_by_s3", "按元素：fmul 4S x s[3]"),
    ("fmla v3.4s, v5.4s, v7.s[2]", 32, "fmla_by_s2", "按元素：fmla 4S x s[2]"),
    ("fmls v3.4s, v5.4s, v7.s[3]", 32, "fmls_by_s3", "按元素：fmls 4S x s[3]"),
    ("fmul v3.2s, v5.2s, v7.s[1]", 32, "fmul_by_2s1", "按元素：fmul 2S x s[1]（Q=0）"),
    ("fmul v3.2d, v5.2d, v7.d[1]", 64, "fmul_by_d1", "按元素：fmul 2D x d[1]"),
    ("fmla v3.2d, v5.2d, v7.d[1]", 64, "fmla_by_d1", "按元素：fmla 2D x d[1]"),
]
for insn, esize, nm, desc in BY_ELEM_FP:
    if esize == 64:
        by_element(insn, esize, nm, desc)
    else:
        by_element(insn, esize, nm, desc)

BY_ELEM_INT = [
    ("mul v3.4s, v5.4s, v7.s[1]", 32, "mul_by_s1", "按元素：mul 4S x s[1]（32 位整数乘）"),
    ("mla v3.4s, v5.4s, v7.s[2]", 32, "mla_by_s2", "按元素：mla 4S x s[2]（乘加）"),
    ("mls v3.4s, v5.4s, v7.s[3]", 32, "mls_by_s3", "按元素：mls 4S x s[3]（乘减）"),
    ("mul v3.8h, v5.8h, v7.h[3]", 16, "mul_by_h3", "按元素：mul 8H x h[3]（16 位整数乘）"),
    ("mla v3.8h, v5.8h, v7.h[5]", 16, "mla_by_h5", "按元素：mla 8H x h[5]（16 位乘加）"),
]
for insn, esize, nm, desc in BY_ELEM_INT:
    by_element(insn, esize, nm, desc, kind="int")


# ---------------------------------------------------------------- 生成

def main():
    cases, failed = [], []
    for c in CASES:
        code, err = base.assemble(c["insns"], c["name"])
        if code is None:
            failed.append((c["name"], err))
            continue
        steps = len(code) // 4
        try:
            g = base.golden(code, c["init"])
        except Exception as exc:                      # noqa: BLE001
            failed.append((c["name"], "unicorn 异常: %s" % exc))
            continue
        entry = {
            "name": c["name"], "desc": c["desc"], "steps": steps,
            "code_hex": code.hex(),
            "expect_x": {},
            "init_v": {"%d" % k: "0x%x" % v[0] for k, v in sorted(c["init"].items())},
            "init_vh": {"%d" % k: "0x%x" % v[1] for k, v in sorted(c["init"].items())},
            "expect_v": {"%d" % k: "0x%x" % v[0] for k, v in sorted(g.items())},
            "expect_vh": {"%d" % k: "0x%x" % v[1] for k, v in sorted(g.items())},
            "expect_sp": "0x%x" % (0x20000000 + 0x8000),
            "expect_nzcv": "0x0",
        }
        cases.append(entry)
        print("[OK] %-20s %d insn, v3=0x%x%016x" % (c["name"], steps, g[3][1], g[3][0]))

    if failed:
        print("\n失败 %d 个：" % len(failed))
        for n, e in failed:
            print("   -", n, "|", e)

    doc = {
        "comment": "NebulaDex NEON 浮点三同 / 跨通道归约 / 按元素 指令黄金向量；"
                   "黄金值由 unicorn-engine 模拟同一份机器码生成",
        "code_base": "0x%x" % base.CODE_BASE, "code_size": base.CODE_SIZE,
        "stack_base": "0x20000000", "stack_size": 0x10000,
        "sp_init": "0x%x" % (0x20000000 + 0x8000),
        "cases": cases,
    }
    open(OUT_JSON, "w").write(json.dumps(doc, indent=1))
    print("\n生成用例 %d 个 -> %s" % (len(cases), OUT_JSON))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
