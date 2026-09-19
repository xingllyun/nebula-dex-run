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
            // bit10 = 1 → 移位立即数；bit10 = 0 → 按元素（by element）
            return (insn >> 10) & 1 == 1
                ? executeShiftImmediate(insn: insn, fpu: fpu)
                : executeByElement(insn: insn, fpu: fpu)
        }
        // 标量 pairwise 族（FADDP/FMAXP/FMINP/FMAXNMP/FMINNMP 的 2S / 2D 形式）
        if top == 0b11110 {
            return executeScalarPairwise(insn: insn, fpu: fpu)
        }
        guard top == 0b01110 else { return false }

        let b21 = (insn >> 21) & 1
        let b11 = (insn >> 11) & 1
        let b10 = (insn >> 10) & 1

        if b21 == 1, b10 == 1 {
            return executeThreeSame(insn: insn, fpu: fpu)
        }
        // 跨通道归约（across lanes）：bits[20] = 1 区分于二同 misc
        if b21 == 1, b10 == 0, (insn >> 20) & 1 == 1 {
            return executeAcrossLanes(insn: insn, fpu: fpu)
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

        // op ≥ 0b11000 属浮点三同族（整数三同 opcode 上界为 0b10111）
        if op >= 0b11000 {
            return executeThreeSameFP(insn: insn, fpu: fpu)
        }

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

    // MARK: - 浮点工具

    /// 读取第 index 个浮点元素（sz = false → 单精度，true → 双精度）。
    @inline(__always)
    static func fpGet(_ src: (UInt64, UInt64), _ index: Int, sz: Bool) -> Double {
        if sz { return Double(bitPattern: laneGet(src, index, 64)) }
        return Double(Float(bitPattern: UInt32(truncatingIfNeeded: laneGet(src, index, 32))))
    }

    /// 写入第 index 个浮点元素（按 sz 截断到对应位宽）。
    @inline(__always)
    static func fpSet(_ dst: inout (UInt64, UInt64), _ index: Int, sz: Bool, _ value: Double) {
        if sz {
            laneSet(&dst, index, 64, value.bitPattern)
        } else {
            laneSet(&dst, index, 32, UInt64(Float(value).bitPattern))
        }
    }

    /// 比较类结果的全 1 掩码。
    @inline(__always)
    static func fpMask(_ sz: Bool) -> UInt64 { sz ? ~0 : 0xFFFF_FFFF }

    /// 默认 NaN（FMAX/FMIN 双侧 NaN 语义）。
    @inline(__always)
    static func fpDefaultNaN(_ sz: Bool) -> Double {
        sz ? Double(bitPattern: UInt64(0x7FF8_0000_0000_0000))
           : Double(Float(bitPattern: 0x7FC0_0000))
    }

    /// FMAX/FMIN/FMAXP/FMINP/FMAXV/FMINV 共用的 NaN 传播语义：
    /// 任一侧为 NaN 即原样传播该 NaN（可由 Double(Float) 转换自动完成 quiet 化）。
    @inline(__always)
    static func fpPropagate(_ a: Double, _ b: Double, max wantMax: Bool) -> Double {
        if a.isNaN { return a }
        if b.isNaN { return b }
        return wantMax ? Swift.max(a, b) : Swift.min(a, b)
    }

    /// FMAXNM/FMINNM/FMAXNMP/FMINNMP/FMAXNMV/FMINNMV 共用 NaN 语义：单侧 NaN 取另一侧，双侧 NaN 取默认 NaN。
    @inline(__always)
    static func fpPick(_ a: Double, _ b: Double, sz: Bool, max wantMax: Bool) -> Double {
        if a.isNaN || b.isNaN {
            if a.isNaN && b.isNaN { return fpDefaultNaN(sz) }
            return a.isNaN ? b : a
        }
        return wantMax ? Swift.max(a, b) : Swift.min(a, b)
    }

    // MARK: - 浮点三同（three same FP）与 pairwise

    /// 覆盖 AArch64 高级 SIMD 浮点三同族（按 (U, bits[23], op) 精确匹配）：
    ///   FADD/FSUB/FMUL/FDIV/FMAX/FMIN/FMAXNM/FMINNM/FABD/FMLA/FMLS/
    ///   FCMEQ/FCMGE/FCMGT/FACGE/FACGT/FRECPS/FRSQRTS，
    ///   以及 pairwise 形式 FADDP/FMAXP/FMINP/FMAXNMP/FMINNMP（U = 1 变体）。
    /// sz = bits[22]：0 = 单精度（2S / 4S），1 = 双精度（1D / 2D）。
    /// 位域依据 clang 交叉汇编 + llvm-objdump 反查真实机器码
    /// （fadd/fsub/fmul/fdiv/fmax/fmin/fmaxnm/fminnm/fabd/fmla/fmls/fcmeq/fcmge/fcmgt/
    ///   facge/facgt/frecps/frsqrts/faddp/fmaxp/fminp）。
    private static func executeThreeSameFP(insn: UInt32, fpu: SDRArmFPU) -> Bool {
        let q = (insn >> 30) & 1 == 1
        let u = (insn >> 29) & 1 == 1
        let b23 = (insn >> 23) & 1 == 1
        let sz = (insn >> 22) & 1 == 1
        let rm = Int((insn >> 16) & 0x1F)
        let op = Int((insn >> 11) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        let esize = sz ? 64 : 32
        let lanes = (q ? 128 : 64) / esize
        let n = (fpu.v[rn], fpu.vh[rn])
        let m = (fpu.v[rm], fpu.vh[rm])
        let dOld = (fpu.v[rd], fpu.vh[rd])
        var out: (UInt64, UInt64) = (0, 0)
        let mask = fpMask(sz)

        /// pairwise 折叠：低半 = Vn 相邻元素对，高半 = Vm 相邻元素对。
        func pairwise(_ combine: (Double, Double) -> Double) {
            for i in 0..<(lanes / 2) {
                fpSet(&out, i, sz: sz, combine(fpGet(n, 2 * i, sz: sz), fpGet(n, 2 * i + 1, sz: sz)))
                fpSet(&out, lanes / 2 + i, sz: sz,
                      combine(fpGet(m, 2 * i, sz: sz), fpGet(m, 2 * i + 1, sz: sz)))
            }
        }

        switch (u, b23, op) {
        case (false, false, 0b11010):                                   // FADD
            for i in 0..<lanes { fpSet(&out, i, sz: sz, fpGet(n, i, sz: sz) + fpGet(m, i, sz: sz)) }
        case (false, true, 0b11010):                                    // FSUB
            for i in 0..<lanes { fpSet(&out, i, sz: sz, fpGet(n, i, sz: sz) - fpGet(m, i, sz: sz)) }
        case (true, true, 0b11010):                                     // FABD
            for i in 0..<lanes { fpSet(&out, i, sz: sz, abs(fpGet(n, i, sz: sz) - fpGet(m, i, sz: sz))) }
        case (true, false, 0b11010):                                    // FADDP
            pairwise { $0 + $1 }
        case (true, false, 0b11011):                                    // FMUL
            for i in 0..<lanes { fpSet(&out, i, sz: sz, fpGet(n, i, sz: sz) * fpGet(m, i, sz: sz)) }
        case (false, false, 0b11000):                                   // FMAXNM
            for i in 0..<lanes {
                fpSet(&out, i, sz: sz, fpPick(fpGet(n, i, sz: sz), fpGet(m, i, sz: sz), sz: sz, max: true))
            }
        case (false, true, 0b11000):                                    // FMINNM
            for i in 0..<lanes {
                fpSet(&out, i, sz: sz, fpPick(fpGet(n, i, sz: sz), fpGet(m, i, sz: sz), sz: sz, max: false))
            }
        case (true, false, 0b11000):                                    // FMAXNMP
            pairwise { fpPick($0, $1, sz: sz, max: true) }
        case (true, true, 0b11000):                                     // FMINNMP
            pairwise { fpPick($0, $1, sz: sz, max: false) }
        case (false, false, 0b11001):                                   // FMLA
            for i in 0..<lanes {
                fpSet(&out, i, sz: sz, fpGet(dOld, i, sz: sz) + fpGet(n, i, sz: sz) * fpGet(m, i, sz: sz))
            }
        case (false, true, 0b11001):                                    // FMLS
            for i in 0..<lanes {
                fpSet(&out, i, sz: sz, fpGet(dOld, i, sz: sz) - fpGet(n, i, sz: sz) * fpGet(m, i, sz: sz))
            }
        case (false, false, 0b11110):                                   // FMAX（NaN 传播）
            for i in 0..<lanes {
                fpSet(&out, i, sz: sz, fpPropagate(fpGet(n, i, sz: sz), fpGet(m, i, sz: sz), max: true))
            }
        case (false, true, 0b11110):                                    // FMIN（NaN 传播）
            for i in 0..<lanes {
                fpSet(&out, i, sz: sz, fpPropagate(fpGet(n, i, sz: sz), fpGet(m, i, sz: sz), max: false))
            }
        case (true, false, 0b11110):                                    // FMAXP（NaN 传播）
            pairwise { fpPropagate($0, $1, max: true) }
        case (true, true, 0b11110):                                     // FMINP（NaN 传播）
            pairwise { fpPropagate($0, $1, max: false) }
        case (false, false, 0b11100):                                   // FCMEQ
            for i in 0..<lanes {
                laneSet(&out, i, esize, fpGet(n, i, sz: sz) == fpGet(m, i, sz: sz) ? mask : 0)
            }
        case (true, false, 0b11100):                                    // FCMGE
            for i in 0..<lanes {
                laneSet(&out, i, esize, fpGet(n, i, sz: sz) >= fpGet(m, i, sz: sz) ? mask : 0)
            }
        case (true, true, 0b11100):                                     // FCMGT
            for i in 0..<lanes {
                laneSet(&out, i, esize, fpGet(n, i, sz: sz) > fpGet(m, i, sz: sz) ? mask : 0)
            }
        case (true, false, 0b11101):                                    // FACGE
            for i in 0..<lanes {
                laneSet(&out, i, esize, abs(fpGet(n, i, sz: sz)) >= abs(fpGet(m, i, sz: sz)) ? mask : 0)
            }
        case (true, true, 0b11101):                                     // FACGT
            for i in 0..<lanes {
                laneSet(&out, i, esize, abs(fpGet(n, i, sz: sz)) > abs(fpGet(m, i, sz: sz)) ? mask : 0)
            }
        case (false, false, 0b11111):                                   // FRECPS：2 - n*m
            for i in 0..<lanes {
                fpSet(&out, i, sz: sz, 2 - fpGet(n, i, sz: sz) * fpGet(m, i, sz: sz))
            }
        case (false, true, 0b11111):                                    // FRSQRTS：(3 - n*m)/2
            for i in 0..<lanes {
                fpSet(&out, i, sz: sz, (3 - fpGet(n, i, sz: sz) * fpGet(m, i, sz: sz)) / 2)
            }
        case (true, false, 0b11111):                                    // FDIV
            for i in 0..<lanes { fpSet(&out, i, sz: sz, fpGet(n, i, sz: sz) / fpGet(m, i, sz: sz)) }
        default:
            return false
        }
        writeBack(fpu, rd, out, q: q)
        return true
    }

    // MARK: - 跨通道归约（across lanes）

    /// 覆盖 AArch64 高级 SIMD 归约族（bits[20:16] = 10000 / 10001，bit10 = 0，Q = 1）：
    ///   整数 ADDV / SMAXV / SMINV / UMAXV / UMINV（元素 8 / 16 / 32 位），
    ///   浮点 FMAXV / FMINV / FMAXNMV / FMINNMV（bits[23] 区分 MAX 与 MIN 对偶）。
    /// 位域依据 clang 交叉汇编 + llvm-objdump 反查真实机器码
    /// （addv/smaxv/sminv/umaxv/uminv/fmaxv/fminv/fmaxnmv/fminnmv）。
    private static func executeAcrossLanes(insn: UInt32, fpu: SDRArmFPU) -> Bool {
        guard (insn >> 30) & 1 == 1 else { return false }   // 归约族只有 Q = 1 形式
        let u = (insn >> 29) & 1 == 1
        let b23 = (insn >> 23) & 1 == 1
        let size = Int((insn >> 22) & 0x3)
        let field = Int((insn >> 16) & 0x1F)
        let op = Int((insn >> 11) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        let src = (fpu.v[rn], fpu.vh[rn])
        var result: UInt64

        if !u, op == 0b10111, field == 0b10001, size <= 2 {
            // ADDV
            let esize = 8 << size
            var acc: UInt64 = 0
            for i in 0..<(128 / esize) { acc = acc &+ laneGet(src, i, esize) }
            result = acc & laneMask(esize)
        } else if !u, op == 0b10101, field == 0b10000 || field == 0b10001, size <= 2 {
            // SMAXV（field = 10000）/ SMINV（field = 10001）
            let esize = 8 << size
            let wantMax = field == 0b10000
            var acc = laneGet(src, 0, esize)
            for i in 1..<(128 / esize) {
                let cur = laneGet(src, i, esize)
                let better = wantMax
                    ? Int64(bitPattern: signExtend(cur, esize)) > Int64(bitPattern: signExtend(acc, esize))
                    : Int64(bitPattern: signExtend(cur, esize)) < Int64(bitPattern: signExtend(acc, esize))
                if better { acc = cur }
            }
            result = acc
        } else if u, op == 0b10101, field == 0b10000 || field == 0b10001, size <= 2 {
            // UMAXV（field = 10000）/ UMINV（field = 10001）
            let esize = 8 << size
            let wantMax = field == 0b10000
            var acc = laneGet(src, 0, esize)
            for i in 1..<(128 / esize) {
                let cur = laneGet(src, i, esize)
                if (wantMax && cur > acc) || (!wantMax && cur < acc) { acc = cur }
            }
            result = acc
        } else if u, field == 0b10000, op == 0b11111 || op == 0b11001, (insn >> 22) & 1 == 0 {
            // FMAXV / FMINV（op = 11111，NaN 传播）、FMAXNMV / FMINNMV（op = 11001，NaN 忽略）；b23 = 0 → MAX 侧。
            // 元素固定 32 位（4S）：2D 形式不存在，16 位（FP16）变体暂不覆盖，编码不符即回退未实现。
            let wantMax = !b23
            let propagate = op == 0b11111
            var acc = fpGet(src, 0, sz: false)
            for i in 1..<4 {
                let cur = fpGet(src, i, sz: false)
                acc = propagate ? fpPropagate(acc, cur, max: wantMax)
                                : fpPick(acc, cur, sz: false, max: wantMax)
            }
            result = UInt64(Float(acc).bitPattern)
        } else {
            return false
        }

        fpu.v[rd] = result
        fpu.vh[rd] = 0
        return true
    }

    // MARK: - 标量 pairwise（scalar pairwise）

    /// 覆盖 AArch64 高级 SIMD 标量 pairwise 族（bits[28:24] = 11110，bits[20:16] = 11000，bit10 = 0）：
    ///   FADDP / FMAXP / FMINP / FMAXNMP / FMINNMP（2S / 2D 形式）。
    /// 位域依据 clang 交叉汇编 + llvm-objdump 反查真实机器码（faddp/fmaxp/fminp/fmaxnmp/fminnmp）。
    private static func executeScalarPairwise(insn: UInt32, fpu: SDRArmFPU) -> Bool {
        guard (insn >> 30) & 1 == 1, (insn >> 29) & 1 == 1,
              ((insn >> 16) & 0x1F) == 0b10000,
              (insn >> 10) & 1 == 0 else { return false }

        let b23 = (insn >> 23) & 1 == 1
        let sz = (insn >> 22) & 1 == 1
        let op = Int((insn >> 11) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let src = (fpu.v[rn], fpu.vh[rn])
        let a = fpGet(src, 0, sz: sz)
        let b = fpGet(src, 1, sz: sz)

        let value: Double
        switch op {
        case 0b11011: value = a + b                                          // FADDP
        case 0b11111: value = fpPropagate(a, b, max: !b23)                   // FMAXP / FMINP（NaN 传播）
        case 0b11001: value = fpPick(a, b, sz: sz, max: !b23)                // FMAXNMP / FMINNMP（NaN 忽略）
        default: return false
        }

        fpu.v[rd] = sz ? value.bitPattern : UInt64(Float(value).bitPattern)
        fpu.vh[rd] = 0
        return true
    }

    // MARK: - 按元素（by element）

    /// 覆盖 AArch64 高级 SIMD 按元素族（bits[28:24] = 01111，bit10 = 0）：
    ///   浮点 FMUL / FMLA / FMLS、整数 MUL / MLA / MLS。
    /// 元素索引：16 位 = H:L:M，32 位 = H:L，64 位 = H。
    /// 位域依据 clang 交叉汇编 + llvm-objdump 反查真实机器码（fmul/fmla/fmls/mul/mla/mls）。
    private static func executeByElement(insn: UInt32, fpu: SDRArmFPU) -> Bool {
        let q = (insn >> 30) & 1 == 1
        let u = (insn >> 29) & 1 == 1
        let size = Int((insn >> 22) & 0x3)
        let l = (insn >> 21) & 1 == 1
        let mBit = (insn >> 20) & 1 == 1
        let opcode = Int((insn >> 12) & 0xF)
        let h = (insn >> 11) & 1 == 1
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        let esize = 8 << size
        guard esize >= 16 else { return false }              // 8 位无按元素形式
        // 16 位形式的 bit20 被借作索引 M 位，寄存器号退化为 4 位 [19:16]。
        let rm = esize == 16 ? Int((insn >> 16) & 0xF) : Int((insn >> 16) & 0x1F)
        let lanes = (q ? 128 : 64) / esize
        let index: Int
        switch esize {
        case 16: index = (h ? 4 : 0) | (l ? 2 : 0) | (mBit ? 1 : 0)
        case 32: index = (h ? 2 : 0) | (l ? 1 : 0)
        default: index = h ? 1 : 0
        }
        guard index < lanes else { return false }

        let n = (fpu.v[rn], fpu.vh[rn])
        let dOld = (fpu.v[rd], fpu.vh[rd])
        let elem = laneGet((fpu.v[rm], fpu.vh[rm]), index, esize)
        var out: (UInt64, UInt64) = (0, 0)
        let full = laneMask(esize)

        switch (u, opcode) {
        case (false, 0b1000):
            // MUL（16 / 32 位）
            guard esize != 64 else { return false }
            for i in 0..<lanes { laneSet(&out, i, esize, (laneGet(n, i, esize) &* elem) & full) }
        case (true, 0b0000), (true, 0b0100):
            // MLA（0000）/ MLS（0100），均仅 16 / 32 位
            guard esize != 64 else { return false }
            let isAdd = opcode == 0b0000
            for i in 0..<lanes {
                let product = (laneGet(n, i, esize) &* elem) & full
                let base = laneGet(dOld, i, esize)
                laneSet(&out, i, esize, isAdd ? (base &+ product) & full : (base &- product) & full)
            }
        case (false, 0b1001), (false, 0b0001), (false, 0b0101):
            // FMUL（1001）/ FMLA（0001）/ FMLS（0101），仅 32 / 64 位
            guard esize == 32 || esize == 64 else { return false }
            let sz = esize == 64
            let e = fpGet((fpu.v[rm], fpu.vh[rm]), index, sz: sz)
            for i in 0..<lanes {
                let nv = fpGet(n, i, sz: sz)
                let value: Double
                switch opcode {
                case 0b1001: value = nv * e
                case 0b0001: value = fpGet(dOld, i, sz: sz) + nv * e
                default: value = fpGet(dOld, i, sz: sz) - nv * e
                }
                fpSet(&out, i, sz: sz, value)
            }
        default:
            return false
        }
        writeBack(fpu, rd, out, q: q)
        return true
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
