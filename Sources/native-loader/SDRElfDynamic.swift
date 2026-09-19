/*
 Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
 Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
*/

import Foundation

/// ELF 动态符号表条目（.dynsym）
public struct SDRElfSymbol {
    public var name: String
    public var value: UInt64
    public var size: UInt64
    public var info: UInt8
    public var other: UInt8
    public var sectionIndex: UInt16

    /// st_shndx == SHN_UNDEF：本模块未定义，需外部提供
    public var isUndefined: Bool { sectionIndex == 0 }
    public var isFunction: Bool { (info & 0x0F) == 2 }
    public var isGlobal: Bool { (info >> 4) == 1 }
}

/// ELF 动态重定位条目（.rela.dyn / .rela.plt）
public struct SDRElfRelocation {
    public var offset: UInt64
    public var type: UInt32
    public var symbolIndex: UInt32
    public var addend: Int64
    public var isPlt: Bool
}

/// 动态段解析结论（不依赖节头，兼容 stripped 产物）
public struct SDRElfDynamicInfo {
    public var hasDynamicSegment = false
    public var symbols: [SDRElfSymbol] = []
    public var relocations: [SDRElfRelocation] = []
    public var needed: [String] = []
    public var symbolEntrySize = 0
    public var stringTableSize: UInt64 = 0
    public var initAddress: UInt64 = 0
}

/// 动态段解析：PT_DYNAMIC → 符号表 / 重定位表 / 依赖列表
public enum SDRElfDynamic {

    private enum Tag {
        static let needed: UInt64 = 1
        static let pltRelSize: UInt64 = 2
        static let hash: UInt64 = 4
        static let stringTable: UInt64 = 5
        static let symbolTable: UInt64 = 6
        static let rela: UInt64 = 7
        static let relaSize: UInt64 = 8
        static let relaEntry: UInt64 = 9
        static let stringTableSize: UInt64 = 10
        static let symbolEntry: UInt64 = 11
        static let initAddress: UInt64 = 12
        static let pltRel: UInt64 = 20
        static let jumpRel: UInt64 = 23
        static let gnuHash: UInt64 = 0x6ffffef5
    }

    public static func parse(_ data: [UInt8], header: SDRElfHeader) -> SDRElfDynamicInfo {
        var info = SDRElfDynamicInfo()
        guard header.littleEndian else {
            SDRLogger.w("native", "大端 ELF 暂不支持动态段解析")
            return info
        }
        guard let dynamic = header.programHeaders.first(where: { $0.isDynamic }), dynamic.filesz > 0 else {
            return info
        }
        info.hasDynamicSegment = true

        let entrySize = header.is64Bit ? 16 : 8
        let dynamicOffset = Int(dynamic.offset)
        guard dynamicOffset >= 0, dynamicOffset < data.count else { return info }
        let entryCount = min(Int(dynamic.filesz) / entrySize, (data.count - dynamicOffset) / entrySize)
        guard entryCount > 0 else { return info }

        var tags: [UInt64: UInt64] = [:]
        for index in 0..<entryCount {
            let offset = dynamicOffset + index * entrySize
            var tag: UInt64 = 0
            var value: UInt64 = 0
            if header.is64Bit {
                guard let t = readU64(data, offset), let v = readU64(data, offset + 8) else { break }
                tag = t; value = v
            } else {
                guard let t = readU32(data, offset), let v = readU32(data, offset + 4) else { break }
                tag = UInt64(t); value = UInt64(v)
            }
            if tag == 0 { break }                                       // DT_NULL
            tags[tag] = value
        }
        guard !tags.isEmpty else { return info }

        // 虚拟地址 → 文件偏移（仅 PT_LOAD 覆盖范围内可用）
        func fileOffset(of vaddr: UInt64) -> Int? {
            for ph in header.programHeaders where ph.isLoad && ph.filesz > 0 {
                if vaddr >= ph.vaddr && vaddr < ph.vaddr + ph.filesz {
                    return Int(ph.offset + (vaddr - ph.vaddr))
                }
            }
            return nil
        }

        func cString(at offset: Int) -> String {
            guard offset >= 0, offset < data.count else { return "" }
            var end = offset
            while end < data.count && data[end] != 0 { end += 1 }
            return String(bytes: data[offset..<end], encoding: .utf8) ?? ""
        }

        info.initAddress = tags[Tag.initAddress] ?? 0
        info.symbolEntrySize = Int(tags[Tag.symbolEntry] ?? (header.is64Bit ? 24 : 16))
        info.stringTableSize = tags[Tag.stringTableSize] ?? 0

        let stringTableOffset = tags[Tag.stringTable].flatMap { fileOffset(of: $0) }

        // 依赖列表（DT_NEEDED 存的是字符串表内偏移，不是虚拟地址）
        if let strOffset = stringTableOffset {
            for index in 0..<entryCount {
                let offset = dynamicOffset + index * entrySize
                let tag: UInt64?
                let value: UInt64?
                if header.is64Bit {
                    tag = readU64(data, offset)
                    value = readU64(data, offset + 8)
                } else {
                    tag = readU32(data, offset).map(UInt64.init)
                    value = readU32(data, offset + 4).map(UInt64.init)
                }
                guard tag == Tag.needed, let nameOffset = value else { continue }
                let name = cString(at: strOffset + Int(nameOffset))
                if !name.isEmpty { info.needed.append(name) }
            }
        }

        // 符号表
        if info.symbolEntrySize > 0, let symbolTableOffset = tags[Tag.symbolTable].flatMap({ fileOffset(of: $0) }) {
            let symbolCount = countSymbols(data: data, tags: tags, fileOffset: fileOffset,
                                           symbolTableOffset: symbolTableOffset,
                                           stringTableOffset: stringTableOffset,
                                           symbolEntrySize: info.symbolEntrySize,
                                           is64: header.is64Bit)
            for index in 0..<symbolCount {
                let offset = symbolTableOffset + index * info.symbolEntrySize
                guard offset >= 0, offset + info.symbolEntrySize <= data.count else { break }
                var nameOffset = 0
                var value: UInt64 = 0
                var size: UInt64 = 0
                var infoByte: UInt8 = 0
                var other: UInt8 = 0
                var sectionIndex: UInt16 = 0
                if header.is64Bit {
                    nameOffset = Int(readU32(data, offset) ?? 0)
                    infoByte = data[offset + 4]
                    other = data[offset + 5]
                    sectionIndex = readU16(data, offset + 6) ?? 0
                    value = readU64(data, offset + 8) ?? 0
                    size = readU64(data, offset + 16) ?? 0
                } else {
                    nameOffset = Int(readU32(data, offset) ?? 0)
                    value = UInt64(readU32(data, offset + 4) ?? 0)
                    size = UInt64(readU32(data, offset + 8) ?? 0)
                    infoByte = data[offset + 12]
                    other = data[offset + 13]
                    sectionIndex = readU16(data, offset + 14) ?? 0
                }
                let name = stringTableOffset.map { cString(at: $0 + nameOffset) } ?? ""
                info.symbols.append(SDRElfSymbol(name: name, value: value, size: size,
                                                 info: infoByte, other: other, sectionIndex: sectionIndex))
            }
        }

        // 重定位表：.rela.dyn，以及 DT_JMPREL 指向的 .rela.plt（按 DT_PLTREL 判定 RELA/REL）
        if let relaVaddr = tags[Tag.rela], let relaOffset = fileOffset(of: relaVaddr) {
            let size = Int(tags[Tag.relaSize] ?? 0)
            let entry = Int(tags[Tag.relaEntry] ?? (header.is64Bit ? 24 : 8))
            appendRelocations(data: data, info: &info, offset: relaOffset, size: size,
                              entrySize: entry, is64: header.is64Bit,
                              useRela: header.is64Bit, isPlt: false)
        }
        if let jumpVaddr = tags[Tag.jumpRel], let jumpOffset = fileOffset(of: jumpVaddr) {
            let size = Int(tags[Tag.pltRelSize] ?? 0)
            let useRela = (tags[Tag.pltRel] ?? 7) == 7
            let entry = useRela ? (header.is64Bit ? 24 : 12) : (header.is64Bit ? 16 : 8)
            appendRelocations(data: data, info: &info, offset: jumpOffset, size: size,
                              entrySize: entry, is64: header.is64Bit, useRela: useRela, isPlt: true)
        }

        return info
    }

    // MARK: - 内部

    private static func countSymbols(data: [UInt8], tags: [UInt64: UInt64],
                                     fileOffset: (UInt64) -> Int?, symbolTableOffset: Int,
                                     stringTableOffset: Int?, symbolEntrySize: Int,
                                     is64: Bool) -> Int {
        // DT_HASH：第二字段即符号表条目数
        if let hashVaddr = tags[Tag.hash], let hashOffset = fileOffset(hashVaddr),
           let nchain = readU32(data, hashOffset + 4), nchain > 0 {
            return Int(nchain)
        }
        // DT_GNU_HASH：沿桶链推到末项
        if let gnuVaddr = tags[Tag.gnuHash], let gnuOffset = fileOffset(gnuVaddr),
           let count = gnuHashSymbolCount(data, at: gnuOffset, is64: is64), count > 0 {
            return count
        }
        // 兜底：以字符串表起点估算
        if let strOffset = stringTableOffset, strOffset > symbolTableOffset, symbolEntrySize > 0 {
            return (strOffset - symbolTableOffset) / symbolEntrySize
        }
        return 0
    }

    private static func gnuHashSymbolCount(_ data: [UInt8], at offset: Int, is64: Bool) -> Int? {
        guard let bucketCount = readU32(data, offset),
              let symbolOffset = readU32(data, offset + 4),
              let bloomSize = readU32(data, offset + 8),
              bucketCount > 0 else { return nil }
        let bloomBytes = Int(bloomSize) * (is64 ? 8 : 4)
        let bucketBase = offset + 16 + bloomBytes
        let chainBase = bucketBase + Int(bucketCount) * 4
        var maxIndex = Int(symbolOffset)
        for index in 0..<Int(bucketCount) {
            guard let bucket = readU32(data, bucketBase + index * 4), bucket >= symbolOffset else { continue }
            var current = Int(bucket)
            var guardCount = 0
            while true {
                guard let chain = readU32(data, chainBase + (current - Int(symbolOffset)) * 4) else { break }
                if chain & 1 == 1 { break }                             // 链尾标记
                current += 1
                guardCount += 1
                if guardCount > 1_000_000 { break }
            }
            maxIndex = max(maxIndex, current + 1)
        }
        return maxIndex
    }

    private static func appendRelocations(data: [UInt8], info: inout SDRElfDynamicInfo,
                                          offset: Int, size: Int, entrySize: Int,
                                          is64: Bool, useRela: Bool, isPlt: Bool) {
        guard entrySize > 0, size > 0 else { return }
        let count = size / entrySize
        for index in 0..<count {
            let base = offset + index * entrySize
            guard base >= 0, base + entrySize <= data.count else { break }
            if useRela && is64 {
                guard let rOffset = readU64(data, base),
                      let rInfo = readU64(data, base + 8),
                      let addend = readU64(data, base + 16) else { break }
                info.relocations.append(SDRElfRelocation(offset: rOffset,
                                                         type: UInt32(rInfo & 0xFFFF_FFFF),
                                                         symbolIndex: UInt32(rInfo >> 32),
                                                         addend: Int64(bitPattern: addend),
                                                         isPlt: isPlt))
            } else if useRela {
                guard let rOffset = readU32(data, base),
                      let rInfo = readU32(data, base + 4),
                      let addend = readU32(data, base + 8) else { break }
                info.relocations.append(SDRElfRelocation(offset: UInt64(rOffset),
                                                         type: rInfo & 0xFF,
                                                         symbolIndex: rInfo >> 8,
                                                         addend: Int64(Int32(bitPattern: addend)),
                                                         isPlt: isPlt))
            } else {
                guard let rOffset = readU32(data, base),
                      let rInfo = readU32(data, base + 4) else { break }
                info.relocations.append(SDRElfRelocation(offset: UInt64(rOffset),
                                                         type: rInfo & 0xFF,
                                                         symbolIndex: rInfo >> 8,
                                                         addend: 0,
                                                         isPlt: isPlt))
            }
        }
    }

    private static func readU16(_ data: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32(_ data: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        for i in (0..<4).reversed() { value = (value << 8) | UInt32(data[offset + i]) }
        return value
    }

    private static func readU64(_ data: [UInt8], _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for i in (0..<8).reversed() { value = (value << 8) | UInt64(data[offset + i]) }
        return value
    }
}
