// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
import Foundation

// 宿主桩桥冒烟：未定义外部符号经宿主桩装配绑定（libc/libm/liblog 通路）
// 覆盖目标：外部符号在装载期即可绑定宿主实现，且绝不写入伪地址

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

// MARK: - 合成 AArch64 .so（与 dl_smoke 同构，便于比对）

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

    // 数据段初值：每个重定位槽写入唯一哨兵，便于验证是否被写入
    for (i, rel) in plan.relocations.enumerated() {
        let fileOffset = 0x400 + Int(rel.offset - 0x1000)
        w64(fileOffset, 0xAABB_0000_0000_0000 + UInt64(i))
    }

    // ELF 头
    bytes[0] = 0x7F; bytes[1] = 0x45; bytes[2] = 0x4C; bytes[3] = 0x46
    bytes[4] = 2
    bytes[5] = 1
    bytes[6] = 1
    w16(16, 3)      // ET_DYN
    w16(18, 183)    // EM_AARCH64
    w32(20, 1)
    w64(24, 0)
    w64(32, 0x40)   // e_phoff
    w64(40, 0)
    w16(52, 64)     // e_ehsize
    w16(54, 56)     // e_phentsize
    w16(56, 3)      // e_phnum

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

// DT_NEEDED / DT_STRTAB / DT_SYMTAB / DT_RELA
let R_AARCH64_GLOB_DAT: UInt32 = 1025
let HOST_STUB_ADDRESS: UInt64 = 0x9000_0000

let hostPlan = SOPlan(
    exports: [],
    undefinedNames: ["host_memcpy"],
    needed: [],
    relocations: [(offset: 0x1000, symbol: "host_memcpy", type: R_AARCH64_GLOB_DAT)]
)
let hostBytes = makeSO(hostPlan)

// MARK: - 用例 1：装配宿主桩后，未定义符号在装载期直接绑定

do {
    let table = SDRSharedLibraryTable()
    table.hostSymbolResolver = { name in name == "host_memcpy" ? HOST_STUB_ADDRESS : nil }

    let loader = SDRImageLoader()
    let image = try table.open(name: "libhost_a.so", loader: loader, resolver: { $0 == "libhost_a.so" ? hostBytes : nil })
    if let image = image {
        let slot = (try? image.memory.readScalar(image.loadBase &+ 0x1000, count: 8)) ?? 0
        check(slot == HOST_STUB_ADDRESS, "宿主桩符号在装载期绑定为桩地址（实得 \(String(slot, radix: 16))）")

        let binding = table.resolveSymbol("host_memcpy", in: image)
        check(binding?.address == HOST_STUB_ADDRESS, "resolveSymbol 命中宿主桩地址")
        check(binding?.libraryPath == "<host>", "绑定结果标注来源为宿主桩")
    } else {
        check(false, "装载返回空")
    }
} catch {
    check(false, "宿主桩绑定链路抛错：\(error)")
}

// MARK: - 用例 2：未装配宿主桩时，符号槽保持原值（不写伪地址）

do {
    let table = SDRSharedLibraryTable()
    let loader = SDRImageLoader()
    let image = try table.open(name: "libhost_b.so", loader: loader, resolver: { $0 == "libhost_b.so" ? hostBytes : nil })
    if let image = image {
        let slot = (try? image.memory.readScalar(image.loadBase &+ 0x1000, count: 8)) ?? 0
        check(slot == 0xAABB_0000_0000_0000, "未装配宿主桩时符号槽保持原值（实得 \(String(slot, radix: 16))）")
        check(table.resolveSymbol("host_memcpy", in: image) == nil, "未装配宿主桩时解析返回空，不伪造地址")
    } else {
        check(false, "装载返回空")
    }
} catch {
    check(false, "未装配宿主桩场景抛错：\(error)")
}

// MARK: - 用例 3：宿主桩只认自己的符号，未提供者保持原值

do {
    let table = SDRSharedLibraryTable()
    table.hostSymbolResolver = { name in name == "host_memcpy" ? HOST_STUB_ADDRESS : nil }
    let mixedPlan = SOPlan(
        exports: [],
        undefinedNames: ["host_memcpy", "host_unknown"],
        needed: [],
        relocations: [
            (offset: 0x1000, symbol: "host_memcpy", type: R_AARCH64_GLOB_DAT),
            (offset: 0x1010, symbol: "host_unknown", type: R_AARCH64_GLOB_DAT)
        ]
    )
    let loader = SDRImageLoader()
    let image = try table.open(name: "libhost_c.so", loader: loader,
                               resolver: { $0 == "libhost_c.so" ? makeSO(mixedPlan) : nil })
    if let image = image {
        let known = (try? image.memory.readScalar(image.loadBase &+ 0x1000, count: 8)) ?? 0
        let unknown = (try? image.memory.readScalar(image.loadBase &+ 0x1010, count: 8)) ?? 0
        check(known == HOST_STUB_ADDRESS, "已装配符号绑定成功")
        check(unknown == 0xAABB_0000_0000_0001, "未装配符号保持原值，未被伪地址污染")
        check(table.resolveSymbol("host_unknown", in: image) == nil, "未装配符号解析返回空")
    } else {
        check(false, "装载返回空")
    }
} catch {
    check(false, "混合符号场景抛错：\(error)")
}

// MARK: - 用例 4：软件镜像导出优先于宿主桩

let dupExporter = SOPlan(exports: [(name: "dup_sym", value: 0x300)], undefinedNames: [], needed: [], relocations: [])
let dupConsumer = SOPlan(
    exports: [],
    undefinedNames: ["dup_sym"],
    needed: [],
    relocations: [(offset: 0x1000, symbol: "dup_sym", type: R_AARCH64_GLOB_DAT)]
)

do {
    let table = SDRSharedLibraryTable()
    table.hostSymbolResolver = { name in name == "dup_sym" ? 0xDEAD_BEEF_0000 : nil }
    let loader = SDRImageLoader()

    let provider = try table.open(name: "libhost_provider.so", loader: loader,
                                  resolver: { $0 == "libhost_provider.so" ? makeSO(dupExporter) : nil })
    let consumer = try table.open(name: "libhost_consumer.so", loader: loader,
                                  resolver: { $0 == "libhost_consumer.so" ? makeSO(dupConsumer) : nil })
    if let provider = provider, let consumer = consumer {
        let slot = (try? consumer.memory.readScalar(consumer.loadBase &+ 0x1000, count: 8)) ?? 0
        check(slot == provider.loadBase &+ 0x300, "软件镜像导出优先于宿主桩（实得 \(String(slot, radix: 16))）")
        check(table.resolveSymbol("dup_sym", in: consumer)?.libraryPath == "libhost_provider.so",
              "绑定结果标注来源为软件镜像而非宿主桩")
    } else {
        check(false, "提供方或消费方装载返回空")
    }
} catch {
    check(false, "优先级场景抛错：\(error)")
}

// MARK: - 用例 5：装配层接口可用（SDRHostCall 索引可被翻译为地址）

let hostIndex = SDRHostCall.shared.register("host_smoke_probe") { _ in 0 }
check(SDRHostCall.shared.index(of: "host_smoke_probe") == hostIndex, "SDRHostCall 符号索引可查询，装配层据此生成桩地址")
check(SDRHostCall.shared.contains("host_smoke_probe"), "SDRHostCall 符号表可查询已注册符号")
let reRegisterIndex = SDRHostCall.shared.register("host_smoke_probe") { _ in 0 }
check(reRegisterIndex == hostIndex, "重名注册幂等，索引稳定")

print("host-smoke: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
