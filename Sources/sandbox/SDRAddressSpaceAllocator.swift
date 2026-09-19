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

/// Guest 虚拟地址空间分配器。
///
/// 软件内存模型里 guest 地址由我们自己编排，不占用 iOS 进程真实地址，
/// 因此需要一个最小的分配器为 `mmap` / `brk` 提供不重叠且对齐的区间。
///
/// 策略：空闲链表按地址升序维护，采用首次适配（first-fit）；
/// 释放时与相邻空闲区间合并，避免长期运行后碎片化导致大块映射失败。
/// 分配与释放均持锁，允许被 guest 的多线程并发调用。
public final class SDRAddressSpaceAllocator {

    public struct Region: Equatable {
        public let base: UInt64
        public let size: UInt64
        public var end: UInt64 { base + size }
    }

    private var freeRegions: [Region] = []
    private var busyRegions: [Region] = []
    private let lock = NSLock()

    /// 地址空间上限（仅约束本分配器，段容量预算由 SDRMemoryGuard 另行把关）
    public let limit: UInt64
    /// 分配起点
    public let minimum: UInt64
    public private(set) var reservedBytes: UInt64 = 0

    /// - Parameters:
    ///   - minimum: 首个可用地址，默认 8 GB 处，避开 SO 镜像装载区（1 GB 起）
    ///   - limit: 地址空间上界，默认 64 GB
    public init(minimum: UInt64 = 0x2_0000_0000, limit: UInt64 = 0x10_0000_0000) {
        self.minimum = (minimum + SDRSyscallNumber.pageSize - 1) / SDRSyscallNumber.pageSize * SDRSyscallNumber.pageSize
        self.limit = limit
        self.freeRegions = [Region(base: self.minimum, size: limit > self.minimum ? limit - self.minimum : 0)]
    }

    /// 在任意位置分配一段对齐区间；失败返回 nil
    public func allocate(size: UInt64, alignment: UInt64 = SDRSyscallNumber.pageSize) -> UInt64? {
        guard size > 0 else { return nil }
        let align = Swift.max(alignment, SDRSyscallNumber.pageSize)
        let rounded = (size + SDRSyscallNumber.pageSize - 1) / SDRSyscallNumber.pageSize * SDRSyscallNumber.pageSize

        lock.lock()
        defer { lock.unlock() }

        for (index, region) in freeRegions.enumerated() {
            let aligned = (region.base + align - 1) / align * align
            let padding = aligned - region.base
            guard padding + rounded <= region.size else { continue }
            guard aligned + rounded <= limit else { continue }

            freeRegions.remove(at: index)
            insertFree(Region(base: region.base, size: padding))
            insertFree(Region(base: aligned + rounded, size: region.size - padding - rounded))
            insertBusy(Region(base: aligned, size: rounded))
            reservedBytes += rounded
            return aligned
        }
        return nil
    }

    /// 在指定地址分配（MAP_FIXED 语义）；地址被占用或越界返回 nil
    public func reserve(base: UInt64, size: UInt64, alignment: UInt64 = SDRSyscallNumber.pageSize) -> UInt64? {
        guard size > 0, base >= minimum, base + size <= limit else { return nil }
        guard base % alignment == 0 else { return nil }
        let rounded = (size + SDRSyscallNumber.pageSize - 1) / SDRSyscallNumber.pageSize * SDRSyscallNumber.pageSize

        lock.lock()
        defer { lock.unlock() }

        guard let index = freeRegions.firstIndex(where: { $0.base <= base && base + rounded <= $0.end }) else {
            return nil
        }
        let region = freeRegions[index]
        freeRegions.remove(at: index)
        insertFree(Region(base: region.base, size: base - region.base))
        insertFree(Region(base: base + rounded, size: region.end - (base + rounded)))
        insertBusy(Region(base: base, size: rounded))
        reservedBytes += rounded
        return base
    }

    /// 释放一段区间；返回是否命中已占用区间
    @discardableResult
    public func deallocate(base: UInt64, size: UInt64) -> Bool {
        guard size > 0 else { return false }
        let rounded = (size + SDRSyscallNumber.pageSize - 1) / SDRSyscallNumber.pageSize * SDRSyscallNumber.pageSize

        lock.lock()
        defer { lock.unlock() }

        var hit = false
        var remainingBusy: [Region] = []
        for region in busyRegions {
            if region.base >= base + rounded || region.end <= base {
                remainingBusy.append(region)
                continue
            }
            hit = true
            if region.base < base {
                remainingBusy.append(Region(base: region.base, size: base - region.base))
            }
            if region.end > base + rounded {
                remainingBusy.append(Region(base: base + rounded, size: region.end - (base + rounded)))
            }
            reservedBytes = reservedBytes >= region.size ? reservedBytes - region.size : 0
        }
        busyRegions = remainingBusy
        if !hit { return false }
        insertFree(Region(base: base, size: rounded))
        return true
    }

    public func owns(_ address: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return busyRegions.contains { address >= $0.base && address < $0.end }
    }

    public var busySnapshot: [Region] {
        lock.lock()
        defer { lock.unlock() }
        return busyRegions
    }

    /// 崩溃恢复：清空全部占用记录，仅保留整块空闲空间
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        busyRegions.removeAll()
        reservedBytes = 0
        freeRegions = [Region(base: minimum, size: limit > minimum ? limit - minimum : 0)]
    }

    // MARK: - 内部

    private func insertFree(_ region: Region) {
        guard region.size > 0 else { return }
        freeRegions.append(region)
        freeRegions.sort { $0.base < $1.base }
        coalesceFree()
    }

    private func insertBusy(_ region: Region) {
        guard region.size > 0 else { return }
        busyRegions.append(region)
        busyRegions.sort { $0.base < $1.base }
    }

    private func coalesceFree() {
        guard freeRegions.count > 1 else { return }
        var merged: [Region] = [freeRegions[0]]
        for region in freeRegions.dropFirst() {
            if let last = merged.last, last.end >= region.base {
                merged[merged.count - 1] = Region(base: last.base, size: Swift.max(last.size, region.end - last.base))
            } else {
                merged.append(region)
            }
        }
        freeRegions = merged
    }
}
