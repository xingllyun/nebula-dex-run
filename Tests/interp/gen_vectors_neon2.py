#!/usr/bin/env python3
"""NEON 边界补充向量生成器（第二轮）

目的：对第一轮修复涉及的指令做「参数空间扩展」独立验证，防止按单个
期望值反推公式造成的过拟合。复用 gen_vectors_neon.py 的汇编/模拟机制。

覆盖：SRI / SHRN / RSHRN / SSHLL / USHLL 在各种 esize × shift 边界，
      SHL/SLI/SSHR/USHR/SSRA/USRA 边界位移，SSHL/USHL 越界位移量，
      BIT/BIF/BSL 的 size 选择器，二同 misc 交叉 size，copy 索引边界。
"""
import importlib.util
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "gen_vectors_neon.py")

spec = importlib.util.spec_from_file_location("gvn", SRC)
gvn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gvn)

gvn.OUT_JSON = os.path.join(HERE, "vectors_neon2.json")
gvn.CASES.clear()

si = gvn.shift_imm      # 移位立即数：init v3=dataD, v5=dataA
ts = gvn.three_same     # 三同
tr = gvn.two_reg        # 二同 misc
cp = gvn.copy_case      # 搬移

# ---- SRI：全覆盖 esize × shift 边界（shift = esize 时结果应全部保留 Vd）----
for size, reg in [(8, "16b"), (16, "8h"), (32, "4s"), (64, "2d")]:
    for shift in sorted({1, size // 4, size // 2, size - 1, size}):
        if shift < 1:
            continue
        si("sri v3.%s, v5.%s, #%d" % (reg, reg, shift), size)

# ---- SHRN / RSHRN / SHRN2 / RSHRN2 ----
for size, dst in [(8, "8b"), (16, "4h"), (32, "2s")]:
    src = {8: "8h", 16: "4s", 32: "2d"}[size]
    for shift in sorted({1, size // 2, size - 1, size}):
        si("shrn v3.%s, v5.%s, #%d" % (dst, src, shift), size)
        si("rshrn v3.%s, v5.%s, #%d" % (dst, src, shift), size)
si("shrn2 v3.16b, v5.8h, #1", 8)
si("shrn2 v3.16b, v5.8h, #8", 8)
si("rshrn2 v3.16b, v5.8h, #8", 8)
si("shrn2 v3.8h, v5.4s, #16", 16)
si("rshrn2 v3.8h, v5.4s, #16", 16)

# ---- SSHLL / USHLL / SSHLL2 / USHLL2 ----
si("sshll v3.8h, v5.8b, #0", 8)
si("sshll v3.8h, v5.8b, #7", 8)
si("ushll v3.8h, v5.8b, #0", 8)
si("ushll v3.8h, v5.8b, #7", 8)
si("sshll v3.4s, v5.4h, #0", 16)
si("sshll v3.4s, v5.4h, #15", 16)
si("ushll v3.4s, v5.4h, #15", 16)
si("sshll v3.2d, v5.2s, #31", 32)
si("ushll v3.2d, v5.2s, #31", 32)
si("sshll2 v3.8h, v5.16b, #0", 8)
si("ushll2 v3.8h, v5.16b, #7", 8)
si("sshll2 v3.4s, v5.8h, #15", 16)
si("ushll2 v3.4s, v5.8h, #15", 16)
si("sshll2 v3.2d, v5.4s, #31", 32)
si("ushll2 v3.2d, v5.4s, #31", 32)

# ---- SHL / SLI / SSHR / USHR / SSRA / USRA 位移边界 ----
si("shl v3.8h, v5.8h, #0", 16)
si("shl v3.4s, v5.4s, #31", 32)
si("shl v3.8b, v5.8b, #7", 8)
si("sli v3.8h, v5.8h, #1", 16)
si("sli v3.8h, v5.8h, #15", 16)
si("sli v3.16b, v5.16b, #7", 8)
si("sshr v3.8h, v5.8h, #16", 16)
si("ushr v3.8h, v5.8h, #16", 16)
si("ssra v3.8h, v5.8h, #16", 16)
si("usra v3.8h, v5.8h, #16", 16)
si("sshr v3.4s, v5.4s, #32", 32)
si("ushr v3.4s, v5.4s, #32", 32)

# ---- SSHL / USHL 越界位移量（含 2d）----
ts("sshl v3.2d, v5.2d, v7.2d", 64, m_kind="SH")
ts("ushl v3.2d, v5.2d, v7.2d", 64, m_kind="SH")
ts("ushl v3.8h, v5.8h, v7.8h", 16, m_kind="SH")

# ---- 逻辑位选 size 选择器 & Q 变体 ----
ts("bit v3.8b, v5.8b, v7.8b", 8)
ts("bif v3.8b, v5.8b, v7.8b", 8)
ts("bsl v3.8b, v5.8b, v7.8b", 8)
ts("bit v3.16b, v5.16b, v7.16b", 8)
ts("bif v3.16b, v5.16b, v7.16b", 8)
ts("bsl v3.16b, v5.16b, v7.16b", 8)

# ---- 二同 misc 交叉 size ----
tr("cls v3.8h, v5.8h", 16)
tr("clz v3.8h, v5.8h", 16)
tr("cls v3.4s, v5.4s", 32)
tr("clz v3.4s, v5.4s", 32)
tr("abs v3.8h, v5.8h", 16)
tr("neg v3.8h, v5.8h", 16)
tr("not v3.8b, v5.8b", 8)
tr("rev64 v3.4s, v5.4s", 32)
tr("rev64 v3.8h, v5.8h", 16)
tr("rev32 v3.4h, v5.4h", 16)
tr("rev32 v3.8b, v5.8b", 8)
tr("rev16 v3.8b, v5.8b", 8)
tr("xtn2 v3.8h, v5.4s", 16)
tr("xtn2 v3.4s, v5.2d", 32)

# ---- copy 索引边界 ----
cp("dup v3.16b, v5.b[0]", 8)
cp("dup v3.16b, v5.b[15]", 8)
cp("dup v3.4s, v5.s[0]", 32)
cp("dup v3.4s, v5.s[3]", 32)
cp("ins v3.b[15], v5.b[0]", 8)
cp("ins v3.b[0], v5.b[15]", 8)
cp("ins v3.d[0], v5.d[1]", 64)
cp("ins v3.s[3], v5.s[0]", 32)

gvn.main()
