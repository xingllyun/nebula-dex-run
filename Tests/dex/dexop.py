#!/usr/bin/env python3
"""Dalvik opcode 权威表（Python 侧唯一真源）。

用途：
1. 作为 SDRDexOpcode.swift 中 names / width 两张表的机械生成源，杜绝手写错标；
2. 作为本地 DEX 解析器与解释器模型的宽度依据；
3. 与 Swift 侧导出表做键集合一致性比对。

格式名与 code unit 宽度严格取自 Android 官方 DexOpcodes.h（Dalvik bytecode format 表）。
"""
import sys

FORMAT_WIDTH = {
    "10x": 1, "12x": 1, "11n": 1, "11x": 1, "10t": 1,
    "20t": 2, "22x": 2, "21s": 2, "21h": 2, "21c": 2, "21t": 2,
    "22t": 2, "22s": 2, "22b": 2, "22c": 2, "23x": 2,
    "30t": 3, "31i": 3, "31c": 3, "31t": 3, "32x": 3, "35c": 3, "3rc": 3,
    "45cc": 4, "4rcc": 4, "51l": 5,
}

# (opcode, 名称, 格式)
_ROWS = [
    (0x00, "nop", "10x"), (0x01, "move", "12x"), (0x02, "move/from16", "22x"),
    (0x03, "move/16", "32x"), (0x04, "move-wide", "12x"), (0x05, "move-wide/from16", "22x"),
    (0x06, "move-wide/16", "32x"), (0x07, "move-object", "12x"), (0x08, "move-object/from16", "22x"),
    (0x09, "move-object/16", "32x"), (0x0A, "move-result", "11x"), (0x0B, "move-result-wide", "11x"),
    (0x0C, "move-result-object", "11x"), (0x0D, "move-exception", "11x"), (0x0E, "return-void", "10x"),
    (0x0F, "return", "11x"), (0x10, "return-wide", "11x"), (0x11, "return-object", "11x"),
    (0x12, "const/4", "11n"), (0x13, "const/16", "21s"), (0x14, "const", "31i"),
    (0x15, "const/high16", "21h"), (0x16, "const-wide/16", "21s"), (0x17, "const-wide/32", "31i"),
    (0x18, "const-wide", "51l"), (0x19, "const-wide/high16", "21h"), (0x1A, "const-string", "21c"),
    (0x1B, "const-string/jumbo", "31c"), (0x1C, "const-class", "21c"), (0x1D, "monitor-enter", "11x"),
    (0x1E, "monitor-exit", "11x"), (0x1F, "check-cast", "21c"), (0x20, "instance-of", "22c"),
    (0x21, "array-length", "12x"), (0x22, "new-instance", "21c"), (0x23, "new-array", "22c"),
    (0x24, "filled-new-array", "35c"), (0x25, "filled-new-array/range", "3rc"),
    (0x26, "fill-array-data", "31t"), (0x27, "throw", "11x"), (0x28, "goto", "10t"),
    (0x29, "goto/16", "20t"), (0x2A, "goto/32", "30t"), (0x2B, "packed-switch", "31t"),
    (0x2C, "sparse-switch", "31t"), (0x2D, "cmpl-float", "23x"), (0x2E, "cmpg-float", "23x"),
    (0x2F, "cmpl-double", "23x"), (0x30, "cmpg-double", "23x"), (0x31, "cmp-long", "23x"),
    (0x32, "if-eq", "22t"), (0x33, "if-ne", "22t"), (0x34, "if-lt", "22t"), (0x35, "if-ge", "22t"),
    (0x36, "if-gt", "22t"), (0x37, "if-le", "22t"), (0x38, "if-eqz", "21t"), (0x39, "if-nez", "21t"),
    (0x3A, "if-ltz", "21t"), (0x3B, "if-gez", "21t"), (0x3C, "if-gtz", "21t"), (0x3D, "if-lez", "21t"),
    (0x3E, "unused-3e", "10x"), (0x3F, "unused-3f", "10x"), (0x40, "unused-40", "10x"),
    (0x41, "unused-41", "10x"), (0x42, "unused-42", "10x"), (0x43, "unused-43", "10x"),
    (0x44, "aget", "23x"), (0x45, "aget-wide", "23x"), (0x46, "aget-object", "23x"),
    (0x47, "aget-boolean", "23x"), (0x48, "aget-byte", "23x"), (0x49, "aget-char", "23x"),
    (0x4A, "aget-short", "23x"), (0x4B, "aput", "23x"), (0x4C, "aput-wide", "23x"),
    (0x4D, "aput-object", "23x"), (0x4E, "aput-boolean", "23x"), (0x4F, "aput-byte", "23x"),
    (0x50, "aput-char", "23x"), (0x51, "aput-short", "23x"), (0x52, "iget", "22c"),
    (0x53, "iget-wide", "22c"), (0x54, "iget-object", "22c"), (0x55, "iget-boolean", "22c"),
    (0x56, "iget-byte", "22c"), (0x57, "iget-char", "22c"), (0x58, "iget-short", "22c"),
    (0x59, "iput", "22c"), (0x5A, "iput-wide", "22c"), (0x5B, "iput-object", "22c"),
    (0x5C, "iput-boolean", "22c"), (0x5D, "iput-byte", "22c"), (0x5E, "iput-char", "22c"),
    (0x5F, "iput-short", "22c"), (0x60, "sget", "21c"), (0x61, "sget-wide", "21c"),
    (0x62, "sget-object", "21c"), (0x63, "sget-boolean", "21c"), (0x64, "sget-byte", "21c"),
    (0x65, "sget-char", "21c"), (0x66, "sget-short", "21c"), (0x67, "sput", "21c"),
    (0x68, "sput-wide", "21c"), (0x69, "sput-object", "21c"), (0x6A, "sput-boolean", "21c"),
    (0x6B, "sput-byte", "21c"), (0x6C, "sput-char", "21c"), (0x6D, "sput-short", "21c"),
    (0x6E, "invoke-virtual", "35c"), (0x6F, "invoke-super", "35c"), (0x70, "invoke-direct", "35c"),
    (0x71, "invoke-static", "35c"), (0x72, "invoke-interface", "35c"), (0x73, "unused-73", "10x"),
    (0x74, "invoke-virtual/range", "3rc"), (0x75, "invoke-super/range", "3rc"),
    (0x76, "invoke-direct/range", "3rc"), (0x77, "invoke-static/range", "3rc"),
    (0x78, "invoke-interface/range", "3rc"), (0x79, "unused-79", "10x"), (0x7A, "unused-7a", "10x"),
    (0x7B, "neg-int", "12x"), (0x7C, "not-int", "12x"), (0x7D, "neg-long", "12x"),
    (0x7E, "not-long", "12x"), (0x7F, "neg-float", "12x"), (0x80, "neg-double", "12x"),
    (0x81, "int-to-long", "12x"), (0x82, "int-to-float", "12x"), (0x83, "int-to-double", "12x"),
    (0x84, "long-to-int", "12x"), (0x85, "long-to-float", "12x"), (0x86, "long-to-double", "12x"),
    (0x87, "float-to-int", "12x"), (0x88, "float-to-long", "12x"), (0x89, "float-to-double", "12x"),
    (0x8A, "double-to-int", "12x"), (0x8B, "double-to-long", "12x"), (0x8C, "double-to-float", "12x"),
    (0x8D, "int-to-byte", "12x"), (0x8E, "int-to-char", "12x"), (0x8F, "int-to-short", "12x"),
    (0x90, "add-int", "23x"), (0x91, "sub-int", "23x"), (0x92, "mul-int", "23x"),
    (0x93, "div-int", "23x"), (0x94, "rem-int", "23x"), (0x95, "and-int", "23x"),
    (0x96, "or-int", "23x"), (0x97, "xor-int", "23x"), (0x98, "shl-int", "23x"),
    (0x99, "shr-int", "23x"), (0x9A, "ushr-int", "23x"), (0x9B, "add-long", "23x"),
    (0x9C, "sub-long", "23x"), (0x9D, "mul-long", "23x"), (0x9E, "div-long", "23x"),
    (0x9F, "rem-long", "23x"), (0xA0, "and-long", "23x"), (0xA1, "or-long", "23x"),
    (0xA2, "xor-long", "23x"), (0xA3, "shl-long", "23x"), (0xA4, "shr-long", "23x"),
    (0xA5, "ushr-long", "23x"), (0xA6, "add-float", "23x"), (0xA7, "sub-float", "23x"),
    (0xA8, "mul-float", "23x"), (0xA9, "div-float", "23x"), (0xAA, "rem-float", "23x"),
    (0xAB, "add-double", "23x"), (0xAC, "sub-double", "23x"), (0xAD, "mul-double", "23x"),
    (0xAE, "div-double", "23x"), (0xAF, "rem-double", "23x"),
    (0xB0, "add-int/2addr", "12x"), (0xB1, "sub-int/2addr", "12x"), (0xB2, "mul-int/2addr", "12x"),
    (0xB3, "div-int/2addr", "12x"), (0xB4, "rem-int/2addr", "12x"), (0xB5, "and-int/2addr", "12x"),
    (0xB6, "or-int/2addr", "12x"), (0xB7, "xor-int/2addr", "12x"), (0xB8, "shl-int/2addr", "12x"),
    (0xB9, "shr-int/2addr", "12x"), (0xBA, "ushr-int/2addr", "12x"), (0xBB, "add-long/2addr", "12x"),
    (0xBC, "sub-long/2addr", "12x"), (0xBD, "mul-long/2addr", "12x"), (0xBE, "div-long/2addr", "12x"),
    (0xBF, "rem-long/2addr", "12x"), (0xC0, "and-long/2addr", "12x"), (0xC1, "or-long/2addr", "12x"),
    (0xC2, "xor-long/2addr", "12x"), (0xC3, "shl-long/2addr", "12x"), (0xC4, "shr-long/2addr", "12x"),
    (0xC5, "ushr-long/2addr", "12x"), (0xC6, "add-float/2addr", "12x"), (0xC7, "sub-float/2addr", "12x"),
    (0xC8, "mul-float/2addr", "12x"), (0xC9, "div-float/2addr", "12x"), (0xCA, "rem-float/2addr", "12x"),
    (0xCB, "add-double/2addr", "12x"), (0xCC, "sub-double/2addr", "12x"),
    (0xCD, "mul-double/2addr", "12x"), (0xCE, "div-double/2addr", "12x"),
    (0xCF, "rem-double/2addr", "12x"),
    (0xD0, "add-int/lit16", "22s"), (0xD1, "rsub-int", "22s"), (0xD2, "mul-int/lit16", "22s"),
    (0xD3, "div-int/lit16", "22s"), (0xD4, "rem-int/lit16", "22s"), (0xD5, "and-int/lit16", "22s"),
    (0xD6, "or-int/lit16", "22s"), (0xD7, "xor-int/lit16", "22s"),
    (0xD8, "add-int/lit8", "22b"), (0xD9, "rsub-int/lit8", "22b"), (0xDA, "mul-int/lit8", "22b"),
    (0xDB, "div-int/lit8", "22b"), (0xDC, "rem-int/lit8", "22b"), (0xDD, "and-int/lit8", "22b"),
    (0xDE, "or-int/lit8", "22b"), (0xDF, "xor-int/lit8", "22b"), (0xE0, "shl-int/lit8", "22b"),
    (0xE1, "shr-int/lit8", "22b"), (0xE2, "ushr-int/lit8", "22b"),
]
for _op in range(0xE3, 0xFA):
    _ROWS.append((_op, "unused-%02x" % _op, "10x"))
_ROWS += [
    (0xFA, "invoke-polymorphic", "45cc"), (0xFB, "invoke-polymorphic/range", "4rcc"),
    (0xFC, "invoke-custom", "35c"), (0xFD, "invoke-custom/range", "3rc"),
    (0xFE, "const-method-handle", "21c"), (0xFF, "const-method-type", "21c"),
]

OPCODES = {op: (name, fmt) for op, name, fmt in _ROWS}
WIDTH = {op: FORMAT_WIDTH[fmt] for op, (_, fmt) in OPCODES.items()}
NAME = {op: name for op, (name, _) in OPCODES.items()}
FORMAT = {op: fmt for op, (_, fmt) in OPCODES.items()}


def _self_check():
    assert set(NAME) == set(range(256)), "opcode 覆盖不完整"
    assert len(_ROWS) == 256, "行数应为 256，实际 %d" % len(_ROWS)
    for op, fmt in FORMAT.items():
        assert fmt in FORMAT_WIDTH, "未知格式 %s @0x%02X" % (fmt, op)
    # 关键抽样：骨架期错标过的条目
    assert WIDTH[0x01] == 1 and WIDTH[0x04] == 1 and WIDTH[0x07] == 1
    assert WIDTH[0x0A] == 1 and WIDTH[0x0C] == 1
    assert WIDTH[0x0F] == 1 and WIDTH[0x10] == 1 and WIDTH[0x11] == 1
    assert WIDTH[0x21] == 1 and WIDTH[0x27] == 1 and WIDTH[0x28] == 1
    assert WIDTH[0x14] == 3 and WIDTH[0x18] == 5 and WIDTH[0x17] == 3
    assert WIDTH[0x6E] == 3 and WIDTH[0x71] == 3 and WIDTH[0x77] == 3
    assert WIDTH[0x2B] == 3 and WIDTH[0x2C] == 3
    assert WIDTH[0xB0] == 1 and NAME[0xB0] == "add-int/2addr"
    assert NAME[0xD0] == "add-int/lit16" and NAME[0xD8] == "add-int/lit8"
    assert WIDTH[0x12] == 1 and WIDTH[0x13] == 2 and WIDTH[0x15] == 2
    return True


if __name__ == "__main__":
    _self_check()
    if len(sys.argv) > 1 and sys.argv[1] == "swift":
        # 机械导出 Swift 片段，供 SDRDexOpcode.swift 生成比对
        print("public static let widths: [Int: Int] = [")
        line = "    "
        for op in range(256):
            piece = "0x%02X: %d, " % (op, WIDTH[op])
            if len(line) + len(piece) > 96:
                print(line.rstrip())
                line = "    "
            line += piece
        print(line.rstrip())
        print("]")
    else:
        print("opcode 表自检通过：256 项，格式 %d 种" % len(FORMAT_WIDTH))
        for op in (0x01, 0x0A, 0x0F, 0x12, 0x14, 0x18, 0x6E, 0x2B, 0xB0, 0xD0, 0xD8, 0xFA):
            print("  0x%02X %-24s %-5s width=%d" % (op, NAME[op], FORMAT[op], WIDTH[op]))
