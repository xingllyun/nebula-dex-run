// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// 阶段二 · 步骤二：最小可用 libc（guest 侧 C 运行时的宿主实现）
//
// 定位：SO 依赖的 libc 符号不落到真实 host libc，而由本文件在 guest 地址空间内实现，
// 经 SDRHostCall 的 BRK #0x4E44 trampoline 桩进入，参数沿用 AAPCS64（x0..x5），
// 返回值写回 x0。所有实现只触碰 SDRMemoryGuard 软件内存与已过沙盒校验的
// SDRSystemServices 系统调用代理层，不产生任何宿主文件系统副作用。
//
// 三层结构：
//   1. 内存/字符串族：直接在 guest 内存上做块搬运与字节比较（无 host 内存参与）；
//   2. 堆：SDRGuestHeap —— 16 字节量子的分桶自由链 + 64 KiB 块 / 大块独立匿名映射；
//   3. 文件/时间/进程族：转发到系统调用代理层，复用 -errno 失败约定。
//
// 体积约定：App 安装包目标 8 MB，本文件不引入 Foundation 之外的任何依赖，
// 也不生成额外资源，避免为运行时体积引入增量。

import Foundation

// MARK: - guest 堆

/// guest 侧堆：16 字节量子分桶自由链 + 块切分 + 大块独立匿名映射。
/// 不做块合并：SO 级分配器的存活周期远短于宿主进程，合并会带来额外元数据与扫描成本。
public final class SDRGuestHeap {

    public static let headerBytes: UInt64 = 16
    public static let quantum: UInt64 = 16
    /// 单次向地址空间申请的块大小
    public static let chunkBytes: UInt64 = 65536
    /// 量子桶数量：128 × 16 = 2048 字节以内的请求走自由链
    public static let smallClassCount = 128
    public static let largeFlag: UInt64 = 1 << 63
    /// 元数据掩码（净尺寸需剥离）
    public static let metaMask: UInt64 = largeFlag | (1 << 62)

    private var freeLists: [[UInt64]]
    /// 当前切分块的水位（避免小请求各自独占一整块）
    private var carveCursor: UInt64 = 0
    private var carveEnd: UInt64 = 0

    /// 已交付给 guest 的净字节数（验收与内存压力探测用）
    public private(set) var allocatedBytes: UInt64 = 0
    /// 历史峰值
    public private(set) var peakAllocatedBytes: UInt64 = 0
    /// 单块最大可用尺寸
    public static let maxSmallPayload = UInt64(smallClassCount) * quantum

    public init() {
        freeLists = Array(repeating: [], count: SDRGuestHeap.smallClassCount)
    }

    @inline(__always)
    private static func roundUp(_ value: UInt64, _ alignment: UInt64) -> UInt64 {
        guard alignment > 0 else { return value }
        return (value + alignment - 1) / alignment * alignment
    }

    /// 申请 payload；`alignment` 为 0 表示按默认 16 字节对齐。失败返回 nil（调用方按 ENOMEM 处理）。
    /// 大对齐请求（> 16）走独立匿名映射：页对齐天然满足 ≤ 页大小的任意对齐，无需补偿。
    public func allocate(_ size: UInt64, alignment: UInt64 = 0, _ context: SDRHostCallContext) -> UInt64? {
        guard size > 0 else { return nil }
        let aligned = SDRGuestHeap.roundUp(size, SDRGuestHeap.quantum)
        let align = max(SDRGuestHeap.quantum, alignment)
        if aligned <= SDRGuestHeap.maxSmallPayload && align <= SDRGuestHeap.quantum {
            let index = Int(aligned / SDRGuestHeap.quantum) - 1
            if index >= 0 && index < freeLists.count, let reused = freeLists[index].popLast() {
                writeHeader(reused - SDRGuestHeap.headerBytes, size: aligned, trailing: reused, context)
                noteAllocated(aligned)
                return reused
            }
            let base = carve(aligned + SDRGuestHeap.headerBytes, context)
            guard let header = base else { return nil }
            writeHeader(header, size: aligned, trailing: header + SDRGuestHeap.headerBytes, context)
            noteAllocated(aligned)
            return header + SDRGuestHeap.headerBytes
        }
        let rounded = SDRGuestHeap.roundUp(aligned, SDRSyscallNumber.pageSize)
        let mapped = context.memory.mapAnonymous(name: "libc.heap.large",
                                                size: rounded + SDRGuestHeap.headerBytes,
                                                alignment: SDRSyscallNumber.pageSize,
                                                readable: true, writable: true, executable: false)
        guard let base = mapped else { return nil }
        writeHeader(base, size: aligned | SDRGuestHeap.largeFlag, trailing: rounded, context)
        noteAllocated(aligned)
        return base + SDRGuestHeap.headerBytes
    }

    /// 释放 payload；返回是否命中了已知块。
    @discardableResult
    public func release(_ payload: UInt64, _ context: SDRHostCallContext) -> Bool {
        guard payload > SDRGuestHeap.headerBytes else { return false }
        let header = payload - SDRGuestHeap.headerBytes
        let raw = context.readScalar(header, count: 8)
        guard raw != 0 else { return false }
        let payloadSize = raw & ~SDRGuestHeap.metaMask
        if raw & SDRGuestHeap.largeFlag != 0 {
            let rounded = context.readScalar(header + 8, count: 8)
            _ = context.memory.unmap(address: header, size: rounded + SDRGuestHeap.headerBytes)
            noteReleased(payloadSize)
            return true
        }
        let origin = context.readScalar(header + 8, count: 8)
        let index = Int(payloadSize / SDRGuestHeap.quantum) - 1
        guard index >= 0 && index < freeLists.count else { return false }
        freeLists[index].append(origin == 0 ? payload : origin)
        noteReleased(payloadSize)
        return true
    }

    /// usable_size 语义：返回该块可安全使用的字节数。
    public func usableSize(_ payload: UInt64, _ context: SDRHostCallContext) -> UInt64 {
        guard payload > SDRGuestHeap.headerBytes else { return 0 }
        let raw = context.readScalar(payload - SDRGuestHeap.headerBytes, count: 8)
        return raw & ~SDRGuestHeap.metaMask
    }

    private func writeHeader(_ header: UInt64, size: UInt64, trailing: UInt64, _ context: SDRHostCallContext) {
        _ = context.writeScalar(header, size, count: 8)
        _ = context.writeScalar(header + 8, trailing, count: 8)
    }

    public func reset() {
        freeLists = Array(repeating: [], count: SDRGuestHeap.smallClassCount)
        carveCursor = 0
        carveEnd = 0
        allocatedBytes = 0
        peakAllocatedBytes = 0
    }

    // MARK: 内部

    /// 从块水位切分；水位不足则申请新块（单块至少 64 KiB，按需放大）。
    private func carve(_ total: UInt64, _ context: SDRHostCallContext) -> UInt64? {
        if carveCursor &+ total <= carveEnd {
            let start = carveCursor
            carveCursor += total
            return start
        }
        let need = max(SDRGuestHeap.chunkBytes, SDRGuestHeap.roundUp(total, SDRSyscallNumber.pageSize))
        guard let base = context.memory.mapAnonymous(name: "libc.heap.chunk",
                                                    size: need,
                                                    alignment: SDRSyscallNumber.pageSize,
                                                    readable: true, writable: true, executable: false) else {
            return nil
        }
        carveCursor = base + total
        carveEnd = base + need
        return base
    }

    private func noteAllocated(_ bytes: UInt64) {
        allocatedBytes += bytes
        if allocatedBytes > peakAllocatedBytes { peakAllocatedBytes = allocatedBytes }
    }

    private func noteReleased(_ bytes: UInt64) {
        allocatedBytes = allocatedBytes > bytes ? allocatedBytes - bytes : 0
    }
}

// MARK: - libc 门面

/// guest 侧最小 C 运行时：符号经 `SDRHostCall` 注册为托管调用，由 BRK #0x4E44 陷阱进入。
/// 全部实现只落在软件内存与系统调用代理层，不链接宿主 libc，也不触碰沙盒外路径。
public final class SDRLibc {

    public static let shared = SDRLibc()

    /// 单次块搬运的字节上限：防御 guest 传入异常长度导致宿主侧巨量分配
    public static let maxTransferBytes: UInt64 = 64 << 20
    /// C 串扫描上限
    public static let maxStringBytes: Int = 1 << 20

    public let heap = SDRGuestHeap()

    /// 已安装符号清单（按安装顺序，供符号解析与验收核对）
    public private(set) var registeredSymbols: [String] = []

    /// stdout 落点（printf/puts 族）；未设置时按 fd=1 转发 write 系统调用
    public var stdoutSink: ((SDRHostCallContext, [UInt8]) -> Void)?

    /// guest errno 槽地址（`__errno` / `__errno_location` 共享）
    public private(set) var errnoSlotAddress: UInt64 = 0

    private var installedBridge: ObjectIdentifier?

    public init() {}

    // MARK: 安装

    /// 幂等安装：同一桥重复安装返回 false，避免重名桩索引漂移。
    @discardableResult
    public func install(into bridge: SDRHostCall) -> Bool {
        if let installed = installedBridge, installed == ObjectIdentifier(bridge) { return false }
        registeredSymbols.removeAll(keepingCapacity: true)
        installMemoryFamily(bridge)
        installStringFamily(bridge)
        installHeapFamily(bridge)
        installIOFamily(bridge)
        installStdioFamily(bridge)
        installTimeAndProcessFamily(bridge)
        installedBridge = ObjectIdentifier(bridge)
        return true
    }

    private func add(_ bridge: SDRHostCall, _ name: String, _ body: @escaping SDRHostCall.Body) {
        _ = bridge.register(name, body: body)
        registeredSymbols.append(name)
    }

    // MARK: 内存族

    private func installMemoryFamily(_ bridge: SDRHostCall) {
        add(bridge, "memcpy") { ctx in
            SDRLibc.transfer(dst: ctx.arg(0), src: ctx.arg(1), count: ctx.arg(2), ctx)
        }
        add(bridge, "memmove") { ctx in
            SDRLibc.transfer(dst: ctx.arg(0), src: ctx.arg(1), count: ctx.arg(2), ctx)
        }
        add(bridge, "memset") { ctx in
            SDRLibc.fill(address: ctx.arg(0), value: UInt8(truncatingIfNeeded: ctx.arg(1)), count: ctx.arg(2), ctx)
        }
        add(bridge, "bzero") { ctx in
            SDRLibc.fill(address: ctx.arg(0), value: 0, count: ctx.arg(1), ctx)
        }
        add(bridge, "memcmp") { ctx in
            SDRLibc.compare(ctx.arg(0), ctx.arg(1), ctx.arg(2), ctx)
        }
        add(bridge, "memchr") { ctx in
            SDRLibc.searchByte(ctx.arg(0), needle: UInt8(truncatingIfNeeded: ctx.arg(1)), count: ctx.arg(2), ctx)
        }
    }

    /// 字节搬运；重叠场景同样安全（数据先落入宿主缓冲再写回）。
    public static func transfer(dst: UInt64, src: UInt64, count: UInt64, _ ctx: SDRHostCallContext) -> UInt64 {
        guard count > 0 else { return dst }
        guard count <= SDRLibc.maxTransferBytes else { return 0 }
        guard let bytes = ctx.read(src, count: Int(count)) else { return 0 }
        return ctx.write(dst, bytes) ? dst : 0
    }

    /// 填充；分片写入以限制宿主侧缓冲。
    public static func fill(address: UInt64, value: UInt8, count: UInt64, _ ctx: SDRHostCallContext) -> UInt64 {
        guard count > 0 else { return address }
        guard count <= SDRLibc.maxTransferBytes else { return 0 }
        let slab = [UInt8](repeating: value, count: 4096)
        var remaining = Int(count)
        var cursor = address
        while remaining > 0 {
            let n = min(remaining, slab.count)
            guard ctx.write(cursor, Array(slab[0..<n])) else { return 0 }
            cursor &+= UInt64(n)
            remaining -= n
        }
        return address
    }

    /// memcmp 语义：返回 <0 / 0 / >0（按首个不同字节的差值）。
    public static func compare(_ lhs: UInt64, _ rhs: UInt64, _ count: UInt64, _ ctx: SDRHostCallContext) -> UInt64 {
        guard count > 0 else { return 0 }
        guard count <= SDRLibc.maxTransferBytes else { return ctx.fail(SDRSyscallNumber.Errno.efault) }
        guard let a = ctx.read(lhs, count: Int(count)), let b = ctx.read(rhs, count: Int(count)) else { return 0 }
        for index in 0..<a.count where a[index] != b[index] {
            return UInt64(bitPattern: Int64(Int(a[index]) - Int(b[index])))
        }
        return 0
    }

    private static func searchByte(_ address: UInt64, needle: UInt8, count: UInt64, _ ctx: SDRHostCallContext) -> UInt64 {
        guard count > 0, count <= SDRLibc.maxTransferBytes else { return 0 }
        guard let bytes = ctx.read(address, count: Int(count)) else { return 0 }
        for (index, byte) in bytes.enumerated() where byte == needle {
            return address &+ UInt64(index)
        }
        return 0
    }

    // MARK: 字符串族

    private func installStringFamily(_ bridge: SDRHostCall) {
        add(bridge, "strlen") { ctx in
            guard let bytes = SDRLibc.loadCString(ctx.arg(0), ctx) else { return 0 }
            return UInt64(bytes.count)
        }
        add(bridge, "strnlen") { ctx in
            guard let bytes = SDRLibc.loadCString(ctx.arg(0), ctx) else { return 0 }
            return min(UInt64(bytes.count), ctx.arg(1))
        }
        add(bridge, "strcmp") { ctx in
            guard let a = SDRLibc.loadCString(ctx.arg(0), ctx), let b = SDRLibc.loadCString(ctx.arg(1), ctx) else { return 0 }
            return SDRLibc.compareBytes(a, b, limit: Int.max)
        }
        add(bridge, "strncmp") { ctx in
            guard let a = SDRLibc.loadCString(ctx.arg(0), ctx), let b = SDRLibc.loadCString(ctx.arg(1), ctx) else { return 0 }
            return SDRLibc.compareBytes(a, b, limit: Int(min(ctx.arg(2), UInt64(Int.max))))
        }
        add(bridge, "strcasecmp") { ctx in
            guard let a = SDRLibc.loadCString(ctx.arg(0), ctx), let b = SDRLibc.loadCString(ctx.arg(1), ctx) else { return 0 }
            return SDRLibc.compareBytes(a.map(SDRLibc.lowercased), b.map(SDRLibc.lowercased), limit: Int.max)
        }
        add(bridge, "strcpy") { ctx in
            guard let bytes = SDRLibc.loadCString(ctx.arg(1), ctx) else { return 0 }
            return ctx.writeCString(ctx.arg(0), bytes) ? ctx.arg(0) : 0
        }
        add(bridge, "strncpy") { ctx in
            guard let src = SDRLibc.loadCString(ctx.arg(1), ctx) else { return 0 }
            let limit = Int(min(ctx.arg(2), UInt64(SDRLibc.maxStringBytes)))
            var bytes = Array(src.prefix(limit))
            while bytes.count < limit { bytes.append(0) }
            return ctx.write(ctx.arg(0), bytes) ? ctx.arg(0) : 0
        }
        add(bridge, "strcat") { ctx in
            guard let head = SDRLibc.loadCString(ctx.arg(0), ctx), let tail = SDRLibc.loadCString(ctx.arg(1), ctx) else { return 0 }
            return ctx.writeCString(ctx.arg(0), head + tail) ? ctx.arg(0) : 0
        }
        add(bridge, "strncat") { ctx in
            guard let head = SDRLibc.loadCString(ctx.arg(0), ctx), let tail = SDRLibc.loadCString(ctx.arg(1), ctx) else { return 0 }
            let limit = Int(min(ctx.arg(2), UInt64(SDRLibc.maxStringBytes)))
            return ctx.writeCString(ctx.arg(0), head + Array(tail.prefix(limit))) ? ctx.arg(0) : 0
        }
        add(bridge, "strchr") { ctx in SDRLibc.findChar(ctx, fromStart: true) }
        add(bridge, "strrchr") { ctx in SDRLibc.findChar(ctx, fromStart: false) }
        add(bridge, "strstr") { ctx in SDRLibc.findSubstring(ctx) }
        add(bridge, "strdup") { ctx in
            guard let bytes = SDRLibc.loadCString(ctx.arg(0), ctx) else { return 0 }
            guard let payload = self.heap.allocate(UInt64(bytes.count + 1), ctx) else { return 0 }
            return ctx.writeCString(payload, bytes) ? payload : 0
        }
        add(bridge, "strndup") { ctx in
            guard let bytes = SDRLibc.loadCString(ctx.arg(0), ctx) else { return 0 }
            let limited = Array(bytes.prefix(Int(min(ctx.arg(1), UInt64(SDRLibc.maxStringBytes)))))
            guard let payload = self.heap.allocate(UInt64(limited.count + 1), ctx) else { return 0 }
            return ctx.writeCString(payload, limited) ? payload : 0
        }
        add(bridge, "atoi") { ctx in
            let (value, _) = SDRLibc.parseInteger(ctx.arg(0), base: 10, ctx)
            return UInt64(bitPattern: value)
        }
        add(bridge, "atol") { ctx in
            let (value, _) = SDRLibc.parseInteger(ctx.arg(0), base: 10, ctx)
            return UInt64(bitPattern: value)
        }
        add(bridge, "strtol") { ctx in SDRLibc.convertInteger(ctx, isSigned: true) }
        add(bridge, "strtoul") { ctx in SDRLibc.convertInteger(ctx, isSigned: false) }
        add(bridge, "strtoll") { ctx in SDRLibc.convertInteger(ctx, isSigned: true) }
        add(bridge, "strerror") { ctx in
            // 不持有静态错误表：直接把 errno 数值渲染为 "errno N"，避免为体积引入字符串表
            let digits = SDRLibc.digits(UInt64(UInt32(bitPattern: Int32(truncatingIfNeeded: ctx.arg(0)))), base: 10, uppercase: false, negative: false)
            guard let payload = self.heap.allocate(UInt64(digits.count + 7), ctx) else { return 0 }
            return ctx.writeCString(payload, Array("errno ".utf8) + digits) ? payload : 0
        }
    }

    static func loadCString(_ address: UInt64, _ ctx: SDRHostCallContext) -> [UInt8]? {
        guard address != 0 else { return nil }
        return ctx.readCStringBytes(address, limit: SDRLibc.maxStringBytes)
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    static func compareBytes(_ a: [UInt8], _ b: [UInt8], limit: Int) -> UInt64 {
        let bound = min(min(a.count, b.count), limit)
        for index in 0..<bound where a[index] != b[index] {
            return UInt64(bitPattern: Int64(Int(a[index]) - Int(b[index])))
        }
        if a.count == b.count { return 0 }
        let shorter = min(a.count, b.count)
        if shorter >= limit { return 0 }
        return a.count < b.count ? UInt64(bitPattern: Int64(-1)) : 1
    }

    private static func findChar(_ ctx: SDRHostCallContext, fromStart: Bool) -> UInt64 {
        guard let bytes = SDRLibc.loadCString(ctx.arg(0), ctx) else { return 0 }
        let needle = UInt8(truncatingIfNeeded: ctx.arg(1))
        let indices = fromStart ? Array(bytes.indices) : Array(bytes.indices.reversed())
        for index in indices where bytes[index] == needle {
            return ctx.arg(0) &+ UInt64(index)
        }
        return 0
    }

    private static func findSubstring(_ ctx: SDRHostCallContext) -> UInt64 {
        guard let haystack = SDRLibc.loadCString(ctx.arg(0), ctx) else { return 0 }
        guard let needle = SDRLibc.loadCString(ctx.arg(1), ctx) else { return 0 }
        if needle.isEmpty { return ctx.arg(0) }
        guard needle.count <= haystack.count else { return 0 }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return ctx.arg(0) &+ UInt64(start) }
        }
        return 0
    }

    private static func convertInteger(_ ctx: SDRHostCallContext, isSigned: Bool) -> UInt64 {
        let base = Int(Int32(truncatingIfNeeded: ctx.arg(2)))
        let (value, endOffset) = SDRLibc.parseInteger(ctx.arg(0), base: base, ctx)
        if ctx.arg(1) != 0, let bytes = loadCString(ctx.arg(0), ctx) {
            _ = ctx.writeScalar(ctx.arg(1), ctx.arg(0) &+ UInt64(min(endOffset, bytes.count)), count: 8)
        }
        return isSigned ? UInt64(bitPattern: value) : UInt64(bitPattern: value)
    }

    /// 解析可选正负号的整数；返回（值, 消耗的字节数）。
    static func parseInteger(_ address: UInt64, base: Int, _ ctx: SDRHostCallContext) -> (Int64, Int) {
        guard let bytes = loadCString(address, ctx), !bytes.isEmpty else { return (0, 0) }
        var index = 0
        var negative = false
        if bytes[index] == 0x2D || bytes[index] == 0x2B {
            negative = bytes[index] == 0x2D
            index += 1
        }
        var radix = base
        if radix == 0 {
            if index + 1 < bytes.count, bytes[index] == 0x30, bytes[index + 1] == 0x78 || bytes[index + 1] == 0x58 {
                radix = 16
                index += 2
            } else if index < bytes.count, bytes[index] == 0x30 {
                radix = 8
            } else {
                radix = 10
            }
        }
        var value: Int64 = 0
        var consumed = 0
        while index < bytes.count {
            guard let digit = SDRLibc.digitValue(bytes[index]), digit < radix else { break }
            value = value &* Int64(radix) &+ Int64(digit)
            consumed += 1
            index += 1
        }
        return (negative ? -value : value, index)
    }

    private static func digitValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x5A: return Int(byte - 0x41) + 10
        case 0x61...0x7A: return Int(byte - 0x61) + 10
        default: return nil
        }
    }

    // MARK: 堆族

    private func installHeapFamily(_ bridge: SDRHostCall) {
        add(bridge, "malloc") { ctx in self.heap.allocate(ctx.arg(0), ctx) ?? 0 }
        add(bridge, "calloc") { ctx in
            let count = ctx.arg(0), size = ctx.arg(1)
            guard count > 0, size > 0, count <= SDRLibc.maxTransferBytes / size else { return 0 }
            let total = count * size
            guard let payload = self.heap.allocate(total, ctx) else { return 0 }
            _ = SDRLibc.fill(address: payload, value: 0, count: total, ctx)
            return payload
        }
        add(bridge, "free") { ctx in
            _ = self.heap.release(ctx.arg(0), ctx)
            return 0
        }
        add(bridge, "realloc") { ctx in
            let payload = ctx.arg(0), size = ctx.arg(1)
            if payload == 0 { return self.heap.allocate(size, ctx) ?? 0 }
            if size == 0 {
                _ = self.heap.release(payload, ctx)
                return 0
            }
            let previous = self.heap.usableSize(payload, ctx)
            guard let fresh = self.heap.allocate(size, ctx) else { return 0 }
            _ = SDRLibc.transfer(dst: fresh, src: payload, count: min(previous, size), ctx)
            _ = self.heap.release(payload, ctx)
            return fresh
        }
        add(bridge, "aligned_alloc") { ctx in
            self.heap.allocate(ctx.arg(1), alignment: ctx.arg(0), ctx) ?? 0
        }
        add(bridge, "memalign") { ctx in
            self.heap.allocate(ctx.arg(1), alignment: ctx.arg(0), ctx) ?? 0
        }
        add(bridge, "posix_memalign") { ctx in
            let out = ctx.arg(0), alignment = ctx.arg(1), size = ctx.arg(2)
            guard out != 0 else { return ctx.fail(SDRSyscallNumber.Errno.efault) }
            guard let payload = self.heap.allocate(size, alignment: alignment, ctx) else {
                return ctx.fail(SDRSyscallNumber.Errno.enomem)
            }
            guard ctx.writeScalar(out, payload, count: 8) else { return ctx.fail(SDRSyscallNumber.Errno.efault) }
            return 0
        }
        add(bridge, "malloc_usable_size") { ctx in self.heap.usableSize(ctx.arg(0), ctx) }
    }

    // MARK: 文件与设备族（转发系统调用代理层）

    private func installIOFamily(_ bridge: SDRHostCall) {
        add(bridge, "open") { ctx in
            ctx.syscall(SDRSyscallNumber.openat, SDRLibc.atFdcwd, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "openat") { ctx in
            ctx.syscall(SDRSyscallNumber.openat, ctx.arg(0), ctx.arg(1), ctx.arg(2), ctx.arg(3))
        }
        add(bridge, "close") { ctx in ctx.syscall(SDRSyscallNumber.close, ctx.arg(0)) }
        add(bridge, "read") { ctx in
            ctx.syscall(SDRSyscallNumber.read, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "write") { ctx in
            ctx.syscall(SDRSyscallNumber.write, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "pread") { ctx in
            ctx.syscall(SDRSyscallNumber.pread64, ctx.arg(0), ctx.arg(1), ctx.arg(2), ctx.arg(3))
        }
        add(bridge, "pwrite") { ctx in
            ctx.syscall(SDRSyscallNumber.pwrite64, ctx.arg(0), ctx.arg(1), ctx.arg(2), ctx.arg(3))
        }
        add(bridge, "lseek") { ctx in
            ctx.syscall(SDRSyscallNumber.lseek, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "fstat") { ctx in ctx.syscall(SDRSyscallNumber.fstat, ctx.arg(0), ctx.arg(1)) }
        add(bridge, "stat") { ctx in
            ctx.syscall(SDRSyscallNumber.newfstatat, SDRLibc.atFdcwd, ctx.arg(0), ctx.arg(1), 0)
        }
        add(bridge, "lstat") { ctx in
            ctx.syscall(SDRSyscallNumber.newfstatat, SDRLibc.atFdcwd, ctx.arg(0), ctx.arg(1), 0x100)
        }
        add(bridge, "fstatat") { ctx in
            ctx.syscall(SDRSyscallNumber.newfstatat, ctx.arg(0), ctx.arg(1), ctx.arg(2), ctx.arg(3))
        }
        add(bridge, "ftruncate") { ctx in
            ctx.syscall(SDRSyscallNumber.ftruncate, ctx.arg(0), ctx.arg(1))
        }
        add(bridge, "fsync") { ctx in ctx.syscall(SDRSyscallNumber.fsync, ctx.arg(0)) }
        add(bridge, "unlink") { ctx in
            ctx.syscall(SDRSyscallNumber.unlinkat, SDRLibc.atFdcwd, ctx.arg(0), 0)
        }
        add(bridge, "unlinkat") { ctx in
            ctx.syscall(SDRSyscallNumber.unlinkat, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "mkdir") { ctx in
            ctx.syscall(SDRSyscallNumber.mkdirat, SDRLibc.atFdcwd, ctx.arg(0), ctx.arg(1))
        }
        add(bridge, "mkdirat") { ctx in
            ctx.syscall(SDRSyscallNumber.mkdirat, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "access") { ctx in
            ctx.syscall(SDRSyscallNumber.faccessat, SDRLibc.atFdcwd, ctx.arg(0), ctx.arg(1), 0)
        }
        add(bridge, "faccessat") { ctx in
            ctx.syscall(SDRSyscallNumber.faccessat, ctx.arg(0), ctx.arg(1), ctx.arg(2), ctx.arg(3))
        }
        add(bridge, "readlink") { ctx in
            ctx.syscall(SDRSyscallNumber.readlinkat, SDRLibc.atFdcwd, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "readlinkat") { ctx in
            ctx.syscall(SDRSyscallNumber.readlinkat, ctx.arg(0), ctx.arg(1), ctx.arg(2), ctx.arg(3))
        }
        add(bridge, "getdents64") { ctx in
            ctx.syscall(SDRSyscallNumber.getdents64, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "dup") { ctx in ctx.syscall(SDRSyscallNumber.dup, ctx.arg(0)) }
        add(bridge, "fcntl") { ctx in
            ctx.syscall(SDRSyscallNumber.fcntl, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "ioctl") { ctx in
            ctx.syscall(SDRSyscallNumber.ioctl, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "pipe2") { ctx in ctx.syscall(SDRSyscallNumber.pipe2, ctx.arg(0), ctx.arg(1)) }
        add(bridge, "isatty") { _ in 0 }
        add(bridge, "getcwd") { ctx in
            let buffer = ctx.arg(0), size = ctx.arg(1)
            guard buffer != 0, size > 0 else { return ctx.fail(SDRSyscallNumber.Errno.efault) }
            let path = Array(ctx.services.workingDirectory.utf8) + [0]
            guard UInt64(path.count) <= size else { return ctx.fail(SDRSyscallNumber.Errno.erange) }
            return ctx.write(buffer, path) ? buffer : 0
        }
        add(bridge, "chdir") { ctx in
            guard let bytes = SDRLibc.loadCString(ctx.arg(0), ctx),
                  let path = String(bytes: bytes, encoding: .utf8) else {
                return ctx.fail(SDRSyscallNumber.Errno.efault)
            }
            let candidate = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: ctx.services.workingDirectory).appendingPathComponent(path)
            guard SDRSandbox.shared.isAllowed(candidate) else {
                return ctx.fail(SDRSyscallNumber.Errno.eacces)
            }
            ctx.services.workingDirectory = candidate.standardizedFileURL.path
            return 0
        }
    }

    // MARK: 标准输入输出族

    private func installStdioFamily(_ bridge: SDRHostCall) {
        add(bridge, "printf") { ctx in
            self.emit(self.format(ctx, format: ctx.arg(0), firstArgument: 1), to: 1, ctx)
        }
        add(bridge, "fprintf") { ctx in
            let fd = Int32(truncatingIfNeeded: ctx.arg(0))
            return self.emit(self.format(ctx, format: ctx.arg(1), firstArgument: 2), to: fd, ctx)
        }
        add(bridge, "sprintf") { ctx in
            self.render(ctx, format: ctx.arg(1), firstArgument: 2, buffer: ctx.arg(0), limit: nil)
        }
        add(bridge, "snprintf") { ctx in
            self.render(ctx, format: ctx.arg(2), firstArgument: 3, buffer: ctx.arg(0), limit: ctx.arg(1))
        }
        add(bridge, "puts") { ctx in
            guard let bytes = SDRLibc.loadCString(ctx.arg(0), ctx) else {
                return ctx.fail(SDRSyscallNumber.Errno.efault)
            }
            return self.emit(bytes + [0x0A], to: 1, ctx)
        }
        add(bridge, "fputs") { ctx in
            let fd = Int32(truncatingIfNeeded: ctx.arg(1))
            guard let bytes = SDRLibc.loadCString(ctx.arg(0), ctx) else {
                return ctx.fail(SDRSyscallNumber.Errno.efault)
            }
            return self.emit(bytes, to: fd, ctx)
        }
        add(bridge, "putchar") { ctx in
            self.emit([UInt8(truncatingIfNeeded: ctx.arg(0))], to: 1, ctx)
        }
        add(bridge, "putc") { ctx in
            self.emit([UInt8(truncatingIfNeeded: ctx.arg(0))], to: Int32(truncatingIfNeeded: ctx.arg(1)), ctx)
        }
        add(bridge, "fputc") { ctx in
            self.emit([UInt8(truncatingIfNeeded: ctx.arg(0))], to: Int32(truncatingIfNeeded: ctx.arg(1)), ctx)
        }
        add(bridge, "fwrite") { ctx in
            let pointer = ctx.arg(0), size = ctx.arg(1), count = ctx.arg(2)
            let fd = Int32(truncatingIfNeeded: ctx.arg(3))
            guard size > 0, count > 0, count <= SDRLibc.maxTransferBytes / size else { return 0 }
            guard let bytes = ctx.read(pointer, count: Int(size * count)) else { return 0 }
            guard self.emit(bytes, to: fd, ctx) != 0 else { return 0 }
            return count
        }
        add(bridge, "fread") { ctx in
            let pointer = ctx.arg(0), size = ctx.arg(1), count = ctx.arg(2)
            let fd = Int32(truncatingIfNeeded: ctx.arg(3))
            guard size > 0, count > 0, count <= SDRLibc.maxTransferBytes / size else { return 0 }
            let total = size * count
            let got = ctx.syscall(SDRSyscallNumber.read, UInt64(bitPattern: Int64(fd)), pointer, total)
            guard got != 0, (got & SDRLibc.failureMask) == 0 else { return 0 }
            return got / size
        }
        add(bridge, "fgets") { ctx in
            let buffer = ctx.arg(0), capacity = ctx.arg(1)
            let fd = Int32(truncatingIfNeeded: ctx.arg(2))
            guard buffer != 0, capacity > 1 else { return 0 }
            guard let scratch = self.heap.allocate(1, ctx) else { return 0 }
            defer { _ = self.heap.release(scratch, ctx) }
            let bound = Int(min(capacity - 1, UInt64(SDRLibc.maxStringBytes)))
            var collected: [UInt8] = []
            while collected.count < bound {
                let got = ctx.syscall(SDRSyscallNumber.read, UInt64(bitPattern: Int64(fd)), scratch, 1)
                guard got == 1, (got & SDRLibc.failureMask) == 0 else { break }
                let byte = UInt8(truncatingIfNeeded: ctx.readScalar(scratch, count: 1))
                collected.append(byte)
                if byte == 0x0A { break }
            }
            guard !collected.isEmpty else { return 0 }
            guard ctx.write(buffer, collected + [0]) else { return 0 }
            return buffer
        }
        add(bridge, "fopen") { ctx in
            guard let bytes = SDRLibc.loadCString(ctx.arg(1), ctx),
                  let mode = String(bytes: bytes, encoding: .utf8) else {
                return ctx.fail(SDRSyscallNumber.Errno.efault)
            }
            let flags = SDRLibc.openFlags(forMode: mode)
            return ctx.syscall(SDRSyscallNumber.openat, SDRLibc.atFdcwd, ctx.arg(0),
                               UInt64(bitPattern: Int64(flags)), 0o644)
        }
        add(bridge, "fclose") { ctx in ctx.syscall(SDRSyscallNumber.close, ctx.arg(0)) }
        add(bridge, "fflush") { _ in 0 }
    }

    // MARK: 时间与进程族

    private func installTimeAndProcessFamily(_ bridge: SDRHostCall) {
        add(bridge, "clock_gettime") { ctx in
            ctx.syscall(SDRSyscallNumber.clock_gettime, ctx.arg(0), ctx.arg(1))
        }
        add(bridge, "clock_getres") { ctx in
            ctx.syscall(SDRSyscallNumber.clock_getres, ctx.arg(0), ctx.arg(1))
        }
        add(bridge, "gettimeofday") { ctx in
            ctx.syscall(SDRSyscallNumber.gettimeofday, ctx.arg(0), ctx.arg(1))
        }
        add(bridge, "time") { ctx in
            let seconds = Int64(Date().timeIntervalSince1970)
            if ctx.arg(0) != 0 {
                _ = ctx.writeScalar(ctx.arg(0), UInt64(bitPattern: seconds), count: 8)
            }
            return UInt64(bitPattern: seconds)
        }
        add(bridge, "nanosleep") { ctx in
            ctx.syscall(SDRSyscallNumber.nanosleep, ctx.arg(0), ctx.arg(1))
        }
        add(bridge, "usleep") { ctx in
            let micros = ctx.arg(0)
            guard let scratch = self.heap.allocate(16, ctx) else {
                return ctx.fail(SDRSyscallNumber.Errno.enomem)
            }
            defer { _ = self.heap.release(scratch, ctx) }
            _ = ctx.writeScalar(scratch, micros / 1_000_000, count: 8)
            _ = ctx.writeScalar(scratch + 8, (micros % 1_000_000) * 1000, count: 8)
            return ctx.syscall(SDRSyscallNumber.nanosleep, scratch, 0)
        }
        add(bridge, "getpid") { ctx in ctx.syscall(SDRSyscallNumber.getpid) }
        add(bridge, "getppid") { ctx in ctx.syscall(SDRSyscallNumber.getppid) }
        add(bridge, "getuid") { ctx in ctx.syscall(SDRSyscallNumber.getuid) }
        add(bridge, "geteuid") { ctx in ctx.syscall(SDRSyscallNumber.geteuid) }
        add(bridge, "getgid") { ctx in ctx.syscall(SDRSyscallNumber.getgid) }
        add(bridge, "getegid") { ctx in ctx.syscall(SDRSyscallNumber.getegid) }
        add(bridge, "gettid") { ctx in ctx.syscall(SDRSyscallNumber.gettid) }
        add(bridge, "sched_yield") { ctx in ctx.syscall(SDRSyscallNumber.sched_yield) }
        add(bridge, "exit") { ctx in ctx.syscall(SDRSyscallNumber.exit, ctx.arg(0)) }
        add(bridge, "_exit") { ctx in ctx.syscall(SDRSyscallNumber.exit, ctx.arg(0)) }
        add(bridge, "abort") { ctx in
            // 与 SIGABRT 等价：置位退出请求，由解释器主循环收口
            ctx.syscall(SDRSyscallNumber.exit_group, 134)
        }
        add(bridge, "getenv") { _ in 0 }
        add(bridge, "sysconf") { ctx in
            let name = Int32(truncatingIfNeeded: ctx.arg(0))
            switch name {
            case 30, 39, 40: return SDRSyscallNumber.pageSize
            case 83, 84: return 1
            default: return UInt64(bitPattern: Int64(-1))
            }
        }
        add(bridge, "getpagesize") { _ in SDRSyscallNumber.pageSize }
        add(bridge, "__errno") { ctx in self.errnoSlot(ctx) }
        add(bridge, "__errno_location") { ctx in self.errnoSlot(ctx) }
        add(bridge, "mmap") { ctx in
            ctx.syscall(SDRSyscallNumber.mmap, ctx.arg(0), ctx.arg(1), ctx.arg(2), ctx.arg(3), ctx.arg(4), ctx.arg(5))
        }
        add(bridge, "munmap") { ctx in ctx.syscall(SDRSyscallNumber.munmap, ctx.arg(0), ctx.arg(1)) }
        add(bridge, "mprotect") { ctx in
            ctx.syscall(SDRSyscallNumber.mprotect, ctx.arg(0), ctx.arg(1), ctx.arg(2))
        }
        add(bridge, "brk") { ctx in ctx.syscall(SDRSyscallNumber.brk, ctx.arg(0)) }
    }

    // MARK: 内部工具

    private func errnoSlot(_ ctx: SDRHostCallContext) -> UInt64 {
        if errnoSlotAddress == 0 {
            errnoSlotAddress = heap.allocate(8, ctx) ?? 0
        }
        return errnoSlotAddress
    }

    /// 输出字节流：stdout 有自定义落点时优先回调，否则按 fd 走 write 系统调用。
    private func emit(_ bytes: [UInt8], to fd: Int32, _ ctx: SDRHostCallContext) -> UInt64 {
        guard !bytes.isEmpty else { return 0 }
        if let sink = stdoutSink, fd == 1 {
            sink(ctx, bytes)
            return UInt64(bytes.count)
        }
        guard let scratch = heap.allocate(UInt64(bytes.count), ctx) else { return 0 }
        defer { _ = heap.release(scratch, ctx) }
        guard ctx.write(scratch, bytes) else { return 0 }
        let written = ctx.syscall(SDRSyscallNumber.write, UInt64(bitPattern: Int64(fd)),
                                  scratch, UInt64(bytes.count))
        return (written & SDRLibc.failureMask) != 0 ? 0 : written
    }

    /// sprintf / snprintf：返回"若缓冲足够本应写入的字符数"（C 语义）。
    private func render(_ ctx: SDRHostCallContext, format: UInt64, firstArgument: Int,
                        buffer: UInt64, limit: UInt64?) -> UInt64 {
        let rendered = self.format(ctx, format: format, firstArgument: firstArgument)
        guard buffer != 0 else { return 0 }
        var payload = rendered
        if let limit {
            let capacity = Int(min(limit, UInt64(Int.max)))
            guard capacity > 0 else { return 0 }
            payload = Array(rendered.prefix(capacity - 1))
            payload.append(0)
            guard ctx.write(buffer, payload) else { return 0 }
            return UInt64(rendered.count)
        }
        payload.append(0)
        guard ctx.write(buffer, payload) else { return 0 }
        return UInt64(rendered.count)
    }

    /// 精简 printf 格式渲染：支持 %d/%i/%u/%x/%X/%p/%s/%c/%% 与 l/z/h 长度修饰（其余原样输出）。
    private func format(_ ctx: SDRHostCallContext, format: UInt64, firstArgument: Int) -> [UInt8] {
        guard let template = SDRLibc.loadCString(format, ctx) else { return [] }
        var out: [UInt8] = []
        var argument = firstArgument
        var index = 0
        while index < template.count {
            let byte = template[index]
            if byte != 0x25 {
                out.append(byte)
                index += 1
                continue
            }
            index += 1
            if index >= template.count { break }
            var specifier = template[index]
            while specifier == 0x6C || specifier == 0x7A || specifier == 0x68
                || specifier == 0x6A || specifier == 0x74 {
                index += 1
                if index >= template.count { break }
                specifier = template[index]
            }
            if index >= template.count { break }
            let value = ctx.arg(argument)
            switch specifier {
            case 0x64, 0x69:
                argument += 1
                let signed = Int64(bitPattern: value)
                if signed < 0 {
                    out.append(0x2D)
                    out.append(contentsOf: SDRLibc.digits((~UInt64(bitPattern: signed)) &+ 1, base: 10, uppercase: false))
                } else {
                    out.append(contentsOf: SDRLibc.digits(UInt64(bitPattern: signed), base: 10, uppercase: false))
                }
            case 0x75:
                argument += 1
                out.append(contentsOf: SDRLibc.digits(value, base: 10, uppercase: false))
            case 0x78, 0x58:
                argument += 1
                out.append(contentsOf: SDRLibc.digits(value, base: 16, uppercase: specifier == 0x58))
            case 0x70:
                argument += 1
                out.append(contentsOf: Array("0x".utf8))
                out.append(contentsOf: SDRLibc.digits(value, base: 16, uppercase: false))
            case 0x73:
                argument += 1
                out.append(contentsOf: SDRLibc.loadCString(value, ctx) ?? [])
            case 0x63:
                argument += 1
                out.append(UInt8(truncatingIfNeeded: value))
            case 0x25:
                out.append(0x25)
            default:
                out.append(0x25)
                out.append(specifier)
            }
            index += 1
        }
        return out
    }

    /// 十进制/十六进制渲染。
    static func digits(_ value: UInt64, base: UInt64, uppercase: Bool, negative: Bool = false) -> [UInt8] {
        let table: [UInt8] = uppercase
            ? Array("0123456789ABCDEF".utf8)
            : Array("0123456789abcdef".utf8)
        var out: [UInt8] = negative ? [0x2D] : []
        if value == 0 {
            out.append(0x30)
            return out
        }
        var digitsBuffer: [UInt8] = []
        var remainder = value
        while remainder > 0 {
            digitsBuffer.append(table[Int(remainder % base)])
            remainder /= base
        }
        out.append(contentsOf: digitsBuffer.reversed())
        return out
    }

    /// C fopen 模式串 → openat 标志位。
    static func openFlags(forMode mode: String) -> Int32 {
        let flags = SDRSyscallNumber.OpenFlag
        switch mode.first {
        case "r":
            return mode.contains("+") ? flags.rdwr : flags.rdonly
        case "w":
            var value = mode.contains("+") ? flags.rdwr : flags.wronly
            value |= flags.creat | flags.trunc
            return value
        case "a":
            var value = mode.contains("+") ? flags.rdwr : flags.wronly
            value |= flags.creat | flags.append
            return value
        default:
            return flags.rdonly
        }
    }

    /// -errno 判定掩码（高位为 1 即失败）
    public static let failureMask: UInt64 = 1 << 63
    /// AT_FDCWD 的 UInt64 表示（代理层按 int32 解读）
    public static let atFdcwd = UInt64(bitPattern: Int64(SDRSyscallNumber.atFdcwd))
}
