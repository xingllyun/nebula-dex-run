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

/// AArch64 解释执行上下文
public final class SDRCpuContext {
    /// 通用寄存器 X0-X30（X31 由 SP / XZR 语义在解释器内按指令类型解析）
    public var x: [UInt64]
    public var sp: UInt64
    public var pc: UInt64
    /// NZCV 标志：N=bit3 Z=bit2 C=bit1 V=bit0
    public var nzcv: UInt32
    /// 标量浮点/向量寄存器文件（V0-V31）
    public let fpu = SDRArmFPU()

    public var lr: UInt64 { get { x[30] } set { x[30] = newValue } }
    public var x0: UInt64 { get { x[0] } set { x[0] = newValue } }

    public init(pc: UInt64 = 0, sp: UInt64 = 0) {
        self.x = [UInt64](repeating: 0, count: 31)
        self.sp = sp
        self.pc = pc
        self.nzcv = 0
    }

    public var negative: Bool { nzcv & 0x8 != 0 }
    public var zero: Bool { nzcv & 0x4 != 0 }
    public var carry: Bool { nzcv & 0x2 != 0 }
    public var overflow: Bool { nzcv & 0x1 != 0 }

    public func setFlags(result: UInt64, is64: Bool, carryOut: Bool, overflowOut: Bool) {
        var f: UInt32 = 0
        let signBit: UInt64 = is64 ? 0x8000_0000_0000_0000 : 0x8000_0000
        if result & signBit != 0 { f |= 0x8 }
        if result == 0 { f |= 0x4 }
        if carryOut { f |= 0x2 }
        if overflowOut { f |= 0x1 }
        nzcv = f
    }
}

public enum SDRInterpreterState {
    case running
    case halted
    case fault(String)
}

/// ARM 指令级解释执行器
/// 设计约束：iOS 非越狱环境不允许 mmap 可执行内存，SO 代码只能以数据形式装载，
/// 由本解释器逐条取指、译码、执行，系统调用经 SDRSystemServices 代理。
///
/// 阶段一能力范围（对齐 Android arm64-v8a 原生库主路径）：
/// - 数据立即数：MOVZ/MOVN/MOVK、ADD/SUB（含 12 位移位立即数）、逻辑立即数、位域（SBFM/BFM/UBFM）、EXTR、ADR/ADRP
/// - 数据寄存器：逻辑（移位）、ADD/SUB（移位/扩展）、ADC/SBC、条件选择、条件比较、
///   乘除（MADD/MSUB/SMULL/UMULL/SMULH/UMULH/SDIV/UDIV）、1-source/2-source（RBIT/REV/CLZ/CLS/LSLV 等）
/// - 访存：LDR/STR 全变体（无符号偏移/非缩放/前索引/后索引/寄存器偏移）、
///   LDRB/LDRH/LDRSB/LDRSH/LDRSW、LDP/STP/LDNP/STNP（含 SIMD&FP 形式）
/// - 浮点：标量 S/D 的算术、比较、转换、寄存器搬移（见 SDRArmFPU）
/// - 分支与系统：B/BL/B.cond/CBZ/CBNZ/TBZ/TBNZ/BR/BLR/RET/SVC/BRK/HLT/NOP/MRS/MSR(NZCV)
public final class SDRArmInterpreter {

    public private(set) var context: SDRCpuContext
    public let memory: SDRMemoryGuard
    public let services: SDRSystemServices
    /// guest → host 托管调用桥（libc 符号桩入口）
    public let hostCall: SDRHostCall
    public var instructionBudget: Int
    public private(set) var executedCount: Int = 0
    /// 未覆盖指令编码（去重，供阶段二补全时定位缺口）
    public private(set) var unsupportedInstructions: Set<UInt32> = []
    /// 指令级跟踪日志开关（热路径默认关闭，避免字符串插值开销）
    public var traceEnabled: Bool = false

    /// 取指缓存窗口（减少段读取的数组分配，仅用于只读代码段）
    /// 窗口越大，分支/循环回边跨窗口后的命中率越高；取 1 KiB（= 256 条指令）。
    private static let fetchWindow = 1024
    private var fetchCacheBase: UInt64 = 0
    private var fetchCache: [UInt8] = []
    /// 由分支指令写入；step 结束时若存在则作为下一条 PC
    private var pendingBranch: UInt64?

    // MARK: - 译码缓存

    /// 译码类别（1 起编，0 保留为「槽未使用」哨兵值）
    private enum DecodeKind: UInt8 {
        case moveWide = 1, bitfield, extract, logicalImm, addSubImm, adr
        case logicalReg, addSubReg, addSubExtended, addSubCarry
        case condCompare, condSelect, dp12, multiply
        case loadStore, loadStorePair, branchOrSystem
        case fpu, neon, unclassified
    }

    /// 直接映射译码缓存：4096 槽，槽内保存完整指令字做校验，
    /// 命中即跳过分类链（同一指令字重复执行时不再重复位域判定）。
    private static let decodeSlotMask = 4095
    private var decodeSlotKeys = [UInt32](repeating: 0, count: 4096)
    private var decodeSlotKinds = [UInt8](repeating: 0, count: 4096)
    /// 译码缓存命中 / 未命中统计（供性能核对，不影响执行语义）
    public private(set) var decodeCacheHits: Int = 0
    public private(set) var decodeCacheMisses: Int = 0

    public init(context: SDRCpuContext, memory: SDRMemoryGuard,
                services: SDRSystemServices, hostCall: SDRHostCall = SDRHostCall.shared,
                budget: Int = 500_000) {
        self.context = context
        self.memory = memory
        self.services = services
        self.hostCall = hostCall
        self.instructionBudget = budget
    }

    public func run(entry: UInt64, args: [UInt64] = []) throws -> UInt64 {
        context.pc = entry
        for (i, a) in args.enumerated() where i < 8 { context.x[i] = a }
        executedCount = 0
        fetchCache.removeAll(keepingCapacity: true)

        var state: SDRInterpreterState = .running
        while case .running = state {
            guard executedCount < instructionBudget else {
                throw SDRAppError(.soImageInvalid, "解释执行超出指令预算")
            }
            // guest 调用 exit / exit_group 后由代理层置位，主循环据此收口
            if services.exitRequested { break }
            guard let insn = try? fetch() else {
                throw SDRAppError(.soImageInvalid, "取指失败 @\(String(context.pc, radix: 16))")
            }
            state = try step(insn)
            executedCount += 1
        }

        if case .fault(let msg) = state {
            throw SDRAppError(.soImageInvalid, "解释执行异常：\(msg)")
        }
        return context.x0
    }

    // MARK: - 取指

    @inline(__always)
    private func decodeLE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    @inline(__always)
    private func fetch() throws -> UInt32 {
        let pc = context.pc
        // 用单次无符号比较替代 (pc >= base && pc + 4 <= base + count)：
        // 窗口内偏移量 pc - base 落在 [0, count - 4] 即命中，且规避加法溢出。
        let win = fetchCache.count
        if win >= 4 {
            let offset = pc &- fetchCacheBase
            if offset <= UInt64(win - 4) {
                return decodeLE(fetchCache, Int(offset))
            }
        }
        if let window = try? memory.read(pc, count: Self.fetchWindow) {
            fetchCacheBase = pc
            fetchCache = window
            return decodeLE(window, 0)
        }
        let bytes = try memory.read(pc, count: 4)
        return decodeLE(bytes, 0)
    }

    // MARK: - 单步

    /// 单步执行；返回下一个状态
    public func step(_ insn: UInt32) throws -> SDRInterpreterState {
        pendingBranch = nil
        let state = try execute(insn)
        if case .running = state {
            if let target = pendingBranch { context.pc = target } else { context.pc &+= 4 }
        }
        return state
    }

    // MARK: - 解码分派

    /// 译码槽索引：Knuth 乘法散列取高位，直接映射 4096 槽
    @inline(__always)
    private func decodeSlotIndex(_ insn: UInt32) -> Int {
        return Int((insn &* 0x9E37_79B9) >> 20) & Self.decodeSlotMask
    }

    private func execute(_ insn: UInt32) throws -> SDRInterpreterState {
        // 译码缓存命中：跳过整条分类链，直接按已记录类别分派。
        // 注意：分类结果只与指令字本身有关，与寄存器/内存状态无关，故缓存始终安全。
        let slot = decodeSlotIndex(insn)
        if decodeSlotKeys[slot] == insn {
            let cached = decodeSlotKinds[slot]
            if cached != 0, let kind = DecodeKind(rawValue: cached) {
                decodeCacheHits += 1
                return try dispatch(kind, insn)
            }
        }
        decodeCacheMisses += 1
        let kind = classify(insn)
        decodeSlotKeys[slot] = insn
        decodeSlotKinds[slot] = kind.rawValue
        return try dispatch(kind, insn)
    }

    /// 指令译码分类（仅在译码缓存未命中时执行）
    ///
    /// 注意：分类顺序必须与原始位域判定顺序严格一致。掩码族之间存在非互斥情形
    /// （例：CCMP/CCMN 的 sf=1 形式 0xFA4xxxxx 同时满足 bits[29:27]=111 的访存掩码），
    /// 重排判定顺序会改变归类结果，故此处不做「高频指令前置」类优化，
    /// 去重开销一律由译码缓存承担。
    private func classify(_ insn: UInt32) -> DecodeKind {
        // 0. A64 基础指令集（非 SIMD）
        if (insn & 0x1F00_0000) == 0x1E00_0000 { return .fpu }

        // 0b. 高级 SIMD（NEON）整数通路：ASIMD 向量空间 bits[28:24] = 01110 / 01111
        if (insn & 0x1F00_0000) == 0x0E00_0000 || (insn & 0x1F00_0000) == 0x0F00_0000 { return .neon }

        // 1. 数据立即数
        if (insn & 0x1F80_0000) == 0x1280_0000 { return .moveWide }     // 100101
        if (insn & 0x1F80_0000) == 0x1300_0000 { return .bitfield }     // 100110
        if (insn & 0x1F80_0000) == 0x1380_0000 { return .extract }      // 100111
        if (insn & 0x1F80_0000) == 0x1200_0000 { return .logicalImm }   // 100100
        if (insn & 0x1F00_0000) == 0x1100_0000 { return .addSubImm }    // 10001
        if (insn & 0x1F00_0000) == 0x1000_0000 { return .adr }          // 10000

        // 2. 数据寄存器
        if (insn & 0x1F00_0000) == 0x0A00_0000 { return .logicalReg }   // 01010
        if (insn & 0x1F00_0000) == 0x0B00_0000 {                        // 01011
            return ((insn >> 21) & 1) == 1 ? .addSubExtended : .addSubReg
        }
        if (insn & 0x1FE0_0000) == 0x1A00_0000 { return .addSubCarry }  // 11010000
        if (insn & 0x1FE0_0000) == 0x1A40_0000 { return .condCompare }
        if (insn & 0x1FE0_0000) == 0x1A80_0000 { return .condSelect }
        if (insn & 0x1FE0_0000) == 0x1AC0_0000 { return .dp12 }
        if (insn & 0x1F00_0000) == 0x1B00_0000 { return .multiply }     // 11011

        // 3. 访存
        if (insn & 0x3800_0000) == 0x3800_0000 { return .loadStore }      // bits[29:27]=111
        if (insn & 0x3800_0000) == 0x2800_0000 { return .loadStorePair }  // bits[29:27]=101

        // 4. 分支与系统
        if (insn & 0x1C00_0000) == 0x1400_0000 || (insn & 0xFF00_0000) == 0xD400_0000
            || (insn & 0xFF00_0000) == 0xD500_0000 { return .branchOrSystem }
        if (insn & 0x7C00_0000) == 0x1400_0000 { return .branchOrSystem }

        return .unclassified
    }

    /// 按译码类别分派到具体执行单元
    @inline(__always)
    private func dispatch(_ kind: DecodeKind, _ insn: UInt32) throws -> SDRInterpreterState {
        switch kind {
        case .fpu:
            if context.fpu.execute(insn: insn, context: context) { return .running }
            return unsupported(insn, "FP/SIMD")
        case .neon:
            if SDRArmNEON.execute(insn: insn, context: context, fpu: context.fpu) { return .running }
            return unsupported(insn, "NEON")
        case .moveWide: return executeMoveWide(insn)
        case .bitfield: return executeBitfield(insn)
        case .extract: return executeExtract(insn)
        case .logicalImm: return executeLogicalImm(insn)
        case .addSubImm: return executeAddSubImm(insn)
        case .adr: return executeADR(insn)
        case .logicalReg: return executeLogicalReg(insn)
        case .addSubReg: return executeAddSubReg(insn)
        case .addSubExtended: return executeAddSubExtended(insn)
        case .addSubCarry: return executeAddSubCarry(insn)
        case .condCompare: return executeConditionalCompare(insn)
        case .condSelect: return executeConditionalSelect(insn)
        case .dp12: return executeDataProcessing12(insn)
        case .multiply: return executeMultiply(insn)
        case .loadStore: return try executeLoadStore(insn)
        case .loadStorePair: return try executeLoadStorePair(insn)
        case .branchOrSystem: return try executeBranchOrSystem(insn)
        case .unclassified: return unsupported(insn, "未分类")
        }
    }

    private func unsupported(_ insn: UInt32, _ kind: String) -> SDRInterpreterState {
        if unsupportedInstructions.count < 512 { unsupportedInstructions.insert(insn) }
        if traceEnabled {
            SDRLogger.d("interp", "未覆盖指令[\(kind)] 0x\(String(insn, radix: 16)) @0x\(String(context.pc, radix: 16))")
        }
        return .running
    }

    // MARK: - 寄存器访问

    /// X31：多数指令按 XZR（0）解析，立即数加/减与访存基址按 SP 解析
    @inline(__always)
    private func gp(_ index: Int, spAllowed: Bool = false) -> UInt64 {
        if index == 31 { return spAllowed ? context.sp : 0 }
        return context.x[index]
    }

    @inline(__always)
    private func setGp(_ index: Int, _ value: UInt64, spAllowed: Bool = false) {
        if index == 31 {
            if spAllowed { context.sp = value }
            return
        }
        context.x[index] = value
    }

    @inline(__always)
    private func truncate(_ value: UInt64, width: Int) -> UInt64 {
        width == 64 ? value : (value & 0xFFFF_FFFF)
    }

    @inline(__always)
    private func signExtend(_ value: UInt64, bits: Int) -> UInt64 {
        guard bits < 64 else { return value }
        let shift = UInt64(64 - bits)
        // 先左移截断，再按有符号右移，保证高位按符号位填充（UInt64 的逻辑右移不扩展符号）
        return UInt64(bitPattern: Int64(bitPattern: value << shift) >> shift)
    }

    // MARK: - 标志计算

    /// 带进位加法（ADC 语义），按 width 精确产生进位与有符号溢出
    private func addWithCarry(_ a: UInt64, _ b: UInt64, _ carryIn: UInt64,
                              width: Int) -> (result: UInt64, carry: UInt64, overflow: UInt64) {
        if width == 64 {
            let (s1, c1) = a.addingReportingOverflow(b)
            let (s2, c2) = s1.addingReportingOverflow(carryIn)
            let carry: UInt64 = (c1 || c2) ? 1 : 0
            let overflow: UInt64 = ((a ^ s2) & (b ^ s2) & 0x8000_0000_0000_0000) != 0 ? 1 : 0
            return (s2, carry, overflow)
        } else {
            let mask: UInt64 = 0xFFFF_FFFF
            let sum = (a & mask) + (b & mask) + carryIn
            let result = sum & mask
            let carry: UInt64 = sum > mask ? 1 : 0
            let overflow: UInt64 = ((a ^ result) & (b ^ result) & 0x8000_0000) != 0 ? 1 : 0
            return (result, carry, overflow)
        }
    }

    private func writeFlags(_ result: UInt64, carry: UInt64, overflow: UInt64, width: Int) {
        var f: UInt32 = 0
        let signBit: UInt64 = width == 64 ? 0x8000_0000_0000_0000 : 0x8000_0000
        if (result & signBit) != 0 { f |= 0x8 }
        if (result & (width == 64 ? UInt64.max : 0xFFFF_FFFF)) == 0 { f |= 0x4 }
        if carry != 0 { f |= 0x2 }
        if overflow != 0 { f |= 0x1 }
        context.nzcv = f
    }

    // MARK: - 移位 / 扩展

    private func shiftedValue(_ value: UInt64, type: UInt32, amount: Int, width: Int) -> UInt64 {
        let mask: UInt64 = width == 64 ? UInt64.max : 0xFFFF_FFFF
        let v = value & mask
        guard amount % width != 0 else { return v }
        let amt = amount % width
        switch type {
        case 0:                                  // LSL
            return (v << UInt64(amt)) & mask
        case 1:                                  // LSR
            return v >> UInt64(amt)
        case 2:                                  // ASR
            let signBit: UInt64 = width == 64 ? 0x8000_0000_0000_0000 : 0x8000_0000
            let negative = (v & signBit) != 0
            var r = v >> UInt64(amt)
            if negative { r |= (mask << UInt64(width - amt)) & mask }
            return r & mask
        default:                                 // ROR
            return ((v >> UInt64(amt)) | (v << UInt64(width - amt))) & mask
        }
    }

    private func extendedValue(_ value: UInt64, option: UInt32) -> UInt64 {
        switch option {
        case 0b000: return UInt64(UInt8(truncatingIfNeeded: value))                       // UXTB
        case 0b001: return UInt64(UInt16(truncatingIfNeeded: value))                      // UXTH
        case 0b010: return UInt64(UInt32(truncatingIfNeeded: value))                      // UXTW
        case 0b011: return value                                                          // UXTX
        case 0b100: return UInt64(bitPattern: Int64(Int8(truncatingIfNeeded: value)))     // SXTB
        case 0b101: return UInt64(bitPattern: Int64(Int16(truncatingIfNeeded: value)))    // SXTH
        case 0b110: return UInt64(bitPattern: Int64(Int32(truncatingIfNeeded: value)))    // SXTW
        default:    return value                                                          // SXTX
        }
    }

    // MARK: - 数据立即数

    private func executeMoveWide(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let opc = (insn >> 29) & 0x3
        let hw = UInt64((insn >> 21) & 0x3)
        let imm16 = UInt64((insn >> 5) & 0xFFFF)
        let rd = Int(insn & 0x1F)
        let shift = hw * 16
        var value: UInt64

        switch opc {
        case 0:                                    // MOVN
            value = ~(imm16 << shift)
        case 2:                                    // MOVZ
            value = imm16 << shift
        case 3:                                    // MOVK
            let mask: UInt64 = 0xFFFF << shift
            value = (gp(rd) & ~mask) | (imm16 << shift)
        default:
            return unsupported(insn, "MoveWide")
        }
        if sf == 0 { value &= 0xFFFF_FFFF }
        setGp(rd, value)
        return .running
    }

    private func executeAddSubImm(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let op = (insn >> 30) & 1
        let setFlags = (insn >> 29) & 1 == 1
        let sh = (insn >> 22) & 1
        var imm = UInt64((insn >> 10) & 0xFFF)
        if sh == 1 { imm <<= 12 }
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32

        let a = gp(rn, spAllowed: true)
        let (result, carry, overflow) = op == 1
            ? addWithCarry(a, ~imm, 1, width: width)
            : addWithCarry(a, imm, 0, width: width)

        if setFlags { writeFlags(result, carry: carry, overflow: overflow, width: width) }
        // ADD/SUB 立即数：Rd=31 且无 S 时写 SP，否则写 XZR（丢弃）
        setGp(rd, result, spAllowed: !setFlags)
        return .running
    }

    private func executeLogicalImm(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let opc = (insn >> 29) & 0x3
        let n = UInt64((insn >> 22) & 1)
        let immr = UInt64((insn >> 16) & 0x3F)
        let imms = UInt64((insn >> 10) & 0x3F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32

        let imm = SDRAlu.decodeBitmask(n: n, immr: immr, imms: imms, width: width)
        let a = truncate(gp(rn), width: width)
        var result: UInt64
        switch opc {
        case 0: result = a & imm        // AND
        case 1: result = a | imm        // ORR
        case 2: result = a ^ imm        // EOR
        default: result = a & imm       // ANDS
        }
        result = truncate(result, width: width)
        if opc == 3 { writeFlags(result, carry: 0, overflow: 0, width: width) }
        setGp(rd, result)
        return .running
    }

    /// SBFM / BFM / UBFM（位域插入与提取，含 SXTB/SXTH/SXTW/UBFX/UBFIZ/BFI 别名）
    private func executeBitfield(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let opc = (insn >> 29) & 0x3
        let n = UInt64((insn >> 22) & 1)
        let immr = UInt64((insn >> 16) & 0x3F)
        let imms = UInt64((insn >> 10) & 0x3F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32

        let src = truncate(gp(rn), width: width)

        if opc == 0b01 {                                    // BFM：把源字段搬到目标位置
            let immsI = Int(imms)
            let immrI = Int(immr)
            let fieldLen: Int
            let srcStart: Int
            let targetStart: Int
            if immrI <= immsI {
                fieldLen = immsI - immrI + 1
                srcStart = immrI
                targetStart = 0
            } else {
                fieldLen = immsI + 1
                srcStart = 0
                targetStart = width - immrI
            }
            let len = min(fieldLen, width)
            let fieldMask: UInt64 = len >= 64 ? UInt64.max : ((UInt64(1) << UInt64(len)) - 1)
            let field = (src >> UInt64(srcStart)) & fieldMask
            let rotate = (width - targetStart) % width
            let placed = shiftedValue(field, type: 0b11, amount: rotate, width: width)
            let dstMask = shiftedValue(fieldMask, type: 0b11, amount: rotate, width: width)
            let old = truncate(gp(rd), width: width)
            setGp(rd, (old & ~dstMask) | (placed & dstMask))
            return .running
        }

        let (wmask, tmask) = decodeBitMasks(n: n, imms: imms, immr: immr, width: width)
        // UBFM/SBFM：源操作数先按 immr 循环右移，再按 wmask 取字段
        let rotated = shiftedValue(src, type: 0b11, amount: Int(immr), width: width)
        let bot = rotated & wmask
        var top: UInt64 = 0
        if opc == 0b00 {                                    // SBFM：按原始源的第 imms 位扩展
            top = ((src >> UInt64(imms)) & 1) == 1 ? UInt64.max : 0
        }
        var dst = (top & ~tmask) | (bot & tmask)
        if opc == 0b00 { dst = signExtend(dst, bits: width) }   // 符号扩展
        else { dst = truncate(dst, width: width) }              // UBFM
        setGp(rd, dst)
        return .running
    }

    /// BitMasks() 的 wmask/tmask 计算（ARM ARM 伪码）
    private func decodeBitMasks(n: UInt64, imms: UInt64, immr: UInt64,
                                width: Int) -> (wmask: UInt64, tmask: UInt64) {
        let combined: UInt64 = (n << 6) | (~imms & 0x3F)
        guard combined != 0 else { return (0, 0) }
        let len = 63 - combined.leadingZeroBitCount
        let esize = 1 << len
        let levels = UInt64(esize - 1)
        let s = Int(imms & levels)
        let r = Int(immr & levels)
        let diff = s - r
        let d = diff < 0 ? diff + esize : diff

        let esizeMask: UInt64 = esize >= 64 ? UInt64.max : ((UInt64(1) << UInt64(esize)) - 1)
        let welemRaw: UInt64 = s + 1 >= 64 ? UInt64.max : ((UInt64(1) << UInt64(s + 1)) - 1)
        let telemRaw: UInt64 = d + 1 >= 64 ? UInt64.max : ((UInt64(1) << UInt64(d + 1)) - 1)
        var welem = welemRaw & esizeMask
        let telem = telemRaw & esizeMask

        let rot = r % esize
        if rot > 0 {
            welem = ((welem >> UInt64(rot)) | (welem << UInt64(esize - rot))) & esizeMask
        }
        var wmask: UInt64 = 0
        var tmask: UInt64 = 0
        var p = 0
        while p + esize <= 64 {
            wmask |= welem << UInt64(p)
            tmask |= telem << UInt64(p)
            p += esize
        }
        let widthMask: UInt64 = width >= 64 ? UInt64.max : ((UInt64(1) << UInt64(width)) - 1)
        return (wmask & widthMask, tmask & widthMask)
    }

    private func executeExtract(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let rm = Int((insn >> 16) & 0x1F)
        let lsb = Int((insn >> 10) & 0x3F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32
        let a = truncate(gp(rn), width: width)
        let b = truncate(gp(rm), width: width)

        // EXTR Xd, Xn, Xm, #lsb：结果为 (Xn:Xm) 的低 width 位，即
        //   lsb == 0 → Xm
        //   lsb >  0 → (Xn << (width - lsb)) | (Xm >> lsb)
        // 其中 a = Xn（高位操作数）、b = Xm（低位操作数），两者不可交换。
        let amount = lsb % width
        let result = amount == 0
            ? b
            : ((b >> UInt64(amount)) | (a << UInt64(width - amount))) & (width == 64 ? UInt64.max : 0xFFFF_FFFF)
        setGp(rd, result)
        return .running
    }

    private func executeADR(_ insn: UInt32) -> SDRInterpreterState {
        let page = (insn >> 31) & 1
        let immlo = Int64((insn >> 29) & 0x3)
        let immhi = Int64((insn >> 5) & 0x7FFFF)
        var imm = (immhi << 2) | immlo
        if (imm & (1 << 20)) != 0 { imm -= (1 << 21) }      // 21 位符号扩展
        let rd = Int(insn & 0x1F)

        let base = page == 1 ? (context.pc & ~0xFFF) : context.pc
        let offset = page == 1 ? (imm << 12) : imm
        setGp(rd, UInt64(bitPattern: Int64(bitPattern: base) &+ offset))
        return .running
    }

    // MARK: - 数据寄存器

    private func executeLogicalReg(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let opc = (insn >> 29) & 0x3
        let shiftType = (insn >> 22) & 0x3
        let invert = (insn >> 21) & 1
        let rm = Int((insn >> 16) & 0x1F)
        let amount = Int((insn >> 10) & 0x3F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32

        var operand = shiftedValue(gp(rm), type: shiftType, amount: amount, width: width)
        if invert == 1 { operand = ~operand & (width == 64 ? UInt64.max : 0xFFFF_FFFF) }
        let a = truncate(gp(rn), width: width)

        var result: UInt64
        switch opc {
        case 0: result = a & operand      // AND / BIC
        case 1: result = a | operand      // ORR / ORN
        case 2: result = a ^ operand      // EOR / EON
        default: result = a & operand     // ANDS / BICS
        }
        result = truncate(result, width: width)
        if opc == 3 { writeFlags(result, carry: 0, overflow: 0, width: width) }
        setGp(rd, result)
        return .running
    }

    private func executeAddSubReg(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let op = (insn >> 30) & 1
        let setFlags = (insn >> 29) & 1 == 1
        let shiftType = (insn >> 22) & 0x3
        let rm = Int((insn >> 16) & 0x1F)
        let amount = Int((insn >> 10) & 0x3F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32

        let a = truncate(gp(rn), width: width)
        let b = shiftedValue(gp(rm), type: shiftType, amount: amount, width: width)
        let (result, carry, overflow) = op == 1
            ? addWithCarry(a, ~b, 1, width: width)
            : addWithCarry(a, b, 0, width: width)

        if setFlags { writeFlags(result, carry: carry, overflow: overflow, width: width) }
        setGp(rd, truncate(result, width: width))
        return .running
    }

    private func executeAddSubExtended(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let op = (insn >> 30) & 1
        let setFlags = (insn >> 29) & 1 == 1
        let rm = Int((insn >> 16) & 0x1F)
        let option = (insn >> 13) & 0x7
        let imm3 = Int((insn >> 10) & 0x7)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32

        let a = gp(rn, spAllowed: true)
        var operand = extendedValue(gp(rm), option: option)
        if width == 32 { operand &= 0xFFFF_FFFF }
        operand = shiftedValue(operand, type: 0, amount: imm3, width: width)

        let (result, carry, overflow) = op == 1
            ? addWithCarry(a, ~operand, 1, width: width)
            : addWithCarry(a, operand, 0, width: width)

        if setFlags { writeFlags(result, carry: carry, overflow: overflow, width: width) }
        setGp(rd, result, spAllowed: !setFlags)
        return .running
    }

    private func executeAddSubCarry(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let op = (insn >> 30) & 1
        let setFlags = (insn >> 29) & 1 == 1
        let rm = Int((insn >> 16) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32

        let carryIn: UInt64 = context.carry ? 1 : 0
        let a = truncate(gp(rn), width: width)
        let b = truncate(gp(rm), width: width)
        let (result, carry, overflow) = op == 1
            ? addWithCarry(a, ~b, carryIn, width: width)   // SBC
            : addWithCarry(a, b, carryIn, width: width)    // ADC

        if setFlags { writeFlags(result, carry: carry, overflow: overflow, width: width) }
        setGp(rd, truncate(result, width: width))
        return .running
    }

    private func executeConditionalSelect(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let op = (insn >> 30) & 1
        let o2 = (insn >> 10) & 1
        let cond = (insn >> 12) & 0xF
        let rm = Int((insn >> 16) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32

        let rnValue = gp(rn)
        let rmValue = gp(rm)
        var value: UInt64
        // CSEL/CSINC/CSINV/CSNEG 四个兄弟指令在条件成立时统一取 Xn；
        // 仅条件不成立时按 (op, o2) 对 Xm 做 直取 / +1 / 取反 / 取负 变换。
        if SDRAlu.conditionHolds(cond, nzcv: context.nzcv) {
            value = rnValue
        } else if op == 0 {
            value = o2 == 0 ? rmValue : rmValue &+ 1
        } else {
            value = o2 == 0 ? ~rmValue : (~rmValue) &+ 1
        }
        setGp(rd, truncate(value, width: width))
        return .running
    }

    private func executeConditionalCompare(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let op = (insn >> 30) & 1                     // 0=CCMN 1=CCMP
        let cond = (insn >> 12) & 0xF
        let isImmediate = (insn >> 11) & 1
        let nzcvImm = insn & 0xF
        let rn = Int((insn >> 5) & 0x1F)
        let width = sf == 1 ? 64 : 32

        let a = truncate(gp(rn), width: width)
        let b: UInt64
        if isImmediate == 1 {
            b = UInt64((insn >> 16) & 0x1F)
        } else {
            b = truncate(gp(Int((insn >> 16) & 0x1F)), width: width)
        }

        if SDRAlu.conditionHolds(cond, nzcv: context.nzcv) {
            let (result, carry, overflow) = op == 1
                ? addWithCarry(a, ~b, 1, width: width)
                : addWithCarry(a, b, 0, width: width)
            writeFlags(result, carry: carry, overflow: overflow, width: width)
        } else {
            context.nzcv = nzcvImm
        }
        return .running
    }

    /// 1-source（RBIT/REV16/REV32/REV/CLZ/CLS）与 2-source（UDIV/SDIV/LSLV/LSRV/ASRV/RORV）
    private func executeDataProcessing12(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let rmField = (insn >> 16) & 0x1F
        let opcode = (insn >> 10) & 0x3F
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)
        let width = sf == 1 ? 64 : 32

        if rmField == 0 {
            let value = truncate(gp(rn), width: width)
            var result: UInt64
            switch opcode {
            case 0b000000:                                     // RBIT
                result = bitReverse(value, width: width)
            case 0b000001:                                     // REV16
                result = byteReverse16(value, width: width)
            case 0b000010:                                     // REV32 (64) / REV (32)
                if sf == 1 {
                    let lo = UInt64(UInt32(truncatingIfNeeded: value).byteSwapped)
                    let hi = UInt64(UInt32(truncatingIfNeeded: value >> 32).byteSwapped)
                    result = lo | (hi << 32)
                } else {
                    result = UInt64(UInt32(truncatingIfNeeded: value).byteSwapped)
                }
            case 0b000011:                                     // REV (64)
                guard sf == 1 else { return unsupported(insn, "1-source") }
                result = value.byteSwapped
            case 0b000100:                                     // CLZ
                result = sf == 1
                    ? UInt64(value.leadingZeroBitCount)
                    : UInt64(UInt32(truncatingIfNeeded: value).leadingZeroBitCount)
            case 0b000101:                                     // CLS
                result = countLeadingSignBits(value, width: width)
            default:
                return unsupported(insn, "1-source")
            }
            setGp(rd, result)
            return .running
        }

        let a = truncate(gp(rn), width: width)
        let b = truncate(gp(Int(rmField)), width: width)
        var result: UInt64
        switch opcode {
        case 0b000010:                                         // UDIV
            result = b == 0 ? 0 : a / b
        case 0b000011:                                         // SDIV
            if b == 0 {
                result = 0
            } else if sf == 1 {
                let sa = Int64(bitPattern: a)
                let sb = Int64(bitPattern: b)
                result = (sa == Int64.min && sb == -1) ? a : UInt64(bitPattern: sa / sb)
            } else {
                let sa = Int32(bitPattern: UInt32(truncatingIfNeeded: a))
                let sb = Int32(bitPattern: UInt32(truncatingIfNeeded: b))
                if sa == Int32.min && sb == -1 {
                    result = UInt64(UInt32(bitPattern: sa))
                } else {
                    result = UInt64(UInt32(bitPattern: sa / sb))
                }
            }
        case 0b001000:                                         // LSLV
            result = shiftedValue(a, type: 0, amount: Int(b & UInt64(width - 1)), width: width)
        case 0b001001:                                         // LSRV
            result = shiftedValue(a, type: 1, amount: Int(b & UInt64(width - 1)), width: width)
        case 0b001010:                                         // ASRV
            result = shiftedValue(a, type: 2, amount: Int(b & UInt64(width - 1)), width: width)
        case 0b001011:                                         // RORV
            result = shiftedValue(a, type: 3, amount: Int(b & UInt64(width - 1)), width: width)
        default:
            return unsupported(insn, "2-source")
        }
        setGp(rd, truncate(result, width: width))
        return .running
    }

    private func bitReverse(_ value: UInt64, width: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<width where (value >> UInt64(i)) & 1 == 1 {
            result |= UInt64(1) << UInt64(width - 1 - i)
        }
        return result
    }

    private func byteReverse16(_ value: UInt64, width: Int) -> UInt64 {
        var result: UInt64 = 0
        var offset = 0
        while offset < width {
            let half = (value >> UInt64(offset)) & 0xFFFF
            let swapped = ((half & 0xFF) << 8) | (half >> 8)
            result |= swapped << UInt64(offset)
            offset += 16
        }
        return result
    }

    private func countLeadingSignBits(_ value: UInt64, width: Int) -> UInt64 {
        let masked = truncate(value, width: width)
        let signBit: UInt64 = width == 64 ? 0x8000_0000_0000_0000 : 0x8000_0000
        let inverted = (masked & signBit) != 0
            ? (~masked & (width == 64 ? UInt64.max : 0xFFFF_FFFF))
            : masked
        let lz = width == 64
            ? inverted.leadingZeroBitCount
            : UInt32(truncatingIfNeeded: inverted).leadingZeroBitCount
        return UInt64(lz - 1)
    }

    /// 三源乘法族：MADD/MSUB/SMADDL/SMSUBL/UMADDL/UMSUBL/SMULH/UMULH
    private func executeMultiply(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let op31 = (insn >> 21) & 0x7
        let o0 = (insn >> 15) & 1
        let rm = gp(Int((insn >> 16) & 0x1F))
        let ra = gp(Int((insn >> 10) & 0x1F))
        let rn = gp(Int((insn >> 5) & 0x1F))
        let rd = Int(insn & 0x1F)
        var result: UInt64

        switch op31 {
        case 0b000:                                            // MADD / MSUB
            let a = sf == 1 ? rn : (rn & 0xFFFF_FFFF)
            let b = sf == 1 ? rm : (rm & 0xFFFF_FFFF)
            let product = a &* b
            result = o0 == 0 ? product &+ ra : ra &- product
        case 0b001:                                            // SMADDL / SMSUBL
            let a = Int64(Int32(truncatingIfNeeded: rn))
            let b = Int64(Int32(truncatingIfNeeded: rm))
            let product = UInt64(bitPattern: a &* b)
            result = o0 == 0 ? product &+ ra : ra &- product
        case 0b101:                                            // UMADDL / UMSUBL
            let a = UInt64(UInt32(truncatingIfNeeded: rn))
            let b = UInt64(UInt32(truncatingIfNeeded: rm))
            let product = a &* b
            result = o0 == 0 ? product &+ ra : ra &- product
        case 0b010:                                            // SMULH
            result = UInt64(bitPattern: Int64(bitPattern: rn).multipliedFullWidth(by: Int64(bitPattern: rm)).high)
        case 0b110:                                            // UMULH
            result = rn.multipliedFullWidth(by: rm).high
        default:
            return unsupported(insn, "3-source")
        }

        if sf == 0 && op31 == 0b000 { result &= 0xFFFF_FFFF }
        setGp(rd, result)
        return .running
    }

    // MARK: - 访存

    private func readBytes(_ address: UInt64, count: Int) throws -> UInt64 {
        // 标量热路径：1/2/4/8 字节直接读取，免去每次访存的临时字节数组分配
        if count <= 8 { return try memory.readScalar(address, count: count) }
        let bytes = try memory.read(address, count: count)
        var value: UInt64 = 0
        for i in 0..<count { value |= UInt64(bytes[i]) << (8 * UInt64(i)) }
        return value
    }

    private func writeBytes(_ address: UInt64, value: UInt64, count: Int) throws {
        if count <= 8 { return try memory.writeScalar(address, value: value, count: count) }
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
        try memory.write(address, bytes: bytes)
    }

    /// 单寄存器加载/存储（含通用寄存器与 SIMD&FP 形式）
    private func executeLoadStore(_ insn: UInt32) throws -> SDRInterpreterState {
        let size = (insn >> 30) & 0x3
        let isVector = (insn >> 26) & 1 == 1
        let opc = (insn >> 22) & 0x3
        let rn = Int((insn >> 5) & 0x1F)
        let rt = Int(insn & 0x1F)
        let byteWidth = 1 << Int(size)

        let isUnsignedOffset = (insn & 0x3B00_0000) == 0x3900_0000
        let isRegisterOffset = (insn & 0x3B20_0C00) == 0x3820_0800
        let isUnscaled = (insn & 0x3B00_0000) == 0x3800_0000

        var address: UInt64
        var writeBackValue: UInt64 = 0
        var writeBack = false
        let base = rn == 31 ? context.sp : context.x[rn]

        if isRegisterOffset {
            let rm = Int((insn >> 16) & 0x1F)
            let option = (insn >> 13) & 0x7
            let scaled = (insn >> 12) & 1
            let extended = extendedValue(context.x[rm], option: option)
            let shift = scaled == 1 ? UInt64(size) : 0
            address = base &+ (extended << shift)
        } else if isUnsignedOffset {
            let imm12 = UInt64((insn >> 10) & 0xFFF)
            address = base &+ (imm12 << UInt64(size))
        } else if isUnscaled {
            let imm9 = signExtend(UInt64((insn >> 12) & 0x1FF), bits: 9)
            let mode = (insn >> 10) & 0x3
            switch mode {
            case 0b01:                                     // post-index
                address = base
                writeBackValue = base &+ imm9
                writeBack = true
            case 0b11:                                     // pre-index
                address = base &+ imm9
                writeBackValue = address
                writeBack = true
            default:                                       // unscaled / unprivileged
                address = base &+ imm9
            }
        } else {
            return unsupported(insn, "LoadStore")
        }

        if isVector {
            // SIMD&FP：size 00=B,01=H,10=S,11=D；opc=00 存储、01 加载
            let isLoad = opc == 0b01
            if isLoad {
                let raw = try readBytes(address, count: byteWidth)
                switch size {
                case 0b00: context.fpu.v[rt] = raw & 0xFF
                case 0b01: context.fpu.v[rt] = raw & 0xFFFF
                case 0b10: context.fpu.writeS(rt, Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
                default:   context.fpu.v[rt] = raw
                }
            } else {
                try writeBytes(address, value: context.fpu.v[rt], count: byteWidth)
            }
        } else {
            let isLoad = opc != 0b00
            if isLoad {
                let raw = try readBytes(address, count: byteWidth)
                var value = raw
                switch size {
                case 0b00:                                 // LDRB / LDRSB
                    if opc == 0b10 { value = signExtend(raw, bits: 8) }
                    else if opc == 0b11 { value = signExtend(raw, bits: 8) & 0xFFFF_FFFF }
                case 0b01:                                 // LDRH / LDRSH
                    if opc == 0b10 { value = signExtend(raw, bits: 16) }
                    else if opc == 0b11 { value = signExtend(raw, bits: 16) & 0xFFFF_FFFF }
                case 0b10:                                 // LDR W / LDRSW
                    if opc == 0b10 { value = signExtend(raw, bits: 32) }
                default:                                   // LDR X
                    break
                }
                if rt != 31 { context.x[rt] = value }
            } else {
                try writeBytes(address, value: rt == 31 ? 0 : context.x[rt], count: byteWidth)
            }
        }

        if writeBack {
            if rn == 31 { context.sp = writeBackValue } else { context.x[rn] = writeBackValue }
        }
        return .running
    }

    /// 寄存器对加载/存储：LDP/STP/LDNP/STNP（含 SIMD&FP 形式）
    private func executeLoadStorePair(_ insn: UInt32) throws -> SDRInterpreterState {
        let opc = (insn >> 30) & 0x3
        let isVector = (insn >> 26) & 1 == 1
        let mode = (insn >> 23) & 0x3
        let isLoad = (insn >> 22) & 1 == 1
        let imm7 = signExtend(UInt64((insn >> 15) & 0x7F), bits: 7)
        let rt2 = Int((insn >> 10) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rt = Int(insn & 0x1F)

        let elementWidth: Int
        if isVector {
            switch opc {
            case 0b00: elementWidth = 4
            case 0b01: elementWidth = 8
            default: elementWidth = 16
            }
        } else {
            // 非 SIMD：opc=00 → 32 位元素；opc=01 → LDPSW（元素宽仍为 4，加载后符号扩展）；
            // opc=10 → 64 位元素。imm7 的缩放系数必须与真实元素宽度一致，
            // 否则 LDPSW 会按 8 字节步长寻址而读到错误地址。
            elementWidth = opc == 0b10 ? 8 : 4
        }

        let base = rn == 31 ? context.sp : context.x[rn]
        let offset = UInt64(bitPattern: Int64(bitPattern: imm7) &* Int64(elementWidth))
        let isPreIndex = mode == 0b011
        let isPostIndex = mode == 0b001
        let address = isPostIndex ? base : base &+ offset
        let writeBackValue = isPostIndex ? (base &+ offset) : address

        if isLoad {
            let first = try readBytes(address, count: elementWidth)
            let second = try readBytes(address &+ UInt64(elementWidth), count: elementWidth)
            if isVector {
                storeVectorPair(rt, first, elementWidth: elementWidth)
                storeVectorPair(rt2, second, elementWidth: elementWidth)
            } else if opc == 0b01 {
                // LDPSW：32 位加载符号扩展到 64 位
                if rt != 31 { context.x[rt] = signExtend(first, bits: 32) }
                if rt2 != 31 { context.x[rt2] = signExtend(second, bits: 32) }
            } else {
                if rt != 31 { context.x[rt] = first }
                if rt2 != 31 { context.x[rt2] = second }
            }
        } else {
            if isVector {
                try writeBytes(address, value: context.fpu.v[rt], count: elementWidth)
                try writeBytes(address &+ UInt64(elementWidth), value: context.fpu.v[rt2], count: elementWidth)
            } else {
                try writeBytes(address, value: rt == 31 ? 0 : context.x[rt], count: elementWidth)
                try writeBytes(address &+ UInt64(elementWidth), value: rt2 == 31 ? 0 : context.x[rt2],
                               count: elementWidth)
            }
        }

        if isPreIndex || isPostIndex {
            if rn == 31 { context.sp = writeBackValue } else { context.x[rn] = writeBackValue }
        }
        return .running
    }

    private func storeVectorPair(_ index: Int, _ raw: UInt64, elementWidth: Int) {
        switch elementWidth {
        case 4: context.fpu.v[index] = raw & 0xFFFF_FFFF
        case 8: context.fpu.v[index] = raw
        default:
            context.fpu.v[index] = raw
            context.fpu.vh[index] = 0
        }
    }

    // MARK: - 托管调用陷阱

    /// BRK #0x4E44：按 x16 中的符号索引取 host 实现，返回值写回 x0 后继续执行（PC 自动 +4 落到桩尾 ret）。
    /// 索引越界（未注册符号）按 -ENOSYS 回落，不改变解释器的停机/退出语义。
    private func handleHostCall(_ _: UInt32) throws -> SDRInterpreterState {
        let index = SDRHostCall.trapIndex(context)
        if let value = try hostCall.dispatch(index: index, context: context,
                                             memory: memory, services: services) {
            context.x0 = value
            return .running
        }
        context.x0 = SDRSystemServices.failure(SDRSyscallNumber.Errno.enosys)
        return .running
    }

    // MARK: - 分支与系统

    private func executeBranchOrSystem(_ insn: UInt32) throws -> SDRInterpreterState {
        // SVC
        if (insn & 0xFFE0_001F) == 0xD400_0001 {
            return try handleSVC(insn)
        }
        // BRK：0x4E44 为托管调用陷阱（libc 符号桩），其余立即数保持软断点停机语义
        if (insn & 0xFFE0_001F) == 0xD420_0000 {
            if SDRHostCall.isHostCallTrap(insn) {
                return try handleHostCall(insn)
            }
            return .halted
        }
        // HLT：进入停机态（软断点）
        if (insn & 0xFFE0_001F) == 0xD440_0000 {
            return .halted
        }
        // B / BL
        if (insn & 0x7C00_0000) == 0x1400_0000 {
            let offset = Int64(bitPattern: signExtend(UInt64(insn & 0x03FF_FFFF), bits: 26)) << 2
            if (insn & 0x8000_0000) != 0 {
                if 30 < context.x.count { context.x[30] = context.pc &+ 4 }
            }
            pendingBranch = UInt64(bitPattern: Int64(bitPattern: context.pc) &+ offset)
            return .running
        }
        // B.cond（排除 BC.cond）
        if (insn & 0xFF00_0000) == 0x5400_0000 && (insn & 0x10) == 0 {
            let cond = insn & 0xF
            if SDRAlu.conditionHolds(cond, nzcv: context.nzcv) {
                let offset = Int64(bitPattern: signExtend(UInt64((insn >> 5) & 0x7FFFF), bits: 19)) << 2
                pendingBranch = UInt64(bitPattern: Int64(bitPattern: context.pc) &+ offset)
            }
            return .running
        }
        // CBZ / CBNZ
        if (insn & 0x7E00_0000) == 0x3400_0000 {
            let sf = (insn >> 31) & 1
            let isNotZero = (insn >> 24) & 1 == 1
            var value = gp(Int(insn & 0x1F))
            if sf == 0 { value &= 0xFFFF_FFFF }
            if (value == 0) != isNotZero {
                let offset = Int64(bitPattern: signExtend(UInt64((insn >> 5) & 0x7FFFF), bits: 19)) << 2
                pendingBranch = UInt64(bitPattern: Int64(bitPattern: context.pc) &+ offset)
            }
            return .running
        }
        // TBZ / TBNZ
        if (insn & 0x7E00_0000) == 0x3600_0000 {
            let isNotZero = (insn >> 24) & 1 == 1
            let bitPosition = Int((((insn >> 31) & 1) << 5) | ((insn >> 19) & 0x1F))
            let value = gp(Int(insn & 0x1F))
            let bit = (value >> UInt64(bitPosition)) & 1
            if (bit == 1) == isNotZero {
                let offset = Int64(bitPattern: signExtend(UInt64((insn >> 5) & 0x3FFF), bits: 14)) << 2
                pendingBranch = UInt64(bitPattern: Int64(bitPattern: context.pc) &+ offset)
            }
            return .running
        }
        // BR / BLR / RET
        if (insn & 0xFE00_0000) == 0xD600_0000 {
            let opc = (insn >> 21) & 0xF
            let rn = Int((insn >> 5) & 0x1F)
            let target = gp(rn)
            switch opc {
            case 0b0000:                                        // BR
                pendingBranch = target
            case 0b0001:                                        // BLR
                if 30 < context.x.count { context.x[30] = context.pc &+ 4 }
                pendingBranch = target
            case 0b0010:                                        // RET
                pendingBranch = target
            default:
                return unsupported(insn, "BranchReg")
            }
            return .running
        }
        // NOP / HINT / 系统指令
        if (insn & 0xFF00_0000) == 0xD500_0000 || (insn & 0xFFE0_001F) == 0xD503_201F {
            // MRS Xt, NZCV / MSR NZCV, Xt
            if (insn & 0xFFFF_FFE0) == 0xD53B_4200 {
                setGp(Int(insn & 0x1F), UInt64(context.nzcv))
                return .running
            }
            if (insn & 0xFFFF_FFE0) == 0xD51B_4200 {
                context.nzcv = UInt32(truncatingIfNeeded: gp(Int(insn & 0x1F)))
                return .running
            }
            return .running                                     // NOP/HINT 等按空操作处理
        }
        return unsupported(insn, "Branch/System")
    }

    private func handleSVC(_ insn: UInt32) throws -> SDRInterpreterState {
        let number = UInt32((insn >> 5) & 0xFFFF)
        let result = try services.dispatch(syscall: number, context: context)
        context.x0 = result
        return .running
    }
}
