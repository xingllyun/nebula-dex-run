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

/// AArch64 标量浮点单元（FP/SIMD 子集）
///
/// 覆盖 Android arm64-v8a 原生库中常见的标量浮点通路：
/// 加减乘除、最值、绝对值/取负/开方、比较（写 NZCV）、
/// 整数与浮点互转、浮点寄存器与通用寄存器互传、浮点立即数。
///
/// 编码依据 bits[28:24] = 11110 的标量浮点格式，按
/// `(bits[20:16], bits[15:10])` 组合分派；向量（Advanced SIMD）
/// 指令不在本单元范围内，返回 false 交由解释器记录。
public final class SDRArmFPU {

    /// 32 个 128 位向量寄存器的低 64 位视图（S/D 标量共用）
    public var v = [UInt64](repeating: 0, count: 32)
    /// 高 64 位视图（为后续 NEON 向量指令预留，标量路径不使用）
    public var vh = [UInt64](repeating: 0, count: 32)

    public init() {}

    public func reset() {
        for i in 0..<32 {
            v[i] = 0
            vh[i] = 0
        }
    }

    // MARK: - 标量寄存器读写

    @inline(__always)
    public func readS(_ index: Int) -> Float {
        Float(bitPattern: UInt32(truncatingIfNeeded: v[index]))
    }

    @inline(__always)
    public func writeS(_ index: Int, _ value: Float) {
        v[index] = UInt64(value.bitPattern)
    }

    @inline(__always)
    public func readD(_ index: Int) -> Double {
        Double(bitPattern: v[index])
    }

    @inline(__always)
    public func writeD(_ index: Int, _ value: Double) {
        v[index] = value.bitPattern
    }

    // MARK: - 指令执行

    /// 尝试执行一条标量浮点指令。
    /// - Returns: true 表示已执行；false 表示本单元未覆盖，交由解释器处理。
    public func execute(insn: UInt32, context: SDRCpuContext) -> Bool {
        guard (insn & 0x1F00_0000) == 0x1E00_0000 else { return false }

        let type = (insn >> 22) & 0x3
        guard type == 0b00 || type == 0b01 else { return false }   // 00=单精度 01=双精度
        let isDouble = type == 0b01
        let sf = (insn >> 31) & 1
        let vd = Int(insn & 0x1F)
        let vn = Int((insn >> 5) & 0x1F)
        let vm = Int((insn >> 16) & 0x1F)
        let op6 = (insn >> 10) & 0x3F
        let op5 = (insn >> 16) & 0x1F

        switch op6 {
        case 0b001000:
            // FCMP / FCMPE（bit3..0 = 1000 时与 0.0 比较）
            let compareWithZero = (insn & 0xF) == 0b1000
            let a = isDouble ? readD(vn) : Double(readS(vn))
            let b: Double = compareWithZero ? 0 : (isDouble ? readD(vm) : Double(readS(vm)))
            writeCompareFlags(context, a: a, b: b)
            return true

        case 0b000010:   // FMUL
            arith(isDouble, vd, vn, vm, { $0 * $1 }, { $0 * $1 })
            return true
        case 0b000110:   // FDIV
            arith(isDouble, vd, vn, vm, { $0 / $1 }, { $0 / $1 })
            return true
        case 0b001010:   // FADD
            arith(isDouble, vd, vn, vm, { $0 + $1 }, { $0 + $1 })
            return true
        case 0b001110:   // FSUB
            arith(isDouble, vd, vn, vm, { $0 - $1 }, { $0 - $1 })
            return true
        case 0b010010:   // FMAX
            arith(isDouble, vd, vn, vm, { SDRFPLogic.fmaxS($0, $1) }, { SDRFPLogic.fmaxD($0, $1) })
            return true
        case 0b010110:   // FMIN
            arith(isDouble, vd, vn, vm, { SDRFPLogic.fminS($0, $1) }, { SDRFPLogic.fminD($0, $1) })
            return true
        case 0b011010:   // FMAXNM
            arith(isDouble, vd, vn, vm, { SDRFPLogic.fmaxnmS($0, $1) }, { SDRFPLogic.fmaxnmD($0, $1) })
            return true
        case 0b011110:   // FMINNM
            arith(isDouble, vd, vn, vm, { SDRFPLogic.fminnmS($0, $1) }, { SDRFPLogic.fminnmD($0, $1) })
            return true

        default:
            return executeUnary(insn, context: context, isDouble: isDouble,
                                sf: sf, vd: vd, vn: vn, vm: vm, op5: op5, op6: op6)
        }
    }

    // MARK: - 一元 / 转换 / 传输

    private func executeUnary(_ insn: UInt32, context: SDRCpuContext, isDouble: Bool,
                              sf: UInt32, vd: Int, vn: Int, vm: Int,
                              op5: UInt32, op6: UInt32) -> Bool {
        // FMOV（浮点立即数）: bits[12:10] = 100
        if ((insn >> 10) & 0x7) == 0b100 {
            let imm8 = UInt32((insn >> 13) & 0xFF)
            let bits = SDRFPLogic.expandFPImm8(imm8, isDouble: isDouble)
            if isDouble { writeD(vd, Double(bitPattern: bits)) }
            else { writeS(vd, Float(bitPattern: UInt32(truncatingIfNeeded: bits))) }
            return true
        }

        switch (op5, op6) {
        case (0b00000, 0b000000):   // FMOV 寄存器搬移（同精度）
            if isDouble { writeD(vd, readD(vn)) } else { writeS(vd, readS(vn)) }
            return true

        case (0b00000, 0b110000):   // FABS
            if isDouble { writeD(vd, Double(bitPattern: v[vn] & 0x7FFF_FFFF_FFFF_FFFF)) }
            else { writeS(vd, Float(bitPattern: UInt32(truncatingIfNeeded: v[vn]) & 0x7FFF_FFFF)) }
            return true

        case (0b00001, 0b010000):   // FNEG
            if isDouble { writeD(vd, Double(bitPattern: v[vn] ^ 0x8000_0000_0000_0000)) }
            else { writeS(vd, Float(bitPattern: UInt32(truncatingIfNeeded: v[vn]) ^ 0x8000_0000)) }
            return true

        case (0b00001, 0b110000):   // FSQRT
            if isDouble { writeD(vd, readD(vn).squareRoot()) } else { writeS(vd, readS(vn).squareRoot()) }
            return true

        case (0b00010, 0b000000):   // SCVTF（有符号整数 → 浮点）
            let raw = gp(context, vn, sf: sf)
            if isDouble { writeD(vd, Double(Int64(bitPattern: raw))) }
            else { writeS(vd, Float(Int64(bitPattern: raw))) }
            return true

        case (0b00011, 0b000000):   // UCVTF（无符号整数 → 浮点）
            let raw = gp(context, vn, sf: sf)
            if isDouble { writeD(vd, Double(raw)) }
            else { writeS(vd, Float(raw)) }
            return true

        case (0b11000, 0b000000):   // FCVTZS（浮点 → 有符号整数，向零取整）
            let value = SDRFPLogic.toSignedInt(isDouble ? readD(vn) : Double(readS(vn)),
                                               is64: sf == 1)
            if sf == 1 { writeGp(context, vd, value) } else { writeGp(context, vd, value & 0xFFFF_FFFF) }
            return true

        case (0b11001, 0b000000):   // FCVTZU（浮点 → 无符号整数，向零取整）
            let value = SDRFPLogic.toUnsignedInt(isDouble ? readD(vn) : Double(readS(vn)),
                                                 is64: sf == 1)
            if sf == 1 { writeGp(context, vd, value) } else { writeGp(context, vd, value & 0xFFFF_FFFF) }
            return true

        case (0b00110, 0b000000):   // FMOV（浮点 → 通用寄存器）
            let raw = v[vn]
            if sf == 1 { writeGp(context, vd, isDouble ? raw : 0) }
            else { writeGp(context, vd, raw & 0xFFFF_FFFF) }
            return true

        case (0b00111, 0b000000):   // FMOV（通用寄存器 → 浮点）
            let raw = gp(context, vn, sf: sf)
            if isDouble { writeD(vd, Double(bitPattern: sf == 1 ? raw : raw & 0xFFFF_FFFF)) }
            else { writeS(vd, Float(bitPattern: UInt32(truncatingIfNeeded: raw))) }
            return true

        case (0b00010, 0b110000):   // FCVT（单精度 → 双精度）
            guard !isDouble else { return false }
            writeD(vd, Double(readS(vn)))
            return true

        case (0b00010, 0b010000):   // FCVT（双精度 → 单精度）
            guard isDouble else { return false }
            writeS(vd, Float(readD(vn)))
            return true

        default:
            _ = vm
            return false
        }
    }

    // MARK: - 内部工具

    private func arith(_ isDouble: Bool, _ vd: Int, _ vn: Int, _ vm: Int,
                       _ op32: (Float, Float) -> Float,
                       _ op64: (Double, Double) -> Double) {
        if isDouble { writeD(vd, op64(readD(vn), readD(vm))) }
        else { writeS(vd, op32(readS(vn), readS(vm))) }
    }

    /// 浮点比较写 NZCV：N=bit3 Z=bit2 C=bit1 V=bit0
    /// 无序 → N=0 Z=0 C=1 V=1；小于 → N=1；相等 → Z=1 C=1；大于 → C=1
    private func writeCompareFlags(_ context: SDRCpuContext, a: Double, b: Double) {
        if a.isNaN || b.isNaN {
            context.nzcv = 0b0011
        } else if a < b {
            context.nzcv = 0b1000
        } else if a == b {
            context.nzcv = 0b0110
        } else {
            context.nzcv = 0b0010
        }
    }

    private func gp(_ context: SDRCpuContext, _ index: Int, sf: UInt32) -> UInt64 {
        let raw = context.x[index]
        return sf == 1 ? raw : (raw & 0xFFFF_FFFF)
    }

    private func writeGp(_ context: SDRCpuContext, _ index: Int, _ value: UInt64) {
        if index == 31 { return }   // XZR
        context.x[index] = value
    }
}

// MARK: - 浮点运算语义

/// IEEE-754 语义辅助（NaN / ±0 处理与 ARM 标量指令一致）
public enum SDRFPLogic {

    public static func fmaxS(_ a: Float, _ b: Float) -> Float {
        if a.isNaN { return b.isNaN ? Float.nan : b }
        if b.isNaN { return a }
        if a > b { return a }
        if b > a { return b }
        if a == 0 && b == 0 { return min(a, b) }   // +0 优先
        return a
    }

    public static func fminS(_ a: Float, _ b: Float) -> Float {
        if a.isNaN { return b.isNaN ? Float.nan : b }
        if b.isNaN { return a }
        if a < b { return a }
        if b < a { return b }
        if a == 0 && b == 0 { return -min(a, b) }  // -0 优先
        return a
    }

    public static func fmaxnmS(_ a: Float, _ b: Float) -> Float {
        if a.isNaN { return b }
        if b.isNaN { return a }
        return fmaxS(a, b)
    }

    public static func fminnmS(_ a: Float, _ b: Float) -> Float {
        if a.isNaN { return b }
        if b.isNaN { return a }
        return fminS(a, b)
    }

    public static func fmaxD(_ a: Double, _ b: Double) -> Double {
        if a.isNaN { return b.isNaN ? Double.nan : b }
        if b.isNaN { return a }
        if a > b { return a }
        if b > a { return b }
        if a == 0 && b == 0 { return min(a, b) }
        return a
    }

    public static func fminD(_ a: Double, _ b: Double) -> Double {
        if a.isNaN { return b.isNaN ? Double.nan : b }
        if b.isNaN { return a }
        if a < b { return a }
        if b < a { return b }
        if a == 0 && b == 0 { return -min(a, b) }
        return a
    }

    public static func fmaxnmD(_ a: Double, _ b: Double) -> Double {
        if a.isNaN { return b }
        if b.isNaN { return a }
        return fmaxD(a, b)
    }

    public static func fminnmD(_ a: Double, _ b: Double) -> Double {
        if a.isNaN { return b }
        if b.isNaN { return a }
        return fminD(a, b)
    }

    /// 浮点 → 有符号整数（向零取整，超范围饱和，NaN → 0）
    public static func toSignedInt(_ value: Double, is64: Bool) -> UInt64 {
        if value.isNaN { return 0 }
        let truncated = value.rounded(.towardZero)
        if is64 {
            if truncated >= 9223372036854775808.0 { return 0x7FFF_FFFF_FFFF_FFFF }
            if truncated < -9223372036854775808.0 { return 0x8000_0000_0000_0000 }
            return UInt64(bitPattern: Int64(truncated))
        } else {
            if truncated >= 2147483648.0 { return 0x7FFF_FFFF }
            if truncated < -2147483648.0 { return 0x8000_0000 }
            return UInt64(bitPattern: Int64(truncated)) & 0xFFFF_FFFF
        }
    }

    /// 浮点 → 无符号整数（向零取整，超范围饱和，NaN → 0）
    public static func toUnsignedInt(_ value: Double, is64: Bool) -> UInt64 {
        if value.isNaN { return 0 }
        let truncated = value.rounded(.towardZero)
        if truncated <= -1.0 { return 0 }
        if is64 {
            if truncated >= 18446744073709551616.0 { return UInt64.max }
            return UInt64(truncated)
        } else {
            if truncated >= 4294967296.0 { return 0xFFFF_FFFF }
            return UInt64(truncated) & 0xFFFF_FFFF
        }
    }

    /// VFPExpandImm：把 8 位浮点立即数展开为 IEEE-754 位模式
    public static func expandFPImm8(_ imm8: UInt32, isDouble: Bool) -> UInt64 {
        let sign = (imm8 >> 7) & 1
        let b = (imm8 >> 6) & 1
        let c = (imm8 >> 5) & 1
        let d = (imm8 >> 4) & 1
        let frac = UInt64(imm8 & 0xF)

        if isDouble {
            var exp: UInt64 = UInt64(~b & 1) << 10
            if b == 1 { exp |= UInt64(0xFF) << 2 }
            exp |= UInt64((c << 1) | d)
            return (UInt64(sign) << 63) | (exp << 52) | (frac << 48)
        } else {
            var exp: UInt64 = UInt64(~b & 1) << 7
            if b == 1 { exp |= UInt64(0x1F) << 2 }
            exp |= UInt64((c << 1) | d)
            return (UInt64(sign) << 31) | (exp << 23) | (frac << 19)
        }
    }
}
