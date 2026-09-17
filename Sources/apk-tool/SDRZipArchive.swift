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

    private func readCentralDirectory() throws {
        guard bytes.count > 22 else { throw SDRAppError(.apkBadZip, "文件过小，不是合法 ZIP") }

        // 从尾部向前找 EOCD（0x06054b50）
        var eocd = -1
        let lower = max(0, bytes.count - 65557)
        var i = bytes.count - 22
        while i >= lower {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i; break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw SDRAppError(.apkBadZip, "未找到 ZIP 中央目录结束记录") }

        var r = SDRByteReader(Array(bytes[eocd...]))
        r.skip(10)
        guard let total = r.u16(), let cdOffset = r.u32() else {
            throw SDRAppError(.apkBadZip, "EOCD 解析失败")
        }

        var p = Int(cdOffset)
        for _ in 0..<Int(total) {
            guard p + 46 <= bytes.count,
                  bytes[p] == 0x50, bytes[p + 1] == 0x4b, bytes[p + 2] == 0x01, bytes[p + 3] == 0x02 else { break }
            var e = SDRByteReader(Array(bytes[(p + 4)...]))
            guard let method = e.u16(), let _ = e.u16(), let _ = e.u16() else { break }
            e.skip(4)                                          // time + date
            guard let _ = e.u32(), let csize = e.u32(), let usize = e.u32() else { break }
            guard let nameLen = e.u16(), let extraLen = e.u16(), let commentLen = e.u16() else { break }
            e.skip(8)                                          // disk / attrs
            guard let lho = e.u32() else { break }
            guard let nameBytes = e.bytes(Int(nameLen)),
                  let name = String(bytes: nameBytes, encoding: .utf8) else { break }

            entries.append(Entry(name: name,
                                 compressedSize: Int(csize),
                                 uncompressedSize: Int(usize),
                                 compressionMethod: method,
                                 localHeaderOffset: Int(lho)))
            p += 46 + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }

        guard !entries.isEmpty else { throw SDRAppError(.apkBadZip, "ZIP 内无任何条目") }
    }

    public func contains(_ name: String) -> Bool { entries.contains { $0.name == name } }
    public func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// 解压指定条目
    public func extract(_ name: String) throws -> [UInt8] {
        guard let e = entry(name) else { throw SDRAppError(.apkBadZip, "条目不存在：\(name)") }

        var r = SDRByteReader(Array(bytes[e.localHeaderOffset...]))
        guard let _ = r.u32(), let _ = r.u16(), let _ = r.u16() else {
            throw SDRAppError(.apkBadZip, "本地文件头损坏：\(name)")
        }
        r.skip(4)                                              // time + date
        guard let _ = r.u32(), let _ = r.u32(), let _ = r.u32() else {
            throw SDRAppError(.apkBadZip, "本地文件头损坏：\(name)")
        }
        guard let nameLen = r.u16(), let extraLen = r.u16() else {
            throw SDRAppError(.apkBadZip, "本地文件头损坏：\(name)")
        }
        let dataStart = e.localHeaderOffset + 30 + Int(nameLen) + Int(extraLen)
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
        var status = inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
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
