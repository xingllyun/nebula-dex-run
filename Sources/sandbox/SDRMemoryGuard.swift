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

/// 软件内存模型：段表 + 访存校验（对应 SO 指令解释执行的内存抽象）
/// 接入内存预算后，单次装载的总段容量受 SDRMemoryBudget 约束，
/// 超限时拒绝映射并记录日志，而不是让进程被系统终止。
///
/// ## 并发契约（阶段二步骤一定稿）
///
/// 本类是 guest 内存的唯一权威，会被解释器主循环（数据面）与系统调用代理（结构面）
/// 同时触及，因此显式约定如下，后续所有改动不得破坏：
///
/// 1. **结构面串行**：`map` / `unmap` / `protect` / `mapAnonymous` / `releaseAll`
///    持内部锁串行执行，任意线程可安全调用；同一时刻至多一个结构变更在途。
/// 2. **数据面无锁**：`read` / `write` / `readScalar` / `writeScalar` / `segment(for:)`
///    不加锁。实现方式是"结构快照 + 引用保活"——每次访问先取一次段表快照
///    （快照是 class 引用，读取即原子，ARC 保证其生命周期长于本次访问），
///    因此数据面永不会观察到半更新的段表，也不会因并发 `unmap` 而悬垂。
/// 3. **弱一致窗口**：`unmap` 与并发中的数据面访问之间允许存在一个窗口——
///    旧快照持有者可能在段被解除映射后仍完成一次读写。宿主不阻塞等待，
///    因为 guest 侧本来就要靠 futex 等同步原语保证访问顺序；
///    宿主承诺的是"不崩溃、不越界、不读到其他段的字节"。
/// 4. **段内字节并发写不互斥**：同一段的并发写不做字节级加锁，
///    由 guest 侧自行同步（宿主不代偿），避免为单线程热路径付出锁开销。
/// 5. **段查找为有序二分**：快照内的段按 `base` 升序排列，查找 O(log n)，
///    不再随段数线性增长。
public final class SDRMemoryGuard {

    public struct Segment {
        public var name: String
        public var base: UInt64
        public var size: UInt64
        public var readable: Bool
        public var writable: Bool
        public var executable: Bool

        public var end: UInt64 { base + size }
    }

    /// 段的后备内存：手工管理的裸缓冲区。
    ///
    /// 刻意不用 `[UInt8]`：数组是值类型，快照与写入路径共享时会触发写时复制，
    /// 单次写入退化为 O(段大小) 的整段拷贝（阶段一性能优化已踩过该坑）。
    /// 裸缓冲区配合 ARC 保活（快照持有引用即可）同时满足"数据面无锁"与"无拷贝"。
    final class Backing {
        let capacity: Int
        let raw: UnsafeMutableRawPointer

        init(size: UInt64) {
            let n = Swift.max(1, Int(size))
            capacity = n
            raw = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16)
            memset(raw, 0, n)
        }

        deinit {
            raw.deallocate()
        }

        func readBytes(offset: Int, count: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: count)
            out.withUnsafeMutableBytes { dst in
                if let base = dst.baseAddress, count > 0 {
                    memcpy(base, raw + offset, count)
                }
            }
            return out
        }

        func writeBytes(offset: Int, _ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            bytes.withUnsafeBytes { src in
                if let base = src.baseAddress {
                    memcpy(raw + offset, base, bytes.count)
                }
            }
        }

        func readScalar(offset: Int, count: Int) -> UInt64 {
            var v: UInt64 = 0
            memcpy(&v, raw + offset, count)
            return v
        }

        func writeScalar(offset: Int, value: UInt64, count: Int) {
            var v = value
            memcpy(raw + offset, &v, count)
        }
    }

    /// 段表的不可变快照，供数据面无锁读取
    final class Snapshot {
        let regions: [Region]
        let mappedBytes: UInt64

        init(regions: [Region], mappedBytes: UInt64) {
            self.regions = regions
            self.mappedBytes = mappedBytes
        }
    }

    final class Region {
        var name: String
        var base: UInt64
        var size: UInt64
        var readable: Bool
        var writable: Bool
        var executable: Bool
        var backing: Backing
        var backingOffset: Int

        init(name: String, base: UInt64, size: UInt64,
             readable: Bool, writable: Bool, executable: Bool,
             backing: Backing, backingOffset: Int) {
            self.name = name
            self.base = base
            self.size = size
            self.readable = readable
            self.writable = writable
            self.executable = executable
            self.backing = backing
            self.backingOffset = backingOffset
        }

        var end: UInt64 { base + size }

        func snapshotValue() -> Segment {
            Segment(name: name, base: base, size: size,
                    readable: readable, writable: writable, executable: executable)
        }
    }

    private let lock = NSLock()
    /// 当前段表快照；数据面只读该引用，结构面在锁内整体替换
    private var snapshot = Snapshot(regions: [], mappedBytes: 0)

    /// 显式指定的预算；为空时按设备能力自动取值
    public var budget: SDRMemoryBudget.Plan?
    /// 内存压力进入 critical 时的回调，由上层决定释放哪些缓存
    public var onMemoryPressureCritical: (() -> Void)?

    /// guest 虚拟地址编排（供 mmap 使用）
    public let addressSpace = SDRAddressSpaceAllocator()

    public init() {
        SDREventBus.shared.on("memory.pressure") { [weak self] payload in
            guard let level = payload as? String,
                  level == SDRMemoryPressureMonitor.Level.critical.rawValue else {
                return
            }
            self?.handleCriticalPressure()
        }
    }

    /// 已映射段总容量（字节）
    public var mappedBytes: UInt64 {
        return snapshot.mappedBytes
    }

    private var effectiveBudget: SDRMemoryBudget.Plan {
        return budget ?? SDRMemoryBudget.current()
    }

    // MARK: - 结构面

    @discardableResult
    public func map(name: String, base: UInt64, size: UInt64,
                    readable: Bool, writable: Bool, executable: Bool) -> Bool {
        guard size > 0 else {
            SDRLogger.e("memory", "段映射尺寸非法：\(name) size=\(size)")
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        let limit = effectiveBudget.soSegmentLimitBytes
        if snapshot.mappedBytes + size > limit {
            SDRLogger.e("memory", "段映射超预算：\(name) 需要 \(size / 1048576) MB，已用 \(snapshot.mappedBytes / 1048576) MB，上限 \(limit / 1048576) MB")
            SDREventBus.shared.emit("memory.budget.exceeded", payload: name)
            return false
        }

        let overlapping = snapshot.regions.contains { base < $0.end && $0.base < base + size }
        guard !overlapping else {
            SDRLogger.e("memory", "段地址重叠：\(name) @0x\(String(base, radix: 16))")
            return false
        }

        let backing = Backing(size: size)
        let region = Region(name: name, base: base, size: size,
                            readable: readable, writable: writable, executable: executable,
                            backing: backing, backingOffset: 0)
        rebuild(inserting: region)
        return true
    }

    /// 匿名映射：自动挑选 guest 地址（`mmap` 的 MAP_ANONYMOUS 分支）
    public func mapAnonymous(name: String, size: UInt64, alignment: UInt64,
                             readable: Bool, writable: Bool, executable: Bool) -> UInt64? {
        let rounded = (size + SDRSyscallNumber.pageSize - 1) / SDRSyscallNumber.pageSize * SDRSyscallNumber.pageSize
        guard let base = addressSpace.allocate(size: rounded, alignment: alignment) else {
            SDRLogger.w("memory", "地址空间不足，匿名映射失败：\(name) 需要 \(rounded / 1024) KB")
            return nil
        }
        guard map(name: name, base: base, size: rounded,
                  readable: readable, writable: writable, executable: executable) else {
            addressSpace.deallocate(base: base, size: rounded)
            return nil
        }
        return base
    }

    /// 在指定地址映射（MAP_FIXED 语义）
    public func mapFixed(name: String, base: UInt64, size: UInt64, alignment: UInt64,
                         readable: Bool, writable: Bool, executable: Bool) -> UInt64? {
        let rounded = (size + SDRSyscallNumber.pageSize - 1) / SDRSyscallNumber.pageSize * SDRSyscallNumber.pageSize
        guard addressSpace.reserve(base: base, size: rounded, alignment: alignment) != nil else {
            return nil
        }
        guard map(name: name, base: base, size: rounded,
                  readable: readable, writable: writable, executable: executable) else {
            addressSpace.deallocate(base: base, size: rounded)
            return nil
        }
        return base
    }

    /// 解除映射；区间可与多个段相交，相交部分被裁剪，完全覆盖的段被移除
    @discardableResult
    public func unmap(address: UInt64, size: UInt64) -> Bool {
        guard size > 0 else { return false }
        let rounded = (size + SDRSyscallNumber.pageSize - 1) / SDRSyscallNumber.pageSize * SDRSyscallNumber.pageSize
        let lower = address
        let upper = address &+ rounded

        lock.lock()
        guard var current = snapshot as Snapshot? else {
            lock.unlock()
            return false
        }
        var hit = false
        var kept: [Region] = []
        for region in current.regions {
            if region.end <= lower || region.base >= upper {
                kept.append(region)
                continue
            }
            hit = true
            // 头部保留：[region.base, lower)
            if region.base < lower {
                kept.append(Region(name: region.name,
                                   base: region.base,
                                   size: lower - region.base,
                                   readable: region.readable,
                                   writable: region.writable,
                                   executable: region.executable,
                                   backing: region.backing,
                                   backingOffset: region.backingOffset))
            }
            // 尾部保留：[upper, region.end)
            if region.end > upper {
                let shift = upper - region.base
                kept.append(Region(name: region.name,
                                   base: upper,
                                   size: region.end - upper,
                                   readable: region.readable,
                                   writable: region.writable,
                                   executable: region.executable,
                                   backing: region.backing,
                                   backingOffset: region.backingOffset + Int(shift)))
            }
            SDRLogger.d("memory", "解除映射 \(region.name) 与 [0x\(String(lower, radix: 16)), 0x\(String(upper, radix: 16))) 相交")
        }
        current = Snapshot(regions: kept, mappedBytes: recomputeMapped(kept))
        snapshot = current
        lock.unlock()

        guard hit else { return false }
        addressSpace.deallocate(base: address, size: rounded)
        return true
    }

    /// 修改已映射段的权限位
    @discardableResult
    public func protect(address: UInt64, size: UInt64,
                        readable: Bool, writable: Bool, executable: Bool) -> Bool {
        guard size > 0 else { return false }
        let rounded = (size + SDRSyscallNumber.pageSize - 1) / SDRSyscallNumber.pageSize * SDRSyscallNumber.pageSize
        let lower = address
        let upper = address &+ rounded

        lock.lock()
        defer { lock.unlock() }

        var hit = false
        for region in snapshot.regions where !(region.end <= lower || region.base >= upper) {
            hit = true
            region.readable = readable
            region.writable = writable
            region.executable = executable
        }
        guard hit else { return false }
        // 权限位属于 Region 的引用对象，数据面读到的是同一对象，无需重建快照；
        // 但快照必须重新发布，避免编译器把旧快照的字段读取提升到循环外。
        snapshot = Snapshot(regions: snapshot.regions, mappedBytes: snapshot.mappedBytes)
        return true
    }

    public func segment(for address: UInt64) -> Segment? {
        return locate(snapshot, address)?.snapshotValue()
    }

    /// 段名精确查找（用于取指段定位）
    public func segments(named name: String) -> [Segment] {
        return snapshot.regions.filter { $0.name == name }.map { $0.snapshotValue() }
    }

    public var segmentCount: Int {
        return snapshot.regions.count
    }

    // MARK: - 数据面（无锁）

    public func read(_ address: UInt64, count: Int) throws -> [UInt8] {
        let snap = snapshot
        guard let region = locate(snap, address), region.readable else {
            throw SDRAppError(.sandboxDenied, "非法读：0x\(String(address, radix: 16))")
        }
        let start = Int(address - region.base)
        guard start + count <= Int(region.size) else {
            throw SDRAppError(.sandboxDenied, "越界读：\(start)+\(count) > \(region.size)")
        }
        return region.backing.readBytes(offset: region.backingOffset + start, count: count)
    }

    public func write(_ address: UInt64, bytes: [UInt8]) throws {
        let snap = snapshot
        guard let region = locate(snap, address), region.writable else {
            throw SDRAppError(.sandboxDenied, "非法写：0x\(String(address, radix: 16))")
        }
        let start = Int(address - region.base)
        guard start + bytes.count <= Int(region.size) else {
            throw SDRAppError(.sandboxDenied, "越界写：\(start)+\(bytes.count) > \(region.size)")
        }
        region.backing.writeBytes(offset: region.backingOffset + start, bytes)
    }

    /// 标量读（count ∈ 1/2/4/8，小端），供解释器访存热路径使用：
    /// 语义与 `read` 完全一致（同样的段权限与越界校验、同样的错误信息），
    /// 但不为单次访存分配临时字节数组。
    public func readScalar(_ address: UInt64, count: Int) throws -> UInt64 {
        let snap = snapshot
        guard let region = locate(snap, address), region.readable else {
            throw SDRAppError(.sandboxDenied, "非法读：0x\(String(address, radix: 16))")
        }
        let start = Int(address - region.base)
        guard start + count <= Int(region.size) else {
            throw SDRAppError(.sandboxDenied, "越界读：\(start)+\(count) > \(region.size)")
        }
        return region.backing.readScalar(offset: region.backingOffset + start, count: count)
    }

    /// 标量写（count ∈ 1/2/4/8，小端），语义与 `write` 一致，原地写入、无临时分配。
    public func writeScalar(_ address: UInt64, value: UInt64, count: Int) throws {
        let snap = snapshot
        guard let region = locate(snap, address), region.writable else {
            throw SDRAppError(.sandboxDenied, "非法写：0x\(String(address, radix: 16))")
        }
        let start = Int(address - region.base)
        guard start + count <= Int(region.size) else {
            throw SDRAppError(.sandboxDenied, "越界写：\(start)+\(count) > \(region.size)")
        }
        region.backing.writeScalar(offset: region.backingOffset + start, value: value, count: count)
    }

    /// 取段字节（不申请可执行内存）；名称不存在时返回空数组
    public func codeBytes(segment name: String) -> [UInt8] {
        guard let region = snapshot.regions.first(where: { $0.name == name }) else {
            return []
        }
        return region.backing.readBytes(offset: region.backingOffset, count: Int(region.size))
    }

    /// 释放全部软件段（停止运行时调用）
    public func releaseAll() {
        lock.lock()
        snapshot = Snapshot(regions: [], mappedBytes: 0)
        lock.unlock()
        addressSpace.reset()
    }

    // MARK: - 内部

    /// 有序二分：快照内段按 base 升序，查找不再随段数线性增长
    private func locate(_ snap: Snapshot, _ address: UInt64) -> Region? {
        var low = 0
        var high = snap.regions.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let region = snap.regions[mid]
            if address < region.base {
                high = mid - 1
            } else if address >= region.end {
                low = mid + 1
            } else {
                return region
            }
        }
        return nil
    }

    private func rebuild(inserting region: Region) {
        var regions = snapshot.regions
        regions.append(region)
        regions.sort { $0.base < $1.base }
        snapshot = Snapshot(regions: regions, mappedBytes: recomputeMapped(regions))
    }

    private func recomputeMapped(_ regions: [Region]) -> UInt64 {
        var total: UInt64 = 0
        for r in regions { total += r.size }
        return total
    }

    private func handleCriticalPressure() {
        SDRLogger.w("memory", "内存压力 critical：已映射 \(mappedBytes / 1048576) MB，通知上层收缩缓存")
        onMemoryPressureCritical?()
    }
}
