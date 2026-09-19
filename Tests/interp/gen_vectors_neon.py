#!/usr/bin/env python3
"""NebulaDex NEON 整数指令黄金向量生成器

流程：clang 交叉汇编单条 NEON 指令 -> unicorn 注入 128 位向量初值并模拟
-> 读取 Q0-Q31 全 128 位黄金值 -> 生成 vectors_neon.json（供 interp-test 对拍）。

覆盖分簇（与 SDRArmNEON.swift 实现一致）：
  three-same、two-reg-misc、shift-by-immediate、copy(DUP/INS)
"""
import json
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(tempfile.gettempdir(), "nebuladex_vec_neon")
OUT_JSON = os.path.join(HERE, "vectors_neon.json")
CODE_BASE, CODE_SIZE = 0x10000000, 0x10000
MASK64 = (1 << 64) - 1
os.makedirs(WORK, exist_ok=True)

# ---------------------------------------------------------------- 数据构造

def edges(esize):
    m = (1 << esize) - 1
    s = 1 << (esize - 1)
    return [0, 1, m, s, s - 1, m - 1, s | 1, 0xA5A5A5A5A5A5A5A5 & m]


# 64 位通道仅 2 个元素，用 0/1 边界会丧失覆盖力，单独给定高位边界组合
D64 = {
    "A": [0x8000000000000000, 0xFFFFFFFFFFFFFFFE],
    "B": [0x8000000000000000, 0x0000000000000002],
    "D": [0xDEADBEEFDEADBEEF, 0x0123456789ABCDEF],
}


def dataA(esize):
    if esize == 64:
        return list(D64["A"])
    return [edges(esize)[i % 8] for i in range(128 // esize)]


def dataB(esize):
    if esize == 64:
        return list(D64["B"])
    e = edges(esize)
    return [e[i % 8] if i % 2 == 0 else e[(i * 3 + 1) % 8] for i in range(128 // esize)]


def dataD(esize):
    if esize == 64:
        return list(D64["D"])
    e = edges(esize)
    return [e[(i * 5 + 2) % 8] for i in range(128 // esize)]


def dataSH(esize):
    """位移量数据：仅最低字节有效（AArch64 按元素低 8 位取有符号位移），
    高位填非零噪声以捕获"误用整元素值"的实现偏差。"""
    shifts = [0, 1, esize - 1, esize, -1, -3, -(esize - 1), -(esize + 1)]
    noise = 0 if esize == 8 else (0xA5A5A5A5A5A5A5A5 & ~0xFF) & ((1 << esize) - 1)
    vals = []
    for i in range(128 // esize):
        vals.append((shifts[i % 8] & 0xFF) | noise)
    return vals


def pack(vals, esize):
    v = 0
    for i, x in enumerate(vals):
        v |= (x & ((1 << esize) - 1)) << (esize * i)
    return (v & MASK64, v >> 64)


def lanes_hex(esize, kind):
    if kind == "A":
        return dataA(esize)
    if kind == "B":
        return dataB(esize)
    if kind == "D":
        return dataD(esize)
    if kind == "SH":
        return dataSH(esize)
    raise ValueError(kind)


# ---------------------------------------------------------------- 用例定义

CASES = []


def add_case(name, desc, insns, init, extra=None):
    CASES.append({"name": name, "desc": desc, "insns": insns, "init": init,
                  "extra": extra or {}})


def three_same(insn, esize, m_kind="B", name=None, desc=None):
    add_case(name or insn.replace(" ", "_").replace(",", ""),
             desc or ("三同：" + insn),
             [insn],
             {3: pack(dataD(esize), esize),
              5: pack(dataA(esize), esize),
              7: pack(lanes_hex(esize, m_kind), esize)})


def two_reg(insn, esize, name=None, desc=None, d_kind="A"):
    add_case(name or insn.replace(" ", "_").replace(",", ""),
             desc or ("二同 misc：" + insn),
             [insn],
             {3: pack(dataD(esize) if d_kind == "D" else dataA(esize), esize),
              5: pack(dataA(esize), esize)})


def shift_imm(insn, esize, name=None, desc=None):
    add_case(name or insn.replace(" ", "_").replace(",", ""),
             desc or ("移位立即数：" + insn),
             [insn],
             {3: pack(dataD(esize), esize),
              5: pack(dataA(esize), esize)})


def copy_case(insn, esize, setup=None, x1=None, name=None, desc=None):
    insns = list(setup or []) + [insn]
    init = {3: pack(dataD(esize), esize)}
    if setup is None:
        init[5] = pack(dataA(esize), esize)
    add_case(name or insn.replace(" ", "_").replace(",", ""),
             desc or ("搬移：" + insn), insns, init,
             {"x1": x1} if x1 is not None else None)


X1_SETUP4 = ["movz x1, #0x1234", "movk x1, #0xBEEF, lsl #16",
             "movk x1, #0xCAFE, lsl #32", "movk x1, #0xF00D, lsl #48"]
X1_SETUP2 = ["movz x1, #0x1234", "movk x1, #0xBEEF, lsl #16"]
X1_64 = 0xF00DCAFEBEEF1234
X1_32 = 0xBEEF1234

# ---- three-same ----
three_same("add v3.16b, v5.16b, v7.16b", 8)
three_same("add v3.8h, v5.8h, v7.8h", 16)
three_same("add v3.4s, v5.4s, v7.4s", 32)
three_same("add v3.2d, v5.2d, v7.2d", 64)
three_same("add v3.8b, v5.8b, v7.8b", 8)          # Q=0：高位须清零
three_same("sub v3.16b, v5.16b, v7.16b", 8)
three_same("sub v3.8h, v5.8h, v7.8h", 16)
three_same("sub v3.4s, v5.4s, v7.4s", 32)
three_same("sub v3.2d, v5.2d, v7.2d", 64)
three_same("mul v3.16b, v5.16b, v7.16b", 8)
three_same("mul v3.8h, v5.8h, v7.8h", 16)
three_same("mul v3.4s, v5.4s, v7.4s", 32)
for ins in ["and", "bic", "orr", "orn", "eor", "bsl", "bit", "bif"]:
    three_same("%s v3.16b, v5.16b, v7.16b" % ins, 8)
three_same("cmeq v3.16b, v5.16b, v7.16b", 8)
three_same("cmeq v3.4s, v5.4s, v7.4s", 32)
three_same("cmtst v3.16b, v5.16b, v7.16b", 8)
three_same("cmtst v3.4s, v5.4s, v7.4s", 32)
three_same("cmgt v3.16b, v5.16b, v7.16b", 8)
three_same("cmgt v3.4s, v5.4s, v7.4s", 32)
three_same("cmhi v3.16b, v5.16b, v7.16b", 8)
three_same("cmhi v3.4s, v5.4s, v7.4s", 32)
three_same("cmge v3.16b, v5.16b, v7.16b", 8)
three_same("cmge v3.4s, v5.4s, v7.4s", 32)
three_same("cmhs v3.16b, v5.16b, v7.16b", 8)
three_same("cmhs v3.4s, v5.4s, v7.4s", 32)
three_same("sshl v3.16b, v5.16b, v7.16b", 8, m_kind="SH")
three_same("sshl v3.8h, v5.8h, v7.8h", 16, m_kind="SH")
three_same("sshl v3.4s, v5.4s, v7.4s", 32, m_kind="SH")
three_same("ushl v3.16b, v5.16b, v7.16b", 8, m_kind="SH")
three_same("ushl v3.4s, v5.4s, v7.4s", 32, m_kind="SH")
three_same("smax v3.16b, v5.16b, v7.16b", 8)
three_same("smax v3.4s, v5.4s, v7.4s", 32)
three_same("smin v3.16b, v5.16b, v7.16b", 8)
three_same("smin v3.4s, v5.4s, v7.4s", 32)
three_same("umax v3.16b, v5.16b, v7.16b", 8)
three_same("umax v3.4s, v5.4s, v7.4s", 32)
three_same("umin v3.16b, v5.16b, v7.16b", 8)
three_same("umin v3.4s, v5.4s, v7.4s", 32)
three_same("addp v3.16b, v5.16b, v7.16b", 8)
three_same("addp v3.8h, v5.8h, v7.8h", 16)
three_same("addp v3.4s, v5.4s, v7.4s", 32)

# ---- two-reg misc ----
two_reg("rev64 v3.16b, v5.16b", 8)
two_reg("rev64 v3.8h, v5.8h", 16)
two_reg("rev64 v3.4s, v5.4s", 32)
two_reg("rev32 v3.16b, v5.16b", 8)
two_reg("rev32 v3.8h, v5.8h", 16)
two_reg("rev16 v3.16b, v5.16b", 8)
two_reg("cnt v3.16b, v5.16b", 8)
two_reg("cnt v3.8b, v5.8b", 8)
two_reg("cls v3.16b, v5.16b", 8)
two_reg("cls v3.4s, v5.4s", 32)
two_reg("clz v3.16b, v5.16b", 8)
two_reg("clz v3.4s, v5.4s", 32)
two_reg("abs v3.16b, v5.16b", 8)
two_reg("abs v3.4s, v5.4s", 32)
two_reg("abs v3.2d, v5.2d", 64)
two_reg("neg v3.16b, v5.16b", 8)
two_reg("neg v3.4s, v5.4s", 32)
two_reg("neg v3.2d, v5.2d", 64)
two_reg("not v3.16b, v5.16b", 8)
two_reg("xtn v3.8b, v5.8h", 8)
two_reg("xtn v3.4h, v5.4s", 16)
two_reg("xtn v3.2s, v5.2d", 32)
two_reg("xtn2 v3.16b, v5.8h", 8)

# ---- shift by immediate ----
shift_imm("shl v3.16b, v5.16b, #3", 8)
shift_imm("shl v3.8h, v5.8h, #5", 16)
shift_imm("shl v3.4s, v5.4s, #7", 32)
shift_imm("shl v3.2d, v5.2d, #13", 64)
shift_imm("sli v3.16b, v5.16b, #3", 8)
shift_imm("sli v3.4s, v5.4s, #7", 32)
shift_imm("sshr v3.16b, v5.16b, #3", 8)
shift_imm("sshr v3.8h, v5.8h, #5", 16)
shift_imm("sshr v3.4s, v5.4s, #7", 32)
shift_imm("sshr v3.2d, v5.2d, #13", 64)
shift_imm("ushr v3.16b, v5.16b, #3", 8)
shift_imm("ushr v3.4s, v5.4s, #7", 32)
shift_imm("ushr v3.2d, v5.2d, #13", 64)
shift_imm("ssra v3.16b, v5.16b, #3", 8)
shift_imm("ssra v3.4s, v5.4s, #7", 32)
shift_imm("usra v3.16b, v5.16b, #3", 8)
shift_imm("usra v3.4s, v5.4s, #7", 32)
shift_imm("sri v3.16b, v5.16b, #3", 8)
shift_imm("sri v3.4s, v5.4s, #7", 32)
shift_imm("shrn v3.8b, v5.8h, #3", 8)
shift_imm("shrn v3.4h, v5.4s, #7", 16)
shift_imm("shrn2 v3.16b, v5.8h, #5", 8)
shift_imm("rshrn v3.8b, v5.8h, #3", 8)
shift_imm("sshll v3.8h, v5.8b, #3", 8)
shift_imm("sshll2 v3.8h, v5.16b, #5", 8)
shift_imm("ushll v3.8h, v5.8b, #3", 8)
shift_imm("ushll2 v3.8h, v5.16b, #5", 8)

# ---- copy ----
copy_case("dup v3.16b, v5.b[7]", 8)
copy_case("dup v3.8b, v5.b[3]", 8)          # Q=0
copy_case("dup v3.8h, v5.h[5]", 16)
copy_case("dup v3.4s, v5.s[2]", 32)
copy_case("dup v3.2d, v5.d[1]", 64)
copy_case("dup v3.16b, w1", 8, setup=X1_SETUP2, x1=X1_32)
copy_case("dup v3.4s, w1", 32, setup=X1_SETUP2, x1=X1_32)
copy_case("dup v3.2d, x1", 64, setup=X1_SETUP4, x1=X1_64)
copy_case("ins v3.b[9], v5.b[3]", 8)
copy_case("ins v3.h[3], v5.h[1]", 16)
copy_case("ins v3.s[1], v5.s[2]", 32)
copy_case("ins v3.d[1], v5.d[0]", 64)
copy_case("ins v3.b[5], w1", 8, setup=X1_SETUP2, x1=X1_32)
copy_case("ins v3.s[2], w1", 32, setup=X1_SETUP2, x1=X1_32)
copy_case("ins v3.d[0], x1", 64, setup=X1_SETUP4, x1=X1_64)


# ---------------------------------------------------------------- 汇编与模拟

def text_bytes(path):
    data = open(path, "rb").read()
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)

    def sh(i):
        return struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)

    strtab = sh(e_shstrndx)
    shstr = data[strtab[4]:strtab[4] + strtab[5]]
    for i in range(e_shnum):
        s = sh(i)
        nm = shstr[s[0]:shstr.index(b"\0", s[0])].decode()
        if nm == ".text":
            return data[s[4]:s[4] + s[5]]
    sys.exit("no .text in " + path)


def assemble(insns, tag):
    asm = "\t.text\n\t.global _start\n_start:\n"
    for i in insns:
        asm += "\t%s\n" % i
    s_path, o_path = os.path.join(WORK, tag + ".s"), os.path.join(WORK, tag + ".o")
    open(s_path, "w").write(asm)
    r = subprocess.run(["clang", "-target", "aarch64-linux-gnu", "-c", s_path, "-o", o_path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, r.stderr.strip().splitlines()[-1] if r.stderr else "?"
    return text_bytes(o_path), None


def golden(code, init):
    from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_PROT_ALL
    import unicorn.arm64_const as ac
    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    uc.mem_map(CODE_BASE, CODE_SIZE, UC_PROT_ALL)
    uc.mem_write(CODE_BASE, bytes(code))
    for idx, (lo, hi) in init.items():
        uc.reg_write(getattr(ac, "UC_ARM64_REG_Q%d" % idx), (hi << 64) | lo)
    uc.reg_write(ac.UC_ARM64_REG_PC, CODE_BASE)
    uc.reg_write(ac.UC_ARM64_REG_NZCV, 0)
    uc.emu_start(CODE_BASE, CODE_BASE + len(code), 0, 64)
    out = {}
    for i in range(32):
        v = uc.reg_read(getattr(ac, "UC_ARM64_REG_Q%d" % i))
        out[i] = (v & MASK64, v >> 64)
    return out


def probe():
    """自检：确认 unicorn 的 Q 寄存器读写与 Q=0 高位清零语义。"""
    code, err = assemble(["add v3.4s, v5.4s, v7.4s"], "probe1")
    assert err is None, err
    init = {5: (0x0000000180000002, 0xFFFFFFFF00000003),
            7: (0x0000000200000001, 0x0000000100000001),
            3: (0xDEADBEEFDEADBEEF, 0xDEADBEEFDEADBEEF)}
    r = golden(code, init)
    assert r[3] == (0x0000000380000003, 0x0000000000000004), \
        "probe1 逐通道加不符: %s" % (r[3],)

    code, err = assemble(["add v3.2s, v5.2s, v7.2s"], "probe2")
    assert err is None, err
    r = golden(code, init)
    assert r[3] == (0x0000000380000003, 0x0), "probe2 Q=0 未清零高位: %s" % (r[3],)
    print("[probe] unicorn Q 寄存器语义自检通过")


def main():
    probe()
    cases, failed = [], []
    for c in CASES:
        code, err = assemble(c["insns"], c["name"])
        if code is None:
            failed.append((c["name"], err))
            continue
        steps = len(code) // 4
        try:
            g = golden(code, c["init"])
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
        if "x1" in c["extra"]:
            entry["expect_x"] = {"1": "0x%x" % c["extra"]["x1"]}
        cases.append(entry)
        print("[OK] %-34s %d insn, v3.hi=0x%x" % (c["name"], steps, g[3][1]))

    if failed:
        print("\n失败 %d 个：" % len(failed))
        for n, e in failed:
            print("   -", n, "|", e)

    doc = {
        "comment": "NebulaDex NEON 整数指令黄金向量；黄金值由 unicorn-engine 模拟同一份机器码生成",
        "code_base": "0x%x" % CODE_BASE, "code_size": CODE_SIZE,
        "stack_base": "0x20000000", "stack_size": 0x10000,
        "sp_init": "0x%x" % (0x20000000 + 0x8000),
        "cases": cases,
    }
    open(OUT_JSON, "w").write(json.dumps(doc, indent=1))
    print("\n生成用例 %d 个 -> %s" % (len(cases), OUT_JSON))


if __name__ == "__main__":
    main()
