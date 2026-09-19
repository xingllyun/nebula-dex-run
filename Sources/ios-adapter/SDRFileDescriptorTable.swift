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

/// Guest 文件描述符表。
///
/// 对 guest 暴露 Linux 风格 fd（0/1/2 为标准流，普通文件从 3 开始），
/// 宿主侧落到 iOS 沙盒内的真实文件句柄。所有路径在进入本表前必须完成沙盒校验，
/// 本表自身只做 fd 生命周期与读写游标管理。
///
/// 游标（offset）由本表自行维护，而非依赖 FileHandle 的内部位置：
/// 这样 `lseek` / `pread` / `O_APPEND` 的语义才能与 Linux 一致。
public final class SDRFileDescriptorTable {

    public struct Entry {
        public var path: String
        public var handle: FileHandle
        public var offset: UInt64
        public var size: UInt64
        public var flags: Int32
        public var isStandardStream: Bool
        public var readable: Bool
        public var writable: Bool
        public var appendMode: Bool
    }

    /// 标准流写入回调（供日志面板订阅）
    public var onStandardStreamWrite: ((Int32, [UInt8]) -> Void)?

    private var entries: [Int32: Entry] = [:]
    private var nextDescriptor: Int32 = 3
    private let lock = NSLock()

    /// 已打开 fd 总数（不含标准流）
    public var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { !$0.isStandardStream }.count
    }

    public init() {
        entries[0] = Entry(path: "/dev/stdin", handle: FileHandle.standardInput, offset: 0, size: 0,
                           flags: SDRSyscallNumber.OpenFlag.rdonly, isStandardStream: true,
                           readable: true, writable: false, appendMode: false)
        entries[1] = Entry(path: "/dev/stdout", handle: FileHandle.standardOutput, offset: 0, size: 0,
                           flags: SDRSyscallNumber.OpenFlag.wronly, isStandardStream: true,
                           readable: false, writable: true, appendMode: false)
        entries[2] = Entry(path: "/dev/stderr", handle: FileHandle.standardError, offset: 0, size: 0,
                           flags: SDRSyscallNumber.OpenFlag.wronly, isStandardStream: true,
                           readable: false, writable: true, appendMode: false)
    }

    // MARK: - 生命周期

    /// 登记一个已打开的真实文件，返回分配的 fd；fd 耗尽返回 nil
    public func install(handle: FileHandle, path: String, flags: Int32, offset: UInt64, size: UInt64) -> Int32? {
        lock.lock()
        defer { lock.unlock() }

        var candidate = nextDescriptor
        var attempts = 0
        while entries[candidate] != nil && attempts < 4096 {
            candidate += 1
            attempts += 1
        }
        guard entries[candidate] == nil, candidate > 0 else { return nil }

        let access = flags & 0x3
        entries[candidate] = Entry(path: path,
                                   handle: handle,
                                   offset: offset,
                                   size: size,
                                   flags: flags,
                                   isStandardStream: false,
                                   readable: access != SDRSyscallNumber.OpenFlag.wronly,
                                   writable: access != SDRSyscallNumber.OpenFlag.rdonly,
                                   appendMode: flags & SDRSyscallNumber.OpenFlag.append != 0)
        nextDescriptor = candidate + 1
        return candidate
    }

    public func entry(_ fd: Int32) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[fd]
    }

    public func contains(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[fd] != nil
    }

    public func updateOffset(_ fd: Int32, to offset: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        entries[fd]?.offset = offset
    }

    public func advanceOffset(_ fd: Int32, by delta: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        entries[fd]?.offset = (entries[fd]?.offset ?? 0) + delta
    }

    /// 更新已登记文件的大小（写入 / 截断后调用，保证 lseek(SEEK_END) 与 fstat 正确）
    public func updateSize(_ fd: Int32, to size: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        entries[fd]?.size = size
    }

    /// 关闭 fd；标准流不可关闭（返回 false）
    @discardableResult
    public func close(_ fd: Int32) -> Bool {
        lock.lock()
        var target: Entry?
        if let e = entries[fd], !e.isStandardStream {
            target = e
            entries.removeValue(forKey: fd)
        }
        lock.unlock()

        guard let e = target else { return false }
        try? e.handle.close()
        return true
    }

    /// 复制 fd（dup 语义），共享同一底层句柄与游标位置
    public func duplicate(_ fd: Int32) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = entries[fd] else { return nil }
        var candidate = nextDescriptor
        var attempts = 0
        while entries[candidate] != nil && attempts < 4096 {
            candidate += 1
            attempts += 1
        }
        guard entries[candidate] == nil, candidate > 0 else { return nil }
        entries[candidate] = e
        nextDescriptor = candidate + 1
        return candidate
    }

    /// 停止运行时统一回收
    public func closeAll() {
        lock.lock()
        let targets = entries.values.filter { !$0.isStandardStream }
        entries = entries.filter { $0.value.isStandardStream }
        nextDescriptor = 3
        lock.unlock()
        for e in targets { try? e.handle.close() }
    }

    public var openPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { !$0.isStandardStream }.map { $0.path }
    }
}
