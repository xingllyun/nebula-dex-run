// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// 阶段二 · 步骤四：宿主桩区（host stub pool）
//
// 步骤三的符号解析只把「符号 → 地址」交给 SDRSharedLibraryTable.hostSymbolResolver，
// 真实运行时还需要一个落地地点：把 SDRHostCall 中每个已注册符号的 trampoline 写进
// guest 地址空间，使 guest 侧的
//
//     bl <stub>   →   movz x16,#index ; brk #0x4E44 ; ret
//
// 能真正被解释器执行并按索引分派回宿主实现。本类即该桩区：
//
// 1. 槽位与 SDRHostCall 的符号索引一一对应（第 n 号符号占第 n 槽，每槽 12 字节）；
// 2. 灌入期以可写映射建立，写完立即 protect 收权为「读 + 执行」，与只读 PT_LOAD 段的
//    处理方式一致（装载期写入、运行期不可写）；
// 3. 未命中的符号一律返回 nil，调用方按「依赖缺失」保留缺口，不静默给假地址。

import Foundation

public final class SDRHostStubPool {
    /// 桩区默认基址（与 SDRAddressSpaceAllocator 的动态区互不重叠）。
    public static let defaultBase: UInt64 = 0x3_0000_0000
    /// 槽位大小：与 trampoline 机器码长度严格一致。
    public static let slotBytes = SDRHostCall.trampolineBytes

    public let name: String
    /// 槽位上限（默认 4096 槽 = 48KB）。
    public let capacity: Int

    public private(set) var base: UInt64 = 0
    public private(set) var size: UInt64 = 0
    public private(set) var isPrepared = false
    public private(set) var preparedSymbolCount = 0

    private var addressBySymbol: [String: UInt64] = [:]
    private var preparedBridgeID: ObjectIdentifier?
    private let lock = NSLock()

    public init(name: String = "host.stubs", capacity: Int = 4096) {
        self.name = name
        self.capacity = max(capacity, 1)
    }

    /// 在 guest 内存中建立桩区：默认收录 `bridge` 当前全部已注册符号。
    /// - Parameters:
    ///   - symbols: 仅收录指定符号（nil 表示全部）。
    /// - Returns: 是否成功建立（幂等：同一内存 + 同一桥重复调用直接返回既有桩区）。
    @discardableResult
    public func prepare(in memory: SDRMemoryGuard,
                        bridge: SDRHostCall = .shared,
                        symbols: [String]? = nil,
                        at base: UInt64 = SDRHostStubPool.defaultBase) -> Bool {
        let bridgeID = ObjectIdentifier(bridge)
        lock.lock()
        if isPrepared, preparedBridgeID == bridgeID, self.base == base {
            lock.unlock()
            return true
        }
        lock.unlock()

        let names = symbols ?? bridge.symbols()
        var targets: [(String, UInt64)] = []
        var maxIndex: UInt64 = 0
        for symbol in names {
            guard let index = bridge.index(of: symbol) else { continue }
            targets.append((symbol, index))
            maxIndex = max(maxIndex, index)
        }
        guard !targets.isEmpty else {
            SDRLogger.w("host.stubs", "桩区未收录任何符号：桥上尚未注册实现")
            return false
        }
        let slotCount = Int(maxIndex) + 1
        guard slotCount <= capacity else {
            SDRLogger.w("host.stubs", "桩区槽位不足：需要 \(slotCount) 槽，容量 \(capacity)")
            return false
        }
        let bytes = UInt64(slotCount) * UInt64(Self.slotBytes)

        guard let mapped = memory.mapAnonymous(name: name, size: bytes,
                                               alignment: SDRSyscallNumber.pageSize,
                                               readable: true, writable: true,
                                               executable: true) else {
            SDRLogger.w("host.stubs", "桩区映射失败：\(name)")
            return false
        }

        // 灌入期：槽位按符号索引排布，每槽写入 movz/brk/ret 三指令。
        var payload = [UInt8](repeating: 0, count: Int(bytes))
        var table: [String: UInt64] = [:]
        for (symbol, index) in targets {
            let offset = Int(index) * Self.slotBytes
            let stub = SDRHostCall.trampolineData(index: index)
            guard offset + stub.count <= payload.count else { continue }
            payload.replaceSubrange(offset..<(offset + stub.count), with: stub)
            table[symbol] = mapped + UInt64(offset)
        }
        guard (try? memory.write(mapped, bytes: payload)) != nil else {
            SDRLogger.w("host.stubs", "桩区写入失败：\(name)")
            _ = memory.unmap(address: mapped, size: bytes)
            return false
        }
        // 运行期：只读 + 可执行（guest 不得改桩，桩也不承载数据）。
        guard memory.protect(address: mapped, size: bytes,
                             readable: true, writable: false, executable: true) else {
            SDRLogger.w("host.stubs", "桩区收权失败：\(name)")
            _ = memory.unmap(address: mapped, size: bytes)
            return false
        }

        lock.lock()
        self.base = mapped
        self.size = bytes
        self.addressBySymbol = table
        self.preparedSymbolCount = table.count
        self.preparedBridgeID = bridgeID
        self.isPrepared = true
        lock.unlock()

        SDRLogger.i("host.stubs", "宿主桩区就绪：\(name) @0x\(String(mapped, radix: 16))，\(table.count) 个符号")
        return true
    }

    /// 符号桩地址（未收录返回 nil）。
    public func address(for symbol: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return addressBySymbol[symbol]
    }

    public func contains(_ symbol: String) -> Bool { address(for: symbol) != nil }

    public func symbols() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return addressBySymbol.keys.sorted()
    }

    /// 直接装配给 `SDRSharedLibraryTable.hostSymbolResolver`。
    public func resolver() -> (String) -> UInt64? {
        { [weak self] symbol in self?.address(for: symbol) }
    }

    /// 供替换/复位测试使用。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        base = 0
        size = 0
        isPrepared = false
        preparedSymbolCount = 0
        addressBySymbol.removeAll()
        preparedBridgeID = nil
    }
}
