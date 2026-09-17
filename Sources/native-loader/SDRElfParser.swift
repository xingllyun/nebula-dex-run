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

public struct SDRElfProgramHeader {
    public var type: UInt32
    public var flags: UInt32
    public var offset: UInt64
    public var vaddr: UInt64
    public var filesz: UInt64
    public var memsz: UInt64
    public var align: UInt64

    public var isLoad: Bool { type == 1 }        // PT_LOAD
    public var isDynamic: Bool { type == 2 }     // PT_DYNAMIC
    public var readable: Bool { flags & 4 != 0 }
    public var writable: Bool { flags & 2 != 0 }
    public var executable: Bool { flags & 1 != 0 }
}

public struct SDRElfHeader {
    public var is64Bit: Bool
    public var littleEndian: Bool
    public var type: UInt16
    public var machine: UInt16
    public var entry: UInt64
    public var programHeaders: [SDRElfProgramHeader]

    /// 0xB7 = AArch64，0x28 = ARM
    public var abiName: String {
        switch machine {
        case 0xB7: return "arm64-v8a"
        case 0x28: return "armeabi-v7a"
        case 0x3E: return "x86_64"
        case 0x03: return "x86"
        default: return "unknown"
        }
    }

    public var pointerSize: Int { is64Bit ? 8 : 4 }
}

public enum SDRElfParser {

    public static func parse(_ data: [UInt8]) throws -> SDRElfHeader {
        guard data.count >= 52,
              data[0] == 0x7F, data[1] == 0x45, data[2] == 0x4C, data[3] == 0x46 else {
            throw SDRAppError(.soElfBadMagic, "ELF 魔数不匹配")
        }
        let elfClass = data[4]
        let dataEncoding = data[5]
        guard elfClass == 1 || elfClass == 2 else {
            throw SDRAppError(.soElfBadMagic, "未知 ELF 类别")
        }
        let is64 = (elfClass == 2)
        let little = (dataEncoding == 1)

        var r = SDRByteReader(data, littleEndian: little)
        r.seek(16)
        guard let type = r.u16(), let machine = r.u16(), let _ = r.u32() else {
            throw SDRAppError(.soElfBadMagic, "ELF 头解析失败")
        }

        var entry: UInt64 = 0
        var phoff: UInt64 = 0
        var phentsize: UInt16 = 0
        var phnum: UInt16 = 0

        if is64 {
            guard let e = r.u64(), let ph = r.u64(), let _ = r.u64(), let _ = r.u32() else {
                throw SDRAppError(.soElfBadMagic, "ELF64 头解析失败")
            }
            entry = e; phoff = ph
            r.skip(6)
            guard let pes = r.u16(), let pn = r.u16() else {
                throw SDRAppError(.soElfBadMagic, "ELF64 程序头参数缺失")
            }
            phentsize = pes; phnum = pn
        } else {
            guard let e = r.u32(), let ph = r.u32(), let _ = r.u32(), let _ = r.u32() else {
                throw SDRAppError(.soElfBadMagic, "ELF32 头解析失败")
            }
            entry = UInt64(e); phoff = UInt64(ph)
            r.skip(6)
            guard let pes = r.u16(), let pn = r.u16() else {
                throw SDRAppError(.soElfBadMagic, "ELF32 程序头参数缺失")
            }
            phentsize = pes; phnum = pn
        }

        guard phnum > 0 else { throw SDRAppError(.soElfBadMagic, "无程序头") }

        var headers: [SDRElfProgramHeader] = []
        for i in 0..<Int(phnum) {
            let base = Int(phoff) + i * Int(phentsize)
            guard base + (is64 ? 56 : 32) <= data.count else { break }
            var p = SDRByteReader(data, littleEndian: little)
            p.seek(base)
            if is64 {
                guard let t = p.u32(), let f = p.u32(), let off = p.u64(), let va = p.u64(),
                      let _ = p.u64(), let fsz = p.u64(), let msz = p.u64(), let al = p.u64() else { break }
                headers.append(SDRElfProgramHeader(type: t, flags: f, offset: off, vaddr: va,
                                                   filesz: fsz, memsz: msz, align: al))
            } else {
                guard let t = p.u32(), let off = p.u32(), let va = p.u32(), let _ = p.u32(),
                      let fsz = p.u32(), let msz = p.u32(), let f = p.u32(), let al = p.u32() else { break }
                headers.append(SDRElfProgramHeader(type: t, flags: f, offset: UInt64(off), vaddr: UInt64(va),
                                                   filesz: UInt64(fsz), memsz: UInt64(msz), align: UInt64(al)))
            }
        }

        guard headers.contains(where: { $0.isLoad }) else {
            throw SDRAppError(.soElfBadMagic, "缺少 PT_LOAD 段")
        }

        return SDRElfHeader(is64Bit: is64, littleEndian: little, type: type, machine: machine,
                            entry: entry, programHeaders: headers)
    }
}
