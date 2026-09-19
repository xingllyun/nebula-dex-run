// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
import Foundation

// ZIP 归档冒烟：内存构造路径 + EOCD 边界 + stored 条目解压
// 覆盖历史缺陷：APK 导入报 APK_BAD_ZIP 的解析链路

var passed = 0
var failed = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        passed += 1
        print("PASS \(message)")
    } else {
        failed += 1
        print("FAIL \(message)")
    }
}

// MARK: - CRC32

let crcTable: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        table[i] = c
    }
    return table
}()

func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes {
        c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
    }
    return c ^ 0xFFFF_FFFF
}

// MARK: - 最小 ZIP 构造（全部 stored，无加密）

struct ZipEntrySpec {
    let name: String
    let data: [UInt8]
}

func makeZip(_ entries: [ZipEntrySpec]) -> [UInt8] {
    var out: [UInt8] = []
    var offsets: [Int] = []

    func u16(_ v: UInt16) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
    }

    func u32(_ v: UInt32) {
        for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
    }

    for entry in entries {
        offsets.append(out.count)
        let nameBytes = Array(entry.name.utf8)
        let data = entry.data
        u32(0x0403_4B50)
        u16(20); u16(0); u16(0); u16(0); u16(0)
        u32(crc32(data))
        u32(UInt32(data.count)); u32(UInt32(data.count))
        u16(UInt16(nameBytes.count)); u16(0)
        out.append(contentsOf: nameBytes)
        out.append(contentsOf: data)
    }

    let centralStart = out.count
    for (i, entry) in entries.enumerated() {
        let nameBytes = Array(entry.name.utf8)
        let data = entry.data
        u32(0x0201_4B50)
        u16(20); u16(20); u16(0); u16(0); u16(0); u16(0)
        u32(crc32(data))
        u32(UInt32(data.count)); u32(UInt32(data.count))
        u16(UInt16(nameBytes.count)); u16(0); u16(0)
        u16(0); u16(0)
        u32(0)
        u32(UInt32(offsets[i]))
        out.append(contentsOf: nameBytes)
    }
    let centralSize = out.count - centralStart

    u32(0x0605_4B50)
    u16(0); u16(0)
    u16(UInt16(entries.count)); u16(UInt16(entries.count))
    u32(UInt32(centralSize)); u32(UInt32(centralStart))
    u16(0)
    return out
}

// MARK: - 用例

let dexPayload: [UInt8] = Array("dex-bytes-0123456789-abcdef".utf8)
let elfStub: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00]

let zipBytes = makeZip([
    ZipEntrySpec(name: "AndroidManifest.xml", data: Array("<manifest/>".utf8)),
    ZipEntrySpec(name: "classes.dex", data: dexPayload),
    ZipEntrySpec(name: "lib/arm64-v8a/libc++_shared.so", data: elfStub)
])

do {
    let archive = try SDRZipArchive(bytes: zipBytes)
    check(archive.entries.count == 3, "内存构造 ZIP 条目数为 3")
    check(archive.contains("classes.dex"), "contains 能命中 classes.dex")
    check(archive.entry("lib/arm64-v8a/libc++_shared.so") != nil, "entries 可索引嵌套目录中的 .so")
    check(archive.extract("classes.dex") == dexPayload, "stored 条目 extract 内容逐字节一致")
    check(archive.extract("lib/arm64-v8a/libc++_shared.so") == elfStub, "二级路径条目解压一致")
    check(!archive.contains("missing.dex"), "不存在的条目返回 false 而非崩溃")
} catch {
    check(false, "内存构造 ZIP 解析抛错：\(error)")
}

do {
    let archive = try SDRZipArchive(url: URL(fileURLWithPath: "/dev/null"))
    _ = archive
    check(false, "空 URL 不应解析成功")
} catch {
    check(true, "空数据经 URL 构造抛错而非返回空归档")
}

do {
    // 尾部附加非 ZIP 数据（模拟签名块/注释）：EOCD 扫描必须能回溯命中
    var extended = zipBytes
    extended.append(contentsOf: [UInt8](repeating: 0xAA, count: 64))
    let archive = try SDRZipArchive(bytes: extended)
    check(archive.entries.count == 3, "尾部附加 64 字节数据后仍定位到 EOCD")
} catch {
    check(false, "附加尾部数据后解析失败：\(error)")
}

do {
    // 截断：EOCD 不完整时不得越界读取
    let truncated = Array(zipBytes.dropLast(20))
    _ = try SDRZipArchive(bytes: truncated)
    check(true, "截断输入未导致越界崩溃")
} catch {
    check(true, "截断输入以抛错方式拒绝，未越界崩溃")
}

print("zip-smoke: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
