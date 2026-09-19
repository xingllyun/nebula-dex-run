// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
import Foundation

// 动态依赖装载冒烟：DT_NEEDED 递归装载 + 跨模块符号解析 + 装载基址隔离
// 覆盖历史缺陷：单基址硬编码导致多库互踩、外部符号只 defer 不解绑

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

// MARK: - 合成 AArch64 .so

struct SOPlan {
    var exports: [(name: String, value: UInt64)] = []
    var undefinedNames: [String] = []
    var needed: [String] = []
    var relocations: [(offset: UInt64, symbol: String, type: UInt32)] = []
}

func makeSO(_ plan: SOPlan) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x900)

    func w16(_ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    func w32(_ offset: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }
    func w64(_ offset: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
    }

    var stringTable: [UInt8] = [0]
    var nameOffset: [String: Int] = [:]
    func intern(_ name: String) -> UInt32 {
        if let existing = nameOffset[name] { return UInt32(existing) }
        let offset = stringTable.count
        nameOffset[name] = offset
        stringTable.append(contentsOf: Array(name.utf8))
        stringTable.append(0)
        return UInt32(offset)
    }

    var exportOffsets: [UInt32] = []
    for entry in plan.exports { exportOffsets.append(intern(entry.name)) }
    var undefinedOffsets: [UInt32] = []
    for name in plan.undefinedNames { undefinedOffsets.append(intern(name)) }
    var neededOffsets: [UInt32] = []
    for name in plan.needed { neededOffsets.append(intern(name)) }

    let symbolCount = 1 + plan.exports.count + plan.undefinedNames.count
    let symtabAddr = 0x100
    let strtabAddr = symtabAddr + symbolCount * 24
    let strtabEnd = strtabAddr + stringTable.count
    let relaAddr = ((strtabEnd + 7) / 8) * 8

    func writeSymbol(_ index: Int, nameOffset: UInt32, value: UInt64, sectionIndex: UInt16) {
        let base = symtabAddr + index * 24
        w32(base + 0, nameOffset)
        bytes[base + 4] = 0x12   // STB_GLOBAL | STT_FUNC
        bytes[base + 5] = 0
        w16(base + 6, sectionIndex)
        w64(base + 8, value)
        w64(base + 16, 0)
    }

    var symbolIndexByName: [String: UInt32] = [:]
    var index = 1
    for (i, entry) in plan.exports.enumerated() {
        writeSymbol(index, nameOffset: exportOffsets[i], value: entry.value, sectionIndex: 1)
        symbolIndexByName[entry.name] = UInt32(index)
        index += 1
    }
    for (i, name) in plan.undefinedNames.enumerated() {
        writeSymbol(index, nameOffset: undefinedOffsets[i], value: 0, sectionIndex: 0)
        symbolIndexByName[name] = UInt32(index)
        index += 1
    }

    for (i, byte) in stringTable.enumerated() { bytes[strtabAddr + i] = byte }

    for (i, rel) in plan.relocations.enumerated() {
        let base = relaAddr + i * 24
        let symbolIndex = UInt64(symbolIndexByName[rel.symbol] ?? 0)
        w64(base + 0, rel.offset)
        w64(base + 8, (symbolIndex << 32) | UInt64(rel.type))
        w64(base + 16, 0)
    }

    // 数据段初值：每个重定位槽写入唯一哨兵，便于验证未被篡改
    for (i, rel) in plan.relocations.enumerated() {
        let fileOffset = 0x400 + Int(rel.offset - 0x1000)
        w64(fileOffset, 0xAABB_0000_0000_0000 + UInt64(i))
    }

    // ELF 头
    bytes[0] = 0x7F; bytes[1] = 0x45; bytes[2] = 0x4C; bytes[3] = 0x46
    bytes[4] = 2
    bytes[5] = 1
    bytes[6] = 1
    w16(16, 3)
    w16(18, 183)
    w32(20, 1)
    w64(24, 0)
    w64(32, 0x40)
    w64(40, 0)
    w16(52, 64)
    w16(54, 56)
    w16(56, 3)

    func writeProgramHeader(_ index: Int, type: UInt32, flags: UInt32, fileOffset: UInt64,
                            vaddr: UInt64, fileSize: UInt64, memSize: UInt64, align: UInt64) {
        let base = 0x40 + index * 56
        w32(base + 0, type)
        w32(base + 4, flags)
        w64(base + 8, fileOffset)
        w64(base + 16, vaddr)
        w64(base + 24, vaddr)
        w64(base + 32, fileSize)
        w64(base + 40, memSize)
        w64(base + 48, align)
    }

    writeProgramHeader(0, type: 1, flags: 4, fileOffset: 0, vaddr: 0,
                       fileSize: 0x400, memSize: 0x400, align: 0x400)
    writeProgramHeader(1, type: 1, flags: 6, fileOffset: 0x400, vaddr: 0x1000,
                       fileSize: 0x200, memSize: 0x200, align: 0x400)
    writeProgramHeader(2, type: 2, flags: 4, fileOffset: 0x800, vaddr: 0x2000,
                       fileSize: 0x100, memSize: 0x100, align: 8)

    var dynamic: [(UInt64, UInt64)] = []
    for offset in neededOffsets { dynamic.append((1, UInt64(offset))) }
    dynamic.append((5, UInt64(strtabAddr)))
    dynamic.append((10, UInt64(stringTable.count)))
    dynamic.append((6, UInt64(symtabAddr)))
    dynamic.append((11, 24))
    dynamic.append((7, UInt64(relaAddr)))
    dynamic.append((8, UInt64(plan.relocations.count * 24)))
    dynamic.append((9, 24))
    dynamic.append((0, 0))
    for (i, entry) in dynamic.enumerated() {
        w64(0x800 + i * 16, entry.0)
        w64(0x800 + i * 16 + 8, entry.1)
    }

    return bytes
}

// DT_*
let DT_NEEDED: UInt64 = 1
let DT_STRTAB: UInt64 = 5
let DT_STRSZ: UInt64 = 10
let DT_SYMTAB: UInt64 = 6
let DT_RELA: UInt64 = 7
let DT_RELASZ: UInt64 = 8
// R_AARCH64_GLOB_DAT
let R_AARCH64_GLOB_DAT: UInt32 = 1025

// MARK: - 用例 1：依赖递归装载 + 跨模块绑定

let soB = SOPlan(
    exports: [(name: "native_b", value: 0x200)],
    undefinedNames: [],
    needed: [],
    relocations: []
)

let soA = SOPlan(
    exports: [(name: "Java_com_nebula_dex_MainActivity_go", value: 0x100)],
    undefinedNames: ["native_b", "malloc"],
    needed: ["libb.so", "libc.so"],
    relocations: [
        (offset: 0x1000, symbol: "native_b", type: R_AARCH64_GLOB_DAT),
        (offset: 0x1010, symbol: "malloc", type: R_AARCH64_GLOB_DAT)
    ]
)

let bytesA = makeSO(soA)
let bytesB = makeSO(soB)

let resolver: (String) -> [UInt8]? = { name in
    switch name {
    case "liba.so": return bytesA
    case "libb.so": return bytesB
    default: return nil
    }
}

let table = SDRSharedLibraryTable()
let loader = SDRImageLoader()

do {
    let opened = try table.open(name: "liba.so", loader: loader, resolver: resolver)
    if let imageA = opened {
        check(table.isLoaded("liba.so"), "主库 liba.so 已注册")
        check(table.isLoaded("libb.so"), "DT_NEEDED 依赖 libb.so 被递归装载")
        check(!table.isLoaded("libc.so"), "宿主桩库 libc.so 未被软件装载")
        check(imageA.dependencies == ["libb.so", "libc.so"], "依赖列表保存完整")

        if let imageB = table.image(named: "libb.so") {
            check(imageA.loadBase != imageB.loadBase, "两镜像装载基址互不相同")
            check(imageB.loadBase > imageA.loadBase, "基址按装载顺序递增，不重叠")

            let slot = imageA.loadBase &+ 0x1000
            let bound = (try? imageA.memory.readScalar(slot, count: 8)) ?? 0
            check(bound == imageB.loadBase &+ 0x200, "跨模块符号槽被补绑为依赖库真实地址")

            let unresolved = (try? imageA.memory.readScalar(imageA.loadBase &+ 0x1010, count: 8)) ?? 0
            check(unresolved == 0xAABB_0000_0000_0001, "宿主桩符号槽保持原值，未写入伪地址")

            let binding = table.resolveSymbol("native_b", in: imageA)
            check(binding?.address == imageB.loadBase &+ 0x200, "dlsym 语义可解析到依赖库导出")
            check(binding?.libraryPath == "libb.so", "绑定结果标注来源库")
        } else {
            check(false, "依赖库 libb.so 未注册进表")
        }

        check(table.resolveSymbol("Java_com_nebula_dex_MainActivity_go")?.address == imageA.loadBase &+ 0x100,
              "JNI 导出可被全局解析")
        check(table.resolveSymbol("no_such_symbol_nebuladex") == nil, "未知符号解析返回空，不伪造地址")
        check(table.pendingDependencies(of: imageA).isEmpty, "依赖全部就位后无待装载项")

        let imageCount = table.loadedImages.count
        check(imageCount == 2, "注册表镜像数为 2（未重复注册）")
    } else {
        check(false, "主库 liba.so 装载返回空")
    }
} catch {
    check(false, "依赖装载链路抛错：\(error)")
}

// MARK: - 用例 2：环依赖（A↔B）终止性

let bytesX = makeSO(SOPlan(
    exports: [(name: "x_sym", value: 0x300)],
    undefinedNames: [],
    needed: ["liby.so"],
    relocations: []
))
let bytesY = makeSO(SOPlan(
    exports: [(name: "y_sym", value: 0x400)],
    undefinedNames: [],
    needed: ["libx.so"],
    relocations: []
))

let cycleTable = SDRSharedLibraryTable()
let cycleResolver: (String) -> [UInt8]? = { name in
    if name == "libx.so" { return bytesX }
    if name == "liby.so" { return bytesY }
    return nil
}

do {
    _ = try cycleTable.open(name: "libx.so", loader: SDRImageLoader(), resolver: cycleResolver)
    check(cycleTable.isLoaded("libx.so") && cycleTable.isLoaded("liby.so"), "环依赖装载终止且两库均注册")
    check(cycleTable.loadedImages.count == 2, "环依赖未产生重复镜像")
} catch {
    check(false, "环依赖装载抛错，链路未收敛：\(error)")
}

// MARK: - 用例 3：依赖缺失不阻断主库

let bytesC = makeSO(SOPlan(
    exports: [(name: "c_sym", value: 0x500)],
    undefinedNames: [],
    needed: ["libmissing.so"],
    relocations: []
))

let gapTable = SDRSharedLibraryTable()
let gapResolver: (String) -> [UInt8]? = { name in
    name == "libc_dep.so" ? bytesC : nil
}

do {
    let imageC = try gapTable.open(name: "libc_dep.so", loader: SDRImageLoader(), resolver: gapResolver)
    check(imageC != nil, "缺失依赖不致主库装载失败")
    if let imageC = imageC {
        check(!gapTable.isLoaded("libmissing.so"), "缺失依赖未被伪造注册")
        check(gapTable.pendingDependencies(of: imageC).count == 1, "缺失依赖仍列为待装载项")
    }
} catch {
    check(false, "缺失依赖场景抛错：\(error)")
}

// MARK: - 用例 4：系统库识别与名称规范化

check(SDRSharedLibraryTable.isHostProvided("libc.so"), "libc.so 识别为宿主桩库")
check(SDRSharedLibraryTable.isHostProvided("/system/lib64/liblog.so"), "系统路径下的 liblog.so 识别为宿主桩库")
check(!SDRSharedLibraryTable.isHostProvided("libb.so"), "普通业务库不视为宿主桩库")
check(SDRSharedLibraryTable.normalize("/system/lib64/libz.so.1") == "libz.so", "版本后缀被正确剥离")
check(SDRSharedLibraryTable.normalize("lib/arm64-v8a/libfoo.so") == "libfoo.so", "带目录路径被规范化为 basename")

// MARK: - 用例 5：卸载

table.closeAll()
check(table.loadedImages.isEmpty, "closeAll 后注册表清空")

print("dl-smoke: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
