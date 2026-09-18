#!/usr/bin/env python3
"""NebulaDex 加固回归向量生成器（第二批：缺陷锁死向量）

定向覆盖已修复缺陷：
  A. signExtend（Swift UInt64 逻辑右移致符号扩展失效）
  B. 位域 BFM/SBFM/UBFM 语义（wmask/tmask 伪码写坏保留位）
  C. BFI<->UBFX 往返、负偏移访存、RORV/LSLV/EXTR、LDPSW 等
流程：clang 交叉汇编 -> 提取 .text -> unicorn 模拟 -> 黄金寄存器值 -> JSON
"""
import json, os, struct, subprocess, sys

# 依赖：clang（支持 --target=aarch64-linux-gnu）、unicorn（pip install unicorn）
# 用法：python3 gen_vectors_hardening.py
HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, ".vec_hardening_build")
ROOT = HERE
CODE_BASE, CODE_SIZE = 0x10000000, 0x10000
STACK_BASE, STACK_SIZE = 0x20000000, 0x10000
SP0 = STACK_BASE + 0x8000
os.makedirs(WORK, exist_ok=True)

P = []
def prog(name, desc, asm): P.append({"name": name, "desc": desc, "asm": asm})

# ---------- A. 符号扩展回归（核心缺陷：负值须补 1 而非补 0） ----------
prog("signext_ldrsw_neg_off", "LDRSW 负偏移访存 + 符号扩展（负值补1）", """
    .text
    .global _start
_start:
    movz x1, #0x8000
    movk x1, #0x8000, lsl #16
    stur x1, [sp, #-8]
    ldrsw x2, [sp, #-8]
    ldur w3, [sp, #-8]
    nop
""")

prog("signext_ldrsh_ldrsb", "LDRSH/LDRSB 半字与字节符号扩展", """
    .text
    .global _start
_start:
    movz x1, #0x8000
    movz x2, #0x80
    sturh w1, [sp, #-2]
    sturb w2, [sp, #-4]
    ldursh x3, [sp, #-2]
    ldursb x4, [sp, #-4]
    nop
""")

prog("signext_ldpsw_pair", "LDPSW 成对加载并双符号扩展", """
    .text
    .global _start
_start:
    movz x1, #0x8000
    movk x1, #0x8000, lsl #16
    movz x2, #0x1234
    stur x1, [sp, #-16]
    stur x2, [sp, #-8]
    ldpsw x3, x4, [sp, #-16]
    ldpsw x5, x6, [sp, #-8]
    nop
""")

prog("mem_neg_offset_all_sizes", "负偏移 STUR/LDUR 全宽度访存", """
    .text
    .global _start
_start:
    movz x1, #0xBEEF
    movk x1, #0xDEAD, lsl #16
    movk x1, #0xFEED, lsl #32
    movk x1, #0xFACE, lsl #48
    stur x1, [sp, #-24]
    ldur x2, [sp, #-24]
    stur w1, [sp, #-32]
    ldur w3, [sp, #-32]
    nop
""")

prog("mem_prepost_neg_index", "前/后索引负偏移 STP/LDP", """
    .text
    .global _start
_start:
    movz x1, #0x1111
    movz x2, #0x2222
    stp x1, x2, [sp, #-16]!
    ldp x3, x4, [sp], #16
    stp w1, w2, [sp, #-8]!
    ldp w5, w6, [sp], #8
    nop
""")

prog("ldp_stp_32bit_element", "32 位元素 STP/LDP 成对访存（opc=00 缩放）", """
    .text
    .global _start
_start:
    movz w0, #0x1111
    movz w1, #0x2222
    stp w0, w1, [sp, #-8]
    ldp w2, w3, [sp, #-8]
    nop
""")

# ---------- B. 位域回归（BFM 不得沿用 wmask/tmask 伪码写坏保留位） ----------
prog("bitfield_sbfm_sign", "SBFM 符号位域提取（负值补1）", """
    .text
    .global _start
_start:
    movz x0, #0x8000
    sbfm x1, x0, #0, #15
    movz x0, #0x4000
    sbfm x2, x0, #14, #15
    nop
""")

prog("bitfield_sbfiz_ubfx", "SBFIZ 左移插入 + UBFX 回读", """
    .text
    .global _start
_start:
    movz x0, #0x00FF
    movz x1, #0
    sbfiz x1, x0, #8, #8
    ubfx x2, x1, #8, #8
    nop
""")

prog("bitfield_bfi_ubfx_roundtrip", "BFI 插入 <-> UBFX 回读往返一致性", """
    .text
    .global _start
_start:
    movz x0, #0x1234
    movk x0, #0xABCD, lsl #16
    movz x1, #0
    bfi x1, x0, #16, #8
    ubfx x2, x1, #16, #8
    bfi x1, x0, #4, #4
    ubfx x3, x1, #4, #4
    nop
""")

prog("bitfield_bfm_preserve", "BFM 保留域外位（不得被写坏）", """
    .text
    .global _start
_start:
    movz x0, #0x0F0F
    movz x1, #0
    movk x1, #0xF0F0, lsl #48
    bfm x1, x0, #8, #15
    nop
""")

prog("bitfield_ubfm_ror", "UBFM 以 immr>imms 实现全宽循环右移", """
    .text
    .global _start
_start:
    movz x0, #0x1000
    ubfm x1, x0, #8, #7
    movz x0, #0x8001
    ubfm x2, x0, #16, #15
    nop
""")

prog("bitfield_bfxil_width", "BFXIL 低位域插入且保留高位", """
    .text
    .global _start
_start:
    movz x0, #0x1234
    movz x1, #0
    movk x1, #0xFFFF, lsl #48
    bfxil x1, x0, #4, #8
    nop
""")

prog("bitfield_32bit_bfi", "32 位 BFI/UBFX 域操作", """
    .text
    .global _start
_start:
    movz w0, #0xFFFF
    movz w1, #0
    bfi w1, w0, #4, #12
    ubfx w2, w1, #4, #12
    nop
""")

# ---------- C. 移位 / 提取 / 位反转 ----------
prog("extr_imm_variants", "EXTR 立即数提取（64/32 位与宽移位）", """
    .text
    .global _start
_start:
    movz x0, #0x1234
    movk x0, #0x5678, lsl #16
    movk x0, #0x9ABC, lsl #32
    movk x0, #0xDEF0, lsl #48
    movz x1, #0x1111
    extr x2, x0, x1, #24
    extr x3, x0, x1, #40
    extr w4, w0, w1, #8
    extr x5, x0, x1, #0
    nop
""")

prog("shift_var_family", "LSLV/LSRV/ASRV/RORV 变量移位", """
    .text
    .global _start
_start:
    movz x0, #0x8000
    movk x0, #0x8000, lsl #16
    movz x1, #3
    lslv x2, x0, x1
    lsrv x3, x0, x1
    asrv x4, x0, x1
    movz x1, #4
    rorv x5, x0, x1
    rorv x6, x0, xzr
    nop
""")

prog("clz_rbit_rev", "CLZ/RBIT/REV 单源位操作", """
    .text
    .global _start
_start:
    movz x0, #0
    movk x0, #0x8000, lsl #16
    clz  x1, x0
    rbit x2, x0
    rev  x3, x0
    rev16 x4, x0
    nop
""")

prog("madd_msub_mneg", "MADD/MSUB/MNEG 乘加乘减", """
    .text
    .global _start
_start:
    movz x0, #7
    movz x1, #9
    movz x2, #3
    madd x3, x0, x1, x2
    msub x4, x0, x1, x2
    mneg x5, x0, x1
    nop
""")

prog("sdiv_udiv_signed", "SDIV/UDIV 有符号与无符号除法", """
    .text
    .global _start
_start:
    movz x0, #7
    movn x1, #2
    sdiv x2, x0, x1
    udiv x3, x0, x1
    nop
""")

# ---------- D. 条件与标志 ----------
prog("ccmp_ccmn_flags", "CCMP/CCMN 条件比较链", """
    .text
    .global _start
_start:
    movz x0, #5
    movz x1, #5
    cmp  x0, x1
    ccmp x0, x1, #0, eq
    cset x2, eq
    movz x3, #9
    ccmn x3, #1, #0, lt
    cset x4, gt
    nop
""")

prog("csel_csinc_csinv_csneg", "CSEL/CSINC/CSINV/CSNEG 条件选择族", """
    .text
    .global _start
_start:
    movz x0, #10
    movz x1, #20
    subs x2, x0, x1
    csel  x3, x0, x1, gt
    csinc x4, x0, x1, lt
    csinv x5, x0, x1, eq
    csneg x6, x0, x1, ne
    csinv x7, x0, x1, ne
    csneg x8, x0, x1, eq
    nop
""")

prog("adc_sbc_carry", "ADCS/SBC 进位链与借位", """
    .text
    .global _start
_start:
    movn x0, #0
    movz x1, #1
    adds x2, x0, x1
    adc  x3, xzr, xzr
    subs x4, xzr, x1
    sbc  x5, xzr, xzr
    nop
""")

# ---------- E. 分支与系统 ----------
prog("branch_cbz_cbnz", "CBZ/CBNZ 比较分支（taken 与 not-taken 双路径）", """
    .text
    .global _start
_start:
    movz x0, #0
    cbz  x0, L1
    movz x1, #99
L1:
    movz x2, #7
    cbz  x2, L2
    movz x3, #5
L2:
    movz x4, #0
    cbnz x4, L3
    movz x5, #6
L3:
    movz x6, #9
    cbnz x6, L4
    movz x7, #99
L4:
    nop
""")

prog("branch_tbz_tbnz", "TBZ/TBNZ 位测试分支（taken 与 not-taken 双路径）", """
    .text
    .global _start
_start:
    movz x0, #0
    tbz  x0, #2, L1
    movz x1, #99
L1:
    movz x2, #4
    tbz  x2, #2, L2
    movz x3, #7
L2:
    movz x4, #4
    tbnz x4, #0, L3
    movz x5, #8
L3:
    movz x6, #5
    tbnz x6, #0, L4
    movz x7, #99
L4:
    nop
""")

prog("branch_adr_blr_ret", "ADR 取址 + BLR 间接调用 + RET 返回", """
    .text
    .global _start
_start:
    adr  x0, target
    blr  x0
    movz x1, #1
    b    Lend
target:
    movz x2, #2
    ret
Lend:
    nop
""")

prog("logic_reg_shifted", "逻辑寄存器带移位（AND/ORR/EOR/BIC/ORN/EON）", """
    .text
    .global _start
_start:
    movz x0, #0xFF00
    movz x1, #0x0F0F
    and  x2, x0, x1, lsl #4
    orr  x3, x0, x1, lsr #4
    eor  x4, x0, x1, asr #4
    bic  x5, x0, x1
    orn  x6, x0, x1
    eon  x7, x0, x1
    nop
""")

prog("addsub_extended_reg", "加减扩展寄存器（UXTB/SXTB 扩展）", """
    .text
    .global _start
_start:
    movz x0, #0xFF
    add  x1, x0, w0, uxtb #2
    sub  x2, x0, w0, sxtb #1
    nop
""")

prog("movn_movz_movk", "MOVN/MOVZ/MOVK 立即数装载", """
    .text
    .global _start
_start:
    movn x0, #0
    movz x1, #0x1234
    movk x1, #0x5678, lsl #48
    movn w2, #1
    movz x3, #0xFFFF, lsl #32
    nop
""")


def asm_to_code(asm, tag):
    s_path = os.path.join(WORK, tag + ".s")
    o_path = os.path.join(WORK, tag + ".o")
    open(s_path, "w").write(asm)
    r = subprocess.run(["clang", "-target", "aarch64-linux-gnu", "-c", s_path, "-o", o_path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, r.stderr
    return text_bytes(o_path), None


def text_bytes(path):
    data = open(path, "rb").read()
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    def sh(i): return struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)
    strtab = sh(e_shstrndx)
    shstr = data[strtab[4]:strtab[4] + strtab[5]]
    for i in range(e_shnum):
        s = sh(i)
        name = shstr[s[0]:shstr.index(b"\0", s[0])].decode()
        if name == ".text":
            return data[s[4]:s[4] + s[5]]
    sys.exit("no .text in " + path)


def pstate_to_nzcv4(raw):
    return (((raw >> 31) & 1) << 3) | (((raw >> 30) & 1) << 2) \
        | (((raw >> 29) & 1) << 1) | ((raw >> 28) & 1)


def golden(code, tag):
    from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE, UC_PROT_ALL
    import unicorn.arm64_const as ac
    XREGS = [getattr(ac, "UC_ARM64_REG_X%d" % i) for i in range(31)]
    DREGS = [getattr(ac, "UC_ARM64_REG_D%d" % i) for i in range(32)]

    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    uc.mem_map(CODE_BASE, CODE_SIZE, UC_PROT_ALL)
    uc.mem_map(STACK_BASE, STACK_SIZE, UC_PROT_ALL)
    uc.mem_write(CODE_BASE, bytes(code))
    uc.reg_write(ac.UC_ARM64_REG_SP, SP0)
    uc.reg_write(ac.UC_ARM64_REG_PC, CODE_BASE)
    uc.reg_write(ac.UC_ARM64_REG_NZCV, 0)

    seen = []
    uc.hook_add(UC_HOOK_CODE, lambda u, a, s, usr: seen.append(a))
    uc.emu_start(CODE_BASE, CODE_BASE + len(code), 0, 64)

    out = {
        "pc": "0x%x" % uc.reg_read(ac.UC_ARM64_REG_PC),
        "sp": "0x%x" % uc.reg_read(ac.UC_ARM64_REG_SP),
        "nzcv": "0x%x" % pstate_to_nzcv4(uc.reg_read(ac.UC_ARM64_REG_NZCV)),
        "x": {"%d" % i: "0x%x" % uc.reg_read(XREGS[i]) for i in range(31)},
        "v": {"%d" % i: "0x%x" % uc.reg_read(DREGS[i]) for i in range(32)},
        "executed": len(seen),
    }
    return out


cases, failed_asm = [], []
for p in P:
    code, err = asm_to_code(p["asm"], p["name"])
    if code is None:
        failed_asm.append((p["name"], err.strip().splitlines()[-1] if err else "?"))
        continue
    g = golden(code, p["name"])
    cases.append({
        "name": p["name"], "desc": p["desc"], "steps": g["executed"],
        "code_hex": code.hex(), "expect_x": g["x"], "expect_v": g["v"],
        "expect_sp": g["sp"], "expect_nzcv": g["nzcv"], "expect_pc": g["pc"],
    })
    print("[OK] %-28s %d bytes, %d steps, nzcv=%s" % (p["name"], len(code), g["executed"], g["nzcv"]))

print()
if failed_asm:
    print("汇编失败 %d 个：" % len(failed_asm))
    for n, e in failed_asm: print("   -", n, "|", e)

doc = {
    "comment": "NebulaDex AArch64 解释器加固回归向量；黄金值由 unicorn-engine 生成",
    "code_base": "0x%x" % CODE_BASE, "code_size": CODE_SIZE,
    "stack_base": "0x%x" % STACK_BASE, "stack_size": STACK_SIZE,
    "sp_init": "0x%x" % SP0, "cases": cases,
}
out_path = os.path.join(ROOT, "vectors_hardening.json")
open(out_path, "w").write(json.dumps(doc, indent=2))
print("\n生成用例 %d 个 -> %s" % (len(cases), out_path))
