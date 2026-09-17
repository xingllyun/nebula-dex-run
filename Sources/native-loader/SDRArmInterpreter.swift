import Foundation

/// AArch64 解释执行上下文
public final class SDRCpuContext {
    public var x: [UInt64]
    public var sp: UInt64
    public var pc: UInt64
    public var nzcv: UInt32
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
public final class SDRArmInterpreter {

    public private(set) var context: SDRCpuContext
    public let memory: SDRMemoryGuard
    public let services: SDRSystemServices
    public var instructionBudget: Int
    public private(set) var executedCount: Int = 0

    public init(context: SDRCpuContext, memory: SDRMemoryGuard,
                services: SDRSystemServices, budget: Int = 500_000) {
        self.context = context
        self.memory = memory
        self.services = services
        self.instructionBudget = budget
    }

    public func run(entry: UInt64, args: [UInt64] = []) throws -> UInt64 {
        context.pc = entry
        for (i, a) in args.enumerated() where i < 8 { context.x[i] = a }
        executedCount = 0

        var state: SDRInterpreterState = .running
        while case .running = state {
            guard executedCount < instructionBudget else {
                throw SDRAppError(.soImageInvalid, "解释执行超出指令预算")
            }
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

    private func fetch() throws -> UInt32 {
        let bytes = try memory.read(context.pc, count: 4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[i]) << (8 * UInt32(i)) }
        return v
    }

    /// 单步执行；返回下一个状态
    public func step(_ insn: UInt32) throws -> SDRInterpreterState {
        let op0 = (insn >> 25) & 0xF

        switch op0 {
        case 0b1000, 0b1001, 0b1010:
            // 数据立即数处理（含 MOVZ/MOVN/MOVK 体系）
            if (insn & 0x1F80_0000) == 0x1280_0000 || (insn & 0x7F80_0000) == 0x5280_0000 {
                return executeMoveWide(insn)
            }
            if (insn & 0x1F00_0000) == 0x1100_0000 {
                return executeAddSubImm(insn)
            }
            return executeLogicalImm(insn)
        case 0b1101, 0b1110, 0b1111:
            return try executeBranchOrSystem(insn)
        case 0b1011:
            return executeAddSubReg(insn)
        default:
            // 寄存器数据操作 / 加载存储
            if (insn & 0x3B00_0000) == 0x3900_0000 || (insn & 0x3B00_0000) == 0x3800_0000 {
                return executeLoadStore(insn)
            }
            if (insn & 0x1F00_0000) == 0x0A00_0000 {
                return executeLogicalReg(insn)
            }
            context.pc += 4
            SDRLogger.d("interp", "未覆盖指令 0x\(String(insn, radix: 16))，跳过")
            return .running
        }
    }

    private func executeMoveWide(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let opc = (insn >> 29) & 0x3
        let hw = UInt64((insn >> 21) & 0x3)
        let imm16 = UInt64((insn >> 5) & 0xFFFF)
        let rd = Int(insn & 0x1F)
        var value = imm16 << (hw * 16)

        switch opc {
        case 0: break                       // MOVN
        case 2: value = ~value              // MOVZ
        case 3:                             // MOVK：保留原值对应半字
            let mask: UInt64 = 0xFFFF << (hw * 16)
            value = (context.x[rd] & ~mask) | (imm16 << (hw * 16))
        default: break
        }

        if sf == 0 { value &= 0xFFFF_FFFF }
        context.x[rd] = value
        context.pc += 4
        return .running
    }

    private func executeAddSubImm(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let sub = (insn >> 30) & 1
        let sh = (insn >> 22) & 1
        let imm12 = UInt64((insn >> 10) & 0xFFF)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        var imm = imm12
        if sh == 1 { imm <<= 12 }

        let a = context.x[rn]
        var result: UInt64
        var carry = false
        var overflow = false

        if sub == 1 {
            (result, carry) = SDRAlu.sub(a, imm, is64: sf == 1)
            overflow = SDRAlu.subOverflow(a, imm, result: result, is64: sf == 1)
        } else {
            (result, carry) = SDRAlu.add(a, imm, is64: sf == 1)
            overflow = SDRAlu.addOverflow(a, imm, result: result, is64: sf == 1)
        }

        if sf == 0 { result &= 0xFFFF_FFFF }
        if rd != 31 { context.x[rd] = result } else { context.sp = result }
        context.setFlags(result: result, is64: sf == 1, carryOut: carry, overflowOut: overflow)
        context.pc += 4
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
        let a = context.x[rn]

        var result: UInt64
        switch opc {
        case 0: result = a & imm      // AND
        case 1: result = a | imm      // ORR
        case 2: result = a ^ imm      // EOR
        default: result = a & imm     // ANDS
        }

        if sf == 0 { result &= 0xFFFF_FFFF }
        context.x[rd] = result
        if opc == 3 {
            context.setFlags(result: result, is64: sf == 1, carryOut: false, overflowOut: false)
        }
        context.pc += 4
        return .running
    }

    private func executeAddSubReg(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let sub = (insn >> 30) & 1
        let shift = UInt64((insn >> 22) & 0x3)
        let rm = Int((insn >> 16) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        var b = context.x[rm]
        switch shift {
        case 1: b <<= 12
        case 2: b = b >> 6
        default: break
        }

        let a = context.x[rn]
        let result = sub == 1 ? (a &- b) : (a &+ b)
        let masked = sf == 1 ? result : (result & 0xFFFF_FFFF)
        context.x[rd] = masked
        context.setFlags(result: masked, is64: sf == 1, carryOut: false, overflowOut: false)
        context.pc += 4
        return .running
    }

    private func executeLogicalReg(_ insn: UInt32) -> SDRInterpreterState {
        let sf = (insn >> 31) & 1
        let opc = (insn >> 29) & 0x3
        let shift = UInt64((insn >> 22) & 0x3)
        let rm = Int((insn >> 16) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rd = Int(insn & 0x1F)

        var b = context.x[rm]
        switch shift {
        case 0: b = b << (b & 0x3F)
        case 1: b = b >> 6
        case 2: b = b >> 6
        default: break
        }

        let a = context.x[rn]
        var result: UInt64
        switch opc {
        case 0: result = a & b
        case 1: result = a | b
        case 2: result = a ^ b
        default: result = a & b
        }
        if sf == 0 { result &= 0xFFFF_FFFF }
        context.x[rd] = result
        context.pc += 4
        return .running
    }

    private func executeLoadStore(_ insn: UInt32) -> SDRInterpreterState {
        let size = UInt64((insn >> 30) & 0x3)
        let isLoad = (insn >> 22) & 1 == 1
        let imm12 = UInt64((insn >> 10) & 0xFFF)
        let rn = Int((insn >> 5) & 0x1F)
        let rt = Int(insn & 0x1F)

        let width: UInt64 = 1 << size
        let offset = imm12 * width
        let address = (rn == 31 ? context.sp : context.x[rn]) + offset
        _ = isLoad
        context.pc += 4
        SDRLogger.d("interp", "访存指令转发：addr=0x\(String(address, radix: 16)) rt=\(rt)")
        return .running
    }

    private func executeBranchOrSystem(_ insn: UInt32) throws -> SDRInterpreterState {
        // SVC 系统调用
        if (insn & 0xFFE0_001F) == 0xD400_0001 {
            return try handleSVC(insn)
        }

        // B / BL 立即数跳转
        if (insn & 0x7C00_0000) == 0x1400_0000 {
            let imm26 = Int64(insn & 0x03FF_FFFF)
            let signed = (imm26 << 38) >> 38
            let link = (insn & 0x8000_0000) != 0
            if link { context.lr = context.pc + 4 }
            context.pc = UInt64(Int64(context.pc) + signed * 4)
            return .running
        }

        // BR / BLR / RET 寄存器跳转
        if (insn & 0xFE00_0000) == 0xD600_0000 {
            let opc = (insn >> 21) & 0xF
            let rn = Int((insn >> 5) & 0x1F)
            let target = context.x[rn]
            switch opc {
            case 0: context.pc = target            // BR
            case 1: context.lr = context.pc + 4; context.pc = target  // BLR
            case 2: context.pc = target            // RET
            default: context.pc += 4
            }
            return .running
        }

        // 条件跳转
        if (insn & 0xFE00_0000) == 0x5400_0000 {
            let cond = UInt32(insn & 0xF)
            let imm19 = Int64((insn >> 5) & 0x7FFFF)
            let signed = (imm19 << 45) >> 45
            if SDRAlu.conditionHolds(cond, nzcv: context.nzcv) {
                context.pc = UInt64(Int64(context.pc) + signed * 4)
            } else {
                context.pc += 4
            }
            return .running
        }

        context.pc += 4
        return .running
    }

    private func handleSVC(_ insn: UInt32) throws -> SDRInterpreterState {
        let number = UInt32((insn >> 5) & 0xFFFF)
        let result = try services.dispatch(syscall: number, context: context)
        context.x0 = result
        context.pc += 4
        return .running
    }
}
