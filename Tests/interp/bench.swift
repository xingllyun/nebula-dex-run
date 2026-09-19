// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// AArch64 解释器吞吐量基准（性能基线，非正确性断言）
// 读取 bench.json（由 temp/gen_bench.py 生成的热循环程序），
// 用 SDRArmInterpreter.run(entry:args:) 整段执行并统计指令吞吐（MIPS）与译码缓存命中率。
// 用法: bench <bench.json> [rounds]
//
// 说明：不做阈值断言，仅打印信息性指标，避免 CI runner 抖动造成误报失败。

import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct BenchDoc: Decodable {
    let code_base: String
    let code_size: Int
    let stack_base: String
    let stack_size: Int
    let sp_init: String
    let code_hex: String
    let iterations: Int
    let instructions_per_iteration: Int
    let budget: Int
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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

@main
struct BenchMain {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fail("用法: bench <bench.json> [rounds]")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
              let doc = try? JSONDecoder().decode(BenchDoc.self, from: data) else {
            fail("无法读取或解析基准文件: \(args[1])")
        }

        let codeBase = parseHex(doc.code_base)
        let stackBase = parseHex(doc.stack_base)
        let spInit = parseHex(doc.sp_init)
        let rounds = args.count >= 3 ? max(1, Int(args[2]) ?? 3) : 3

        print("NebulaDex 解释器吞吐量基准 | 每轮 \(doc.instructions_per_iteration) 指令 x \(doc.iterations) 轮 | 取样 \(rounds) 次")

        var bestSeconds = Double.greatestFiniteMagnitude
        var execCount = 0
        var hitRateText = "-"

        for round in 1...rounds {
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

            guard memory.map(name: "code", base: codeBase, size: UInt64(doc.code_size),
                             readable: true, writable: true, executable: true),
                  memory.map(name: "stack", base: stackBase, size: UInt64(doc.stack_size),
                             readable: true, writable: true, executable: false) else {
                fail("段映射失败")
            }
            do {
                try memory.write(codeBase, bytes: hexToBytes(doc.code_hex))
            } catch {
                fail("代码写入失败: \(error.localizedDescription)")
            }

            let ctx = SDRCpuContext(pc: codeBase, sp: spInit)
            let interp = SDRArmInterpreter(context: ctx, memory: memory, services: services, budget: doc.budget)
            services.bind(interpreter: interp)

            let start = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try interp.run(entry: codeBase, args: [UInt64(doc.iterations)])
            } catch {
                fail("执行失败: \(error.localizedDescription)")
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000.0

            execCount = interp.executedCount
            let total = interp.decodeCacheHits + interp.decodeCacheMisses
            let hitRate = total > 0 ? 100.0 * Double(interp.decodeCacheHits) / Double(total) : 0.0
            hitRateText = String(format: "%.2f%% (%d/%d)", hitRate, interp.decodeCacheHits, total)
            bestSeconds = min(bestSeconds, elapsed)

            print(String(format: "  round %d: 指令 %d | %.3f s | %.2f MIPS | 译码缓存命中率 %@",
                         round, execCount, elapsed, Double(execCount) / elapsed / 1_000_000.0, hitRateText))
        }

        print(String(format: "BEST: 指令 %d | %.3f s | %.2f MIPS | 译码缓存命中率 %@",
                     execCount, bestSeconds, Double(execCount) / bestSeconds / 1_000_000.0, hitRateText))
    }
}
