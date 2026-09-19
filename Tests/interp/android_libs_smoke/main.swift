// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// 阶段二 · 步骤四验收：Android 运行时基础库冒烟（liblog / libm / libz + 宿主桩区）
//
// 验收方式：与 libc 冒烟一致 —— 直接在 guest 代码段写入宿主调用桩并真实执行，
// 覆盖三条链路：
//   1. 整数返回族（liblog / libz）：参数经 X0..X5，返回值经 X0；
//   2. 标量返回族（libm）：参数经 V0/V1，返回值经陷阱写回 V0；
//   3. SDRHostStubPool：桩区字节与符号索引一致、收权后不可写、可从桩区入口真实执行。

import Foundation

// MARK: - 断言

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("[android-libs-smoke] OK   \(label)")
    } else {
        failures += 1
        print("[android-libs-smoke] FAIL \(label)")
    }
}

// MARK: - 被测对象

let memory = SDRMemoryGuard()
let services = SDRSystemServices()
let bridge = SDRHostCall()
let libc = SDRLibc()
let android = SDRAndroidLibs()

_ = libc.install(into: bridge)
let installed = android.install(into: bridge)

// MARK: - 工具

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

func mapCode(_ label: String, _ words: [UInt32]) -> UInt64? {
    guard let code = memory.mapAnonymous(name: "code.\(label)", size: 4096, alignment: 4096,
                                         readable: true, writable: true, executable: true) else {
        return nil
    }
    guard (try? memory.write(code, bytes: assemble(words))) != nil else { return nil }
    return code
}

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

func decodeLE(_ bytes: [UInt8]) -> UInt64 {
    var value: UInt64 = 0
    for (i, byte) in bytes.enumerated() where i < 8 {
        value |= UInt64(byte) << (8 * i)
    }
    return value
}

/// 单次宿主调用：桩 = movz x16,#index ; brk #0x4E44 ; hlt（HALT 收口）。
/// doubles 写入 V0..（libm），floats 写入 S0..（libm 单精度），args 写入 X0..（整数族）。
func callSymbol(_ symbol: String, args: [UInt64] = [], doubles: [Double] = [],
                floats: [Float] = [], label: String) -> (x0: UInt64, d0: Double, ok: Bool) {
    guard let index = bridge.index(of: symbol) else {
        expect(false, "符号未注册：\(symbol)")
        return (0, 0, false)
    }
    var words = SDRHostCall.trampolineInstructions(index: index)
    words[2] = 0xD440_0000   // HLT 取代 ret，便于单次调用收口
    guard let code = mapCode(label, words) else {
        expect(false, "代码段映射失败：\(label)")
        return (0, 0, false)
    }
    let context = SDRCpuContext()
    for (i, value) in doubles.enumerated() where i < 8 { context.fpu.writeD(i, value) }
    for (i, value) in floats.enumerated() where i < 8 { context.fpu.writeS(i, value) }
    let interpreter = SDRArmInterpreter(context: context, memory: memory, services: services,
                                        hostCall: bridge, budget: 64)
    services.bind(interpreter: interpreter)
    _ = try? interpreter.run(entry: code, args: args)
    return (context.x0, context.fpu.readD(0), true)
}

// MARK: - 用例 A：装配

let expectedSymbols = SDRAndroidLibs.libLogSymbols.count
    + SDRAndroidLibs.libMathSymbols.count
    + SDRAndroidLibs.libZSymbols.count
expect(installed == expectedSymbols,
       "Android 基础库注册符号数 = \(expectedSymbols)（实得 \(installed)）")
expect(bridge.index(of: "__android_log_write") != nil, "liblog 符号已登记")
expect(bridge.index(of: "sqrt") != nil, "libm 双精度符号已登记")
expect(bridge.index(of: "sqrtf") != nil, "libm 单精度符号已登记")
expect(bridge.index(of: "crc32") != nil, "libz 符号已登记")
expect(android.install(into: bridge) == installed, "重复安装幂等")

// MARK: - 用例 B：liblog

android.resetProbe()
let logTag = guestString("log.tag", "star.dex") ?? 0
let logText = guestString("log.text", "NebulaDex") ?? 0
let logged = callSymbol("__android_log_write", args: [4, logTag, logText], label: "log.write")
expect(logged.x0 == 10, "__android_log_write 返回写入字节数（含 NUL）= 10（实得 \(logged.x0)）")
expect(android.lastMessage == "[star.dex] NebulaDex",
       "日志内容含 tag 与正文（实得 \(android.lastMessage ?? "nil")）")
expect(android.emittedMessageCount == 1, "日志转发计数 = 1（实得 \(android.emittedMessageCount)）")

// MARK: - 用例 C：libm（标量参数在 V0/V1，返回写回 V0）

let root = callSymbol("sqrt", doubles: [2.0], label: "sqrt")
expect(abs(root.d0 - 2.0.squareRoot()) < 1e-12, "sqrt(2)（实得 \(root.d0)）")

let power = callSymbol("pow", doubles: [2.0, 10.0], label: "pow")
expect(abs(power.d0 - 1024.0) < 1e-9, "pow(2,10)（实得 \(power.d0)）")

let modulo = callSymbol("fmod", doubles: [7.5, 2.0], label: "fmod")
expect(abs(modulo.d0 - 1.5) < 1e-12, "fmod(7.5,2)（实得 \(modulo.d0)）")

let floored = callSymbol("floor", doubles: [-1.25], label: "floor")
expect(floored.d0 == -2.0, "floor(-1.25)（实得 \(floored.d0)）")

let scaled = callSymbol("ldexp", args: [4], doubles: [1.5], label: "ldexp")
expect(scaled.d0 == 24.0, "ldexp(1.5,4)（实得 \(scaled.d0)）")

let rootSingle = callSymbol("sqrtf", floats: [2.0], label: "sqrtf")
expect(abs(rootSingle.d0 - Double(Float(2.0).squareRoot())) < 1e-9,
       "sqrtf(2)（实得 \(rootSingle.d0)）")

let powerSingle = callSymbol("powf", floats: [3.0, 3.0], label: "powf")
expect(abs(powerSingle.d0 - 27.0) < 1e-4, "powf(3,3)（实得 \(powerSingle.d0)）")

// MARK: - 用例 D：libz

let abc = guestString("z.abc", "abc") ?? 0
let crc = callSymbol("crc32", args: [0, abc, 3], label: "crc32")
expect(crc.x0 == 0x3524_41C2, "crc32(\"abc\") = 0x352441C2（实得 0x\(String(crc.x0, radix: 16))）")

let wiki = guestString("z.wiki", "Wikipedia") ?? 0
let adler = callSymbol("adler32", args: [1, wiki, 9], label: "adler32")
expect(adler.x0 == 0x11E6_0398,
       "adler32(1,\"Wikipedia\") = 0x11E60398（实得 0x\(String(adler.x0, radix: 16))）")

// zlib 压缩后的 "hello, nebula"（21 字节，宿主 zlib 产物，作为 golden 输入）
let zlibPayload: [UInt8] = [0x78, 0x9C, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0xD7, 0x51, 0xC8,
                            0x4B, 0x4D, 0x2A, 0xCD, 0x49, 0x04, 0x00, 0x21, 0xC1, 0x04, 0xD8]
let plainText = "hello, nebula"
if let dest = guestBuffer("z.dest"), let destLen = guestBuffer("z.len", size: 64),
   let source = guestBuffer("z.src", size: 64) {
    _ = writeGuest(destLen, [0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])  // 4096（uLongf 小端）
    let wrote = writeGuest(source, zlibPayload)
    expect(wrote, "zlib 载荷写入 guest 数据段")
    let restored = callSymbol("uncompress",
                              args: [dest, destLen, source, UInt64(zlibPayload.count)],
                              label: "uncompress")
    expect(restored.x0 == 0, "uncompress 返回 Z_OK（实得 \(restored.x0)）")
    expect(decodeLE(readGuest(destLen, count: 8)) == UInt64(plainText.utf8.count),
           "uncompress 回写解压长度 = \(plainText.utf8.count)")
    let text = String(decoding: readGuest(dest, count: plainText.utf8.count), as: UTF8.self)
    expect(text == plainText, "uncompress 产物一致（实得 \"\(text)\"）")
} else {
    expect(false, "uncompress 用例的 guest 缓冲分配失败")
}

// MARK: - 用例 E：宿主桩区

let pool = SDRHostStubPool(capacity: 4096)
expect(pool.prepare(in: memory, bridge: bridge), "宿主桩区建立成功")
expect(pool.preparedSymbolCount == bridge.symbolCount,
       "桩区覆盖全部已注册符号（\(bridge.symbolCount)）")

if let stub = pool.address(for: "sqrt"), let sqrtIndex = bridge.index(of: "sqrt") {
    let stubBytes = readGuest(stub, count: SDRHostCall.trampolineBytes)
    expect(stubBytes == SDRHostCall.trampolineData(index: sqrtIndex),
           "桩字节与符号索引一致（sqrt → #\(sqrtIndex)）")
    if let segment = memory.segment(for: stub) {
        expect(segment.readable && !segment.writable && segment.executable,
               "桩区运行期收权为「只读 + 可执行」")
    } else {
        expect(false, "桩区段信息查询失败")
    }

    // 从桩区入口真实执行：sqrt(9) → 3，返回后跳转 HLT 收口
    if let halt = mapCode("stub.halt", [0xD440_0000]) {
        let context = SDRCpuContext()
        context.x[30] = halt
        context.fpu.writeD(0, 9.0)
        let interpreter = SDRArmInterpreter(context: context, memory: memory, services: services,
                                            hostCall: bridge, budget: 8)
        services.bind(interpreter: interpreter)
        _ = try? interpreter.run(entry: stub, args: [])
        expect(abs(context.fpu.readD(0) - 3.0) < 1e-12,
               "从桩区入口执行 sqrt(9) 并回写 V0（实得 \(context.fpu.readD(0))）")
    } else {
        expect(false, "收口代码段映射失败")
    }
} else {
    expect(false, "桩区未收录 sqrt")
}
expect(pool.address(for: "not.registered.symbol") == nil, "未收录符号不返回假地址")

// MARK: - 收口

print("[android-libs-smoke] 共 \(checks) 项检查，失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
