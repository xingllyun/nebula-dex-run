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
import zlib

/// 极简 ZIP 读取器：仅支持本项目所需（中央目录 + Deflate/Store 解压）
public final class SDRZipArchive {
    public struct Entry {
        public let name: String
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let compressionMethod: UInt16
        public let localHeaderOffset: Int
    }

    public private(set) var entries: [Entry] = []
    private let bytes: [UInt8]

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        self.bytes = [UInt8](data)
        try readCentralDirectory()
    }

    /// 内存字节构造：APK/构件已在内存中（导入校验、CI 冒烟）时避免二次落盘
    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        try readCentralDirectory()
    }

    private func readCentralDirectory() throws {
        guard bytes.count > 22 else { throw SDRAppError(.apkBadZip, "文件过小，不是合法 ZIP") }

        // 从尾部向前找 EOCD（0x06054b50）
        var eocd = -1
        let lower = max(0, bytes.count - 65557)
        var i = bytes.count - 22
        while i >= lower {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06,
               i + 22 <= bytes.count {
                eocd = i; break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw SDRAppError(.apkBadZip, "未找到 ZIP 中央目录结束记录") }

        var r = SDRByteReader(Array(bytes[eocd...]))
        r.skip(8)                                           // 签名 + 本盘号 + 目录起始盘号
        guard let entriesThisDisk = r.u16(), let total = r.u16(),
              let _ = r.u32(), let cdOffset32 = r.u32() else {
            throw SDRAppError(.apkBadZip, "EOCD 解析失败")
        }

        // ZIP64 分流：出现哨兵值时改走 ZIP64 结束记录
        var entryCount = Int(total)
        var p = Int(cdOffset32)
        if total == 0xFFFF || cdOffset32 == 0xFFFF_FFFF || entriesThisDisk == 0xFFFF,
           let zip64 = zip64Directory(eocd: eocd) {
            entryCount = zip64.count
            p = zip64.offset
        }

        for _ in 0..<entryCount {
            guard p + 46 <= bytes.count,
                  bytes[p] == 0x50, bytes[p + 1] == 0x4b, bytes[p + 2] == 0x01, bytes[p + 3] == 0x02 else { break }
            var e = SDRByteReader(Array(bytes[(p + 4)...]))
            e.skip(4)                                          // version made by + version needed
            guard let _ = e.u16(), let method = e.u16() else { break }   // flags + method
            e.skip(8)                                          // time(2) + date(2) + crc32(4)
            guard let csize = e.u32(), let usize = e.u32() else { break }
            guard let nameLen = e.u16(), let extraLen = e.u16(), let commentLen = e.u16() else { break }
            e.skip(8)                                          // disk + internal attrs + external attrs
            guard let lho = e.u32(), let nameBytes = e.bytes(Int(nameLen)) else { break }
            let extraBytes = e.bytes(Int(extraLen)) ?? []

            // ZIP64 扩展字段（0x0001）：哨兵值按“未压缩大小 / 压缩大小 / 本地头偏移”顺序回填
            var resolvedUsize = UInt64(usize)
            var resolvedCsize = UInt64(csize)
            var resolvedLho = UInt64(lho)
            if usize == 0xFFFF_FFFF || csize == 0xFFFF_FFFF || lho == 0xFFFF_FFFF {
                let zip64Values = Self.zip64ExtraValues(extraBytes)
                var index = 0
                if usize == 0xFFFF_FFFF, index < zip64Values.count { resolvedUsize = zip64Values[index]; index += 1 }
                if csize == 0xFFFF_FFFF, index < zip64Values.count { resolvedCsize = zip64Values[index]; index += 1 }
                if lho == 0xFFFF_FFFF, index < zip64Values.count { resolvedLho = zip64Values[index] }
            }

            // 名称编码：UTF-8 优先，无 UTF-8 标志位时回退 Latin-1，避免整包误判为损坏
            let name = String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1)
                ?? ""
            guard !name.isEmpty else {
                p += 46 + Int(nameLen) + Int(extraLen) + Int(commentLen)
                continue
            }

            entries.append(Entry(name: name,
                                 compressedSize: Int(resolvedCsize),
                                 uncompressedSize: Int(resolvedUsize),
                                 compressionMethod: method,
                                 localHeaderOffset: Int(resolvedLho)))
            p += 46 + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }

        guard !entries.isEmpty else { throw SDRAppError(.apkBadZip, "ZIP 内无任何条目") }
    }

    /// ZIP64 结束记录定位：EOCD 前 20 字节为 locator（0x07064b50）
    private func zip64Directory(eocd: Int) -> (offset: Int, count: Int)? {
        let locator = eocd - 20
        guard locator >= 0, locator + 20 <= bytes.count,
              bytes[locator] == 0x50, bytes[locator + 1] == 0x4b,
              bytes[locator + 2] == 0x06, bytes[locator + 3] == 0x07 else { return nil }
        var l = SDRByteReader(Array(bytes[(locator + 4)...]))
        guard let _ = l.u32(), let recordOffset = l.u64() else { return nil }
        let base = Int(recordOffset)
        guard base >= 0, base + 56 <= bytes.count,
              bytes[base] == 0x50, bytes[base + 1] == 0x4b,
              bytes[base + 2] == 0x06, bytes[base + 3] == 0x06 else { return nil }
        var z = SDRByteReader(Array(bytes[(base + 4)...]))
        guard let _ = z.u64(), let _ = z.u16(), let _ = z.u16(),
              let _ = z.u32(), let _ = z.u32(),
              let _ = z.u64(),          // 本盘条目数
              let count = z.u64(),      // 总条目数
              let _ = z.u64(),          // 中央目录大小
              let cdOffset = z.u64()    // 中央目录偏移
        else { return nil }
        return (Int(cdOffset), Int(count))
    }

    /// ZIP64 扩展字段（tag 0x0001）取值
    static func zip64ExtraValues(_ extra: [UInt8]) -> [UInt64] {
        var values: [UInt64] = []
        var i = 0
        while i + 4 <= extra.count {
            let tag = UInt16(extra[i]) | (UInt16(extra[i + 1]) << 8)
            let size = Int(UInt16(extra[i + 2]) | (UInt16(extra[i + 3]) << 8))
            i += 4
            guard i + size <= extra.count else { break }
            if tag == 0x0001 {
                var j = i
                while j + 8 <= i + size {
                    var v: UInt64 = 0
                    for k in 0..<8 { v |= UInt64(extra[j + k]) << (8 * UInt64(k)) }
                    values.append(v)
                    j += 8
                }
            }
            i += size
        }
        return values
    }

    public func contains(_ name: String) -> Bool { entries.contains { $0.name == name } }
    public func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// 解压指定条目
    public func extract(_ name: String) throws -> [UInt8] {
        guard let e = entry(name) else { throw SDRAppError(.apkBadZip, "条目不存在：\(name)") }

        // 本地文件头字段按固定偏移直读：sig(4) + version(2) + flags(2) + method(2)
        // + time(2) + date(2) + crc(4) + csize(4) + usize(4) + nameLen(2) + extraLen(2) + name
        let h = e.localHeaderOffset
        guard h + 30 <= bytes.count,
              bytes[h] == 0x50, bytes[h + 1] == 0x4b,
              bytes[h + 2] == 0x03, bytes[h + 3] == 0x04 else {
            throw SDRAppError(.apkBadZip, "本地文件头损坏：\(name)")
        }
        let nameLen = Int(bytes[h + 26]) | (Int(bytes[h + 27]) << 8)
        let extraLen = Int(bytes[h + 28]) | (Int(bytes[h + 29]) << 8)
        let dataStart = h + 30 + nameLen + extraLen
        guard dataStart + e.compressedSize <= bytes.count else {
            throw SDRAppError(.apkBadZip, "条目数据越界：\(name)")
        }
        let raw = Array(bytes[dataStart..<(dataStart + e.compressedSize)])

        switch e.compressionMethod {
        case 0: return raw
        case 8: return try Self.inflateRaw(raw, expected: e.uncompressedSize)
        default: throw SDRAppError(.apkBadZip, "不支持的压缩方式 \(e.compressionMethod)：\(name)")
        }
    }

    /// raw deflate 解压（windowBits = -15）
    static func inflateRaw(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        guard !input.isEmpty else { return [] }
        var strm = z_stream()
        let status = inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw SDRAppError(.apkBadZip, "inflateInit2 失败：\(status)") }
        defer { inflateEnd(&strm) }

        var out = [UInt8](repeating: 0, count: max(expected, 1024))
        var written = 0

        try input.withUnsafeBufferPointer { inBuf in
            strm.next_in = UnsafeMutablePointer<UInt8>(mutating: inBuf.baseAddress)
            strm.avail_in = uInt(inBuf.count)

            while true {
                let chunk = 64 * 1024
                var buffer = [UInt8](repeating: 0, count: chunk)
                var produced = 0
                let rc: Int32 = buffer.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                    strm.next_out = outBuf.baseAddress
                    strm.avail_out = uInt(chunk)
                    let r = inflate(&strm, Z_NO_FLUSH)
                    produced = chunk - Int(strm.avail_out)
                    return r
                }
                if produced > 0 {
                    if written + produced > out.count {
                        out.append(contentsOf: [UInt8](repeating: 0, count: max(produced, out.count)))
                    }
                    out.replaceSubrange(written..<(written + produced), with: buffer[0..<produced])
                    written += produced
                }
                if rc == Z_STREAM_END { break }
                if rc != Z_OK { throw SDRAppError(.apkBadZip, "inflate 失败：\(rc)") }
            }
        }
        return Array(out[0..<written])
    }
}
