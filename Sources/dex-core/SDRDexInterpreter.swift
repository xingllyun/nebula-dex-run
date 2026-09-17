import Foundation

/// Dalvik 字节码解释器
public final class SDRDexInterpreter {

    public struct Frame {
        public var registers: [Int64]
        public var pc: Int
        public var methodIndex: Int
    }

    public private(set) var frames: [Frame] = []
    public var maxSteps: Int = 5_000_000
    private(set) var executedSteps = 0

    public let maxRegisters = 256

    public init() {}

    /// 执行一个方法体（code 为 16 位 code unit 序列）
    @discardableResult
    public func run(code: [UInt16], registerCount: Int, methodIndex: Int = 0) throws -> Int64 {
        var frame = Frame(registers: [Int64](repeating: 0, count: min(registerCount, maxRegisters)),
                          pc: 0, methodIndex: methodIndex)
        frames.append(frame)
        defer { frames.removeLast() }

        while frame.pc < code.count {
            executedSteps += 1
            if executedSteps > maxSteps {
                throw SDRAppError(.dexOpUnsupported, "指令步数超限（疑似死循环），已中止")
            }

            let unit = code[frame.pc]
            let opcode = Int(unit & 0xFF)
            let width = SDRDexOpcode.width(opcode: opcode)
            guard width > 0 else {
                throw SDRAppError(.dexOpUnsupported,
                                  "暂不支持变长指令 \(SDRDexOpcode.names[opcode] ?? String(format: "0x%02X", opcode)) @pc=\(frame.pc)")
            }

            switch opcode {
            case 0x00:                                  // nop
                frame.pc += 1
            case 0x0E:                                  // return-void
                frame.pc = code.count
                return 0
            case 0x0F, 0x11:                            // return / return-object
                let v = Int(unit >> 8)
                frame.pc = code.count
                return frame.registers[v]
            case 0x12:                                  // const/4
                let v = Int((unit >> 8) & 0x0F)
                var lit = Int64((unit >> 12) & 0x0F)
                if lit & 0x8 != 0 { lit -= 0x10 }
                frame.registers[v] = lit
                frame.pc += 1
            case 0x13:                                  // const/16
                let v = Int(unit >> 8)
                frame.registers[v] = Int64(Int16(bitPattern: code[frame.pc + 1]))
                frame.pc += 2
            case 0x14:                                  // const
                let v = Int(unit >> 8)
                frame.registers[v] = Int64(Int32(bitPattern: UInt32(code[frame.pc + 1]) | (UInt32(code[frame.pc + 2]) << 16)))
                frame.pc += 3
            case 0x28:                                  // goto
                let rawOffset = Int8(bitPattern: UInt8(unit >> 8))
                frame.pc += Int(rawOffset)
            case 0x6E, 0x70, 0x71, 0x72:                // invoke-*
                let name = SDRDexOpcode.names[opcode] ?? "invoke"
                SDRLogger.d("dex", "\(name) method_idx=\(code[frame.pc + 1]) @pc=\(frame.pc)")
                frame.pc += 3
            default:
                SDRLogger.v("dex", "未实现指令 \(SDRDexOpcode.names[opcode] ?? String(format: "0x%02X", opcode)) @pc=\(frame.pc)")
                frame.pc += max(width, 1)
            }
        }
        return 0
    }
}
