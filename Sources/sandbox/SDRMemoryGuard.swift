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
public final class SDRMemoryGuard {
    public struct Segment {
        public var name: String
        public var base: UInt64
        public var size: UInt64
        public var readable: Bool
        public var writable: Bool
        public var executable: Bool
    }

    private var segments: [Segment] = []
    private var storage: [UInt64: [UInt8]] = [:]
    private let lock = NSLock()

    /// 显式指定的预算；为空时按设备能力自动取值
    public var budget: SDRMemoryBudget.Plan?
    /// 已映射段总容量（字节）
    public private(set) var mappedBytes: UInt64 = 0
    /// 内存压力进入 critical 时的回调，由上层决定释放哪些缓存
    public var onMemoryPressureCritical: (() -> Void)?

    public init() {
        SDREventBus.shared.on("memory.pressure") { [weak self] payload in
            guard let level = payload as? String,
                  level == SDRMemoryPressureMonitor.Level.critical.rawValue else {
                return
            }
            self?.handleCriticalPressure()
        }
    }

    private var effectiveBudget: SDRMemoryBudget.Plan {
        return budget ?? SDRMemoryBudget.current()
    }

    @discardableResult
    public func map(name: String, base: UInt64, size: UInt64,
                    readable: Bool, writable: Bool, executable: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let limit = effectiveBudget.soSegmentLimitBytes
        if mappedBytes + size > limit {
            SDRLogger.e("memory", "段映射超预算：\(name) 需要 \(size / 1048576) MB，已用 \(mappedBytes / 1048576) MB，上限 \(limit / 1048576) MB")
            SDREventBus.shared.emit("memory.budget.exceeded", payload: name)
            return false
        }

        segments.append(Segment(name: name, base: base, size: size,
                                readable: readable, writable: writable, executable: executable))
        storage[base] = [UInt8](repeating: 0, count: Int(size))
        mappedBytes += size
        return true
    }

    public func segment(for address: UInt64) -> Segment? {
        return segments.first { address >= $0.base && address < $0.base + $0.size }
    }

    public func read(_ address: UInt64, count: Int) throws -> [UInt8] {
        guard let seg = segment(for: address), seg.readable else {
            throw SDRAppError(.sandboxDenied, "非法读：0x\(String(address, radix: 16))")
        }
        guard let buf = storage[seg.base] else {
            throw SDRAppError(.soImageInvalid, "段无后备存储：\(seg.name)")
        }
        let start = Int(address - seg.base)
        guard start + count <= buf.count else {
            throw SDRAppError(.sandboxDenied, "越界读：\(start)+\(count) > \(buf.count)")
        }
        return Array(buf[start..<(start + count)])
    }

    public func write(_ address: UInt64, bytes: [UInt8]) throws {
        guard let seg = segment(for: address), seg.writable else {
            throw SDRAppError(.sandboxDenied, "非法写：0x\(String(address, radix: 16))")
        }
        guard storage[seg.base] != nil else {
            throw SDRAppError(.soImageInvalid, "段无后备存储：\(seg.name)")
        }
        let start = Int(address - seg.base)
        // 原地写入：借字典下标的 mutating 访问器直通底层缓冲区，
        // 避免原先 `guard var buf = storage[...]` 触发的整段写时复制
        // （单次写由 O(段大小) 降为 O(写入字节数)，解释器访存热路径收益显著）。
        var wrote = false
        var limit = 0
        storage[seg.base]?.withUnsafeMutableBufferPointer { buf in
            limit = buf.count
            guard start + bytes.count <= buf.count else { return }
            bytes.withUnsafeBufferPointer { src in
                if let srcBase = src.baseAddress, let dstBase = buf.baseAddress, src.count > 0 {
                    memcpy(dstBase + start, srcBase, src.count)
                }
            }
            wrote = true
        }
        guard wrote else {
            throw SDRAppError(.sandboxDenied, "越界写：\(start)+\(bytes.count) > \(limit)")
        }
    }

    /// 标量读（count ∈ 1/2/4/8，小端），供解释器访存热路径使用：
    /// 语义与 `read` 完全一致（同样的段权限与越界校验、同样的错误信息），
    /// 但不为单次访存分配临时字节数组。
    public func readScalar(_ address: UInt64, count: Int) throws -> UInt64 {
        guard let seg = segment(for: address), seg.readable else {
            throw SDRAppError(.sandboxDenied, "非法读：0x\(String(address, radix: 16))")
        }
        guard let buf = storage[seg.base] else {
            throw SDRAppError(.soImageInvalid, "段无后备存储：\(seg.name)")
        }
        let start = Int(address - seg.base)
        guard start + count <= buf.count else {
            throw SDRAppError(.sandboxDenied, "越界读：\(start)+\(count) > \(buf.count)")
        }
        var value: UInt64 = 0
        buf.withUnsafeBufferPointer { raw in
            for i in 0..<count {
                value |= UInt64(raw[start + i]) << (8 * UInt64(i))
            }
        }
        return value
    }

    /// 标量写（count ∈ 1/2/4/8，小端），语义与 `write` 一致，原地写入、无临时分配。
    public func writeScalar(_ address: UInt64, value: UInt64, count: Int) throws {
        guard let seg = segment(for: address), seg.writable else {
            throw SDRAppError(.sandboxDenied, "非法写：0x\(String(address, radix: 16))")
        }
        guard storage[seg.base] != nil else {
            throw SDRAppError(.soImageInvalid, "段无后备存储：\(seg.name)")
        }
        let start = Int(address - seg.base)
        var wrote = false
        var limit = 0
        var raw = value
        storage[seg.base]?.withUnsafeMutableBufferPointer { buf in
            limit = buf.count
            guard start + count <= buf.count else { return }
            withUnsafeBytes(of: &raw) { src in
                let n = Swift.min(count, src.count)
                if let dstBase = buf.baseAddress, n > 0 {
                    memcpy(dstBase + start, src.baseAddress!, n)
                }
            }
            wrote = true
        }
        guard wrote else {
            throw SDRAppError(.sandboxDenied, "越界写：\(start)+\(count) > \(limit)")
        }
    }

    /// 取代码段字节区间，供指令解释器取指（不申请可执行内存）
    public func codeBytes(segment name: String) -> [UInt8] {
        guard let seg = segments.first(where: { $0.name == name }) else {
            return []
        }
        return storage[seg.base] ?? []
    }

    /// 释放全部软件段（停止运行时调用）
    public func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        segments.removeAll()
        storage.removeAll()
        mappedBytes = 0
    }

    private func handleCriticalPressure() {
        SDRLogger.w("memory", "内存压力 critical：已映射 \(mappedBytes / 1048576) MB，通知上层收缩缓存")
        onMemoryPressureCritical?()
    }
}
