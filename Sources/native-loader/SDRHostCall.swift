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

    public init(memory: SDRMemoryGuard, services: SDRSystemServices, arguments: [UInt64]) {
        self.memory = memory
        self.services = services
        self.arguments = arguments
    }

    /// a0..a5；越界参数按 0 处理（与寄存器未初始化语义一致）。
    public func arg(_ index: Int) -> UInt64 {
        guard index >= 0, index < arguments.count else { return 0 }
        return arguments[index]
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

    private var bodies: [Body] = []
    private var names: [String] = []
    private var indexByName: [String: UInt64] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: 符号表

    /// 注册符号并返回其稳定索引；重名注册幂等（返回既有索引）。
    @discardableResult
    public func register(_ name: String, body: @escaping Body) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let existing = indexByName[name] { return existing }
        let index = UInt64(bodies.count)
        bodies.append(body)
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
        return bodies.count
    }

    public func symbols() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        bodies.removeAll()
        names.removeAll()
        indexByName.removeAll()
    }

    // MARK: 分派

    /// 陷阱分派：索引越界返回 nil（调用方按未实现符号回落）。
    public func dispatch(index: UInt64,
                         context: SDRCpuContext,
                         memory: SDRMemoryGuard,
                         services: SDRSystemServices) throws -> UInt64? {
        lock.lock()
        let body: Body? = Int(index) < bodies.count ? bodies[Int(index)] : nil
        lock.unlock()
        guard let body else { return nil }
        let arguments = (0..<6).map { slot -> UInt64 in
            slot < context.x.count ? context.x[slot] : 0
        }
        return try body(SDRHostCallContext(memory: memory, services: services, arguments: arguments))
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

    /// 从陷阱指令取符号索引。
    public static func trapIndex(_ instruction: UInt32) -> UInt64 {
        UInt64((instruction >> 5) & 0xFFFF)
    }
}
