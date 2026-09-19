// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// AArch64 解释器验收驱动（阶段一）
// 读取 vectors.json（黄金值由 unicorn-engine 对同一份机器码模拟得出），
// 用 SDRArmInterpreter 逐条单步执行并比对通用寄存器 / 浮点寄存器 / SP / NZCV。
// 用法: interp-test Tests/interp/vectors.json

import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct TestCase: Decodable {
    let name: String
    let desc: String
    let steps: Int
    let code_hex: String
    let expect_x: [String: String]
    let expect_v: [String: String]
    /// NEON 128 位向量的高 64 位（Q = 1 时由 vh 承载；缺省表示不校验高半）
    let expect_vh: [String: String]?
    /// 执行前注入 v 寄存器低 64 位初值（NEON 向量测试必需）
    let init_v: [String: String]?
    /// 执行前注入 v 寄存器高 64 位初值
    let init_vh: [String: String]?
    let expect_sp: String
    let expect_nzcv: String
}

struct VectorDoc: Decodable {
    let code_base: String
    let code_size: Int
    let stack_base: String
    let stack_size: Int
    let sp_init: String
    let cases: [TestCase]
}

func parseHex(_ s: String) -> UInt64 {
    let t = (s.hasPrefix("0x") || s.hasPrefix("0X")) ? String(s.dropFirst(2)) : s
    return UInt64(t, radix: 16) ?? 0
}

func hexToBytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
        if let b = UInt8(s[idx..<next], radix: 16) { out.append(b) }
        idx = next
    }
    return out
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: interp-test <vectors.json>\n".data(using: .utf8)!)
    exit(2)
}

guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let doc = try? JSONDecoder().decode(VectorDoc.self, from: data) else {
    FileHandle.standardError.write("无法读取或解析向量文件: \(args[1])\n".data(using: .utf8)!)
    exit(2)
}

let codeBase = parseHex(doc.code_base)
let stackBase = parseHex(doc.stack_base)
let spInit = parseHex(doc.sp_init)

var totalChecks = 0
var failedChecks = 0
var failedCases: [String] = []

print("NebulaDex AArch64 解释器验收 | 用例 \(doc.cases.count) 个")

for c in doc.cases {
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
    let services = SDRSystemServices()

    // 代码段在装载阶段需要写入机器码，故此处同时开启写权限（仅测试用）
    guard memory.map(name: "code", base: codeBase, size: UInt64(doc.code_size),
                     readable: true, writable: true, executable: true) else {
        print("FAIL [\(c.name)] 代码段映射失败")
        failedCases.append(c.name)
        continue
    }
    guard memory.map(name: "stack", base: stackBase, size: UInt64(doc.stack_size),
                     readable: true, writable: true, executable: false) else {
        print("FAIL [\(c.name)] 栈段映射失败")
        failedCases.append(c.name)
        continue
    }

    do {
        try memory.write(codeBase, bytes: hexToBytes(c.code_hex))
    } catch {
        print("FAIL [\(c.name)] 代码写入失败: \(error.localizedDescription)")
        failedCases.append(c.name)
        continue
    }

    let ctx = SDRCpuContext(pc: codeBase, sp: spInit)
    let interp = SDRArmInterpreter(context: ctx, memory: memory, services: services, budget: 100_000)
    services.bind(interpreter: interp)

    // NEON 向量用例：执行前注入 v 寄存器 128 位初值（低 64 位 / 高 64 位）
    if let iv = c.init_v {
        for (key, value) in iv {
            if let index = Int(key), index >= 0, index < 32 { ctx.fpu.v[index] = parseHex(value) }
        }
    }
    if let ivh = c.init_vh {
        for (key, value) in ivh {
            if let index = Int(key), index >= 0, index < 32 { ctx.fpu.vh[index] = parseHex(value) }
        }
    }

    do {
        for i in 0..<c.steps {
            let bytes = try memory.read(ctx.pc, count: 4)
            let insn = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            let state = try interp.step(insn)
            if case .running = state {} else {
                print("  注意 [\(c.name)] 第 \(i) 步后状态非 running @0x\(String(ctx.pc, radix: 16))")
            }
        }
    } catch {
        print("FAIL [\(c.name)] 执行异常: \(error.localizedDescription)")
        failedCases.append(c.name)
        continue
    }

    var caseFailed = false
    func check(_ label: String, _ got: UInt64, _ wantHex: String) {
        totalChecks += 1
        let want = parseHex(wantHex)
        if got != want {
            failedChecks += 1
            caseFailed = true
            print("  MISMATCH [\(c.name)] \(label): got 0x\(String(got, radix: 16)) want 0x\(String(want, radix: 16))")
        }
    }

    for i in 0..<31 {
        if let want = c.expect_x[String(i)] { check("x\(i)", ctx.x[i], want) }
    }
    for i in 0..<32 {
        if let want = c.expect_v[String(i)] { check("v\(i)", ctx.fpu.v[i], want) }
    }
    if let wantVh = c.expect_vh {
        for i in 0..<32 {
            if let want = wantVh[String(i)] { check("vh\(i)", ctx.fpu.vh[i], want) }
        }
    }
    check("sp", ctx.sp, c.expect_sp)
    check("nzcv", UInt64(ctx.nzcv), c.expect_nzcv)

    if !caseFailed {
        print("PASS [\(c.name)] \(c.desc)")
    }
    if caseFailed || failedCases.contains(c.name) {
        if !failedCases.contains(c.name) { failedCases.append(c.name) }
    }
}

print("")
print("校验项 \(totalChecks) 个 | 失败 \(failedChecks) 项 | 用例 \(doc.cases.count - failedCases.count)/\(doc.cases.count) 通过")
if !failedCases.isEmpty {
    print("失败用例: \(failedCases.joined(separator: ", "))")
    exit(1)
}
print("ALL PASS")
