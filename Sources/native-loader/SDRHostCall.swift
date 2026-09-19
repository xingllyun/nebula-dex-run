// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// 阶段二 · 步骤二：guest → host 托管调用桥
//
// SO 中的 libc 符号（memcpy/malloc/open…）不以真实 host 地址存在，而是由本桥在 guest
// 地址空间内生成 trampoline 桩：
//
//     movz x16, #<symbolIndex>      // x16 携带符号索引
//     brk  #0x4E44                  // 自定义陷阱：解释器识别后转交 host 实现
//     ret                           // 返回 x30（桩按标准 AAPCS64 调用约定被 BL 进入）
//
// 解释器在 BRK 分支识别 0x4E44 立即数后调用 `SDRHostCall.dispatch`，把 host 实现
// 的返回值写入 x0 并继续执行；#0x4E44 以外的 BRK 保持原有停机语义（软断点回归不受影响）。
//
// 该设计的收益：
// 1. guest 侧无需知道任何 host 地址，符号解析（步骤三）只需把 GOT/重定位项填成桩地址；
// 2. 桩与真实 libc 调用点二进制兼容（BL sym → 参数仍在 x0..x7，返回值仍在 x0）；
// 3. 单测可直接把桩写进 guest 代码段，用解释器真实执行来验收语义。

import Foundation

// MARK: - host 调用上下文

/// 单次 host 调用可见的全部外部世界：guest 内存读写 + 系统调用代理 + 调用参数（a0..a5）。
public final class SDRHostCallContext {
    public let memory: SDRMemoryGuard
    public let services: SDRSystemServices
    public let arguments: [UInt64]
    /// V0..V7 的 64 位原始位模式（AAPCS64 浮点/向量参数寄存器，供 libm 桥取 double 实参）。
    public let floatArguments: [UInt64]

    public init(memory: SDRMemoryGuard, services: SDRSystemServices, arguments: [UInt64],
                floatArguments: [UInt64] = []) {
        self.memory = memory
        self.services = services
        self.arguments = arguments
        self.floatArguments = floatArguments
    }

    /// a0..a5；越界参数按 0 处理（与寄存器未初始化语义一致）。
    public func arg(_ index: Int) -> UInt64 {
        guard index >= 0, index < arguments.count else { return 0 }
        return arguments[index]
    }

    /// v0..v7 按 double 语义读取（libm 桥的实参通道）；越界按 0.0 处理。
    public func floatArg(_ index: Int) -> Double {
        guard index >= 0, index < floatArguments.count else { return 0 }
        return Double(bitPattern: floatArguments[index])
    }

    /// s0..s7 按 float 语义读取（取 v 寄存器低 32 位）。
    public func singleFloatArg(_ index: Int) -> Float {
        guard index >= 0, index < floatArguments.count else { return 0 }
        return Float(bitPattern: UInt32(truncatingIfNeeded: floatArguments[index]))
    }

    /// 读取 guest 内存；失败返回 nil（调用方按 errno 语义处理，而非抛错打断解释执行）。
    public func read(_ address: UInt64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        return try? memory.read(address, count: count)
    }

    @discardableResult
    public func write(_ address: UInt64, _ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        return (try? memory.write(address, bytes: bytes)) != nil
    }

    public func readScalar(_ address: UInt64, count: Int) -> UInt64 {
        (try? memory.readScalar(address, count: count)) ?? 0
    }

    @discardableResult
    public func writeScalar(_ address: UInt64, _ value: UInt64, count: Int) -> Bool {
        (try? memory.writeScalar(address, value: value, count: count)) != nil
    }

    /// 读 NUL 结尾的 C 串原始字节（不做 UTF-8 解码，保证 strlen/strcmp 的字节语义）。
    public func readCStringBytes(_ address: UInt64, limit: Int = 1 << 20) -> [UInt8]? {
        var result: [UInt8] = []
        var cursor = address
        while result.count <= limit {
            guard let chunk = read(cursor, count: min(256, limit + 1 - result.count)) else { return nil }
            guard !chunk.isEmpty else { return nil }
            for byte in chunk {
                if byte == 0 { return result }
                result.append(byte)
            }
            cursor &+= UInt64(chunk.count)
        }
        return nil
    }

    @discardableResult
    public func writeCString(_ address: UInt64, _ bytes: [UInt8]) -> Bool {
        write(address, bytes + [0])
    }

    /// AArch64 失败约定：返回 -errno 的二进制补码。
    public func fail(_ errno: Int32) -> UInt64 {
        UInt64(bitPattern: -Int64(errno))
    }

    /// 转发到系统调用代理层：libc 的文件/时间/进程族直接复用已校验过的 syscall 语义。
    @discardableResult
    public func syscall(_ number: UInt32,
                        _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0,
                        _ a3: UInt64 = 0, _ a4: UInt64 = 0, _ a5: UInt64 = 0) -> UInt64 {
        let scratch = SDRCpuContext()
        scratch.x[0] = a0
        scratch.x[1] = a1
        scratch.x[2] = a2
        scratch.x[3] = a3
        scratch.x[4] = a4
        scratch.x[5] = a5
        return (try? services.dispatch(syscall: number, context: scratch)) ?? 0
    }
}

// MARK: - 托管调用桥

public final class SDRHostCall {
    public static let shared = SDRHostCall()

    /// guest 侧桩使用的 BRK 立即数（"ND"：NebulaDex）。其余立即数保持软断点停机语义。
    public static let trapImmediate: UInt32 = 0x4E44

    /// 单个桩 3 条指令 = 12 字节。
    public static let trampolineInstructionCount = 3
    public static let trampolineBytes = 12

    /// movz 的 imm16 上限即符号数上限。
    public static var symbolLimit: Int { 0x1_0000 }

    public typealias Body = (SDRHostCallContext) throws -> UInt64
    /// 标量（libm 族）实现：实参经 `floatArg(_:)` 读取，返回值写回 V0。
    public typealias ScalarBody = (SDRHostCallContext) throws -> Double

    /// 单次托管调用的返回通道：整数写回 X0，标量写回 V0。
    public enum Outcome {
        case integer(UInt64)
        case scalar(Double)
    }

    private enum Entry {
        case integer(Body)
        case scalar(ScalarBody)
    }

    private var entries: [Entry] = []
    private var names: [String] = []
    private var indexByName: [String: UInt64] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: 符号表

    /// 注册整数返回符号并返回其稳定索引；重名注册幂等（返回既有索引）。
    @discardableResult
    public func register(_ name: String, body: @escaping Body) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let existing = indexByName[name] { return existing }
        let index = UInt64(entries.count)
        entries.append(.integer(body))
        names.append(name)
        indexByName[name] = index
        return index
    }

    /// 注册标量（double 返回）符号：用于 libm 族，返回值经 BRK 陷阱写回 V0。
    @discardableResult
    public func registerScalar(_ name: String, body: @escaping ScalarBody) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let existing = indexByName[name] { return existing }
        let index = UInt64(entries.count)
        entries.append(.scalar(body))
        names.append(name)
        indexByName[name] = index
        return index
    }

    public func index(of name: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return indexByName[name]
    }

    public func contains(_ name: String) -> Bool { index(of: name) != nil }

    public var symbolCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public func symbols() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        names.removeAll()
        indexByName.removeAll()
    }

    // MARK: 分派

    /// 陷阱分派：索引取 x16（见 trapIndex），越界返回 nil（调用方按未实现符号回落 -ENOSYS）。
    public func dispatch(index: UInt64,
                         context: SDRCpuContext,
                         memory: SDRMemoryGuard,
                         services: SDRSystemServices) throws -> Outcome? {
        lock.lock()
        let entry: Entry? = index < UInt64(entries.count) ? entries[Int(index)] : nil
        lock.unlock()
        guard let entry else { return nil }
        let arguments = (0..<6).map { slot -> UInt64 in
            slot < context.x.count ? context.x[slot] : 0
        }
        let floats = (0..<8).map { slot -> UInt64 in
            slot < context.fpu.v.count ? context.fpu.v[slot] : 0
        }
        let call = SDRHostCallContext(memory: memory, services: services,
                                      arguments: arguments, floatArguments: floats)
        switch entry {
        case .integer(let body):
            return .integer(try body(call))
        case .scalar(let body):
            return .scalar(try body(call))
        }
    }

    // MARK: 桩机器码

    /// `movz x16,#index ; brk #0x4E44 ; ret`
    public static func trampolineInstructions(index: UInt64) -> [UInt32] {
        let immediate = UInt32(truncatingIfNeeded: index & 0xFFFF)
        let movz = 0xD280_0000 | (immediate << 5) | 16   // movz x16, #imm16
        let brk = 0xD420_0000 | (trapImmediate << 5)     // brk #0x4E44
        return [movz, brk, 0xD65F_03C0]                  // ret
    }

    public static func trampolineData(index: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trampolineBytes)
        for instruction in trampolineInstructions(index: index) {
            bytes.append(UInt8(truncatingIfNeeded: instruction))
            bytes.append(UInt8(truncatingIfNeeded: instruction >> 8))
            bytes.append(UInt8(truncatingIfNeeded: instruction >> 16))
            bytes.append(UInt8(truncatingIfNeeded: instruction >> 24))
        }
        return bytes
    }

    /// 是否为托管调用陷阱（其余 BRK 保持停机语义）。
    public static func isHostCallTrap(_ instruction: UInt32) -> Bool {
        (instruction & 0xFFE0_001F) == 0xD420_0000 && ((instruction >> 5) & 0xFFFF) == trapImmediate
    }

    /// 从 CPU 状态取符号索引：桩中的 `movz x16,#index` 把索引写入 x16，
    /// BRK 立即数只承载陷阱标识（自身不携带索引）。
    public static func trapIndex(_ context: SDRCpuContext) -> UInt64 {
        context.x.count > 16 ? context.x[16] : UInt64.max
    }
}
