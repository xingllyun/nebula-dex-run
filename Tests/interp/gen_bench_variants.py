#!/usr/bin/env python3
"""生成三份基准变体，用于定位解释器吞吐量瓶颈：
  full     标量 ALU + NEON + 访存 + 分支（12 指令/轮）
  no_store 去掉 str/ldr（10 指令/轮）
  no_neon  NEON 换成标量（保持 12 指令/轮，条数可比）
"""
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "gen_vectors_neon.py")
spec = importlib.util.spec_from_file_location("gvn", SRC)
gvn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gvn)

ITERATIONS = 500_000

COMMON = [
    "add x1, x1, #1",
    "add x2, x2, #3",
    "eor x3, x1, x2",
    "lsl x4, x3, #2",
    "and x5, x4, x2",
    "orr x6, x5, x1",
]
NEON = ["add v3.4s, v5.4s, v7.4s", "eor v4.16b, v5.16b, v6.16b"]
NEON_ALT = ["add x10, x5, x1", "eor x11, x6, x2"]
STORE = ["str x6, [sp, #-16]", "ldr x7, [sp, #-16]"]

VARIANTS = {
    "full": COMMON + NEON + STORE,
    "no_store": COMMON + NEON,
    "no_neon": COMMON + NEON_ALT + STORE,
}

docs = {}
for name, body in VARIANTS.items():
    insns = ["mov x9, x0", "bench_loop:"] + body + ["sub x9, x9, #1", "cbnz x9, bench_loop", "brk #0"]
    code, err = gvn.assemble(insns, "bench_" + name)
    assert err is None, err
    per_iter = len(body) + 2
    docs[name] = {
        "comment": "bench variant " + name,
        "code_base": hex(gvn.CODE_BASE),
        "code_size": gvn.CODE_SIZE,
        "stack_base": "0x20000000",
        "stack_size": 0x10000,
        "sp_init": "0x20008000",
        "code_hex": bytes(code).hex(),
        "iterations": ITERATIONS,
        "instructions_per_iteration": per_iter,
        "budget": ITERATIONS * per_iter + 64,
    }
    out = os.path.join(HERE, "bench_%s.json" % name)
    json.dump(docs[name], open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("%-10s 指令/轮 = %2d | 机器码 %d 字节 -> %s" % (name, per_iter, len(code), os.path.basename(out)))
