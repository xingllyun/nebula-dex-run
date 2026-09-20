/*
Copyright © 2026 星云云络科技 (Xingyun Cloud Tech)
Project: NebulaDex - iOS APK Runtime

Licensed under the MIT License (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://opensource.org/licenses/MIT

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

// ============================================================================
// 本文件由 Tests/dex/gen_dex_opcode_swift.py 从 Tests/dex/dexop.py 机械生成，
// 请勿手工修改。修改 opcode 表请改 dexop.py 后重新生成：
//     python3 Tests/dex/gen_dex_opcode_swift.py
// 生成后可用 Tests/dex/verify_opcode_swift.py 做反向一致性校验。
// 权威来源：Android 官方 Dalvik bytecode format 表（code unit 宽度以格式为准）。
// ============================================================================

import Foundation

/// Dalvik 字节码静态表：名称 / 格式 / 宽度（code unit）。
///
/// 宽度不再"按需子集 + 特判"，而是覆盖 0x00-0xFF 全 256 槽位的完整表；
/// 未定义槽位统一命名 `unused-xx`，宽度按 10x 记 1。
public enum SDRDexOpcode {

    /// 指令槽位总数
    public static let slotCount = 256

    /// 指令名（下标即 opcode）
    public static let names: [String] = [
        "nop", "move", "move/from16", "move/16",
        "move-wide", "move-wide/from16", "move-wide/16", "move-object",
        "move-object/from16", "move-object/16", "move-result", "move-result-wide",
        "move-result-object", "move-exception", "return-void", "return",
        "return-wide", "return-object", "const/4", "const/16",
        "const", "const/high16", "const-wide/16", "const-wide/32",
        "const-wide", "const-wide/high16", "const-string", "const-string/jumbo",
        "const-class", "monitor-enter", "monitor-exit", "check-cast",
        "instance-of", "array-length", "new-instance", "new-array",
        "filled-new-array", "filled-new-array/range", "fill-array-data", "throw",
        "goto", "goto/16", "goto/32", "packed-switch",
        "sparse-switch", "cmpl-float", "cmpg-float", "cmpl-double",
        "cmpg-double", "cmp-long", "if-eq", "if-ne",
        "if-lt", "if-ge", "if-gt", "if-le",
        "if-eqz", "if-nez", "if-ltz", "if-gez",
        "if-gtz", "if-lez", "unused-3e", "unused-3f",
        "unused-40", "unused-41", "unused-42", "unused-43",
        "aget", "aget-wide", "aget-object", "aget-boolean",
        "aget-byte", "aget-char", "aget-short", "aput",
        "aput-wide", "aput-object", "aput-boolean", "aput-byte",
        "aput-char", "aput-short", "iget", "iget-wide",
        "iget-object", "iget-boolean", "iget-byte", "iget-char",
        "iget-short", "iput", "iput-wide", "iput-object",
        "iput-boolean", "iput-byte", "iput-char", "iput-short",
        "sget", "sget-wide", "sget-object", "sget-boolean",
        "sget-byte", "sget-char", "sget-short", "sput",
        "sput-wide", "sput-object", "sput-boolean", "sput-byte",
        "sput-char", "sput-short", "invoke-virtual", "invoke-super",
        "invoke-direct", "invoke-static", "invoke-interface", "unused-73",
        "invoke-virtual/range", "invoke-super/range", "invoke-direct/range", "invoke-static/range",
        "invoke-interface/range", "unused-79", "unused-7a", "neg-int",
        "not-int", "neg-long", "not-long", "neg-float",
        "neg-double", "int-to-long", "int-to-float", "int-to-double",
        "long-to-int", "long-to-float", "long-to-double", "float-to-int",
        "float-to-long", "float-to-double", "double-to-int", "double-to-long",
        "double-to-float", "int-to-byte", "int-to-char", "int-to-short",
        "add-int", "sub-int", "mul-int", "div-int",
        "rem-int", "and-int", "or-int", "xor-int",
        "shl-int", "shr-int", "ushr-int", "add-long",
        "sub-long", "mul-long", "div-long", "rem-long",
        "and-long", "or-long", "xor-long", "shl-long",
        "shr-long", "ushr-long", "add-float", "sub-float",
        "mul-float", "div-float", "rem-float", "add-double",
        "sub-double", "mul-double", "div-double", "rem-double",
        "add-int/2addr", "sub-int/2addr", "mul-int/2addr", "div-int/2addr",
        "rem-int/2addr", "and-int/2addr", "or-int/2addr", "xor-int/2addr",
        "shl-int/2addr", "shr-int/2addr", "ushr-int/2addr", "add-long/2addr",
        "sub-long/2addr", "mul-long/2addr", "div-long/2addr", "rem-long/2addr",
        "and-long/2addr", "or-long/2addr", "xor-long/2addr", "shl-long/2addr",
        "shr-long/2addr", "ushr-long/2addr", "add-float/2addr", "sub-float/2addr",
        "mul-float/2addr", "div-float/2addr", "rem-float/2addr", "add-double/2addr",
        "sub-double/2addr", "mul-double/2addr", "div-double/2addr", "rem-double/2addr",
        "add-int/lit16", "rsub-int", "mul-int/lit16", "div-int/lit16",
        "rem-int/lit16", "and-int/lit16", "or-int/lit16", "xor-int/lit16",
        "add-int/lit8", "rsub-int/lit8", "mul-int/lit8", "div-int/lit8",
        "rem-int/lit8", "and-int/lit8", "or-int/lit8", "xor-int/lit8",
        "shl-int/lit8", "shr-int/lit8", "ushr-int/lit8", "unused-e3",
        "unused-e4", "unused-e5", "unused-e6", "unused-e7",
        "unused-e8", "unused-e9", "unused-ea", "unused-eb",
        "unused-ec", "unused-ed", "unused-ee", "unused-ef",
        "unused-f0", "unused-f1", "unused-f2", "unused-f3",
        "unused-f4", "unused-f5", "unused-f6", "unused-f7",
        "unused-f8", "unused-f9", "invoke-polymorphic", "invoke-polymorphic/range",
        "invoke-custom", "invoke-custom/range", "const-method-handle", "const-method-type",
    ]

    /// 指令格式（下标即 opcode，如 "12x" / "35c" / "51l"）
    public static let formats: [String] = [
        "10x", "12x", "22x", "32x", "12x", "22x", "32x", "12x",
        "22x", "32x", "11x", "11x", "11x", "11x", "10x", "11x",
        "11x", "11x", "11n", "21s", "31i", "21h", "21s", "31i",
        "51l", "21h", "21c", "31c", "21c", "11x", "11x", "21c",
        "22c", "12x", "21c", "22c", "35c", "3rc", "31t", "11x",
        "10t", "20t", "30t", "31t", "31t", "23x", "23x", "23x",
        "23x", "23x", "22t", "22t", "22t", "22t", "22t", "22t",
        "21t", "21t", "21t", "21t", "21t", "21t", "10x", "10x",
        "10x", "10x", "10x", "10x", "23x", "23x", "23x", "23x",
        "23x", "23x", "23x", "23x", "23x", "23x", "23x", "23x",
        "23x", "23x", "22c", "22c", "22c", "22c", "22c", "22c",
        "22c", "22c", "22c", "22c", "22c", "22c", "22c", "22c",
        "21c", "21c", "21c", "21c", "21c", "21c", "21c", "21c",
        "21c", "21c", "21c", "21c", "21c", "21c", "35c", "35c",
        "35c", "35c", "35c", "10x", "3rc", "3rc", "3rc", "3rc",
        "3rc", "10x", "10x", "12x", "12x", "12x", "12x", "12x",
        "12x", "12x", "12x", "12x", "12x", "12x", "12x", "12x",
        "12x", "12x", "12x", "12x", "12x", "12x", "12x", "12x",
        "23x", "23x", "23x", "23x", "23x", "23x", "23x", "23x",
        "23x", "23x", "23x", "23x", "23x", "23x", "23x", "23x",
        "23x", "23x", "23x", "23x", "23x", "23x", "23x", "23x",
        "23x", "23x", "23x", "23x", "23x", "23x", "23x", "23x",
        "12x", "12x", "12x", "12x", "12x", "12x", "12x", "12x",
        "12x", "12x", "12x", "12x", "12x", "12x", "12x", "12x",
        "12x", "12x", "12x", "12x", "12x", "12x", "12x", "12x",
        "12x", "12x", "12x", "12x", "12x", "12x", "12x", "12x",
        "22s", "22s", "22s", "22s", "22s", "22s", "22s", "22s",
        "22b", "22b", "22b", "22b", "22b", "22b", "22b", "22b",
        "22b", "22b", "22b", "10x", "10x", "10x", "10x", "10x",
        "10x", "10x", "10x", "10x", "10x", "10x", "10x", "10x",
        "10x", "10x", "10x", "10x", "10x", "10x", "10x", "10x",
        "10x", "10x", "45cc", "4rcc", "35c", "3rc", "21c", "21c",
    ]

    /// 指令长度（以 16 位 code unit 计，下标即 opcode）
    public static let widths: [Int] = [
        1, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 2, 3, 2, 2, 3, 5, 2, 2, 3, 2, 1, 1, 2,
        2, 1, 2, 2, 3, 3, 3, 1, 1, 2, 3, 3, 3, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1,
        1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3,
        3, 3, 3, 1, 3, 3, 3, 3, 3, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 4, 4, 3, 3, 2, 2,
    ]

    /// 取指令宽度；越界返回 0
    public static func width(opcode: Int) -> Int {
        guard opcode >= 0 && opcode < slotCount else { return 0 }
        return widths[opcode]
    }

    /// 取指令名；越界返回占位名
    public static func name(opcode: Int) -> String {
        guard opcode >= 0 && opcode < slotCount else { return String(format: "??0x%02X", opcode) }
        return names[opcode]
    }

    /// 取指令格式；越界返回 "?"
    public static func format(opcode: Int) -> String {
        guard opcode >= 0 && opcode < slotCount else { return "?" }
        return formats[opcode]
    }

    /// 是否为非指令槽位（官方未定义，出现即视为非法字节码）
    public static func isUnused(opcode: Int) -> Bool {
        guard opcode >= 0 && opcode < slotCount else { return true }
        return names[opcode].hasPrefix("unused-")
    }

    /// 静态自检：三张表长度一致且宽度与格式表自洽。返回 nil 表示通过。
    public static func validate() -> String? {
        guard names.count == slotCount, formats.count == slotCount, widths.count == slotCount else {
            return "opcode 表长度不一致：names=\(names.count) formats=\(formats.count) widths=\(widths.count)"
        }
        for op in 0..<slotCount {
            let expect = SDRDexOpcode.widthOfFormat(formats[op])
            if expect != widths[op] {
                return String(format: "宽度表与格式表不一致：0x%02X %@ 格式=%@ 宽度=%d 应为 %d",
                              op, names[op], formats[op], widths[op], expect)
            }
        }
        return nil
    }

    /// 由格式名推导 code unit 宽度（与 dexop.py 的 FORMAT_WIDTH 保持一致）
    public static func widthOfFormat(_ format: String) -> Int {
        switch format {
        case "10x", "12x", "11n", "11x", "10t": return 1
        case "20t", "22x", "21s", "21h", "21c", "21t", "22t", "22s", "22b", "22c", "23x": return 2
        case "30t", "31i", "31c", "31t", "32x", "35c", "3rc": return 3
        case "45cc", "4rcc": return 4
        case "51l": return 5
        default: return 0
        }
    }
}
