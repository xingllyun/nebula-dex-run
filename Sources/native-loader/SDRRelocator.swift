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

public enum SDRRelocType: UInt32 {
    case none = 0
    case aarch64Abs64 = 257
    case aarch64GlobDat = 1025
    case aarch64JumpSlot = 1026
    case aarch64Relative = 1027
    case armAbs32 = 2
    case armGlobDat = 21
    case armJumpSlot = 22
    case armRelative = 23
}

/// 静态重定位器：不调用 dyld，全部在软件镜像内完成
public enum SDRRelocator {

    /// 按动态重定位表逐项落地：只改表里明确列出的槽位，不触碰其它数据
    public static func apply(image: SDRLoadedImage, dynamic: SDRElfDynamicInfo) throws {
        guard !dynamic.relocations.isEmpty else {
            SDRLogger.d("reloc", "无动态重定位表，跳过：\(image.path)")
            return
        }

        let base = image.loadBase
        let pointerSize = image.header.pointerSize
        var applied = 0
        var deferred = 0
        var skipped = 0

        for rel in dynamic.relocations {
            let target = base &+ rel.offset
            let symbol = Int(rel.symbolIndex) < dynamic.symbols.count
                ? dynamic.symbols[Int(rel.symbolIndex)]
                : nil
            var newValue: UInt64?

            switch rel.type {
            case SDRRelocType.aarch64Relative.rawValue, SDRRelocType.armRelative.rawValue:
                newValue = base &+ UInt64(bitPattern: rel.addend)

            case SDRRelocType.aarch64Abs64.rawValue, SDRRelocType.armAbs32.rawValue:
                if let sym = symbol, !sym.isUndefined {
                    newValue = base &+ sym.value &+ UInt64(bitPattern: rel.addend)
                } else {
                    deferred += 1
                }

            case SDRRelocType.aarch64GlobDat.rawValue, SDRRelocType.aarch64JumpSlot.rawValue,
                 SDRRelocType.armGlobDat.rawValue, SDRRelocType.armJumpSlot.rawValue:
                if let sym = symbol, !sym.isUndefined, sym.value != 0 {
                    newValue = base &+ sym.value
                } else {
                    // 外部符号：保留原值交调用期惰性解析，绝不写入伪地址
                    deferred += 1
                }

            default:
                skipped += 1
            }

            guard let value = newValue else { continue }
            do {
                try image.memory.writeScalar(target, value: value, count: pointerSize)
                applied += 1
            } catch {
                skipped += 1
            }
        }

        SDRLogger.d("reloc", "动态重定位生效 \(applied) 项（跳过 \(skipped)，外部符号待解析 \(deferred)）：\(image.path)")
    }

    public static func resolveLazy(image: SDRLoadedImage, symbol: String) -> UInt64? {
        if let addr = image.jniExports[symbol] { return addr }
        return nil
    }

    private static func readPointer(_ buf: [UInt8], at offset: Int, is64: Bool) -> UInt64? {
        if is64 {
            guard offset + 8 <= buf.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(buf[offset + i]) << (8 * UInt64(i)) }
            return v
        } else {
            guard offset + 4 <= buf.count else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(buf[offset + i]) << (8 * UInt32(i)) }
            return UInt64(v)
        }
    }

    private static func writePointer(_ buf: inout [UInt8], at offset: Int, value: UInt64, is64: Bool) {
        let n = is64 ? 8 : 4
        guard offset + n <= buf.count else { return }
        for i in 0..<n {
            buf[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF)
        }
    }
}
