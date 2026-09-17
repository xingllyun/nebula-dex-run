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

/// 安卓二进制 XML 的字符串池提取（用于包名/版本等基础识别）
public enum SDRBinaryXML {

    public static func stringPool(_ data: [UInt8]) -> [String] {
        guard data.count > 8 else { return [] }
        // 头部：type(2) headerSize(2) size(4)
        var r = SDRByteReader(data)
        guard let type = r.u16(), type == 0x0003, let headerSize = r.u16(), let _ = r.u32() else { return [] }
        guard let stringCount = r.u32(), let _ = r.u32(), let flags = r.u32(), let stringsStart = r.u32() else { return [] }
        let utf8 = (flags & (1 << 8)) != 0
        guard let _ = r.u32() else { return [] }

        let offsetsStart = Int(headerSize)
        var result: [String] = []
        let base = Int(stringsStart)

        for i in 0..<Int(stringCount) {
            let offPos = offsetsStart + i * 4
            guard offPos + 4 <= data.count else { break }
            var o = SDRByteReader(Array(data[offPos...]))
            guard let offset = o.u32() else { break }
            let pos = base + Int(offset)
            guard pos < data.count else { break }
            if utf8 {
                result.append(readUTF8(data, pos))
            } else {
                result.append(readUTF16(data, pos))
            }
        }
        return result
    }

    private static func readUTF8(_ data: [UInt8], _ pos: Int) -> String {
        var p = pos
        // 字符数 + 字节数（UTF-16 长度形式），此处取字节数近似
        guard p < data.count else { return "" }
        if data[p] & 0x80 != 0 { p += 2 } else { p += 1 }
        guard p < data.count else { return "" }
        var len = 0
        if data[p] & 0x80 != 0 {
            len = (Int(data[p] & 0x7F) << 8) | Int(data[p + 1])
            p += 2
        } else {
            len = Int(data[p])
            p += 1
        }
        guard p + len <= data.count else { return "" }
        return String(bytes: data[p..<(p + len)], encoding: .utf8) ?? ""
    }

    private static func readUTF16(_ data: [UInt8], _ pos: Int) -> String {
        var p = pos
        guard p + 2 <= data.count else { return "" }
        var len = Int(data[p]) | (Int(data[p + 1]) << 8)
        p += 2
        if len & 0x8000 != 0 {
            guard p + 2 <= data.count else { return "" }
            len = (len & 0x7FFF) | (Int(data[p]) << 16)
            p += 2
        }
        let byteLen = len * 2
        guard p + byteLen <= data.count else { return "" }
        var units: [UInt16] = []
        var i = p
        while i + 1 < p + byteLen {
            units.append(UInt16(data[i]) | (UInt16(data[i + 1]) << 8))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// 从字符串池推断包名/版本（启发式；精确解析需完整 AXML 属性表，后续迭代）
public enum SDRManifestReader {
    public static func packageName(from strings: [String]) -> String? {
        strings.first { s in
            s.contains(".") && !s.contains(" ") && !s.contains("/") &&
            s.range(of: "^[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z0-9_]+)+$", options: .regularExpression) != nil
        }
    }

    public static func versionName(from strings: [String]) -> String? {
        strings.first { s in
            s.range(of: "^[0-9]+(\\.[0-9]+){1,2}$", options: .regularExpression) != nil
        }
    }
}
