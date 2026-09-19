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

/// AArch64 高级 SIMD（NEON）整数执行单元（阶段一 · 第一轮）
///
/// 覆盖 Android arm64-v8a 原生库由 Clang 生成的整数向量主通路：
///   - 三同 three-same：ADD/SUB/MUL、AND/BIC/ORR/ORN/EOR/BSL/BIT/BIF、
///     CMEQ/CMTST/CMGT/CMHI/CMGE/CMHS、SSHL/USHL、SMAX/SMIN/UMAX/UMIN、ADDP
///   - 二同 two-register-misc：REV64/REV32/REV16、CNT、CLS/CLZ、ABS/NEG、NOT、XTN/XTN2
///   - 移位立即数 shift-by-immediate：SHL/SLI、SSHR/USHR、SSRA/USRA、SRI、
///     SHRN/SHRN2、SSHLL/USHLL（含 2 形式）
///   - 搬移 copy：DUP(element)、DUP(general)、INS(element)、INS(general)
///
/// 位域依据：全部以 `clang -target aarch64-linux-gnu` 交叉汇编 + `llvm-objdump`
/// 反查真实机器码后机械拆分（反查脚本与位域表见 Tests/interp/gen_vectors_neon.py 注释），
/// 不依赖手册记忆，避免移位/比较/逻辑族编码错位。
///
/// 顶层分派（bits[28:24]）：
///   0b01111 → 移位立即数（bit10 = 1；bit10 = 0 为按元素 by-element，当前未覆盖）
///   0b01110 → bit21 = 1 且 bit10 = 1 → 三同（opcode = bits[15:11]）
///              bit21 = 1 且 bits[20:17] = 0 且 bit11 = 1 且 bit10 = 0 → 二同 misc（opcode = bits[16:12]）
///              bit21 = 0 且 bit10 = 1 → 搬移 copy（opcode = bits[15:11]）
///              其余（三不同/跨通道归约/按元素等）→ 返回 false
///
/// 寄存器语义：Q = 0 时只写低 64 位并把高 64 位清零（D 寄存器写入语义），
/// Q = 1 时写满 128 位；INS 类只改单个元素、保留其余位。
/// 未覆盖的编码一律返回 false，由主解释器按 unsupported 上报，绝不猜测执行。

enum SDRArmNEON {

    // MARK: - 顶层分派

    /// 高级 SIMD 整数指令入口。
    /// - Returns: true 表示已识别并执行；false 表示本单元未覆盖该编码。
    static func execute(insn: UInt32, context: SDRCpuContext, fpu: SDRArmFPU) -> Bool {
        let top = (insn >> 24) & 0x1F
        if top == 0b01111 {
            guard (insn >> 10) & 1 == 1 else { return false }   // bit10 = 0 为按元素，暂未覆盖
            return executeShiftImmediate(insn: insn, fpu: fpu)
        }
        guard top == 0b01110 else { return false }

        let b21 = (insn >> 21) & 1
        let b11 = (insn >> 11) & 1
        let b10 = (insn >> 10) & 1

        if b21 == 1, b10 == 1 {
            return executeThreeSame(insn: insn, fpu: fpu)
        }
        // 二同 misc 固定形如 size:10000：bits[20:17] = 0000，bit11 = 1，bit10 = 0
        if b21 == 1, ((insn >> 17) & 0xF) == 0, b11 == 1, b10 == 0 {
            return executeTwoRegMisc(insn: insn, fpu: fpu)
        }
        if b21 == 0, b10 == 1 {
            return executeCopy(insn: insn, context: context, fpu: fpu)
        }
        return false
    }

    // MARK: - 通道读写与通用工具

    /// 元素掩码（esize 位全 1；esize = 64 时为全 1）。
    @inline(__always)
    static func laneMask(_ esize: Int) -> UInt64 {
        esize >= 64 ? ~0 : ((UInt64(1) << UInt64(esize)) - 1)
    }

    /// 读取第 index 个 esize 位元素；低/高 64 位分视图，元素不跨 64 位边界。
    @inline(__always)
    static func laneGet(_ src: (UInt64, UInt64), _ index: Int, _ esize: Int) -> UInt64 {
        let bitPos = index * esize
        let word = bitPos < 64 ? src.0 : src.1
        let off = bitPos & 63
        return (word >> UInt64(off)) & laneMask(esize)
    }

    /// 写入第 index 个 esize 位元素。
    @inline(__always)
    static func laneSet(_ dst: inout (UInt64, UInt64), _ index: Int, _ esize: Int, _ value: UInt64) {
        let m = laneMask(esize)
        let bitPos = index * esize
        if bitPos < 64 {
            let off = UInt64(bitPos)
            dst.0 = (dst.0 & ~(m << off)) | ((value & m) << off)
        } else {
            let off = UInt64(bitPos - 64)
            dst.1 = (dst.1 & ~(m << off)) | ((value & m) << off)
        }
    }

    /// 按 esize 位宽做有符号扩展（用于比较/最值/算术右移）。
    @inline(__always)
    static func signExtend(_ value: UInt64, _ bits: Int) -> UInt64 {
        guard bits < 64 else { return value }
        let shift = UInt64(64 - bits)
        return UInt64(bitPattern: Int64(bitPattern: value << shift) >> shift)
    }

    /// 提交写回：Q = 0 时高 64 位清零。
    @inline(__always)
    static func writeBack(_ fpu: SDRArmFPU, _ rd: Int, _ value: (UInt64, UInt64), q: Bool) {
        fpu.v[rd] = value.0
        fpu.vh[rd] = q ? value.1 : 0
    }

    // MARK: - 三同（three same）

    private static func executeThreeSame(insn: UInt32, fpu: SDRArmFPU) -> Bool {
        let q = (insn >> 30) & 1 == 1
        let u = (insn >> 29) & 1 == 1
        let size = Int((insn >> 22) & 0x3)
        let rm = Int((insn >> 16) & 0x1F)
        let op = Int((insn >> 11) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        let esize = 8 << size
        let lanes = (q ? 128 : 64) / esize
        let n = (fpu.v[rn], fpu.vh[rn])
        let m = (fpu.v[rm], fpu.vh[rm])
        let dOld = (fpu.v[rd], fpu.vh[rd])
        var out: (UInt64, UInt64) = (0, 0)
        let full = laneMask(esize)

        switch (u, op) {
        case (false, 0b10000), (true, 0b10000):
            // ADD（U=0）/ SUB（U=1）
            for i in 0..<lanes {
                let a = laneGet(n, i, esize), b = laneGet(m, i, esize)
                laneSet(&out, i, esize, u ? (a &- b) : (a &+ b))
            }

        case (false, 0b10011):
            // MUL（U=0，无 64 位形式）
            guard size != 3 else { return false }
            for i in 0..<lanes {
                laneSet(&out, i, esize, laneGet(n, i, esize) &* laneGet(m, i, esize))
            }

        case (false, 0b00011), (true, 0b00011):
            // 逻辑族：由 (U, size) 选定具体指令，逐位作用于整字
            let variant = (u ? 4 : 0) + size
            var lo: UInt64 = 0, hi: UInt64 = 0
            switch variant {
            case 0: lo = n.0 & m.0; hi = n.1 & m.1                     // AND
            case 1: lo = n.0 & ~m.0; hi = n.1 & ~m.1                  // BIC
            case 2: lo = n.0 | m.0; hi = n.1 | m.1                    // ORR（含 MOV 别名）
            case 3: lo = n.0 | ~m.0; hi = n.1 | ~m.1                  // ORN
            case 4: lo = n.0 ^ m.0; hi = n.1 ^ m.1                    // EOR
            case 5: lo = (n.0 & dOld.0) | (m.0 & ~dOld.0)             // BSL
                    hi = (n.1 & dOld.1) | (m.1 & ~dOld.1)
            case 6: lo = (dOld.0 & ~m.0) | (n.0 & m.0)                // BIT：Vm 为 1 处取 Vn
                    hi = (dOld.1 & ~m.1) | (n.1 & m.1)
            default: lo = (dOld.0 & m.0) | (n.0 & ~m.0)               // BIF：Vm 为 0 处取 Vn
                     hi = (dOld.1 & m.1) | (n.1 & ~m.1)
            }
            out = (lo, hi)

        case (true, 0b10001):
            // CMEQ（寄存器）
            guard size != 3 else { return false }
            for i in 0..<lanes {
                laneSet(&out, i, esize, laneGet(n, i, esize) == laneGet(m, i, esize) ? full : 0)
            }

        case (false, 0b10001):
            // CMTST
            guard size != 3 else { return false }
            for i in 0..<lanes {
                laneSet(&out, i, esize, (laneGet(n, i, esize) & laneGet(m, i, esize)) != 0 ? full : 0)
            }

        case (false, 0b00110):
            // CMGT（有符号）
            guard size != 3 else { return false }
            for i in 0..<lanes {
                let a = signExtend(laneGet(n, i, esize), esize)
                let b = signExtend(laneGet(m, i, esize), esize)
                laneSet(&out, i, esize, Int64(bitPattern: a) > Int64(bitPattern: b) ? full : 0)
            }

        case (true, 0b00110):
            // CMHI（无符号）
            guard size != 3 else { return false }
            for i in 0..<lanes {
                laneSet(&out, i, esize, laneGet(n, i, esize) > laneGet(m, i, esize) ? full : 0)
            }

        case (false, 0b00111):
            // CMGE（有符号）
            guard size != 3 else { return false }
            for i in 0..<lanes {
                let a = signExtend(laneGet(n, i, esize), esize)
                let b = signExtend(laneGet(m, i, esize), esize)
                laneSet(&out, i, esize, Int64(bitPattern: a) >= Int64(bitPattern: b) ? full : 0)
            }

        case (true, 0b00111):
            // CMHS（无符号）
            guard size != 3 else { return false }
            for i in 0..<lanes {
                laneSet(&out, i, esize, laneGet(n, i, esize) >= laneGet(m, i, esize) ? full : 0)
            }

        case (false, 0b01000), (true, 0b01000):
            // SSHL（U=0，负位移为算术右移）/ USHL（U=1，负位移为逻辑右移）
            for i in 0..<lanes {
                let a = laneGet(n, i, esize)
                let amount = Int(Int8(truncatingIfNeeded: laneGet(m, i, esize)))
                let result: UInt64
                if amount >= 0 {
                    result = amount >= esize ? 0 : ((a << UInt64(amount)) & full)
                } else {
                    let s = -amount
                    if s >= esize {
                        result = u ? 0 : full       // 算术右移到顶：负数填 1
                    } else if u {
                        result = a >> UInt64(s)
                    } else {
                        result = signExtend(a >> UInt64(s), esize - s) & full
                    }
                }
                laneSet(&out, i, esize, result)
            }

        case (false, 0b01100):
            // SMAX
            for i in 0..<lanes {
                let a = laneGet(n, i, esize), b = laneGet(m, i, esize)
                laneSet(&out, i, esize,
                        Int64(bitPattern: signExtend(a, esize)) >= Int64(bitPattern: signExtend(b, esize)) ? a : b)
            }

        case (true, 0b01100):
            // UMAX
            for i in 0..<lanes {
                let a = laneGet(n, i, esize), b = laneGet(m, i, esize)
                laneSet(&out, i, esize, a >= b ? a : b)
            }

        case (false, 0b01101):
            // SMIN
            for i in 0..<lanes {
                let a = laneGet(n, i, esize), b = laneGet(m, i, esize)
                laneSet(&out, i, esize,
                        Int64(bitPattern: signExtend(a, esize)) <= Int64(bitPattern: signExtend(b, esize)) ? a : b)
            }

        case (true, 0b01101):
            // UMIN
            for i in 0..<lanes {
                let a = laneGet(n, i, esize), b = laneGet(m, i, esize)
                laneSet(&out, i, esize, a <= b ? a : b)
            }

        case (false, 0b10111):
            // ADDP：源内相邻元素两两相加，低半来自 Vn、高半来自 Vm
            let pairs = lanes / 2
            for i in 0..<pairs {
                laneSet(&out, i, esize,
                        laneGet(n, 2 * i, esize) &+ laneGet(n, 2 * i + 1, esize))
                laneSet(&out, pairs + i, esize,
                        laneGet(m, 2 * i, esize) &+ laneGet(m, 2 * i + 1, esize))
            }

        default:
            return false
        }

        writeBack(fpu, rd, out, q: q)
        return true
    }

    // MARK: - 二同 misc（two register miscellaneous）

    private static func executeTwoRegMisc(insn: UInt32, fpu: SDRArmFPU) -> Bool {
        let q = (insn >> 30) & 1 == 1
        let u = (insn >> 29) & 1 == 1
        let size = Int((insn >> 22) & 0x3)
        let op = Int((insn >> 12) & 0x1F)      // bits[16:12]
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        let esize = 8 << size
        let bits = esize                              // 元素位宽（非字节数）
        let lanes = (q ? 128 : 64) / esize
        let src = (fpu.v[rn], fpu.vh[rn])
        var out: (UInt64, UInt64) = (0, 0)

        switch (u, op) {
        case (false, 0b00000), (true, 0b00000), (false, 0b00001):
            // REV64（U=0,size=0/1/2）、REV32（U=1,size=0/1）、REV16（U=0,size=0）
            let container: Int
            if u {
                guard size <= 1 else { return false }
                container = 4                                  // REV32：容器 4 字节
            } else if op == 0b00001 {
                guard size == 0 else { return false }
                container = 2                                  // REV16：容器 2 字节
            } else {
                guard size <= 2 else { return false }
                container = 8                                  // REV64：容器 8 字节
            }
            let per = container * 8 / esize
            let containers = (q ? 16 : 8) / container
            for c in 0..<containers {
                for i in 0..<per {
                    laneSet(&out, c * per + (per - 1 - i), esize,
                            laneGet(src, c * per + i, esize))
                }
            }

        case (false, 0b00101):
            // CNT：按字节统计 1 的个数
            guard size == 0 else { return false }
            for i in 0..<(q ? 16 : 8) {
                laneSet(&out, i, 8, UInt64(laneGet(src, i, 8).nonzeroBitCount))
            }

        case (false, 0b00100):
            // CLS：esize 位内前导符号位数
            for i in 0..<lanes {
                let a = laneGet(src, i, esize)
                let sign = (a >> UInt64(bits - 1)) & 1
                var count = 0
                var idx = bits - 2
                while idx >= 0 {
                    if ((a >> UInt64(idx)) & 1) != sign { break }
                    count += 1
                    idx -= 1
                }
                laneSet(&out, i, esize, UInt64(count))
            }

        case (true, 0b00100):
            // CLZ：esize 位内前导零个数
            for i in 0..<lanes {
                let a = laneGet(src, i, esize)
                var count = 0
                var idx = bits - 1
                while idx >= 0 {
                    if ((a >> UInt64(idx)) & 1) == 1 { break }
                    count += 1
                    idx -= 1
                }
                laneSet(&out, i, esize, UInt64(count))
            }

        case (false, 0b01011):
            // ABS：按元素宽度回绕取绝对值
            for i in 0..<lanes {
                let a = laneGet(src, i, esize)
                let negative = (a & (UInt64(1) << UInt64(bits - 1))) != 0
                laneSet(&out, i, esize, negative ? ((~a &+ 1) & laneMask(esize)) : a)
            }

        case (true, 0b01011):
            // NEG
            for i in 0..<lanes {
                laneSet(&out, i, esize, 0 &- laneGet(src, i, esize))
            }

        case (true, 0b00101):
            // NOT（MVN）
            guard size == 0 else { return false }
            for i in 0..<(q ? 16 : 8) {
                laneSet(&out, i, 8, ~laneGet(src, i, 8) & 0xFF)
            }

        case (false, 0b10010):
            // XTN（Q=0）/ XTN2（Q=1）：窄化截断，源为完整 128 位向量
            guard size != 3 else { return false }
            let dstEsize = esize
            let srcEsize = esize * 2
            let dstLanes = 64 / dstEsize                    // 半宽结果恒为 64 位
            var half: (UInt64, UInt64) = (0, 0)
            for i in 0..<dstLanes {
                laneSet(&half, i, dstEsize, laneGet(src, i, srcEsize))
            }
            if q {
                out = (fpu.v[rd], half.0)                   // 写高半，低半保留
            } else {
                out = (half.0, 0)                           // 写低半，高半清零
            }
            fpu.v[rd] = out.0
            fpu.vh[rd] = out.1
            return true

        default:
            return false
        }

        writeBack(fpu, rd, out, q: q)
        return true
    }

    // MARK: - 移位立即数（shift by immediate）

    private static func executeShiftImmediate(insn: UInt32, fpu: SDRArmFPU) -> Bool {
        let q = (insn >> 30) & 1 == 1
        let u = (insn >> 29) & 1 == 1
        let immhimmb = Int((insn >> 16) & 0x7F)     // immh:immb
        let op = Int((insn >> 11) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        guard immhimmb >= 8 else { return false }   // immh 全 0 非法
        let esize = 8 << highestSetBit(immhimmb >> 3)
        guard esize <= 64 else { return false }
        let bits = esize                              // 元素位宽（非字节数）
        let src = (fpu.v[rn], fpu.vh[rn])
        let dstOld = (fpu.v[rd], fpu.vh[rd])
        var out: (UInt64, UInt64) = (0, 0)

        switch (u, op) {
        case (false, 0b01010), (true, 0b01010):
            // SHL（U=0）/ SLI（U=1）：左移，位移 = immh:immb - esize
            let shift = immhimmb - esize
            guard shift >= 0, shift < esize else { return false }
            for i in 0..<((q ? 128 : 64) / esize) {
                let a = laneGet(src, i, esize)
                let shifted = (a << UInt64(shift)) & laneMask(esize)
                if u {
                    // SLI：低 shift 位取自 Vd 原值
                    let kept = laneGet(dstOld, i, esize) & ((UInt64(1) << UInt64(shift)) - 1)
                    laneSet(&out, i, esize, kept | shifted)
                } else {
                    laneSet(&out, i, esize, shifted)
                }
            }

        case (false, 0b00000):
            // SSHR：算术右移，位移 = 2*esize - immh:immb
            let shift = 2 * esize - immhimmb
            guard shift >= 1, shift <= esize else { return false }
            let s = Int64(shift)
            for i in 0..<((q ? 128 : 64) / esize) {
                let a = Int64(bitPattern: signExtend(laneGet(src, i, esize), esize))
                laneSet(&out, i, esize, UInt64(bitPattern: a >> s))
            }

        case (true, 0b00000):
            // USHR：逻辑右移
            let shift = 2 * esize - immhimmb
            guard shift >= 1, shift <= esize else { return false }
            for i in 0..<((q ? 128 : 64) / esize) {
                laneSet(&out, i, esize, laneGet(src, i, esize) >> UInt64(shift))
            }

        case (false, 0b00010):
            // SSRA：算术右移后与 Vd 累加
            let shift = 2 * esize - immhimmb
            guard shift >= 1, shift <= esize else { return false }
            for i in 0..<((q ? 128 : 64) / esize) {
                let a = Int64(bitPattern: signExtend(laneGet(src, i, esize), esize)) >> Int64(shift)
                laneSet(&out, i, esize, laneGet(dstOld, i, esize) &+ UInt64(bitPattern: a))
            }

        case (true, 0b00010):
            // USRA：逻辑右移后与 Vd 累加
            let shift = 2 * esize - immhimmb
            guard shift >= 1, shift <= esize else { return false }
            for i in 0..<((q ? 128 : 64) / esize) {
                let a = laneGet(src, i, esize) >> UInt64(shift)
                laneSet(&out, i, esize, laneGet(dstOld, i, esize) &+ a)
            }

        case (true, 0b01000):
            // SRI：右移结果写入低 (esize-shift) 位，高 shift 位保留 Vd 原值
            let shift = 2 * esize - immhimmb
            guard shift >= 1, shift <= esize else { return false }
            for i in 0..<((q ? 128 : 64) / esize) {
                let a = laneGet(src, i, esize) >> UInt64(shift)
                let kept = laneGet(dstOld, i, esize) & ~laneMask(esize - shift)
                laneSet(&out, i, esize, a | kept)
            }

        case (false, 0b10000), (false, 0b10001):
            // SHRN（op=10000）/ RSHRN（op=10001）：源元素宽 2*esize，窄化到 esize
            let shift = 2 * esize - immhimmb
            guard shift >= 1, shift <= esize else { return false }
            let rounding = op == 0b10001
            let dstLanes = 64 / esize
            var half: (UInt64, UInt64) = (0, 0)
            for i in 0..<dstLanes {
                let srcWord = signExtend(laneGet(src, i, esize * 2), bits * 2)
                var narrowed = srcWord >> UInt64(shift)
                if rounding {
                    // RSHRN：先加舍入常数 1 << (shift-1) 再右移
                    narrowed = (srcWord &+ (UInt64(1) << UInt64(shift - 1))) >> UInt64(shift)
                }
                laneSet(&half, i, esize, narrowed)
            }
            if q {
                fpu.v[rd] = dstOld.0
                fpu.vh[rd] = half.0
            } else {
                fpu.v[rd] = half.0
                fpu.vh[rd] = 0
            }
            return true

        case (false, 0b10100), (true, 0b10100):
            // SSHLL（U=0）/ USHLL（U=1）：源元素宽 esize，扩展到 2*esize
            let shift = immhimmb - esize
            guard shift >= 0, shift < esize else { return false }
            let dstEsize = esize * 2
            let srcPerHalf = 64 / esize                 // 源半宽为 64 位
            var wide: (UInt64, UInt64) = (0, 0)
            for i in 0..<srcPerHalf {
                let srcIndex = q ? (srcPerHalf + i) : i
                let a = laneGet(src, srcIndex, esize)
                let extended = u ? a : signExtend(a, esize)
                laneSet(&wide, i, dstEsize, (extended << UInt64(shift)) & laneMask(dstEsize))
            }
            fpu.v[rd] = wide.0                          // 结果恒为 128 位
            fpu.vh[rd] = wide.1
            return true

        default:
            return false
        }

        writeBack(fpu, rd, out, q: q)
        return true
    }

    // MARK: - 搬移（copy：DUP / INS）

    private static func executeCopy(insn: UInt32, context: SDRCpuContext, fpu: SDRArmFPU) -> Bool {
        let q = (insn >> 30) & 1 == 1
        let bit29 = (insn >> 29) & 1
        let imm5 = Int((insn >> 16) & 0x1F)
        let imm4 = Int((insn >> 11) & 0xF)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        guard imm5 != 0 else { return false }
        let lowBit = lowestSetBit(imm5)
        let esize = 8 << lowBit
        guard esize <= 64 else { return false }
        let index = imm5 >> (lowBit + 1)
        let lanes = (q ? 128 : 64) / esize
        let bit15 = (insn >> 15) & 1

        // 实测反查：搬移组内 INS(element) 的 bits[14:11] 承载 imm4 源索引，
        // 故 U=1 时 bits[15:11] 不固定（d/s/h/b 各不相同），必须先用 bit29 分流：
        //   U=1 且 bit15=0 → INS(element)
        //   U=0 且 bits[15:11] = 00000 / 00001 / 00011 → DUP(element)/DUP(general)/INS(general)
        if bit29 == 1 {
            guard bit15 == 0 else { return false }
            let srcIndex = imm4 >> lowBit
            guard srcIndex < (128 / esize), index < (128 / esize) else { return false }
            var out: (UInt64, UInt64) = (fpu.v[rd], fpu.vh[rd])
            laneSet(&out, index, esize, laneGet((fpu.v[rn], fpu.vh[rn]), srcIndex, esize))
            fpu.v[rd] = out.0
            fpu.vh[rd] = out.1
            return true
        }

        switch Int((insn >> 11) & 0x1F) {
        case 0b00000:
            // DUP（元素）：取 Vn 第 index 个元素填满 Vd
            guard index < (128 / esize) else { return false }
            let value = laneGet((fpu.v[rn], fpu.vh[rn]), index, esize)
            var out: (UInt64, UInt64) = (0, 0)
            for i in 0..<lanes { laneSet(&out, i, esize, value) }
            writeBack(fpu, rd, out, q: q)
            return true

        case 0b00001:
            // DUP（通用寄存器）：取 Xn/Wn 低 esize 位填满 Vd
            let value = context.x[rn] & laneMask(esize)
            var out: (UInt64, UInt64) = (0, 0)
            for i in 0..<lanes { laneSet(&out, i, esize, value) }
            writeBack(fpu, rd, out, q: q)
            return true

        case 0b00011:
            // INS（通用寄存器）：源为 Xn/Wn 低位，只改 Vd 单个元素
            guard index < (128 / esize) else { return false }
            var out: (UInt64, UInt64) = (fpu.v[rd], fpu.vh[rd])
            laneSet(&out, index, esize, context.x[rn] & laneMask(esize))
            fpu.v[rd] = out.0
            fpu.vh[rd] = out.1
            return true

        default:
            return false
        }
    }

    // MARK: - 位工具

    @inline(__always)
    static func lowestSetBit(_ value: Int) -> Int {
        var v = value
        var n = 0
        while v & 1 == 0 {
            v >>= 1
            n += 1
        }
        return n
    }

    @inline(__always)
    static func highestSetBit(_ value: Int) -> Int {
        var n = -1
        var v = value
        while v != 0 {
            v >>= 1
            n += 1
        }
        return n
    }
}
