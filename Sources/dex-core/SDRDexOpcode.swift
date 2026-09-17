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

import Foundation

/// Dalvik 字节码表（按需子集；未实现项统一按 DEX_OP_UNSUPPORTED 记录）
public enum SDRDexOpcode {
    public static let names: [Int: String] = [
        0x00: "nop", 0x01: "move", 0x02: "move/from16", 0x03: "move/16",
        0x04: "move-wide", 0x05: "move-wide/from16", 0x06: "move-wide/16",
        0x07: "move-object", 0x0A: "move-result", 0x0C: "move-result-object",
        0x0E: "return-void", 0x0F: "return", 0x10: "return-wide", 0x11: "return-object",
        0x12: "const/4", 0x13: "const/16", 0x14: "const", 0x15: "const/high16",
        0x16: "const-wide/16", 0x17: "const-wide/32", 0x18: "const-wide",
        0x1A: "const-string", 0x1C: "const-class", 0x1F: "check-cast",
        0x21: "array-length", 0x22: "new-instance", 0x23: "new-array",
        0x27: "throw", 0x28: "goto", 0x29: "goto/16", 0x2A: "goto/32",
        0x2B: "packed-switch", 0x2D: "cmpl-float", 0x2E: "cmpg-float",
        0x2F: "cmpl-double", 0x30: "cmpg-double", 0x31: "cmp-long",
        0x32: "if-eq", 0x33: "if-ne", 0x34: "if-lt", 0x35: "if-ge",
        0x36: "if-gt", 0x37: "if-le", 0x38: "if-eqz", 0x39: "if-nez",
        0x3A: "if-ltz", 0x3B: "if-gez", 0x3C: "if-gtz", 0x3D: "if-lez",
        0x44: "aget", 0x45: "aget-wide", 0x46: "aget-object", 0x4B: "aput",
        0x52: "iget", 0x59: "iput", 0x5B: "sget", 0x61: "sput",
        0x6E: "invoke-virtual", 0x6F: "invoke-super", 0x70: "invoke-direct",
        0x71: "invoke-static", 0x72: "invoke-interface",
        0x74: "invoke-virtual/range", 0x75: "invoke-super/range",
        0x76: "invoke-direct/range", 0x77: "invoke-static/range",
        0x78: "invoke-interface/range",
        0x7B: "neg-int", 0x7C: "not-int", 0x7D: "neg-long", 0x7E: "not-long",
        0x81: "int-to-long", 0x8F: "int-to-byte", 0x90: "add-int",
        0x91: "sub-int", 0x92: "mul-int", 0x93: "div-int", 0x94: "rem-int",
        0x95: "and-int", 0x96: "or-int", 0x97: "xor-int", 0x98: "shl-int",
        0x99: "shr-int", 0x9A: "ushr-int",
        0xA0: "add-long", 0xA1: "sub-long", 0xA2: "mul-long",
        0xAB: "add-int/2addr", 0xAC: "sub-int/2addr", 0xB0: "add-int/lit16",
        0xD0: "add-int/lit8", 0xD8: "add-int/lit8",
        0xFF: "unused",
    ]

    /// 指令长度（以 16 位 code unit 计），0 表示需按格式特判
    public static func width(opcode: Int) -> Int {
        switch opcode {
        case 0x00, 0x0E: return 1
        case 0x12: return 1
        case 0x01, 0x04, 0x07, 0x0A, 0x0C, 0x0F, 0x10, 0x11, 0x13, 0x15,
             0x16, 0x1C, 0x1F, 0x21, 0x22, 0x23, 0x27, 0x28, 0x2D, 0x2E,
             0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
             0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x44, 0x45, 0x46, 0x4B, 0x52,
             0x59, 0x5B, 0x61, 0x7B, 0x7C, 0x81, 0x8F, 0x90, 0x91, 0x92,
             0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xAB, 0xAC,
             0xD0: return 2
        case 0x02, 0x05, 0x08, 0x14, 0x17, 0x1A, 0x29, 0x6E, 0x6F, 0x70,
             0x71, 0x72, 0xB0: return 2
        case 0x03, 0x06, 0x09, 0x18, 0x2A: return 3
        case 0x74, 0x75, 0x76, 0x77, 0x78: return 3
        case 0x2B, 0x2C: return 0
        default: return 2
        }
    }
}
