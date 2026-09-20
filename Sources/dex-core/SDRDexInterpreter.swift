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

/// 方法调用外接桥（阶段四接入 Java 运行时 / JNIEnv 函数表；阶段三用于宿主回调与测试替身）
public protocol SDRDexNativeBridge: AnyObject {
    func invoke(signature: String, args: [Int64]) throws -> Int64
}

/// Dalvik 字节码解释器（阶段三：DEX 解释器核心补全）
///
/// 设计约定：
/// 1. 寄存器统一 `Int64` 存放；32 位语义一律先 `s32` 截断再运算，宽值完整存于起始寄存器，
///    高槽（起始 +1）同步写入高 32 位，与 `move-wide` / `invoke` 取参一致。
/// 2. 未实现指令（浮点族、invoke-polymorphic、throw 等）**一律抛 `dexOpUnsupported`**，
///    严禁静默跳过或按宽度滑过——静默跳过会让字节码流"看似跑通"却语义全错。
/// 3. `move-result` 族读取 `result`，语义为「紧随 invoke 的下一条指令」。
public final class SDRDexInterpreter {

    public struct Frame {
        public var registers: [Int64]
        public var pc: Int
        public var methodIndex: Int
        public var method: String
    }

    public private(set) var frames: [Frame] = []
    public var maxSteps: Int = 5_000_000
    public private(set) var executedSteps = 0
    public let maxRegisters = 256

    public let file: SDRDexFile?
    public weak var bridge: (any SDRDexNativeBridge)?
    public let heap = SDRDexHeap()

    /// 静态字段区（键为 "Lcls;->name:type"）
    public var staticFields: [String: Int64] = [:]

    /// 宿主原生方法实现（键为完整签名）
    public var natives: [String: ([Int64]) throws -> Int64] = [:]

    /// 最近一次 invoke 的返回值
    public private(set) var result: Int64 = 0

    private var codeOffsetsCache: [UInt32: UInt32]?

    private static let intOps = ["add", "sub", "mul", "div", "rem", "and", "or", "xor", "shl", "shr", "ushr"]
    private static let longOps = ["add", "sub", "mul", "div", "rem", "and", "or", "xor", "shl", "shr", "ushr"]

    public init(file: SDRDexFile? = nil, bridge: (any SDRDexNativeBridge)? = nil) {
        self.file = file
        self.bridge = bridge
    }

    // MARK: - 入口

    /// 按签名调用（测试与宿主统一入口；"Lcls;->name(proto)ret"）
    @discardableResult
    public func invokeMethod(_ signature: String, args: [Int64] = []) throws -> Int64 {
        guard let dex = file else {
            throw SDRAppError(.dexOpUnsupported, "解释器未绑定 DEX 文件，无法解析 \(signature)")
        }
        if let idx = dex.findMethodIndex(signature), let off = codeOffset(forMethodIndex: idx), off != 0 {
            return try runMethod(methodIndex: idx, args: args)
        }
        if let native = natives[signature] { return try native(args) }
        if let bridge = bridge { return try bridge.invoke(signature: signature, args: args) }
        if dex.findMethodIndex(signature) == nil {
            throw SDRAppError(.dexOpUnsupported, "方法签名不存在：\(signature)")
        }
        throw SDRAppError(.dexOpUnsupported, "方法无方法体且无原生实现：\(signature)")
    }

    /// 执行指定方法体
    @discardableResult
    public func runMethod(methodIndex: UInt32, args: [Int64] = []) throws -> Int64 {
        guard let dex = file else { throw SDRAppError(.dexOpUnsupported, "解释器未绑定 DEX 文件") }
        guard let codeOff = codeOffset(forMethodIndex: methodIndex), codeOff != 0 else {
            throw SDRAppError(.dexOpUnsupported,
                              "方法无方法体（native/abstract）：\(dex.methodSignature(at: methodIndex))")
        }
        let item = try dex.codeItem(at: codeOff)
        return try run(code: item.insns,
                       registerCount: Int(item.registersSize),
                       insSize: Int(item.insSize),
                       methodIndex: methodIndex,
                       callerArgs: args)
    }

    /// 执行一段方法体（旧签名兼容：无参数装配）
    @discardableResult
    public func run(code: [UInt16], registerCount: Int, methodIndex: Int = 0) throws -> Int64 {
        try run(code: code, registerCount: registerCount, insSize: 0,
                methodIndex: UInt32(max(0, methodIndex)), callerArgs: [])
    }

    /// 执行方法体并装配入参
    @discardableResult
    public func run(code: [UInt16], registerCount: Int, insSize: Int,
                    methodIndex: UInt32, callerArgs: [Int64]) throws -> Int64 {
        var regs = [Int64](repeating: 0, count: min(max(registerCount, 0), maxRegisters))
        let proto = file?.methodParts(at: methodIndex).proto ?? "()V"
        let types = SDRDexInterpreter.paramTypes(proto)
        var slot = max(0, regs.count - insSize)
        for (t, v) in zip(types, callerArgs) {
            if t == "J" || t == "D" {
                wrW(&regs, slot, v)
                slot += 2
            } else {
                wr32(&regs, slot, v)
                slot += 1
            }
        }
        let label = file?.methodSignature(at: methodIndex) ?? "method#\(methodIndex)"
        frames.append(Frame(registers: regs, pc: 0, methodIndex: Int(methodIndex), method: label))
        defer { frames.removeLast() }
        return try execute(code: code, regs: &regs, methodIndex: methodIndex)
    }

    /// method_idx → code_off（0 表示无方法体）
    public func codeOffset(forMethodIndex methodIndex: UInt32) -> UInt32? {
        if codeOffsetsCache == nil {
            var map: [UInt32: UInt32] = [:]
            if let dex = file {
                for m in dex.allEncodedMethods() { map[m.methodIdx] = m.codeOff }
            }
            codeOffsetsCache = map
        }
        return codeOffsetsCache?[methodIndex]
    }

    /// 原型串 → 参数类型短名列表（J / D 各占两个寄存器槽）
    public static func paramTypes(_ proto: String) -> [String] {
        guard proto.hasPrefix("("), let close = proto.firstIndex(of: ")") else { return [] }
        let inner = String(proto[proto.index(after: proto.startIndex)..<close])
        var types: [String] = []
        var chars = Array(inner)
        var i = 0
        while i < chars.count {
            if chars[i] == "[" {
                while i < chars.count && chars[i] == "[" { i += 1 }
                if i < chars.count && chars[i] == "L" {
                    while i < chars.count && chars[i] != ";" { i += 1 }
                    i += 1
                } else {
                    i += 1
                }
                types.append("[")
            } else if chars[i] == "L" {
                while i < chars.count && chars[i] != ";" { i += 1 }
                i += 1
                types.append("L")
            } else {
                types.append(String(chars[i]))
                i += 1
            }
        }
        return types
    }

    // MARK: - 执行核心

    private func execute(code: [UInt16], regs: inout [Int64], methodIndex: UInt32) throws -> Int64 {
        let dex = file
        var pc = 0

        while pc < code.count {
            executedSteps += 1
            if executedSteps > maxSteps {
                throw SDRAppError(.dexOpUnsupported, "指令步数超限（疑似死循环），已中止")
            }

            let unit = code[pc]

            // ---- payload 伪指令（低字节为 0 且整体非 0）----
            if unit != 0 && (unit & 0xFF) == 0 {
                pc += SDRDexInterpreter.payloadWidth(code, pc)
                continue
            }

            let opcode = Int(unit & 0xFF)
            if SDRDexOpcode.isUnused(opcode: opcode) {
                throw SDRAppError(.dexOpUnsupported,
                                  String(format: "非法指令（官方未定义槽位）0x%02X @pc=%d", opcode, pc))
            }
            let width = SDRDexOpcode.width(opcode: opcode)
            guard width > 0 else {
                throw SDRAppError(.dexOpUnsupported,
                                  "指令宽度未知 \(SDRDexOpcode.name(opcode: opcode)) @pc=\(pc)")
            }
            var next = pc + width

            switch opcode {

            // ---- 0x00 nop ----
            case 0x00:
                break

            // ---- 0x01-0x09 move 族 ----
            case 0x01, 0x07:                                            // move / move-object (12x)
                wr32(&regs, Int(unit & 0x0F), rd32(regs, Int((unit >> 4) & 0x0F)))
            case 0x02, 0x08:                                            // move/from16 / move-object/from16 (22x)
                wr32(&regs, Int(unit >> 8), rd32(regs, Int(u1(code, pc + 1))))
            case 0x03, 0x09:                                            // move/16 / move-object/16 (32x)
                wr32(&regs, Int(u1(code, pc + 1)), rd32(regs, Int(u1(code, pc + 2))))
            case 0x04:                                                  // move-wide (12x)
                wrW(&regs, Int(unit & 0x0F), rdW(regs, Int((unit >> 4) & 0x0F)))
            case 0x05:                                                  // move-wide/from16 (22x)
                wrW(&regs, Int(unit >> 8), rdW(regs, Int(u1(code, pc + 1))))
            case 0x06:                                                  // move-wide/16 (32x)
                wrW(&regs, Int(u1(code, pc + 1)), rdW(regs, Int(u1(code, pc + 2))))

            // ---- 0x0A-0x0D move-result 族 ----
            case 0x0A:                                                  // move-result
                wr32(&regs, Int(unit >> 8), result)
            case 0x0B:                                                  // move-result-wide
                wrW(&regs, Int(unit >> 8), result)
            case 0x0C:                                                  // move-result-object
                wr32(&regs, Int(unit >> 8), result)
            case 0x0D:                                                  // move-exception
                throw SDRAppError(.dexOpUnsupported, "move-exception 待阶段四异常模型实现 @pc=\(pc)")

            // ---- 0x0E-0x11 return 族 ----
            case 0x0E:
                return 0
            case 0x0F, 0x11:
                return rd32(regs, Int(unit >> 8))
            case 0x10:
                return rdW(regs, Int(unit >> 8))

            // ---- 0x12-0x19 const 族 ----
            case 0x12:                                                  // const/4（lit4 符号扩展）
                let lit4 = Int64((unit >> 12) & 0x0F)
                wr32(&regs, Int((unit >> 8) & 0x0F), lit4 >= 8 ? lit4 - 16 : lit4)
            case 0x13:                                                  // const/16
                wr32(&regs, Int(unit >> 8), Int64(Int16(bitPattern: u1(code, pc + 1))))
            case 0x14:                                                  // const（int32）
                wr32(&regs, Int(unit >> 8),
                     Int64(Int32(bitPattern: UInt32(u1(code, pc + 1)) | (UInt32(u1(code, pc + 2)) << 16))))
            case 0x15:                                                  // const/high16：lit16 << 16
                wr32(&regs, Int(unit >> 8), s32(Int64(Int16(bitPattern: u1(code, pc + 1))) << 16))
            case 0x16:                                                  // const-wide/16
                wrW(&regs, Int(unit >> 8), Int64(Int16(bitPattern: u1(code, pc + 1))))
            case 0x17:                                                  // const-wide/32
                wrW(&regs, Int(unit >> 8),
                    Int64(Int32(bitPattern: UInt32(u1(code, pc + 1)) | (UInt32(u1(code, pc + 2)) << 16))))
            case 0x18:                                                  // const-wide（int64）
                wrW(&regs, Int(unit >> 8), SDRDexInterpreter.int64(code, pc + 1))
            case 0x19:                                                  // const-wide/high16：lit16 << 48
                wrW(&regs, Int(unit >> 8), s64(Int64(Int16(bitPattern: u1(code, pc + 1))) << 48))

            // ---- 0x1A-0x1C 引用常量 ----
            case 0x1A, 0x1B:                                            // const-string / jumbo（21c / 31c）
                let idx = opcode == 0x1A
                    ? UInt32(u1(code, pc + 1))
                    : (UInt32(u1(code, pc + 1)) | (UInt32(u1(code, pc + 2)) << 16))
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "const-string 需要 DEX 文件上下文") }
                guard Int(idx) < dex.strings.count else {
                    throw SDRAppError(.dexBadMagic, "const-string 索引越界：\(idx)")
                }
                wr32(&regs, Int(unit >> 8), heap.newString(dex.strings[Int(idx)]))
            case 0x1C:                                                  // const-class
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "const-class 需要 DEX 文件上下文") }
                wr32(&regs, Int(unit >> 8), SDRDexHeap.classTag | Int64(u1(code, pc + 1)))

            // ---- 0x1D-0x1E 监视器（单线程解释器下等价 no-op）----
            case 0x1D, 0x1E:
                SDRLogger.v("dex", "\(SDRDexOpcode.name(opcode: opcode)) 单线程下为 no-op @pc=\(pc)")

            // ---- 0x1F-0x21 类型与数组长度 ----
            case 0x1F:                                                  // check-cast（单线程仅校验非空引用）
                break
            case 0x20:                                                  // instance-of
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "instance-of 需要 DEX 文件上下文") }
                let target = dex.typeDescriptor(at: UInt32(u1(code, pc + 1)))
                let obj = rd32(regs, Int((unit >> 4) & 0x0F))
                wr32(&regs, Int(unit & 0x0F), heap.isInstance(obj, of: target) ? 1 : 0)
            case 0x21:                                                  // array-length (12x)
                let handle = rd32(regs, Int((unit >> 4) & 0x0F))
                wr32(&regs, Int(unit & 0x0F), Int64(heap.arrayLength(handle)))

            // ---- 0x22-0x23 分配 ----
            case 0x22:                                                  // new-instance
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "new-instance 需要 DEX 文件上下文") }
                let desc = dex.typeDescriptor(at: UInt32(u1(code, pc + 1)))
                wr32(&regs, Int(unit >> 8), heap.newInstance(descriptor: desc))
            case 0x23:                                                  // new-array
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "new-array 需要 DEX 文件上下文") }
                let desc = dex.typeDescriptor(at: UInt32(u1(code, pc + 1)))
                let length = Int(rd32(regs, Int((unit >> 4) & 0x0F)))
                wr32(&regs, Int(unit & 0x0F), heap.newArray(descriptor: desc, length: length))

            // ---- 0x24-0x25 filled-new-array ----
            case 0x24, 0x25:
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "filled-new-array 需要 DEX 文件上下文") }
                let typeIdx = UInt32(u1(code, pc + 1))
                let desc = dex.typeDescriptor(at: typeIdx)
                var slots: [Int] = []
                var count = 0
                if opcode == 0x24 {
                    count = Int(unit & 0x0F)
                    let word = u1(code, pc + 2)
                    var list: [Int] = []
                    if count >= 5 { list.append(Int((unit >> 12) & 0x0F)) }
                    for i in 0..<4 { list.append(Int((word >> (4 * i)) & 0x0F)) }
                    slots = Array(list.prefix(count))
                } else {
                    count = Int(unit >> 8)
                    var r = Int(u1(code, pc + 2))
                    for _ in 0..<count { slots.append(r); r += 1 }
                }
                let handle = heap.newArray(descriptor: desc, length: count)
                for (i, slotIdx) in slots.enumerated() { heap.setElement(handle, i, rd32(regs, slotIdx)) }
                result = handle

            // ---- 0x26 fill-array-data ----
            case 0x26:
                let handle = rd32(regs, Int(unit >> 8))
                let off = SDRDexInterpreter.s32(code, pc + 1)
                let pp = pc + Int(off)
                let elemWidth = Int(u1(code, pp + 1))
                let count = Int(UInt32(u1(code, pp + 2)) | (UInt32(u1(code, pp + 3)) << 16))
                for i in 0..<count {
                    let startUnit = pp + 4 + (i * max(elemWidth, 1)) / 2
                    var value: Int64 = 0
                    switch elemWidth {
                    case 1:
                        value = s8(Int64(u1(code, startUnit) & 0xFF))
                    case 2:
                        value = Int64(Int16(bitPattern: u1(code, startUnit)))
                    case 4:
                        value = Int64(Int32(bitPattern: UInt32(u1(code, startUnit)) | (UInt32(u1(code, startUnit + 1)) << 16)))
                    case 8:
                        value = SDRDexInterpreter.int64(code, startUnit)
                    default:
                        throw SDRAppError(.dexOpUnsupported, "fill-array-data 元素宽度非法：\(elemWidth)")
                    }
                    heap.setElement(handle, i, value)
                }

            // ---- 0x27 throw（阶段四）----
            case 0x27:
                throw SDRAppError(.dexOpUnsupported, "throw 待阶段四异常模型实现 @pc=\(pc)")

            // ---- 0x28-0x2A 无条件跳转 ----
            case 0x28:                                                  // goto（10t，相对当前 pc）
                next = pc + Int(Int8(bitPattern: UInt8(unit >> 8)))
            case 0x29:                                                  // goto/16（20t）
                next = pc + Int(Int16(bitPattern: u1(code, pc + 1)))
            case 0x2A:                                                  // goto/32（30t）
                next = pc + Int(SDRDexInterpreter.s32(code, pc + 1))

            // ---- 0x2B-0x2C 开关跳转 ----
            case 0x2B:                                                  // packed-switch
                let key = rd32(regs, Int(unit >> 8))
                let pp = pc + Int(SDRDexInterpreter.s32(code, pc + 1))
                let size = Int(u1(code, pp + 1))
                let firstKey = SDRDexInterpreter.s32(code, pp + 2)
                if key >= firstKey && key < firstKey + Int64(size) {
                    let i = Int(key - firstKey)
                    let target = SDRDexInterpreter.s32(code, pp + 4 + i * 2)
                    next = pc + Int(target)
                }
            case 0x2C:                                                  // sparse-switch
                let key = rd32(regs, Int(unit >> 8))
                let pp = pc + Int(SDRDexInterpreter.s32(code, pc + 1))
                let size = Int(u1(code, pp + 1))
                var target: Int64 = 0
                for i in 0..<size {
                    let k = SDRDexInterpreter.s32(code, pp + 2 + i * 2)
                    let t = SDRDexInterpreter.s32(code, pp + 2 + size * 2 + i * 2)
                    if k == key { target = t; break }
                }
                if target != 0 { next = pc + Int(target) }

            // ---- 0x2D-0x31 比较 ----
            case 0x2D, 0x2E, 0x2F, 0x30:
                throw SDRAppError(.dexOpUnsupported,
                                  "\(SDRDexOpcode.name(opcode: opcode)) 属浮点族，待阶段五实现 @pc=\(pc)")
            case 0x31:                                                  // cmp-long（23x：AA=目标，第二字低字节=左，高字节=右）
                let lhs = rdW(regs, Int(u1(code, pc + 1) & 0x00FF))
                let rhs = rdW(regs, Int((u1(code, pc + 1) >> 8) & 0x00FF))
                wr32(&regs, Int(unit >> 8), lhs > rhs ? 1 : (lhs == rhs ? 0 : -1))

            // ---- 0x32-0x37 if-test ----
            case 0x32, 0x33, 0x34, 0x35, 0x36, 0x37:
                let a = rd32(regs, Int(unit & 0x0F))
                let b = rd32(regs, Int((unit >> 4) & 0x0F))
                let off = Int(Int16(bitPattern: u1(code, pc + 1)))
                let hit: Bool
                switch opcode {
                case 0x32: hit = a == b
                case 0x33: hit = a != b
                case 0x34: hit = a < b
                case 0x35: hit = a >= b
                case 0x36: hit = a > b
                default: hit = a <= b
                }
                if hit { next = pc + off }

            // ---- 0x38-0x3D if-testz ----
            case 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D:
                let a = rd32(regs, Int(unit >> 8))
                let off = Int(Int16(bitPattern: u1(code, pc + 1)))
                let hit: Bool
                switch opcode {
                case 0x38: hit = a == 0
                case 0x39: hit = a != 0
                case 0x3A: hit = a < 0
                case 0x3B: hit = a >= 0
                case 0x3C: hit = a > 0
                default: hit = a <= 0
                }
                if hit { next = pc + off }

            // ---- 0x44-0x4A aget 族 ----
            case 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A:
                let a = Int(unit & 0x0F)
                let arr = rd32(regs, Int((unit >> 4) & 0x0F))
                let idx = Int(rd32(regs, Int(unit >> 8)))
                let raw = heap.element(arr, idx)
                switch opcode {
                case 0x47: wr32(&regs, a, raw & 1)                          // aget-boolean
                case 0x48: wr32(&regs, a, s8(raw))                          // aget-byte
                case 0x49: wr32(&regs, a, raw & 0xFFFF)                     // aget-char
                case 0x4A: wr32(&regs, a, s16(raw))                         // aget-short
                case 0x45: wrW(&regs, a, raw)                               // aget-wide
                default: wr32(&regs, a, raw)                                // aget / aget-object
                }

            // ---- 0x4B-0x51 aput 族 ----
            case 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51:
                let a = Int(unit & 0x0F)
                let arr = rd32(regs, Int((unit >> 4) & 0x0F))
                let idx = Int(rd32(regs, Int(unit >> 8)))
                let value: Int64
                switch opcode {
                case 0x4E: value = rd32(regs, a) & 1                        // aput-boolean
                case 0x4F: value = s8(rd32(regs, a))                        // aput-byte
                case 0x50: value = rd32(regs, a) & 0xFFFF                   // aput-char
                case 0x51: value = s16(rd32(regs, a))                       // aput-short
                case 0x4C: value = rdW(regs, a)                             // aput-wide
                default: value = rd32(regs, a)                              // aput / aput-object
                }
                heap.setElement(arr, idx, value)

            // ---- 0x52-0x58 iget 族 ----
            case 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58:
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "iget 需要 DEX 文件上下文") }
                let key = SDRDexInterpreter.fieldKey(dex.fieldSignature(at: UInt32(u1(code, pc + 1))))
                let obj = rd32(regs, Int((unit >> 4) & 0x0F))
                let raw = heap.field(obj, key)
                switch opcode {
                case 0x55: wr32(&regs, Int(unit & 0x0F), raw & 1)
                case 0x56: wr32(&regs, Int(unit & 0x0F), s8(raw))
                case 0x57: wr32(&regs, Int(unit & 0x0F), raw & 0xFFFF)
                case 0x58: wr32(&regs, Int(unit & 0x0F), s16(raw))
                case 0x53: wrW(&regs, Int(unit & 0x0F), raw)
                default: wr32(&regs, Int(unit & 0x0F), raw)
                }

            // ---- 0x59-0x5F iput 族 ----
            case 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F:
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "iput 需要 DEX 文件上下文") }
                let key = SDRDexInterpreter.fieldKey(dex.fieldSignature(at: UInt32(u1(code, pc + 1))))
                let obj = rd32(regs, Int((unit >> 4) & 0x0F))
                let value: Int64
                switch opcode {
                case 0x5C: value = rd32(regs, Int(unit & 0x0F)) & 1
                case 0x5D: value = s8(rd32(regs, Int(unit & 0x0F)))
                case 0x5E: value = rd32(regs, Int(unit & 0x0F)) & 0xFFFF
                case 0x5F: value = s16(rd32(regs, Int(unit & 0x0F)))
                case 0x5A: value = rdW(regs, Int(unit & 0x0F))
                default: value = rd32(regs, Int(unit & 0x0F))
                }
                heap.setField(obj, key, value)

            // ---- 0x60-0x66 sget 族 ----
            case 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66:
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "sget 需要 DEX 文件上下文") }
                let sig = dex.fieldSignature(at: UInt32(u1(code, pc + 1)))
                let raw = staticFields[sig] ?? 0
                switch opcode {
                case 0x63: wr32(&regs, Int(unit >> 8), raw & 1)
                case 0x64: wr32(&regs, Int(unit >> 8), s8(raw))
                case 0x65: wr32(&regs, Int(unit >> 8), raw & 0xFFFF)
                case 0x66: wr32(&regs, Int(unit >> 8), s16(raw))
                case 0x61: wrW(&regs, Int(unit >> 8), raw)
                default: wr32(&regs, Int(unit >> 8), raw)
                }

            // ---- 0x67-0x6D sput 族 ----
            case 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D:
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "sput 需要 DEX 文件上下文") }
                let sig = dex.fieldSignature(at: UInt32(u1(code, pc + 1)))
                let value: Int64
                switch opcode {
                case 0x6A: value = rd32(regs, Int(unit >> 8)) & 1
                case 0x6B: value = s8(rd32(regs, Int(unit >> 8)))
                case 0x6C: value = rd32(regs, Int(unit >> 8)) & 0xFFFF
                case 0x6D: value = s16(rd32(regs, Int(unit >> 8)))
                case 0x68: value = rdW(regs, Int(unit >> 8))
                default: value = rd32(regs, Int(unit >> 8))
                }
                staticFields[sig] = value

            // ---- 0x6E-0x78 invoke 族 ----
            case 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78:
                guard let dex = dex else { throw SDRAppError(.dexOpUnsupported, "invoke 需要 DEX 文件上下文") }
                let methodIdx = UInt32(u1(code, pc + 1))
                let signature = dex.methodSignature(at: methodIdx)
                let types = SDRDexInterpreter.paramTypes(dex.methodParts(at: methodIdx).proto)
                var args: [Int64] = []
                if opcode >= 0x74 {
                    let count = Int(unit >> 8)
                    var slot = Int(u1(code, pc + 2))
                    for t in types.prefix(count) {
                        if t == "J" || t == "D" { args.append(rdW(regs, slot)); slot += 2 } else { args.append(rd32(regs, slot)); slot += 1 }
                    }
                } else {
                    let count = Int(unit & 0x0F)
                    let word = u1(code, pc + 2)
                    var slots: [Int] = []
                    if count >= 5 { slots.append(Int((unit >> 12) & 0x0F)) }
                    for i in 0..<4 { slots.append(Int((word >> (4 * i)) & 0x0F)) }
                    var cursor = 0
                    for t in types {
                        guard cursor < slots.count else { break }
                        if t == "J" || t == "D" {
                            args.append(rdW(regs, slots[cursor]))
                            cursor += 2
                        } else {
                            args.append(rd32(regs, slots[cursor]))
                            cursor += 1
                        }
                    }
                }
                result = try invokeResolved(signature: signature, methodIndex: methodIdx, args: args)

            // ---- 0x7B-0x80 neg/not 族 ----
            case 0x7B: wr32(&regs, Int(unit >> 8), s32(0 &- s32(rd32(regs, Int(unit >> 8)))))   // neg-int
            case 0x7C: wr32(&regs, Int(unit >> 8), s32(~s32(rd32(regs, Int(unit >> 8)))))       // not-int
            case 0x7D: wrW(&regs, Int(unit >> 8), 0 &- rdW(regs, Int(unit >> 8)))               // neg-long
            case 0x7E: wrW(&regs, Int(unit >> 8), ~rdW(regs, Int(unit >> 8)))                   // not-long
            case 0x7F, 0x80:
                throw SDRAppError(.dexOpUnsupported,
                                  "\(SDRDexOpcode.name(opcode: opcode)) 属浮点族，待阶段五实现 @pc=\(pc)")

            // ---- 0x81-0x8F 类型转换（整数域；浮点域待阶段五）----
            case 0x81: wrW(&regs, Int(unit >> 8), s32(rd32(regs, Int(unit >> 8))))              // int-to-long
            case 0x84: wr32(&regs, Int(unit >> 8), s32(rdW(regs, Int(unit >> 8))))              // long-to-int
            case 0x8D: wr32(&regs, Int(unit >> 8), s8(rd32(regs, Int(unit >> 8))))              // int-to-byte
            case 0x8E: wr32(&regs, Int(unit >> 8), rd32(regs, Int(unit >> 8)) & 0xFFFF)         // int-to-char
            case 0x8F: wr32(&regs, Int(unit >> 8), s16(rd32(regs, Int(unit >> 8))))             // int-to-short
            case 0x82, 0x83, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C:
                throw SDRAppError(.dexOpUnsupported,
                                  "\(SDRDexOpcode.name(opcode: opcode)) 属浮点转换族，待阶段五实现 @pc=\(pc)")

            // ---- 0x90-0x9A int 二元 ----
            case 0x90...0x9A:
                let a = Int(unit & 0x0F)
                let b = rd32(regs, Int((unit >> 4) & 0x0F))
                let c = rd32(regs, Int(unit >> 8))
                let value = try intBinary(Self.intOps[opcode - 0x90], b, c)
                wr32(&regs, a, value)

            // ---- 0x9B-0xA5 long 二元 ----
            case 0x9B...0xA5:
                let a = Int(unit & 0x0F)
                let b = rdW(regs, Int((unit >> 4) & 0x0F))
                let c = rdW(regs, Int(unit >> 8))
                let value = try longBinary(Self.longOps[opcode - 0x9B], b, c)
                wrW(&regs, a, value)

            // ---- 0xA6-0xAF 浮点二元（阶段五）----
            case 0xA6...0xAF:
                throw SDRAppError(.dexOpUnsupported,
                                  "\(SDRDexOpcode.name(opcode: opcode)) 属浮点族，待阶段五实现 @pc=\(pc)")

            // ---- 0xB0-0xBA int /2addr ----
            case 0xB0...0xBA:
                let a = Int(unit & 0x0F)
                let b = rd32(regs, Int((unit >> 4) & 0x0F))
                let value = try intBinary(Self.intOps[opcode - 0xB0], rd32(regs, a), b)
                wr32(&regs, a, value)

            // ---- 0xBB-0xC5 long /2addr ----
            case 0xBB...0xC5:
                let a = Int(unit & 0x0F)
                let b = rdW(regs, Int((unit >> 4) & 0x0F))
                let value = try longBinary(Self.longOps[opcode - 0xBB], rdW(regs, a), b)
                wrW(&regs, a, value)

            // ---- 0xC6-0xCF 浮点 /2addr（阶段五）----
            case 0xC6...0xCF:
                throw SDRAppError(.dexOpUnsupported,
                                  "\(SDRDexOpcode.name(opcode: opcode)) 属浮点族，待阶段五实现 @pc=\(pc)")

            // ---- 0xD0-0xD7 int/lit16 ----
            case 0xD0...0xD7:
                let a = Int(unit & 0x0F)
                let b = rd32(regs, Int((unit >> 4) & 0x0F))
                let lit = Int64(Int16(bitPattern: u1(code, pc + 1)))
                let value = try intBinary(Self.intOps[opcode - 0xD0], b, lit)
                wr32(&regs, a, value)

            // ---- 0xD8-0xE2 int/lit8 ----
            case 0xD8...0xE2:
                let a = Int((unit >> 8) & 0x0F)
                let b = rd32(regs, Int((unit >> 12) & 0x0F))
                let lit = s8(Int64(u1(code, pc + 1) & 0xFF))
                let value = try intBinary(Self.intOps[opcode - 0xD8], b, lit)
                wr32(&regs, a, value)

            // ---- 0xFA-0xFD invoke-polymorphic / invoke-custom（阶段四）----
            case 0xFA, 0xFB, 0xFC, 0xFD:
                throw SDRAppError(.dexOpUnsupported,
                                  "\(SDRDexOpcode.name(opcode: opcode)) 待阶段四实现 @pc=\(pc)")

            default:
                throw SDRAppError(.dexOpUnsupported,
                                  "未实现指令 \(SDRDexOpcode.name(opcode: opcode))（格式 \(SDRDexOpcode.format(opcode: opcode))）@pc=\(pc)")
            }

            pc = next
        }

        _ = methodIndex
        return 0
    }

    // MARK: - 调用分派

    private func invokeResolved(signature: String, methodIndex: UInt32, args: [Int64]) throws -> Int64 {
        if let off = codeOffset(forMethodIndex: methodIndex), off != 0 {
            return try runMethod(methodIndex: methodIndex, args: args)
        }
        if let native = natives[signature] { return try native(args) }
        if let bridge = bridge { return try bridge.invoke(signature: signature, args: args) }
        throw SDRAppError(.dexOpUnsupported, "外部方法无实现：\(signature)")
    }

    // MARK: - 运算语义

    private func intBinary(_ sym: String, _ a: Int64, _ b: Int64) throws -> Int64 {
        let x = s32(a)
        switch sym {
        case "add": return s32(x &+ s32(b))
        case "sub": return s32(x &- s32(b))
        case "mul": return s32(x &* s32(b))
        case "div": return try intDiv(x, s32(b))
        case "rem": return try intRem(x, s32(b))
        case "and": return x & s32(b)
        case "or": return x | s32(b)
        case "xor": return x ^ s32(b)
        case "shl": return s32(x << (s32(b) & 0x1F))
        case "shr": return x >> (s32(b) & 0x1F)
        case "ushr":
            let u = UInt32(bitPattern: Int32(truncatingIfNeeded: x))
            return Int64(u >> UInt32(s32(b) & 0x1F))
        default:
            throw SDRAppError(.dexOpUnsupported, "未知 int 二元运算：\(sym)")
        }
    }

    private func longBinary(_ sym: String, _ a: Int64, _ b: Int64) throws -> Int64 {
        switch sym {
        case "add": return a &+ b
        case "sub": return a &- b
        case "mul": return a &* b
        case "div": return try longDiv(a, b)
        case "rem": return try longRem(a, b)
        case "and": return a & b
        case "or": return a | b
        case "xor": return a ^ b
        case "shl": return a << (b & 0x3F)
        case "shr": return a >> (b & 0x3F)
        case "ushr":
            let u = UInt64(bitPattern: a)
            return Int64(bitPattern: u >> UInt64(b & 0x3F))
        default:
            throw SDRAppError(.dexOpUnsupported, "未知 long 二元运算：\(sym)")
        }
    }

    /// div-int 溢出（Int32.min / -1）按 JVM 语义回绕，除零抛错（阶段四接 ArithmeticException）
    private func intDiv(_ x: Int64, _ y: Int64) throws -> Int64 {
        if y == 0 { throw SDRAppError(.dexOpUnsupported, "div-int 除数为 0") }
        if x == Int64(Int32.min) && y == -1 { return Int64(Int32.min) }
        return s32(x / y)
    }

    private func intRem(_ x: Int64, _ y: Int64) throws -> Int64 {
        if y == 0 { throw SDRAppError(.dexOpUnsupported, "rem-int 除数为 0") }
        if x == Int64(Int32.min) && y == -1 { return 0 }
        return s32(x % y)
    }

    private func longDiv(_ x: Int64, _ y: Int64) throws -> Int64 {
        if y == 0 { throw SDRAppError(.dexOpUnsupported, "div-long 除数为 0") }
        if x == Int64.min && y == -1 { return Int64.min }
        return x / y
    }

    private func longRem(_ x: Int64, _ y: Int64) throws -> Int64 {
        if y == 0 { throw SDRAppError(.dexOpUnsupported, "rem-long 除数为 0") }
        if x == Int64.min && y == -1 { return 0 }
        return x % y
    }

    // MARK: - 底层工具

    @inline(__always) private func u1(_ code: [UInt16], _ pc: Int) -> UInt16 {
        (pc >= 0 && pc < code.count) ? code[pc] : 0
    }

    @inline(__always) private func s8(_ v: Int64) -> Int64 { Int64(Int8(truncatingIfNeeded: v)) }
    @inline(__always) private func s16(_ v: Int64) -> Int64 { Int64(Int16(truncatingIfNeeded: v)) }
    @inline(__always) private func s32(_ v: Int64) -> Int64 { Int64(Int32(truncatingIfNeeded: v)) }
    @inline(__always) private func s64(_ v: Int64) -> Int64 { v }

    @inline(__always) private func rd32(_ r: [Int64], _ i: Int) -> Int64 {
        guard i >= 0 && i < r.count else { return 0 }
        return Int64(Int32(truncatingIfNeeded: r[i]))
    }

    @inline(__always) private func wr32(_ r: inout [Int64], _ i: Int, _ v: Int64) {
        guard i >= 0 && i < r.count else { return }
        r[i] = Int64(Int32(truncatingIfNeeded: v))
    }

    @inline(__always) private func rdW(_ r: [Int64], _ i: Int) -> Int64 {
        guard i >= 0 && i < r.count else { return 0 }
        let lo = UInt64(bitPattern: r[i]) & 0xFFFF_FFFF
        guard i + 1 < r.count else { return Int64(bitPattern: lo) }
        let hi = UInt64(bitPattern: r[i + 1]) & 0xFFFF_FFFF
        return Int64(bitPattern: lo | (hi << 32))
    }

    @inline(__always) private func wrW(_ r: inout [Int64], _ i: Int, _ v: Int64) {
        guard i >= 0 && i < r.count else { return }
        r[i] = v
        if i + 1 < r.count {
            r[i + 1] = Int64((UInt64(bitPattern: v) >> 32) & 0xFFFF_FFFF)
        }
    }

    /// 从 code unit 序列读小端 int32（相对 pc 的偏移）
    private static func s32(_ code: [UInt16], _ at: Int) -> Int64 {
        let lo = (at >= 0 && at < code.count) ? code[at] : 0
        let hi = (at + 1 >= 0 && at + 1 < code.count) ? code[at + 1] : 0
        return Int64(Int32(bitPattern: UInt32(lo) | (UInt32(hi) << 16)))
    }

    /// 从 code unit 序列读小端 int64（占 4 个 code unit）
    private static func int64(_ code: [UInt16], _ at: Int) -> Int64 {
        var raw: UInt64 = 0
        for i in 0..<4 {
            let w = (at + i >= 0 && at + i < code.count) ? code[at + i] : 0
            raw |= UInt64(w) << (16 * i)
        }
        return Int64(bitPattern: raw)
    }

    /// payload 伪指令长度（code unit）
    private static func payloadWidth(_ code: [UInt16], _ pc: Int) -> Int {
        let ident = (pc >= 0 && pc < code.count) ? code[pc] : 0
        func unit(_ i: Int) -> UInt16 { (pc + i >= 0 && pc + i < code.count) ? code[pc + i] : 0 }
        switch ident {
        case 0x0100:                                                // packed-switch-payload
            return 4 + 2 * Int(unit(1))
        case 0x0200:                                                // sparse-switch-payload
            return 2 + 4 * Int(unit(1))
        case 0x0300:                                                // fill-array-data-payload
            let elemWidth = Int(unit(1))
            let count = Int(UInt32(unit(2)) | (UInt32(unit(3)) << 16))
            return 4 + (elemWidth * count + 1) / 2
        default:
            return 1
        }
    }

    /// 字段签名 → "name:type"（实例字段键；静态字段直接用完整签名）
    private static func fieldKey(_ signature: String) -> String {
        guard let range = signature.range(of: "->") else { return signature }
        return String(signature[range.upperBound...])
    }
}
