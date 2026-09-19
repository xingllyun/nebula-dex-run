// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// 系统调用代理层冒烟验收（阶段二 · 步骤一）
// 不依赖 guest 指令流，直接以 AArch64 Linux 真实调用号驱动 SDRSystemServices，
// 校验 mmap/brk/文件往返/沙盒越界拦截/未实现号回落 -ENOSYS 等关键语义。
// 用法: syscall-smoke

import Foundation
#if canImport(Darwin)
import Darwin
#endif

var totalChecks = 0
var failedChecks = 0

func check(_ condition: Bool, _ label: String) {
    totalChecks += 1
    if condition {
        print("ok   \(label)")
    } else {
        failedChecks += 1
        print("FAIL \(label)")
    }
}

func asInt64(_ value: UInt64) -> Int64 { Int64(bitPattern: value) }

// MARK: - 运行环境

let fileManager = FileManager.default
try? fileManager.createDirectory(at: SDRSandbox.shared.tempDirectory, withIntermediateDirectories: true)
try? fileManager.createDirectory(at: SDRSandbox.shared.tempDirectory.appendingPathComponent("smoke"),
                                 withIntermediateDirectories: true)

let memory = SDRMemoryGuard()
memory.budget = SDRMemoryBudget.Plan(
    tier: .standard,
    residentLimitBytes: 256 * 1024 * 1024,
    addressSpaceLimitBytes: 512 * 1024 * 1024,
    dexCacheLimitBytes: 64 * 1024 * 1024,
    soSegmentLimitBytes: 64 * 1024 * 1024,
    registerStackDepth: 64,
    allowsWideAddressArena: false,
    basedOnPhysicalBytes: 0,
    basedOnAvailableBytes: 0)

let context = SDRCpuContext()
let services = SDRSystemServices()
let interpreter = SDRArmInterpreter(context: context, memory: memory, services: services, budget: 1000)
services.bind(interpreter: interpreter)

/// 数据交换区（guest 侧字符串 / 结构体都放这里）
let scratchBase: UInt64 = 0x4000_0000
let scratchSize: UInt64 = 64 * 1024
guard memory.map(name: "scratch", base: scratchBase, size: scratchSize,
                 readable: true, writable: true, executable: false) else {
    print("FAIL 无法建立 scratch 段")
    exit(1)
}

@discardableResult
func syscall(_ number: UInt32,
             _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0,
             _ a3: UInt64 = 0, _ a4: UInt64 = 0, _ a5: UInt64 = 0) -> UInt64 {
    context.x[0] = a0
    context.x[1] = a1
    context.x[2] = a2
    context.x[3] = a3
    context.x[4] = a4
    context.x[5] = a5
    do {
        return try services.dispatch(syscall: number, context: context)
    } catch {
        print("FAIL 调用号 \(number) 抛出异常：\(error.localizedDescription)")
        failedChecks += 1
        return 0
    }
}

func writeGuest(_ address: UInt64, _ bytes: [UInt8]) {
    do { try memory.write(address, bytes: bytes) } catch { print("FAIL guest 写入失败 @\(address)") }
}

func writeCString(_ address: UInt64, _ text: String) {
    writeGuest(address, Array(text.utf8) + [0])
}

func readGuest(_ address: UInt64, _ count: Int) -> [UInt8] {
    (try? memory.read(address, count: count)) ?? []
}

func readLE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[offset + index]) }
    return value
}

// MARK: - 1. mmap / mprotect / munmap

let mmapBase = syscall(SDRSyscallNumber.mmap, 0, 4096,
                       UInt64(bitPattern: Int64(SDRSyscallNumber.MMapProt.read | SDRSyscallNumber.MMapProt.write)),
                       UInt64(bitPattern: Int64(SDRSyscallNumber.MMapFlag.anonymous | SDRSyscallNumber.MMapFlag.private)),
                       UInt64(bitPattern: Int64(-1)), 0)
check(asInt64(mmapBase) > 0 && mmapBase % SDRSyscallNumber.pageSize == 0, "mmap 匿名映射返回页对齐地址 0x\(String(mmapBase, radix: 16))")

writeGuest(mmapBase, [0xAB, 0xCD, 0xEF, 0x12])
check(readGuest(mmapBase, 4) == [0xAB, 0xCD, 0xEF, 0x12], "mmap 段可读回写入内容")

check(asInt64(syscall(SDRSyscallNumber.mprotect, mmapBase, 4096, UInt64(SDRSyscallNumber.MMapProt.read))) == 0, "mprotect 读取权限返回 0")

check(asInt64(syscall(SDRSyscallNumber.munmap, mmapBase, 4096)) == 0, "munmap 返回 0")
check(memory.segment(for: mmapBase) == nil, "munmap 后段表不再包含该地址")

// MARK: - 2. brk

let brkInitial = syscall(SDRSyscallNumber.brk, 0)
check(brkInitial == 0, "brk(0) 初始返回 0")

let brkRequest: UInt64 = 0x3000_0000
let brkGranted = syscall(SDRSyscallNumber.brk, brkRequest)
check(brkGranted >= brkRequest, "brk 首次扩容返回不低于请求值（0x\(String(brkGranted, radix: 16))）")
check(memory.segment(for: brkRequest) != nil, "brk 扩容后堆段可见")

let brkShrink = syscall(SDRSyscallNumber.brk, brkRequest)
check(brkShrink == brkRequest, "brk 回退到已分配范围内返回请求值")

// MARK: - 3. 文件往返（openat / write / lseek / read / fstat / close）

let pathPointer = scratchBase
writeCString(pathPointer, "smoke/hello.txt")
let openFlags = SDRSyscallNumber.OpenFlag.creat | SDRSyscallNumber.OpenFlag.rdwr | SDRSyscallNumber.OpenFlag.trunc
let fdRaw = syscall(SDRSyscallNumber.openat,
                    UInt64(bitPattern: Int64(SDRSyscallNumber.atFdcwd)), pathPointer,
                    UInt64(bitPattern: Int64(openFlags)), 0o644)
let descriptor = Int32(bitPattern: UInt32(truncatingIfNeeded: fdRaw))
check(descriptor >= 3, "openat(O_CREAT|O_RDWR) 返回 guest fd=\(descriptor)")

let payload = Array("nebula-dex-syscall-smoke".utf8)
let payloadPointer = scratchBase + 256
writeGuest(payloadPointer, payload)
let written = syscall(SDRSyscallNumber.write, UInt64(UInt64(bitPattern: Int64(descriptor))), payloadPointer, UInt64(payload.count))
check(asInt64(written) == Int64(payload.count), "write 返回写入字节数 \(asInt64(written))")

let seekResult = syscall(SDRSyscallNumber.lseek, UInt64(UInt64(bitPattern: Int64(descriptor))), 0, 0)
check(asInt64(seekResult) == 0, "lseek(SEEK_SET, 0) 归零游标")

let readPointer = scratchBase + 512
let readBytes = syscall(SDRSyscallNumber.read, UInt64(UInt64(bitPattern: Int64(descriptor))), readPointer, UInt64(payload.count))
check(asInt64(readBytes) == Int64(payload.count), "read 返回读取字节数 \(asInt64(readBytes))")
check(readGuest(readPointer, payload.count) == payload, "read 内容与写入一致")

let statPointer = scratchBase + 1024
let statResult = syscall(SDRSyscallNumber.fstat, UInt64(UInt64(bitPattern: Int64(descriptor))), statPointer)
check(asInt64(statResult) == 0, "fstat 返回 0")
check(readLE64(readGuest(statPointer, 128), 48) == UInt64(payload.count), "fstat 上报 st_size=\(payload.count)")

let closeResult = syscall(SDRSyscallNumber.close, UInt64(UInt64(bitPattern: Int64(descriptor))))
check(asInt64(closeResult) == 0, "close 返回 0")
check(asInt64(syscall(SDRSyscallNumber.close, UInt64(UInt64(bitPattern: Int64(descriptor))))) == -Int64(SDRSyscallNumber.Errno.ebadf),
      "重复 close 返回 -EBADF")

// MARK: - 4. 沙盒越界拦截

let escapePointer = scratchBase + 2048
writeCString(escapePointer, "../../../../../../../../etc/passwd")
let escapeRaw = syscall(SDRSyscallNumber.openat,
                        UInt64(bitPattern: Int64(SDRSyscallNumber.atFdcwd)), escapePointer,
                        UInt64(bitPattern: Int64(SDRSyscallNumber.OpenFlag.rdonly)), 0)
check(asInt64(escapeRaw) == -Int64(SDRSyscallNumber.Errno.eacces), "相对路径越出沙盒被拒绝（-EACCES）")

let absoluteEscapePointer = scratchBase + 2560
writeCString(absoluteEscapePointer, "/../../../../../../etc/passwd")
let absoluteEscapeRaw = syscall(SDRSyscallNumber.openat,
                                UInt64(bitPattern: Int64(SDRSyscallNumber.atFdcwd)), absoluteEscapePointer,
                                UInt64(bitPattern: Int64(SDRSyscallNumber.OpenFlag.rdonly)), 0)
check(asInt64(absoluteEscapeRaw) == -Int64(SDRSyscallNumber.Errno.eacces), "guest 绝对路径越出沙盒被拒绝（-EACCES）")

let missingPointer = scratchBase + 3072
writeCString(missingPointer, "smoke/not-exist.txt")
let missingRaw = syscall(SDRSyscallNumber.openat,
                         UInt64(bitPattern: Int64(SDRSyscallNumber.atFdcwd)), missingPointer,
                         UInt64(bitPattern: Int64(SDRSyscallNumber.OpenFlag.rdonly)), 0)
check(asInt64(missingRaw) == -Int64(SDRSyscallNumber.Errno.enoent), "缺失文件且无 O_CREAT 返回 -ENOENT")

// MARK: - 5. 标准流与未实现号

var standardStreamBytes: [UInt8] = []
services.fileDescriptors.onStandardStreamWrite = { _, bytes in standardStreamBytes = bytes }
let bannerPointer = scratchBase + 3584
let banner = Array("stage2\n".utf8)
writeGuest(bannerPointer, banner)
let bannerWritten = syscall(SDRSyscallNumber.write, 1, bannerPointer, UInt64(banner.count))
check(asInt64(bannerWritten) == Int64(banner.count) && standardStreamBytes == banner, "write(fd=1) 走标准流回调")

let unsupported = syscall(9999)
check(asInt64(unsupported) == -Int64(SDRSyscallNumber.Errno.enosys), "未实现调用号返回 -ENOSYS")
check(services.unsupportedCalls[9999] == 1, "未实现调用号被计数")

// MARK: - 6. 时间与标识

let timespecPointer = scratchBase + 4096
check(asInt64(syscall(SDRSyscallNumber.clock_gettime, 0, timespecPointer)) == 0, "clock_gettime(CLOCK_REALTIME) 返回 0")
check(readLE64(readGuest(timespecPointer, 16), 0) > 0, "clock_gettime 写出非零 tv_sec")

let timevalPointer = scratchBase + 8192
check(asInt64(syscall(SDRSyscallNumber.gettimeofday, timevalPointer, 0)) == 0, "gettimeofday 返回 0")
check(readLE64(readGuest(timevalPointer, 16), 0) > 0, "gettimeofday 写出非零 tv_sec")

let utsnamePointer = scratchBase + 12288
check(asInt64(syscall(SDRSyscallNumber.uname, utsnamePointer)) == 0, "uname 返回 0")
check(readGuest(utsnamePointer, 5) == Array("Linux".utf8), "uname 系统名以 Linux 开头")

check(asInt64(syscall(SDRSyscallNumber.getpid)) == 4242, "getpid 返回稳定 pid")
check(asInt64(syscall(SDRSyscallNumber.gettid)) == 4242, "gettid 返回稳定 tid")

let randomPointer = scratchBase + 16384
check(asInt64(syscall(SDRSyscallNumber.getrandom, randomPointer, 16)) == 16, "getrandom 返回填充字节数")

check(asInt64(syscall(SDRSyscallNumber.futex, scratchBase + 20480, 0)) == -Int64(SDRSyscallNumber.Errno.eagain),
      "futex(FUTEX_WAIT) 单线程模型返回 -EAGAIN")

// MARK: - 7. 退出语义

check(!services.exitRequested, "初始未请求退出")
check(asInt64(syscall(SDRSyscallNumber.exit_group, 7)) == 0, "exit_group 返回 0")
check(services.exitRequested && services.exitCode == 7, "exit_group 置位退出请求并记录退出码")

// MARK: - 收口

services.fileDescriptors.closeAll()
print("NebulaDex 系统调用代理层冒烟：\(totalChecks) 项检查，失败 \(failedChecks) 项")
if failedChecks > 0 {
    FileHandle.standardError.write("syscall 冒烟未通过\n".data(using: .utf8)!)
    exit(1)
}
exit(0)
