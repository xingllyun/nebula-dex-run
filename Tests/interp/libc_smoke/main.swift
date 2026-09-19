// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// 阶段二 · 步骤二验收：最小 libc 冒烟
//
// 验收方式与系统调用冒烟一致：不依赖真实 SO 文件，直接在 guest 代码段写入
// `movz x16,#idx ; brk #0x4E44 ; hlt` 三指令桩，用解释器真实执行，检查 host 实现
// 的返回值与内存副作用。桩尾的 ret 换成 HLT，便于单次调用收口。

import Foundation

// MARK: - 断言与工具

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("[libc-smoke] OK   \(label)")
    } else {
        failures += 1
        print("[libc-smoke] FAIL \(label)")
    }
}

let memory = SDRMemoryGuard()
let services = SDRSystemServices()
let bridge = SDRHostCall()
let libc = SDRLibc()

func assemble(_ words: [UInt32]) -> [UInt8] {
    var bytes: [UInt8] = []
    for word in words {
        bytes.append(UInt8(truncatingIfNeeded: word))
        bytes.append(UInt8(truncatingIfNeeded: word >> 8))
        bytes.append(UInt8(truncatingIfNeeded: word >> 16))
        bytes.append(UInt8(truncatingIfNeeded: word >> 24))
    }
    return bytes
}

/// 独立代码段 + 独立上下文，避免跨用例状态串扰；预算给足（桩 + 收口只需 3 步）。
func execute(_ words: [UInt32], args: [UInt64], label: String) -> UInt64 {
    guard let code = memory.mapAnonymous(name: "code.\(label)", size: 4096, alignment: 4096,
                                         readable: true, writable: true, executable: true) else {
        failures += 1
        print("[libc-smoke] FAIL 代码段映射失败：\(label)")
        return 0
    }
    guard (try? memory.write(code, bytes: assemble(words))) != nil else {
        failures += 1
        print("[libc-smoke] FAIL 代码段写入失败：\(label)")
        return 0
    }
    let context = SDRCpuContext()
    let interpreter = SDRArmInterpreter(context: context, memory: memory, services: services,
                                        hostCall: bridge, budget: 64)
    _ = try? interpreter.run(entry: code, args: args)
    return context.x0
}

/// guest 数据段：可读写，用于字符串/缓冲。
func guestBuffer(_ label: String, size: UInt64 = 4096) -> UInt64? {
    memory.mapAnonymous(name: "data.\(label)", size: size, alignment: 4096,
                        readable: true, writable: true, executable: false)
}

func writeGuest(_ address: UInt64, _ bytes: [UInt8]) -> Bool {
    (try? memory.write(address, bytes: bytes)) != nil
}

func readGuest(_ address: UInt64, count: Int) -> [UInt8] {
    (try? memory.read(address, count: count)) ?? []
}

func guestString(_ label: String, _ text: String) -> UInt64? {
    guard let base = guestBuffer(label) else { return nil }
    guard writeGuest(base, Array(text.utf8) + [0]) else { return nil }
    return base
}

func callProgram(_ symbol: String, args: [UInt64], label: String) -> UInt64 {
    guard let index = bridge.index(of: symbol) else {
        failures += 1
        print("[libc-smoke] FAIL 符号未注册：\(symbol)")
        return 0
    }
    var words = SDRHostCall.trampolineInstructions(index: index)
    words[2] = 0xD440_0000   // 桩尾 ret → HLT
    return execute(words, args: args, label: label)
}

func fail(_ errno: Int32) -> UInt64 { UInt64(bitPattern: Int64(-errno)) }

// MARK: - 安装

expect(libc.install(into: bridge), "符号安装到托管调用桥")
expect(!libc.install(into: bridge), "重复安装幂等")
expect(bridge.symbolCount == libc.registeredSymbols.count, "符号索引与清单一致（\(bridge.symbolCount) 个）")
for required in ["memcpy", "memset", "strlen", "malloc", "free", "realloc", "printf", "snprintf", "open", "read", "write", "clock_gettime", "getpid"] {
    expect(bridge.contains(required), "必备符号存在：\(required)")
}

// MARK: - 内存与字符串族

if let text = guestString("strlen", "NebulaDex") {
    expect(callProgram("strlen", args: [text], label: "strlen") == 9, "strlen(\"NebulaDex\") == 9")
    expect(callProgram("strnlen", args: [text, 4], label: "strnlen") == 4, "strnlen(...,4) == 4")
} else {
    expect(false, "字符串段映射失败")
}

if let src = guestString("memcpy.src", "abcdef"), let dst = guestBuffer("memcpy.dst") {
    let returned = callProgram("memcpy", args: [dst, src, 6], label: "memcpy")
    expect(returned == dst, "memcpy 返回目标地址")
    expect(readGuest(dst, count: 6) == Array("abcdef".utf8), "memcpy 内容一致")
    expect(callProgram("memcmp", args: [dst, src, 6], label: "memcmp") == 0, "memcmp 相等返回 0")
    let copied = callProgram("memmove", args: [dst + 2, dst, 4], label: "memmove")
    expect(copied == dst + 2, "memmove 返回目标地址")
    expect(readGuest(dst, count: 6) == Array("ababcd".utf8), "memmove 重叠搬运安全")
} else {
    expect(false, "memcpy 用例段映射失败")
}

if let filled = guestBuffer("memset") {
    _ = callProgram("memset", args: [filled, 0, 32], label: "memset.zero")
    _ = callProgram("memset", args: [filled, 0x41, 8], label: "memset")
    expect(readGuest(filled, count: 8) == [UInt8](repeating: 0x41, count: 8), "memset 填充 A")
    expect(callProgram("memchr", args: [filled, 0x41, 8], label: "memchr") == filled, "memchr 命中首字节")
    expect(callProgram("strlen", args: [filled], label: "strlen.memset") == 8, "strlen 读取填充结果")
} else {
    expect(false, "memset 用例段映射失败")
}

if let hello = guestString("strcmp.a", "hello"), let hell = guestString("strcmp.b", "hell") {
    expect(callProgram("strcmp", args: [hello, hello], label: "strcmp") == 0, "strcmp 同串 == 0")
    expect(callProgram("strncmp", args: [hello, hell, 4], label: "strncmp") == 0, "strncmp 前 4 字节相等")
    expect(callProgram("strcmp", args: [hell, hello], label: "strcmp.rev") > 0, "strcmp 短串 < 长串（返回值 > 0）")
    if let target = guestBuffer("strcpy.dst") {
        expect(callProgram("strcpy", args: [target, hello], label: "strcpy") == target, "strcpy 返回目标")
        expect(readGuest(target, count: 6) == Array("hello\u{0}".utf8), "strcpy 附带结束符")
        expect(callProgram("strcat", args: [target, hell], label: "strcat") == target, "strcat 返回目标")
        expect(readGuest(target, count: 10) == Array("hellohell\u{0}".utf8), "strcat 拼接结果")
    }
    if let found = guestString("strstr.hay", "nebula-dex-run"), let needle = guestString("strstr.needle", "dex") {
        expect(callProgram("strstr", args: [found, needle], label: "strstr") == found + 7, "strstr 命中偏移 7")
    }
    expect(callProgram("atoi", args: [hello], label: "atoi") == 0, "atoi 非数字返回 0")
} else {
    expect(false, "字符串比较用例段映射失败")
}

if let digits = guestString("strtol.in", "  -42abc") {
    expect(callProgram("strtol", args: [digits, 0, 10], label: "strtol") == UInt64(bitPattern: Int64(-42)), "strtol 解析 -42")
    expect(callProgram("atoi", args: [digits + 2], label: "atoi.neg") == UInt64(bitPattern: Int64(-42)), "atoi 解析负号")
} else {
    expect(false, "整数解析用例段映射失败")
}

// MARK: - 堆族

let allocatedBefore = libc.heap.allocatedBytes
let smallPayload = callProgram("malloc", args: [48], label: "malloc.48")
expect(smallPayload != 0 && smallPayload % 16 == 0, "malloc(48) 返回 16 对齐地址")
expect(writeGuest(smallPayload, Array("hello".utf8)), "malloc 结果可写")
expect(callProgram("malloc_usable_size", args: [smallPayload], label: "usable") >= 48, "malloc_usable_size ≥ 48")
expect(libc.heap.allocatedBytes > allocatedBefore, "堆记账递增")

let grown = callProgram("realloc", args: [smallPayload, 4096], label: "realloc")
expect(grown != 0, "realloc 返回新块")
expect(readGuest(grown, count: 5) == Array("hello".utf8), "realloc 保留原数据")
expect(callProgram("free", args: [grown], label: "free") == 0, "free 返回 0")
expect(libc.heap.allocatedBytes == allocatedBefore, "释放后堆记账回落")

let reused = callProgram("malloc", args: [48], label: "malloc.reuse")
expect(reused != 0, "释放后的尺寸类可重新分配")
_ = callProgram("free", args: [reused], label: "free.reuse")

let zeroed = callProgram("calloc", args: [8, 16], label: "calloc")
if zeroed != 0 {
    expect(readGuest(zeroed, count: 128) == [UInt8](repeating: 0, count: 128), "calloc 全零")
    _ = callProgram("free", args: [zeroed], label: "free.calloc")
} else {
    expect(false, "calloc 分配失败")
}

let big = callProgram("malloc", args: [200_000], label: "malloc.big")
if big != 0 {
    expect(writeGuest(big, [UInt8](repeating: 0x5A, count: 64)), "大块分配可写")
    expect(callProgram("free", args: [big], label: "free.big") == 0, "大块释放成功")
} else {
    expect(false, "大块分配失败")
}

// MARK: - 格式化与标准输出

if let target = guestBuffer("snprintf.buf"), let name = guestString("snprintf.name", "ok"),
   let format = guestString("snprintf.fmt", "v=%d/%s") {
    let length = callProgram("snprintf", args: [target, 64, format, 42, name], label: "snprintf")
    expect(length == 7, "snprintf 返回本应写入长度 7（实际 \(length)）")
    expect(readGuest(target, count: 8) == Array("v=42/ok\u{0}".utf8), "snprintf 输出 v=42/ok")
}

if let format = guestString("printf.fmt", "n=%d\n") {
    var captured: [UInt8] = []
    libc.stdoutSink = { _, bytes in captured.append(contentsOf: bytes) }
    let written = callProgram("printf", args: [format, 7], label: "printf")
    libc.stdoutSink = nil
    expect(written == 4, "printf 返回写入字节数 4（实际 \(written)）")
    expect(captured == Array("n=7\n".utf8), "printf 捕获输出 n=7")
}

if let text = guestString("puts.text", "ready") {
    var captured: [UInt8] = []
    libc.stdoutSink = { _, bytes in captured.append(contentsOf: bytes) }
    _ = callProgram("puts", args: [text], label: "puts")
    libc.stdoutSink = nil
    expect(captured == Array("ready\n".utf8), "puts 追加换行")
}

// MARK: - 文件往返（转发系统调用代理层）

if let path = guestString("file.path", services.workingDirectory + "/libc_smoke.txt"),
   let payload = guestBuffer("file.payload") {
    _ = writeGuest(payload, Array("libc-roundtrip".utf8))
    let openFlags = SDRSyscallNumber.OpenFlag.wronly | SDRSyscallNumber.OpenFlag.creat | SDRSyscallNumber.OpenFlag.trunc
    let fd = callProgram("open", args: [path, UInt64(bitPattern: Int64(openFlags)), 0o644], label: "open.w")
    expect(fd > 0, "libc open 打开写通道（fd=\(fd)）")
    let wrote = callProgram("write", args: [fd, payload, 14], label: "write")
    expect(wrote == 14, "libc write 写入 14 字节")
    _ = callProgram("close", args: [fd], label: "close")

    let readFd = callProgram("open", args: [path, UInt64(bitPattern: Int64(SDRSyscallNumber.OpenFlag.rdonly)), 0], label: "open.r")
    expect(readFd > 0, "libc open 打开读通道（fd=\(readFd)）")
    if let sink = guestBuffer("file.read") {
        let got = callProgram("read", args: [readFd, sink, 14], label: "read")
        expect(got == 14, "libc read 读回 14 字节")
        expect(readGuest(sink, count: 14) == Array("libc-roundtrip".utf8), "libc 文件往返内容一致")
    }
    _ = callProgram("close", args: [readFd], label: "close.r")
}

// MARK: - 时间与进程族

let pid = callProgram("getpid", args: [], label: "getpid")
expect(pid == 4242, "getpid 返回沙盒进程号（\(pid)）")
let pagesize = callProgram("sysconf", args: [39], label: "sysconf")
expect(pagesize == 4096, "sysconf(_SC_PAGESIZE) == 4096")
let seconds = callProgram("time", args: [0], label: "time")
expect(seconds > 1_700_000_000, "time 返回 Unix 秒（\(seconds)）")
let errnoSlot = callProgram("__errno", args: [], label: "__errno")
if errnoSlot != 0 {
    expect(errnoSlot % 8 == 0, "__errno 返回可写槽地址")
} else {
    expect(false, "__errno 未返回有效槽")
}

// MARK: - 失败约定

expect(bridge.index(of: "definitely_absent_symbol") == nil, "未注册符号不可查（回落 -ENOSYS 由桩索引越界路径覆盖）")

var outOfRange = SDRHostCall.trampolineInstructions(index: 60_000)
outOfRange[2] = 0xD440_0000
let escaped = execute(outOfRange, args: [], label: "escape")
expect(escaped == fail(SDRSyscallNumber.Errno.enosys), "越界符号索引回落 -ENOSYS")

// MARK: - 汇总

print("[libc-smoke] 共 \(checks) 项，失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
