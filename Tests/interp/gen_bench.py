#!/usr/bin/env python3
"""生成解释器吞吐量基准程序（热循环，混合标量 ALU / NEON / 访存 / 分支）。

输出 bench.json：
  code_hex     循环程序机器码
  iterations   循环轮数（由 x0 传入循环计数器初值）
  budget       解释器指令预算（略大于总指令数）
"""
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "gen_vectors_neon.py")

spec = importlib.util.spec_from_file_location("gvn", SRC)
gvn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gvn)

BODY = [
    "add x1, x1, #1",
    "add x2, x2, #3",
    "eor x3, x1, x2",
    "lsl x4, x3, #2",
    "and x5, x4, x2",
    "orr x6, x5, x1",
    "add v3.4s, v5.4s, v7.4s",
    "eor v4.16b, v5.16b, v6.16b",
    "str x6, [sp, #-16]",
    "ldr x7, [sp, #-16]",
    "sub x9, x9, #1",
]
BRANCH = "cbnz x9, bench_loop"

INSNS = ["mov x9, x0", "bench_loop:"] + BODY + [BRANCH, "brk #0"]
PER_ITER = len(BODY) + 1          # 分支算 1 条
ITERATIONS = 500_000

code, err = gvn.assemble(INSNS, "bench_loop")
assert err is None, err

doc = {
    "comment": "NebulaDex 解释器吞吐量基准：标量 ALU + NEON + 访存 + 循环分支",
    "code_base": hex(gvn.CODE_BASE),
    "code_size": gvn.CODE_SIZE,
    "stack_base": "0x20000000",
    "stack_size": 0x10000,
    "sp_init": "0x20008000",
    "code_hex": bytes(code).hex(),
    "iterations": ITERATIONS,
    "instructions_per_iteration": PER_ITER,
    "budget": ITERATIONS * PER_ITER + 64,
}

out = os.path.join(HERE, "bench.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=1)
print("指令数/轮 = %d | 机器码 %d 字节 | 预算 %d"
      % (PER_ITER, len(code), doc["budget"]))
print("生成 ->", out)
