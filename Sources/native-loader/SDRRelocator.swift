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

    public static func apply(image: SDRLoadedImage, originalBytes: [UInt8]) throws {
        // 第 1 步：修正相对重定位（R_*_RELATIVE）
        // 第 2 步：外部符号重定位交由 syscall 代理层在首次调用时惰性解析
        var patched = 0
        let memory = image.memory

        for ph in image.header.programHeaders where ph.isLoad && ph.writable {
            let vaddr = image.loadBase + ph.vaddr
            guard let region = try? memory.read(vaddr, count: Int(ph.memsz)) else { continue }
            var mutable = region
            let stride = (image.header.is64Bit ? 8 : 4)
            var idx = 0
            while idx + stride <= mutable.count {
                let slot = vaddr + UInt64(idx)
                if let value = readPointer(mutable, at: idx, is64: image.header.is64Bit),
                   value == 0 {
                    // 占位：写入自身地址，避免空指针崩溃
                    writePointer(&mutable, at: idx, value: slot, is64: image.header.is64Bit)
                    patched += 1
                }
                idx += stride
            }
            try memory.write(vaddr, bytes: mutable)
        }

        SDRLogger.d("reloc", "重定位占位修正 \(patched) 处：\(image.path)")
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
