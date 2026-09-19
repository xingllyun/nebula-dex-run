// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// SO 装载冒烟验收（阶段二 · 步骤三前置）
// 以合成的最小 AArch64 .so 驱动 SDRElfParser → SDRElfDynamic → SDRRelocator → SDRImageLoader，
// 校验：程序头字段位置、.dynsym 真实符号提取、按重定位表逐项落地、以及“非重定位数据不得被改写”的回归。
// 用法: elf-smoke

import Foundation
#if canImport(Darwin)
import Darwin
#endif

var totalChecks = 0
var failedChecks = 0

func check(_ condition: Bool, _ label: String) {
    totalChecks += 1
    if condition {
        print("ok   \(label)")
    } else {
        failedChecks += 1
        print("FAIL \(label)")
    }
}

func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

// MARK: - 合成最小 AArch64 .so（ELF64 标准布局）

func makeSyntheticSO() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x900)

    func writeU16(_ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    func writeU32(_ offset: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }
    func writeU64(_ offset: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
    }
    func writeBytes(_ offset: Int, _ payload: [UInt8]) {
        for (index, byte) in payload.enumerated() { bytes[offset + index] = byte }
    }

    // ELF 头
    writeBytes(0, [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0])
    writeU16(0x10, 3)                    // e_type = ET_DYN
    writeU16(0x12, 0xB7)                 // e_machine = AArch64
    writeU32(0x14, 1)                    // e_version
    writeU64(0x18, 0x200)                // e_entry
    writeU64(0x20, 0x40)                 // e_phoff
    writeU16(0x34, 64)                   // e_ehsize
    writeU16(0x36, 56)                   // e_phentsize
    writeU16(0x38, 3)                    // e_phnum

    func writeProgramHeader(_ index: Int, type: UInt32, flags: UInt32, offset: UInt64,
                            vaddr: UInt64, fileSize: UInt64, memSize: UInt64, align: UInt64) {
        let base = 0x40 + index * 56
        writeU32(base + 0, type)
        writeU32(base + 4, flags)
        writeU64(base + 8, offset)
        writeU64(base + 16, vaddr)
        writeU64(base + 32, fileSize)
        writeU64(base + 40, memSize)
        writeU64(base + 48, align)
    }
    writeProgramHeader(0, type: 1, flags: 4, offset: 0x000, vaddr: 0x0000, fileSize: 0x400, memSize: 0x400, align: 0x400)
    writeProgramHeader(1, type: 1, flags: 6, offset: 0x400, vaddr: 0x1000, fileSize: 0x200, memSize: 0x200, align: 0x400)
    writeProgramHeader(2, type: 2, flags: 4, offset: 0x800, vaddr: 0x2000, fileSize: 0x100, memSize: 0x100, align: 8)

    // 字符串表
    var stringTable: [UInt8] = [0]
    var nameOffset: [String: Int] = [:]
    for name in ["JNI_OnLoad", "Java_com_demo_Main_run", "external_data", "liblog.so"] {
        stringTable.append(0)
        nameOffset[name] = stringTable.count
        stringTable.append(contentsOf: Array(name.utf8))
    }
    writeBytes(0x160, stringTable)

    // 符号表：0 号空项 + JNI_OnLoad / Java_* / 未定义外部符号
    let symbols: [(String, UInt8, UInt16, UInt64, UInt64)] = [
        ("", 0, 0, 0, 0),
        ("JNI_OnLoad", 0x12, 1, 0x120, 0x20),
        ("Java_com_demo_Main_run", 0x12, 1, 0x180, 0x30),
        ("external_data", 0x11, 0, 0, 0)
    ]
    for (index, symbol) in symbols.enumerated() {
        let base = 0x100 + index * 24
        writeU32(base + 0, UInt32(nameOffset[symbol.0] ?? 0))
        bytes[base + 4] = symbol.1
        bytes[base + 5] = 0
        writeU16(base + 6, symbol.2)
        writeU64(base + 8, symbol.3)
        writeU64(base + 16, symbol.4)
    }

    // .rela.dyn：RELATIVE + GLOB_DAT(未定义) + GLOB_DAT(已定义)
    let relaDyn: [(UInt64, UInt32, UInt64, Int64)] = [
        (0x1000, 0, 1027, 0x1234),       // R_AARCH64_RELATIVE
        (0x1010, 3, 1025, 0),            // GLOB_DAT ← 未定义符号
        (0x1018, 2, 1025, 0)             // GLOB_DAT ← 已定义符号
    ]
    for (index, item) in relaDyn.enumerated() {
        let base = 0x1C0 + index * 24
        writeU64(base + 0, item.0)
        writeU64(base + 8, (item.2 << 32) | UInt64(item.1))
        writeU64(base + 16, UInt64(bitPattern: item.3))
    }

    // .rela.plt：JUMP_SLOT ← JNI_OnLoad
    writeU64(0x210 + 0, 0x1020)
    writeU64(0x210 + 8, (1 << 32) | 1026)   // R_AARCH64_JUMP_SLOT
    writeU64(0x210 + 16, 0)

    // DT_HASH：nbucket = 1，nchain = 4（符号表条目数）
    writeU32(0x230, 1)
    writeU32(0x234, 4)

    // 数据段（vaddr 0x1000）：5 个 8 字节槽
    writeU64(0x400 + 0, 0)                   // RELATIVE 目标
    writeU64(0x400 + 8, 0)                   // 普通 0 值数据（回归断言）
    writeU64(0x400 + 16, 0xDEADBEEF)         // 未定义符号 GOT（回归断言）
    writeU64(0x400 + 24, 0)                  // 已定义符号 GOT
    writeU64(0x400 + 32, 0)                  // JUMP_SLOT

    // PT_DYNAMIC
    let dynamic: [(UInt64, UInt64)] = [
        (1, UInt64(nameOffset["liblog.so"] ?? 0)),   // DT_NEEDED
        (5, 0x160),                                   // DT_STRTAB
        (10, UInt64(stringTable.count)),              // DT_STRSZ
        (6, 0x100),                                   // DT_SYMTAB
        (11, 24),                                     // DT_SYMENT
        (7, 0x1C0),                                   // DT_RELA
        (8, 72),                                      // DT_RELASZ
        (9, 24),                                      // DT_RELAENT
        (23, 0x210),                                  // DT_JMPREL
        (2, 24),                                      // DT_PLTRELSZ
        (20, 7),                                      // DT_PLTREL = RELA
        (12, 0x1234),                                 // DT_INIT
        (0, 0)                                        // DT_NULL
    ]
    for (index, item) in dynamic.enumerated() {
        let base = 0x800 + index * 16
        writeU64(base + 0, item.0)
        writeU64(base + 8, item.1)
    }

    return bytes
}

// MARK: - 1. ELF 头解析（含程序头字段位置回归）

let fixture = makeSyntheticSO()

do {
    let header = try SDRElfParser.parse(fixture)
    check(header.programHeaders.count == 3, "程序头数量解析为 3（e_phentsize/e_phnum 字段位置正确）")
    check(header.entry == 0x200, "入口地址解析为 0x200")
    check(header.abiName == "arm64-v8a", "ABI 识别为 arm64-v8a")
    check(header.programHeaders[1].vaddr == 0x1000 && header.programHeaders[1].writable,
          "第二个 PT_LOAD 为可写段 vaddr=0x1000")

    // MARK: - 2. 动态段解析

    let dynamic = SDRElfDynamic.parse(fixture, header: header)
    check(dynamic.hasDynamicSegment, "检出 PT_DYNAMIC")
    check(dynamic.symbols.count == 4, "DT_HASH nchain 给出的符号表条目数为 4（实得 \(dynamic.symbols.count)）")
    check(dynamic.symbols.count > 1 && dynamic.symbols[1].name == "JNI_OnLoad",
          "符号 1 名称为 JNI_OnLoad")
    check(dynamic.symbols.count > 3 && dynamic.symbols[3].name == "external_data" && dynamic.symbols[3].isUndefined,
          "符号 3 external_data 标记为未定义")
    check(dynamic.needed == ["liblog.so"], "DT_NEEDED 解析出 liblog.so（实得 \(dynamic.needed)）")
    check(dynamic.initAddress == 0x1234, "DT_INIT 解析为 0x1234")
    check(dynamic.relocations.count == 4, "重定位条目共 4 项（实得 \(dynamic.relocations.count)）")
    check(dynamic.relocations.filter { $0.isPlt }.count == 1, "其中 1 项来自 .rela.plt")

    for rel in dynamic.relocations {
        print("DIAG reloc offset=\(hex(rel.offset)) type=\(rel.type) sym=\(rel.symbolIndex) plt=\(rel.isPlt)")
    }

    // MARK: - 3. 装载 + 重定位 + JNI 登记

    let image = try SDRImageLoader().load(bytes: fixture, path: "synthetic-aarch64.so", preferredABI: "arm64-v8a")
    let base = image.loadBase

    check(image.memory.segment(for: base)?.writable == false,
          "只读 PT_LOAD（flags=R）装载后按 ELF 权限收权为不可写（回归）")
    check(image.memory.segment(for: base)?.readable == true,
          "只读 PT_LOAD 仍可读")
    check(image.memory.segment(for: base + 0x1000)?.writable == true,
          "可写 PT_LOAD（flags=RW）保持可写，重定位目标段未被误收权")

    let slotRelative = try image.memory.readScalar(base + 0x1000, count: 8)
    let slotPlainZero = try image.memory.readScalar(base + 0x1008, count: 8)
    let slotUndefined = try image.memory.readScalar(base + 0x1010, count: 8)
    let slotDefined = try image.memory.readScalar(base + 0x1018, count: 8)
    let slotPlt = try image.memory.readScalar(base + 0x1020, count: 8)

    check(slotRelative == base + 0x1234,
          "R_AARCH64_RELATIVE 落地为 loadBase+0x1234（实得 \(hex(slotRelative))）")
    check(slotPlainZero == 0,
          "普通 0 值数据槽保持为 0，未被占位重定位篡改（回归）")
    check(slotUndefined == 0xDEADBEEF,
          "未定义外部符号的 GOT 槽保留原值 0xDEADBEEF，未写入伪地址（回归）")
    check(slotDefined == base + 0x180,
          "已定义符号 GLOB_DAT 落地为 loadBase+0x180（实得 \(hex(slotDefined))）")
    check(slotPlt == base + 0x120,
          "JUMP_SLOT 落地为 loadBase+0x120（实得 \(hex(slotPlt))）")

    // 诊断：区分“段权限被误收”与“重定位未执行”
    let seg0 = image.memory.segment(for: base)
    let seg1 = image.memory.segment(for: base + 0x1000)
    print("DIAG seg0 r=\(seg0?.readable ?? false) w=\(seg0?.writable ?? false) size=\(seg0?.size ?? 0)")
    print("DIAG seg1 r=\(seg1?.readable ?? false) w=\(seg1?.writable ?? false) size=\(seg1?.size ?? 0)")
    do {
        try image.memory.writeScalar(base + 0x1028, value: 0xAABBCCDD, count: 8)
        let echo = try image.memory.readScalar(base + 0x1028, count: 8)
        print("DIAG 手动写 base+0x1028 成功，读回 \(hex(echo))")
    } catch {
        print("DIAG 手动写 base+0x1028 失败：\(error)")
    }

    check(image.jniExports["JNI_OnLoad"] == base + 0x120,
          "JNI_OnLoad 导出地址取自 .dynsym 的 st_value（实得 \(hex(image.jniExports["JNI_OnLoad"] ?? 0))）")
    check(image.jniExports["JNI_OnLoad"] != base + image.header.entry,
          "JNI_OnLoad 地址不再是 ELF 入口占位（回归）")
    check(image.jniExports["Java_com_demo_Main_run"] == base + 0x180,
          "Java_* 导出一并登记")
    check(image.jniExports.count == 2, "JNI 导出恰好 2 项，未伪造额外符号（实得 \(image.jniExports.count)）")
    check(image.dependencies == ["liblog.so"], "镜像记录了依赖 liblog.so")
    check(image.initialized, "镜像完成初始化标记")
} catch {
    check(false, "合成 .so 装载过程抛出异常：\(error)")
}

// MARK: - 收口

print("NebulaDex SO 装载冒烟：\(totalChecks) 项检查，失败 \(failedChecks) 项")
if failedChecks > 0 {
    FileHandle.standardError.write("SO 装载冒烟未通过\n".data(using: .utf8)!)
    exit(1)
}
exit(0)
