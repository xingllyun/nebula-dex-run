#!/usr/bin/env python3
# Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
# Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
"""从 dexop.py（权威表）机械生成 Sources/dex-core/SDRDexOpcode.swift。

骨架期的手写表曾出现约 27 处宽度错标（11x/12x/10t 记成 2、31i/51l/35c 被低估），
根因是"人工誊抄官方表"。此处改为代码生成：只要 dexop.py 正确，
Swift 侧不可能漂移；再由 verify_opcode_swift.py 做反向比对作为门禁。

用法：
    python3 Tests/dex/gen_dex_opcode_swift.py            # 写入默认路径
    python3 Tests/dex/gen_dex_opcode_swift.py --check    # 只校验不写入
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dexop  # noqa: E402

HEADER = '''/*
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
@@NAMES@@
    ]

    /// 指令格式（下标即 opcode，如 "12x" / "35c" / "51l"）
    public static let formats: [String] = [
@@FORMATS@@
    ]

    /// 指令长度（以 16 位 code unit 计，下标即 opcode）
    public static let widths: [Int] = [
@@WIDTHS@@
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
            return "opcode 表长度不一致：names=\\(names.count) formats=\\(formats.count) widths=\\(widths.count)"
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
'''


def _emit(items, per_line, fmt):
    out = []
    for i in range(0, len(items), per_line):
        chunk = items[i:i + per_line]
        out.append("        " + ", ".join(fmt(v) for v in chunk) + ",")
    return "\n".join(out)


def build() -> str:
    names, formats, widths = [], [], []
    for op in range(256):
        name = dexop.NAME.get(op)
        fmt = dexop.FORMAT.get(op)
        if name is None or fmt is None:
            raise SystemExit("dexop.py 缺少 opcode 0x%02X 的定义" % op)
        w = dexop.FORMAT_WIDTH.get(fmt)
        if w is None:
            raise SystemExit("dexop.py 的 FORMAT_WIDTH 缺少格式 %s（opcode 0x%02X）" % (fmt, op))
        names.append(name)
        formats.append(fmt)
        widths.append(w)
    # 用占位符替换而非 % 格式化：模板内含 %@ / %02X 等 Swift format 说明符，
    # 直接走 % 运算会被误当成占位符而抛 "unsupported format character"。
    body = HEADER
    body = body.replace("@@NAMES@@", _emit(names, 4, lambda s: '"%s"' % s))
    body = body.replace("@@FORMATS@@", _emit(formats, 8, lambda s: '"%s"' % s))
    body = body.replace("@@WIDTHS@@", _emit(widths, 16, lambda n: str(n)))
    return body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只比对不写入")
    ap.add_argument("--out", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "Sources", "dex-core", "SDRDexOpcode.swift"))
    args = ap.parse_args()
    text = build()
    out = os.path.normpath(args.out)
    if args.check:
        try:
            cur = open(out, encoding="utf-8").read()
        except OSError:
            print("未找到 %s" % out)
            return 1
        if cur != text:
            print("SDRDexOpcode.swift 与 dexop.py 不一致，请重新生成")
            return 1
        print("SDRDexOpcode.swift 与 dexop.py 一致（256 槽位）")
        return 0
    open(out, "w", encoding="utf-8").write(text)
    print("已生成 %s（%d 字节）" % (out, len(text.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
