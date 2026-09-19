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

/// 系统服务代理：解释器发出的 `svc #0` 在此处被翻译为宿主（iOS）原生调用。
/// 对应文档 §4.4「syscall 代理层」。
///
/// 阶段二重写要点：
/// - 分派键改为 **AArch64 Linux 真实系统调用号**（`SDRSyscallNumber`），与 Android arm64-v8a SO 内
///   `svc #0` 前写入 x8 的号完全对齐；此前的 0x1001 自增占位号全部下线。
/// - 内存类调用（mmap/munmap/mprotect/brk）落到 `SDRMemoryGuard` 的 guest 地址空间，
///   SO 里的真实读写会命中软件内存模型，而不是再打日志。
/// - 文件类调用落到 `SDRFileDescriptorTable`，路径先过沙盒校验，杜绝访问容器外文件。
/// - **未实现的调用号一律返回 -ENOSYS**，不再静默返回 0，避免把缺失能力伪装成成功。
public final class SDRSystemServices {

    public struct Descriptor {
        public let number: UInt32
        public let name: String
        public let handler: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, SDRArmInterpreter) throws -> UInt64
    }

    // MARK: - 分派表

    private var table: [UInt32: Descriptor] = [:]
    public private(set) var callCount: [String: Int] = [:]
    /// 未实现的系统调用号 → 命中次数
    public private(set) var unsupportedCalls: [UInt32: Int] = [:]
    /// 未实现调用的日志上限，避免同一号刷屏
    public var unsupportedLogLimit = 32
    private var unsupportedLogged = 0

    // MARK: - 运行时状态

    /// guest 文件描述符表
    public let fileDescriptors = SDRFileDescriptorTable()
    /// guest 进程/线程标识（宿主侧不暴露真实 pid）
    public var processIdentifier: Int32 = 4242
    public var threadIdentifier: Int32 = 4242
    /// Android 应用 uid 区段
    public var userId: Int32 = 10123
    /// 当前可执行文件路径（供 /proc/self/exe 查询）
    public var executablePath: String?
    /// guest 当前工作目录（沙盒内，相对路径的解析基准）
    public var workingDirectory: String
    /// 进程终止请求：exit / exit_group 命中后置位，由解释器主循环收口
    public private(set) var exitRequested = false
    public private(set) var exitCode: Int32 = 0
    /// program break（brk 语义）
    public private(set) var programBreak: UInt64 = 0

    private weak var interpreterRef: SDRArmInterpreter?
    private var interpreterStub: SDRArmInterpreter {
        interpreterRef ?? SDRArmInterpreter(context: SDRCpuContext(), memory: SDRMemoryGuard(), services: self)
    }

    /// 解释器在 dispatch 期间由调用方注入，避免循环持有
    public func bind(interpreter: SDRArmInterpreter) { interpreterRef = interpreter }

    public init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory ?? SDRSandbox.shared.tempDirectory.path
        registerBuiltins()
    }

    // MARK: - 注册与分派

    public func register(number: UInt32, name: String,
                         handler: @escaping (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, SDRArmInterpreter) throws -> UInt64) {
        table[number] = Descriptor(number: number, name: name, handler: handler)
    }

    /// 已注册的调用号清单（调试与验收用）
    public var registeredNumbers: [UInt32] { table.keys.sorted() }

    public func dispatch(syscall number: UInt32, context: SDRCpuContext) throws -> UInt64 {
        guard let desc = table[number] else {
            unsupportedCalls[number, default: 0] += 1
            if unsupportedLogged < unsupportedLogLimit {
                unsupportedLogged += 1
                SDRLogger.w("syscall", "未实现的系统调用号 \(number)，返回 -ENOSYS")
            }
            return Self.failure(SDRSyscallNumber.Errno.enosys)
        }

        callCount[desc.name, default: 0] += 1
        let interpreter = interpreterRef ?? interpreterStub
        return try desc.handler(context.x[0], context.x[1], context.x[2],
                                context.x[3], context.x[4], context.x[5], interpreter)
    }

    // MARK: - 返回值与字节编解码小工具

    /// Linux 系统调用失败：返回 -errno（以二进制补码写入 x0）
    public static func failure(_ errno: Int32) -> UInt64 {
        UInt64(bitPattern: Int64(-errno))
    }

    @inline(__always)
    private static func signed32(_ raw: UInt64) -> Int32 {
        Int32(bitPattern: UInt32(truncatingIfNeeded: raw))
    }

    private static func putLE16(_ buf: inout [UInt8], _ offset: Int, _ value: UInt16) {
        buf[offset] = UInt8(truncatingIfNeeded: value)
        buf[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func putLE32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        var v = value
        for i in 0..<4 {
            buf[offset + i] = UInt8(truncatingIfNeeded: v)
            v >>= 8
        }
    }

    private static func putLE64(_ buf: inout [UInt8], _ offset: Int, _ value: UInt64) {
        var v = value
        for i in 0..<8 {
            buf[offset + i] = UInt8(truncatingIfNeeded: v)
            v >>= 8
        }
    }

    private static func readLE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(bytes[offset + i]) }
        return v
    }

    // MARK: - guest 内存访问

    private func readString(_ interp: SDRArmInterpreter, _ address: UInt64, limit: Int = 4096) -> String? {
        guard address != 0 else { return nil }
        var collected: [UInt8] = []
        var cursor = address
        while collected.count < limit {
            let chunk = Swift.min(128, limit - collected.count)
            guard let bytes = try? interp.memory.read(cursor, count: chunk) else {
                return collected.isEmpty ? nil : String(decoding: collected, as: UTF8.self)
            }
            if let zero = bytes.firstIndex(of: 0) {
                collected.append(contentsOf: bytes[..<zero])
                return String(decoding: collected, as: UTF8.self)
            }
            collected.append(contentsOf: bytes)
            cursor &+= UInt64(chunk)
        }
        return String(decoding: collected, as: UTF8.self)
    }

    @discardableResult
    private func writeStruct(_ interp: SDRArmInterpreter, _ address: UInt64, _ bytes: [UInt8]) -> Bool {
        guard address != 0 else { return false }
        do {
            try interp.memory.write(address, bytes: bytes)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 路径解析与沙盒校验

    /// guest 路径 → 宿主沙盒内 URL。
    /// guest 的绝对路径（/data/...、/system/...）被平移到应用沙盒根之下，
    /// 任何越出沙盒的解析结果都被拒绝（返回 nil）。
    private func resolvePath(_ path: String) -> URL? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let root = SDRSandbox.shared.root.standardizedFileURL
        let url: URL
        if path.hasPrefix("/") {
            let trimmed = String(path.drop(while: { $0 == "/" }))
            url = root.appendingPathComponent(trimmed).standardizedFileURL
        } else {
            let base = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
            url = base.appendingPathComponent(path).standardizedFileURL
        }
        let rootPath = root.path
        let candidate = url.standardizedFileURL.path
        guard candidate == rootPath || candidate.hasPrefix(rootPath + "/") else { return nil }
        return url
    }

    private func describe(_ url: URL) -> (exists: Bool, isDirectory: Bool, size: UInt64) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else { return (false, false, 0) }
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        return (true, isDirectory.boolValue, size)
    }

    /// aarch64 `struct stat`（128 字节，bionic 布局）的最小可用填充
    private func statBytes(size: UInt64, isDirectory: Bool) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 128)
        Self.putLE32(&buf, 0, 0x2F)                                  // st_dev
        Self.putLE32(&buf, 16, isDirectory ? 0o040755 : 0o100644)    // st_mode
        Self.putLE32(&buf, 20, 1)                                    // st_nlink
        Self.putLE32(&buf, 24, UInt32(bitPattern: userId))           // st_uid
        Self.putLE32(&buf, 28, UInt32(bitPattern: userId))           // st_gid
        Self.putLE64(&buf, 48, size)                                 // st_size
        Self.putLE32(&buf, 56, 4096)                                 // st_blksize
        Self.putLE64(&buf, 64, (size + 511) / 512)                   // st_blocks
        let now = Date().timeIntervalSince1970
        let seconds = UInt64(now)
        let nanos = UInt64((now - now.rounded(.down)) * 1_000_000_000)
        for base in [72, 88, 104] {                                  // atim / mtim / ctim
            Self.putLE64(&buf, base, seconds)
            Self.putLE64(&buf, base + 8, nanos)
        }
        return buf
    }

    private func currentTimespec() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 16)
        let now = Date().timeIntervalSince1970
        Self.putLE64(&buf, 0, UInt64(now))
        Self.putLE64(&buf, 8, UInt64((now - now.rounded(.down)) * 1_000_000_000))
        return buf
    }

    // MARK: - 内置调用注册

    private func registerBuiltins() {
        registerFileCalls()
        registerMemoryCalls()
        registerProcessCalls()
        registerTimeCalls()
        registerMiscCalls()
    }

    // MARK: 文件与目录

    private func registerFileCalls() {
        register(number: SDRSyscallNumber.read, name: "read") { [weak self] fdRaw, buf, count, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd), entry.readable else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            let want = Int(Swift.min(count, 4 << 20))
            guard want > 0 else { return 0 }
            if entry.isStandardStream { return 0 }   // guest stdin 暂接 EOF
            do {
                try entry.handle.seek(toOffset: entry.offset)
                let data = entry.handle.readData(ofLength: want)
                guard !data.isEmpty else { return 0 }
                try interp.memory.write(buf, bytes: [UInt8](data))
                self.fileDescriptors.advanceOffset(fd, by: UInt64(data.count))
                return UInt64(data.count)
            } catch {
                return Self.failure(SDRSyscallNumber.Errno.eio)
            }
        }

        register(number: SDRSyscallNumber.write, name: "write") { [weak self] fdRaw, buf, count, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd), entry.writable else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            let want = Int(Swift.min(count, 4 << 20))
            guard want > 0 else { return 0 }
            guard let bytes = try? interp.memory.read(buf, count: want) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            if entry.isStandardStream {
                self.fileDescriptors.onStandardStreamWrite?(fd, bytes)
                let text = String(decoding: bytes.prefix(256), as: UTF8.self)
                SDRLogger.d("syscall", "guest fd\(fd) 输出：\(text)")
                self.fileDescriptors.advanceOffset(fd, by: UInt64(bytes.count))
                return UInt64(bytes.count)
            }
            do {
                if entry.appendMode {
                    try entry.handle.seekToEnd()
                } else {
                    try entry.handle.seek(toOffset: entry.offset)
                }
                try entry.handle.write(contentsOf: Data(bytes))
                let written = UInt64(bytes.count)
                let position = try entry.handle.offsetInFile
                self.fileDescriptors.updateOffset(fd, to: position)
                self.fileDescriptors.updateSize(fd, to: Swift.max(entry.size, position))
                return written
            } catch {
                return Self.failure(SDRSyscallNumber.Errno.eio)
            }
        }

        register(number: SDRSyscallNumber.writev, name: "writev") { [weak self] fdRaw, iovPtr, iovCount, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd), entry.writable else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            let segments = Int(Swift.min(iovCount, 64))
            var total: UInt64 = 0
            for index in 0..<segments {
                let descriptor = iovPtr &+ UInt64(index * 16)
                guard let raw = try? interp.memory.read(descriptor, count: 16) else {
                    return Self.failure(SDRSyscallNumber.Errno.efault)
                }
                let base = Self.readLE64(raw, 0)
                let length = Self.readLE64(raw, 8)
                guard length > 0 else { continue }
                guard let bytes = try? interp.memory.read(base, count: Int(Swift.min(length, 4 << 20))) else {
                    return Self.failure(SDRSyscallNumber.Errno.efault)
                }
                if entry.isStandardStream {
                    self.fileDescriptors.onStandardStreamWrite?(fd, bytes)
                } else {
                    do {
                        if entry.appendMode { try entry.handle.seekToEnd() }
                        else { try entry.handle.seek(toOffset: entry.offset + total) }
                        try entry.handle.write(contentsOf: Data(bytes))
                    } catch {
                        return Self.failure(SDRSyscallNumber.Errno.eio)
                    }
                }
                total &+= UInt64(bytes.count)
            }
            if !entry.isStandardStream {
                self.fileDescriptors.advanceOffset(fd, by: total)
                self.fileDescriptors.updateSize(fd, to: Swift.max(entry.size, entry.offset + total))
            }
            return total
        }

        register(number: SDRSyscallNumber.readv, name: "readv") { [weak self] fdRaw, iovPtr, iovCount, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd), entry.readable else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            guard !entry.isStandardStream else { return 0 }
            let segments = Int(Swift.min(iovCount, 64))
            var total: UInt64 = 0
            for index in 0..<segments {
                let descriptor = iovPtr &+ UInt64(index * 16)
                guard let raw = try? interp.memory.read(descriptor, count: 16) else {
                    return Self.failure(SDRSyscallNumber.Errno.efault)
                }
                let base = Self.readLE64(raw, 0)
                let length = Int(Swift.min(Self.readLE64(raw, 8), 4 << 20))
                guard length > 0 else { continue }
                do {
                    try entry.handle.seek(toOffset: entry.offset + total)
                    let data = entry.handle.readData(ofLength: length)
                    guard !data.isEmpty else { break }
                    try interp.memory.write(base, bytes: [UInt8](data))
                    total &+= UInt64(data.count)
                    if data.count < length { break }
                } catch {
                    return Self.failure(SDRSyscallNumber.Errno.eio)
                }
            }
            self.fileDescriptors.advanceOffset(fd, by: total)
            return total
        }

        register(number: SDRSyscallNumber.pread64, name: "pread64") { [weak self] fdRaw, buf, count, offset, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd), entry.readable, !entry.isStandardStream else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            let want = Int(Swift.min(count, 4 << 20))
            guard want > 0 else { return 0 }
            do {
                try entry.handle.seek(toOffset: offset)
                let data = entry.handle.readData(ofLength: want)
                guard !data.isEmpty else { return 0 }
                try interp.memory.write(buf, bytes: [UInt8](data))
                return UInt64(data.count)
            } catch {
                return Self.failure(SDRSyscallNumber.Errno.eio)
            }
        }

        register(number: SDRSyscallNumber.pwrite64, name: "pwrite64") { [weak self] fdRaw, buf, count, offset, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd), entry.writable, !entry.isStandardStream else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            let want = Int(Swift.min(count, 4 << 20))
            guard want > 0 else { return 0 }
            guard let bytes = try? interp.memory.read(buf, count: want) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            do {
                try entry.handle.seek(toOffset: offset)
                try entry.handle.write(contentsOf: Data(bytes))
                self.fileDescriptors.updateSize(fd, to: Swift.max(entry.size, offset + UInt64(bytes.count)))
                return UInt64(bytes.count)
            } catch {
                return Self.failure(SDRSyscallNumber.Errno.eio)
            }
        }

        register(number: SDRSyscallNumber.openat, name: "openat") { [weak self] _, pathPtr, flagsRaw, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let flags = Self.signed32(flagsRaw)
            guard let path = self.readString(interp, pathPtr) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            guard let url = self.resolvePath(path) else {
                SDRLogger.w("syscall", "沙盒拒绝访问：\(path)")
                return Self.failure(SDRSyscallNumber.Errno.eacces)
            }

            let fm = FileManager.default
            var state = self.describe(url)
            if !state.exists {
                guard flags & SDRSyscallNumber.OpenFlag.creat != 0 else {
                    return Self.failure(SDRSyscallNumber.Errno.enoent)
                }
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: url.path, contents: nil) else {
                    return Self.failure(SDRSyscallNumber.Errno.eacces)
                }
                state = self.describe(url)
            } else if flags & SDRSyscallNumber.OpenFlag.creat != 0, flags & SDRSyscallNumber.OpenFlag.excl != 0 {
                return Self.failure(SDRSyscallNumber.Errno.eexist)
            }

            if flags & SDRSyscallNumber.OpenFlag.directory != 0, !state.isDirectory {
                return Self.failure(SDRSyscallNumber.Errno.enotdir)
            }

            let access = flags & 0x3
            do {
                let handle: FileHandle
                if access == SDRSyscallNumber.OpenFlag.rdonly {
                    handle = try FileHandle(forReadingFrom: url)
                } else if access == SDRSyscallNumber.OpenFlag.wronly {
                    handle = try FileHandle(forWritingTo: url)
                } else {
                    handle = try FileHandle(forUpdating: url)
                }
                if flags & SDRSyscallNumber.OpenFlag.trunc != 0, !state.isDirectory {
                    try handle.truncate(atOffset: 0)
                }
                let size = flags & SDRSyscallNumber.OpenFlag.trunc != 0 ? 0 : state.size
                guard let fd = self.fileDescriptors.install(handle: handle, path: url.path,
                                                            flags: flags, offset: 0, size: size) else {
                    try? handle.close()
                    return Self.failure(SDRSyscallNumber.Errno.emfile)
                }
                SDRLogger.d("syscall", "openat(\(path)) -> fd\(fd)")
                return UInt64(bitPattern: Int64(fd))
            } catch {
                return Self.failure(SDRSyscallNumber.Errno.eacces)
            }
        }

        register(number: SDRSyscallNumber.close, name: "close") { [weak self] fdRaw, _, _, _, _, _, _ in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard self.fileDescriptors.contains(fd) else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            return self.fileDescriptors.close(fd) ? 0 : Self.failure(SDRSyscallNumber.Errno.ebadf)
        }

        register(number: SDRSyscallNumber.lseek, name: "lseek") { [weak self] fdRaw, offsetRaw, whenceRaw, _, _, _, _ in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd) else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            let delta = Int64(bitPattern: offsetRaw)
            let whence = Self.signed32(whenceRaw)
            let base: Int64
            switch whence {
            case SDRSyscallNumber.SeekWhence.set.rawValue: base = 0
            case SDRSyscallNumber.SeekWhence.cur.rawValue: base = Int64(entry.offset)
            case SDRSyscallNumber.SeekWhence.end.rawValue: base = Int64(entry.size)
            default: return Self.failure(SDRSyscallNumber.Errno.einval)
            }
            let target = base + delta
            guard target >= 0 else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            self.fileDescriptors.updateOffset(fd, to: UInt64(target))
            return UInt64(target)
        }

        register(number: SDRSyscallNumber.fstat, name: "fstat") { [weak self] fdRaw, statPtr, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd) else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            var size = entry.size
            var isDirectory = false
            if !entry.isStandardStream {
                let state = self.describe(URL(fileURLWithPath: entry.path))
                if state.exists { size = state.size; isDirectory = state.isDirectory }
            } else {
                var flag: ObjCBool = false
                if FileManager.default.fileExists(atPath: entry.path, isDirectory: &flag) { isDirectory = flag.boolValue }
            }
            guard self.writeStruct(interp, statPtr, self.statBytes(size: size, isDirectory: isDirectory)) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            return 0
        }

        register(number: SDRSyscallNumber.newfstatat, name: "newfstatat") { [weak self] _, pathPtr, statPtr, flagsRaw, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard let path = self.readString(interp, pathPtr) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            guard let url = self.resolvePath(path) else {
                return Self.failure(SDRSyscallNumber.Errno.eacces)
            }
            let state = self.describe(url)
            guard state.exists else { return Self.failure(SDRSyscallNumber.Errno.enoent) }
            guard self.writeStruct(interp, statPtr, self.statBytes(size: state.size, isDirectory: state.isDirectory)) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            return 0
        }

        register(number: SDRSyscallNumber.faccessat, name: "faccessat") { [weak self] _, pathPtr, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard let path = self.readString(interp, pathPtr) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            guard let url = self.resolvePath(path) else {
                return Self.failure(SDRSyscallNumber.Errno.eacces)
            }
            return self.describe(url).exists ? 0 : Self.failure(SDRSyscallNumber.Errno.enoent)
        }

        register(number: SDRSyscallNumber.mkdirat, name: "mkdirat") { [weak self] _, pathPtr, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard let path = self.readString(interp, pathPtr) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            guard let url = self.resolvePath(path) else {
                return Self.failure(SDRSyscallNumber.Errno.eacces)
            }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return 0
            } catch {
                return Self.failure(self.describe(url).exists ? SDRSyscallNumber.Errno.eexist : SDRSyscallNumber.Errno.eacces)
            }
        }

        register(number: SDRSyscallNumber.unlinkat, name: "unlinkat") { [weak self] _, pathPtr, flagsRaw, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard let path = self.readString(interp, pathPtr) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            guard let url = self.resolvePath(path) else {
                return Self.failure(SDRSyscallNumber.Errno.eacces)
            }
            let flags = Self.signed32(flagsRaw)
            let state = self.describe(url)
            guard state.exists else { return Self.failure(SDRSyscallNumber.Errno.enoent) }
            // AT_REMOVEDIR(0x200)：目录删除只在沙盒内允许，且不递归
            let isDirectoryRemoval = flags & 0x200 != 0
            guard isDirectoryRemoval == state.isDirectory else {
                return Self.failure(SDRSyscallNumber.Errno.eisdir)
            }
            do {
                try FileManager.default.removeItem(at: url)
                SDRLogger.d("syscall", "unlinkat 已移除沙盒内条目：\(url.path)")
                return 0
            } catch {
                return Self.failure(SDRSyscallNumber.Errno.eacces)
            }
        }

        register(number: SDRSyscallNumber.readlinkat, name: "readlinkat") { [weak self] _, pathPtr, buf, bufsiz, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard let path = self.readString(interp, pathPtr) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            guard path.contains("/proc/self/exe"), let target = self.executablePath else {
                return Self.failure(SDRSyscallNumber.Errno.enoent)
            }
            let bytes = Array(target.utf8.prefix(Int(Swift.min(bufsiz, 4096))))
            guard self.writeStruct(interp, buf, bytes) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            return UInt64(bytes.count)
        }

        register(number: SDRSyscallNumber.getdents64, name: "getdents64") { _, _, _, _, _, _, _ in
            // 目录枚举依赖宿主目录流的 fd 抽象，阶段二暂以「空目录」语义收口，
            // 避免把未实现的枚举伪装成有内容；阶段三接入真实目录后替换。
            0
        }

        register(number: SDRSyscallNumber.ftruncate, name: "ftruncate") { [weak self] fdRaw, length, _, _, _, _, _ in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd), entry.writable, !entry.isStandardStream else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            do {
                try entry.handle.truncate(atOffset: length)
                self.fileDescriptors.updateSize(fd, to: length)
                return 0
            } catch {
                return Self.failure(SDRSyscallNumber.Errno.eio)
            }
        }

        register(number: SDRSyscallNumber.fsync, name: "fsync") { [weak self] fdRaw, _, _, _, _, _, _ in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            return self.fileDescriptors.contains(Self.signed32(fdRaw))
                ? 0 : Self.failure(SDRSyscallNumber.Errno.ebadf)
        }

        register(number: SDRSyscallNumber.fdatasync, name: "fdatasync") { [weak self] fdRaw, _, _, _, _, _, _ in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            return self.fileDescriptors.contains(Self.signed32(fdRaw))
                ? 0 : Self.failure(SDRSyscallNumber.Errno.ebadf)
        }

        register(number: SDRSyscallNumber.dup, name: "dup") { [weak self] fdRaw, _, _, _, _, _, _ in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard let fd = self.fileDescriptors.duplicate(Self.signed32(fdRaw)) else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            return UInt64(bitPattern: Int64(fd))
        }

        register(number: SDRSyscallNumber.fcntl, name: "fcntl") { [weak self] fdRaw, command, _, _, _, _, _ in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard let entry = self.fileDescriptors.entry(fd) else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            switch Self.signed32(command) {
            case 1: return 0                                   // F_GETFD
            case 2: return 0                                   // F_SETFD
            case 3: return UInt64(bitPattern: Int64(entry.flags))  // F_GETFL
            case 4: return 0                                   // F_SETFL
            default: return 0
            }
        }
    }

    // MARK: 内存

    private func registerMemoryCalls() {
        register(number: SDRSyscallNumber.mmap, name: "mmap") { [weak self] address, length, protRaw, flagsRaw, fdRaw, offset, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let prot = Self.signed32(protRaw)
            let flags = Self.signed32(flagsRaw)
            let readable = prot & SDRSyscallNumber.MMapProt.read != 0
            let writable = prot & SDRSyscallNumber.MMapProt.write != 0
            let executable = prot & SDRSyscallNumber.MMapProt.exec != 0
            let anonymous = flags & SDRSyscallNumber.MMapFlag.anonymous != 0
            let fixed = flags & SDRSyscallNumber.MMapFlag.fixed != 0
            let memory = interp.memory
            let label = anonymous ? "anon-\(String(UInt32(truncatingIfNeeded: offset), radix: 16))" : "file-\(Self.signed32(fdRaw))"
            let alignment = SDRSyscallNumber.pageSize

            let base: UInt64?
            if anonymous {
                if fixed, address != 0 {
                    base = memory.mapFixed(name: label, base: address, size: length, alignment: alignment,
                                           readable: readable, writable: writable, executable: executable)
                } else {
                    base = memory.mapAnonymous(name: label, size: length, alignment: alignment,
                                               readable: readable, writable: writable, executable: executable)
                }
            } else {
                let fd = Self.signed32(fdRaw)
                guard let entry = self.fileDescriptors.entry(fd) else {
                    return Self.failure(SDRSyscallNumber.Errno.ebadf)
                }
                guard let image = self.readMappedFile(entry: entry, length: length, offset: offset, interp: interp, memory: memory, fixed: fixed, address: address) else {
                    return Self.failure(SDRSyscallNumber.Errno.enomem)
                }
                base = image
            }
            guard let mapped = base else {
                return Self.failure(SDRSyscallNumber.Errno.enomem)
            }
            SDRLogger.d("syscall", "mmap(len=\(length), prot=\(prot), flags=0x\(String(UInt32(bitPattern: flags), radix: 16))) -> 0x\(String(mapped, radix: 16))")
            return mapped
        }

        register(number: SDRSyscallNumber.munmap, name: "munmap") { [weak self] address, length, _, _, _, _, interp in
            guard self != nil else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard length > 0 else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard interp.memory.unmap(address: address, size: length) else {
                return Self.failure(SDRSyscallNumber.Errno.einval)
            }
            return 0
        }

        register(number: SDRSyscallNumber.mprotect, name: "mprotect") { _, address, length, protRaw, _, _, interp in
            let prot = Self.signed32(protRaw)
            guard interp.memory.protect(address: address, size: length,
                                        readable: prot & SDRSyscallNumber.MMapProt.read != 0,
                                        writable: prot & SDRSyscallNumber.MMapProt.write != 0,
                                        executable: prot & SDRSyscallNumber.MMapProt.exec != 0) else {
                return Self.failure(SDRSyscallNumber.Errno.enomem)
            }
            return 0
        }

        register(number: SDRSyscallNumber.brk, name: "brk") { [weak self] request, _, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            if request == 0 { return self.programBreak }
            if self.programBreak == 0 {
                let base = (request + 0xFFFF) / 0x1_0000 * 0x1_0000
                self.programBreak = base
                SDRLogger.d("syscall", "brk 初始化为 0x\(String(base, radix: 16))")
                return base
            }
            let previous = self.programBreak
            guard request > previous else {
                self.programBreak = request
                return request
            }
            let growth = (request - previous + 0xFFFF) / 0x1_0000 * 0x1_0000
            guard interp.memory.map(name: "heap", base: previous, size: growth,
                                    readable: true, writable: true, executable: false) else {
                SDRLogger.w("syscall", "brk 扩容失败，保持 0x\(String(previous, radix: 16))")
                return previous
            }
            self.programBreak = previous + growth
            return self.programBreak
        }

        register(number: SDRSyscallNumber.madvise, name: "madvise") { _, _, _, _, _, _, _ in 0 }
        register(number: SDRSyscallNumber.msync, name: "msync") { [weak self] address, length, _, _, _, _, interp in
            guard self != nil else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            return interp.memory.segment(for: address) != nil || length == 0
                ? 0 : Self.failure(SDRSyscallNumber.Errno.enomem)
        }
        register(number: SDRSyscallNumber.mlock, name: "mlock") { _, _, _, _, _, _, _ in 0 }
        register(number: SDRSyscallNumber.munlock, name: "munlock") { _, _, _, _, _, _, _ in 0 }
    }

    /// 文件映射：先取地址，再把文件内容读入该段（只读镜像语义）
    private func readMappedFile(entry: SDRFileDescriptorTable.Entry, length: UInt64, offset: UInt64,
                                interp: SDRArmInterpreter, memory: SDRMemoryGuard,
                                fixed: Bool, address: UInt64) -> UInt64? {
        let base: UInt64?
        if fixed, address != 0 {
            base = memory.mapFixed(name: "file-\(entry.path)", base: address, size: length,
                                   alignment: SDRSyscallNumber.pageSize,
                                   readable: true, writable: false, executable: false)
        } else {
            base = memory.mapAnonymous(name: "file-\(entry.path)", size: length,
                                       alignment: SDRSyscallNumber.pageSize,
                                       readable: true, writable: false, executable: false)
        }
        guard let mapped = base else { return nil }
        do {
            try entry.handle.seek(toOffset: offset)
            let data = entry.handle.readData(ofLength: Int(Swift.min(length, 8 << 20)))
            if !data.isEmpty {
                try interp.memory.write(mapped, bytes: [UInt8](data))
            }
        } catch {
            _ = memory.unmap(address: mapped, size: length)
            return nil
        }
        return mapped
    }

    // MARK: 进程与线程

    private func registerProcessCalls() {
        register(number: SDRSyscallNumber.getpid, name: "getpid") { [weak self] _, _, _, _, _, _, _ in
            UInt64(bitPattern: Int64(self?.processIdentifier ?? 4242))
        }
        register(number: SDRSyscallNumber.getppid, name: "getppid") { _, _, _, _, _, _, _ in 1 }
        register(number: SDRSyscallNumber.gettid, name: "gettid") { [weak self] _, _, _, _, _, _, _ in
            UInt64(bitPattern: Int64(self?.threadIdentifier ?? 4242))
        }
        register(number: SDRSyscallNumber.getuid, name: "getuid") { [weak self] _, _, _, _, _, _, _ in
            UInt64(UInt32(bitPattern: self?.userId ?? 10123))
        }
        register(number: SDRSyscallNumber.geteuid, name: "geteuid") { [weak self] _, _, _, _, _, _, _ in
            UInt64(UInt32(bitPattern: self?.userId ?? 10123))
        }
        register(number: SDRSyscallNumber.getgid, name: "getgid") { [weak self] _, _, _, _, _, _, _ in
            UInt64(UInt32(bitPattern: self?.userId ?? 10123))
        }
        register(number: SDRSyscallNumber.getegid, name: "getegid") { [weak self] _, _, _, _, _, _, _ in
            UInt64(UInt32(bitPattern: self?.userId ?? 10123))
        }
        register(number: SDRSyscallNumber.set_tid_address, name: "set_tid_address") { [weak self] _, _, _, _, _, _, _ in
            UInt64(bitPattern: Int64(self?.threadIdentifier ?? 4242))
        }
        register(number: SDRSyscallNumber.set_robust_list, name: "set_robust_list") { _, _, _, _, _, _, _ in 0 }
        register(number: SDRSyscallNumber.sched_yield, name: "sched_yield") { _, _, _, _, _, _, _ in 0 }
        register(number: SDRSyscallNumber.prctl, name: "prctl") { _, _, _, _, _, _, _ in 0 }
        register(number: SDRSyscallNumber.prlimit64, name: "prlimit64") { [weak self] _, _, _, limitPtr, _, _, interp in
            guard self != nil else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard limitPtr != 0 else { return 0 }
            var buf = [UInt8](repeating: 0, count: 16)
            Self.putLE64(&buf, 0, 1 << 40)      // RLIM_INFINITY 的量级近似
            Self.putLE64(&buf, 8, 1 << 40)
            _ = self?.writeStruct(interp, limitPtr, buf)
            return 0
        }
        register(number: SDRSyscallNumber.rt_sigaction, name: "rt_sigaction") { _, _, _, _, _, _, _ in 0 }
        register(number: SDRSyscallNumber.rt_sigprocmask, name: "rt_sigprocmask") { _, _, _, _, _, _, _ in 0 }
        register(number: SDRSyscallNumber.rt_sigreturn, name: "rt_sigreturn") { _, _, _, _, _, _, _ in 0 }
        register(number: SDRSyscallNumber.tgkill, name: "tgkill") { _, _, _, _, _, _, _ in 0 }
        register(number: SDRSyscallNumber.wait4, name: "wait4") { _, _, _, _, _, _, _ in
            Self.failure(SDRSyscallNumber.Errno.echild)
        }
        register(number: SDRSyscallNumber.futex, name: "futex") { _, operation, _, _, _, _, _ in
            let op = UInt32(truncatingIfNeeded: operation) & 0x7F
            switch op {
            case 0, 9:      // FUTEX_WAIT / FUTEX_WAIT_BITSET：单线程模型下按「值已变化」返回
                return Self.failure(SDRSyscallNumber.Errno.eagain)
            default:        // WAKE / REQUEUE 等：无人可唤醒
                return 0
            }
        }
        register(number: SDRSyscallNumber.exit, name: "exit") { [weak self] code, _, _, _, _, _, _ in
            self?.requestExit(code: Self.signed32(code))
            return 0
        }
        register(number: SDRSyscallNumber.exit_group, name: "exit_group") { [weak self] code, _, _, _, _, _, _ in
            self?.requestExit(code: Self.signed32(code))
            return 0
        }
    }

    // MARK: 时间

    private func registerTimeCalls() {
        register(number: SDRSyscallNumber.clock_gettime, name: "clock_gettime") { [weak self] clockId, timespecPtr, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            switch Self.signed32(clockId) {
            case 0, 1, 4, 6, 7:     // REALTIME / MONOTONIC / MONOTONIC_RAW / BOOTTIME / TAI
                break
            default:
                return Self.failure(SDRSyscallNumber.Errno.einval)
            }
            guard self.writeStruct(interp, timespecPtr, self.currentTimespec()) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            return 0
        }

        register(number: SDRSyscallNumber.clock_getres, name: "clock_getres") { [weak self] _, timespecPtr, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard timespecPtr != 0 else { return 0 }
            var buf = [UInt8](repeating: 0, count: 16)
            Self.putLE64(&buf, 0, 0)
            Self.putLE64(&buf, 8, 1)
            guard self.writeStruct(interp, timespecPtr, buf) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            return 0
        }

        register(number: SDRSyscallNumber.gettimeofday, name: "gettimeofday") { [weak self] timevalPtr, timezonePtr, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let now = Date().timeIntervalSince1970
            var buf = [UInt8](repeating: 0, count: 16)
            Self.putLE64(&buf, 0, UInt64(now))
            Self.putLE64(&buf, 8, UInt64((now - now.rounded(.down)) * 1_000_000))
            guard self.writeStruct(interp, timevalPtr, buf) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            if timezonePtr != 0 {
                _ = self.writeStruct(interp, timezonePtr, [UInt8](repeating: 0, count: 16))
            }
            return 0
        }

        register(number: SDRSyscallNumber.nanosleep, name: "nanosleep") { [weak self] requestPtr, remainderPtr, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard let raw = try? interp.memory.read(requestPtr, count: 16) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            let seconds = Double(Self.readLE64(raw, 0)) + Double(Self.readLE64(raw, 8)) / 1_000_000_000
            // 上限 1 秒：避免 guest 长时间挂起宿主线程
            let clamped = Swift.min(Swift.max(seconds, 0), 1.0)
            if clamped > 0 { Thread.sleep(forTimeInterval: clamped) }
            if remainderPtr != 0 {
                _ = self.writeStruct(interp, remainderPtr, [UInt8](repeating: 0, count: 16))
            }
            return 0
        }

        register(number: SDRSyscallNumber.clock_nanosleep, name: "clock_nanosleep") { [weak self] _, _, requestPtr, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            guard let raw = try? interp.memory.read(requestPtr, count: 16) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            let seconds = Double(Self.readLE64(raw, 0)) + Double(Self.readLE64(raw, 8)) / 1_000_000_000
            let clamped = Swift.min(Swift.max(seconds, 0), 1.0)
            if clamped > 0 { Thread.sleep(forTimeInterval: clamped) }
            return 0
        }
    }

    // MARK: 设备与杂项

    private func registerMiscCalls() {
        register(number: SDRSyscallNumber.ioctl, name: "ioctl") { [weak self] fdRaw, request, _, _, _, _, _ in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let fd = Self.signed32(fdRaw)
            guard self.fileDescriptors.contains(fd) else {
                return Self.failure(SDRSyscallNumber.Errno.ebadf)
            }
            SDRLogger.d("syscall", "ioctl(fd=\(fd), request=0x\(String(UInt32(truncatingIfNeeded: request), radix: 16))) 无对应宿主能力")
            return Self.failure(SDRSyscallNumber.Errno.enotty)
        }

        register(number: SDRSyscallNumber.uname, name: "uname") { [weak self] utsnamePtr, _, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            var buf = [UInt8](repeating: 0, count: 65 * 6)
            let fields = ["Linux", "Android", "5.10.0-nebula", "#1 SMP", "aarch64", "(none)"]
            for (index, field) in fields.enumerated() {
                let bytes = Array(field.utf8.prefix(64))
                for (offset, byte) in bytes.enumerated() {
                    buf[index * 65 + offset] = byte
                }
            }
            guard self.writeStruct(interp, utsnamePtr, buf) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            return 0
        }

        register(number: SDRSyscallNumber.getrandom, name: "getrandom") { [weak self] bufPtr, length, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let want = Int(Swift.min(length, 4096))
            guard want > 0 else { return 0 }
            var generator = SystemRandomNumberGenerator()
            var bytes = [UInt8](repeating: 0, count: want)
            for index in 0..<want {
                let value: UInt64 = generator.next()
                bytes[index] = UInt8(truncatingIfNeeded: value)
            }
            guard self.writeStruct(interp, bufPtr, bytes) else {
                return Self.failure(SDRSyscallNumber.Errno.efault)
            }
            return UInt64(want)
        }

        register(number: SDRSyscallNumber.memfd_create, name: "memfd_create") { [weak self] namePtr, _, _, _, _, _, interp in
            guard let self = self else { return Self.failure(SDRSyscallNumber.Errno.einval) }
            let guestName = self.readString(interp, namePtr) ?? "memfd"
            let safeName = guestName.replacingOccurrences(of: "/", with: "_")
            let url = SDRSandbox.shared.tempDirectory
                .appendingPathComponent("memfd-\(UUID().uuidString)-\(safeName)")
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forUpdating: url) else {
                return Self.failure(SDRSyscallNumber.Errno.eacces)
            }
            guard let fd = self.fileDescriptors.install(handle: handle, path: url.path,
                                                        flags: SDRSyscallNumber.OpenFlag.rdwr,
                                                        offset: 0, size: 0) else {
                try? handle.close()
                return Self.failure(SDRSyscallNumber.Errno.emfile)
            }
            return UInt64(bitPattern: Int64(fd))
        }

        register(number: SDRSyscallNumber.epoll_create1, name: "epoll_create1") { _, _, _, _, _, _, _ in
            Self.failure(SDRSyscallNumber.Errno.enosys)
        }
        register(number: SDRSyscallNumber.epoll_ctl, name: "epoll_ctl") { _, _, _, _, _, _, _ in
            Self.failure(SDRSyscallNumber.Errno.enosys)
        }
        register(number: SDRSyscallNumber.eventfd2, name: "eventfd2") { _, _, _, _, _, _, _ in
            Self.failure(SDRSyscallNumber.Errno.enosys)
        }
        register(number: SDRSyscallNumber.pipe2, name: "pipe2") { _, _, _, _, _, _, _ in
            Self.failure(SDRSyscallNumber.Errno.enosys)
        }
        register(number: SDRSyscallNumber.statx, name: "statx") { _, _, _, _, _, _, _ in
            Self.failure(SDRSyscallNumber.Errno.enosys)
        }
        register(number: SDRSyscallNumber.mremap, name: "mremap") { _, _, _, _, _, _, _ in
            Self.failure(SDRSyscallNumber.Errno.enosys)
        }
    }

    private func requestExit(code: Int32) {
        exitRequested = true
        exitCode = code
        SDRLogger.i("syscall", "guest 请求退出，exit_code=\(code)")
    }
}
