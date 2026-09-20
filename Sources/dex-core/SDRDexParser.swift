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

/// DEX 文件头（header_item）
public struct SDRDexHeader {
    public var version: String
    public var fileSize: UInt32
    public var headerSize: UInt32
    public var endianTag: UInt32
    public var linkSize: UInt32
    public var linkOff: UInt32
    public var mapOff: UInt32
    public var stringIdsSize: UInt32
    public var stringIdsOff: UInt32
    public var typeIdsSize: UInt32
    public var typeIdsOff: UInt32
    public var protoIdsSize: UInt32
    public var protoIdsOff: UInt32
    public var fieldIdsSize: UInt32
    public var fieldIdsOff: UInt32
    public var methodIdsSize: UInt32
    public var methodIdsOff: UInt32
    public var classDefsSize: UInt32
    public var classDefsOff: UInt32
    public var dataSize: UInt32
    public var dataOff: UInt32

    public var isLittleEndian: Bool { endianTag == 0x12345678 }
}

/// code_item（方法体）
/// 单个 catch 目标：`typeDescriptor == nil` 表示 catch-all（finally 合成块）
public struct SDRDexCatchTarget {
    public var typeDescriptor: String?
    public var address: Int
}

/// 一条 try_item 展开后的异常表条目：指令区间 [startAddr, endAddr) 与全部 catch 目标
public struct SDRDexTryBlock {
    public var startAddr: Int
    public var endAddr: Int
    public var targets: [SDRDexCatchTarget]
}

/// 原始 try_item（8 字节：start_addr / insn_count / handler_off）
public struct SDRDexTryItem {
    public var startAddr: UInt32
    public var insnCount: UInt16
    public var handlerOff: UInt16
}

public struct SDRDexCodeItem {
    public var registersSize: UInt16
    public var insSize: UInt16
    public var outsSize: UInt16
    public var triesSize: UInt16
    public var debugInfoOff: UInt32
    public var insnsSize: UInt32
    public var insns: [UInt16]
    /// 异常表（阶段四异常模型）：按 try_item 声明顺序展开，供解释器快速匹配
    public var tries: [SDRDexTryBlock]
}

public struct SDRDexMethodId {
    public var classIdx: UInt32
    public var protoIdx: UInt32
    public var nameIdx: UInt32
}

public struct SDRDexProtoId {
    public var shortyIdx: UInt32
    public var returnTypeIdx: UInt32
    public var parametersOff: UInt32
}

public struct SDRDexFieldId {
    public var classIdx: UInt32
    public var typeIdx: UInt32
    public var nameIdx: UInt32
}

public struct SDRDexClassDef {
    public var classIdx: UInt32
    public var accessFlags: UInt32
    public var superclassIdx: UInt32
    public var interfacesOff: UInt32
    public var sourceFileIdx: UInt32
    public var annotationsOff: UInt32
    public var classDataOff: UInt32
    public var staticValuesOff: UInt32
}

public struct SDRDexEncodedField {
    public var fieldIdx: UInt32
    public var accessFlags: UInt32
}

public struct SDRDexEncodedMethod {
    public var methodIdx: UInt32
    public var accessFlags: UInt32
    public var codeOff: UInt32
}

public struct SDRDexClassData {
    public var staticFields: [SDRDexEncodedField]
    public var instanceFields: [SDRDexEncodedField]
    public var directMethods: [SDRDexEncodedMethod]
    public var virtualMethods: [SDRDexEncodedMethod]

    public var allMethods: [SDRDexEncodedMethod] { directMethods + virtualMethods }
}

/// 已解析的 DEX 文件（头 + 各 id 表 + 类定义；按需惰性读取 code_item / class_data）
public final class SDRDexFile {

    public let data: [UInt8]
    public let header: SDRDexHeader
    public let strings: [String]
    public let typeIds: [UInt32]
    public let protoIds: [SDRDexProtoId]
    public let fieldIds: [SDRDexFieldId]
    public let methodIds: [SDRDexMethodId]
    public let classDefs: [SDRDexClassDef]

    /// 签名（"Lcls;->name(proto)ret"）→ method_idx 索引
    public private(set) lazy var signatureIndex: [String: UInt32] = {
        var map: [String: UInt32] = [:]
        for i in 0..<methodIds.count { map[methodSignature(at: UInt32(i))] = UInt32(i) }
        return map
    }()

    /// method_idx → accessFlags（惰性全量索引，供 isStaticMethod 判定 this 槽位）
    private var methodAccessFlags: [UInt32: UInt32] = [:]
    private var methodAccessIndexBuilt = false

    /// 类描述符（"Lcls;"）→ class_defs 下标
    public private(set) lazy var classIndex: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, def) in classDefs.enumerated() { map[typeDescriptor(at: def.classIdx)] = i }
        return map
    }()

    public init(data: [UInt8]) throws {
        self.data = data
        let header = try SDRDexParser.parseHeader(data)
        self.header = header

        var r = SDRByteReader(data, littleEndian: header.isLittleEndian)

        // string_ids → 字符串表
        var strings: [String] = []
        strings.reserveCapacity(Int(header.stringIdsSize))
        for i in 0..<Int(header.stringIdsSize) {
            r.seek(Int(header.stringIdsOff) + i * 4)
            guard let off = r.u32() else { break }
            r.seek(Int(off))
            // string_data_item = uleb128(utf16_size) + MUTF-8 字节序列 + 0x00 终止符
            guard let _ = r.uleb128() else { break }
            var raw: [UInt8] = []
            while let b = r.u8(), b != 0 { raw.append(b) }
            strings.append(String(decoding: raw, as: UTF8.self))
        }
        self.strings = strings

        // type_ids
        var types: [UInt32] = []
        types.reserveCapacity(Int(header.typeIdsSize))
        for i in 0..<Int(header.typeIdsSize) {
            r.seek(Int(header.typeIdsOff) + i * 4)
            guard let v = r.u32() else { break }
            types.append(v)
        }
        self.typeIds = types

        // proto_ids（12 字节：shorty / return_type / parameters_off）
        var protos: [SDRDexProtoId] = []
        protos.reserveCapacity(Int(header.protoIdsSize))
        for i in 0..<Int(header.protoIdsSize) {
            r.seek(Int(header.protoIdsOff) + i * 12)
            guard let shorty = r.u32(), let ret = r.u32(), let params = r.u32() else { break }
            protos.append(SDRDexProtoId(shortyIdx: shorty, returnTypeIdx: ret, parametersOff: params))
        }
        self.protoIds = protos

        // field_ids（8 字节：class(u16) / type(u16) / name(u32)）
        var fields: [SDRDexFieldId] = []
        fields.reserveCapacity(Int(header.fieldIdsSize))
        for i in 0..<Int(header.fieldIdsSize) {
            r.seek(Int(header.fieldIdsOff) + i * 8)
            guard let c = r.u16(), let t = r.u16(), let n = r.u32() else { break }
            fields.append(SDRDexFieldId(classIdx: UInt32(c), typeIdx: UInt32(t), nameIdx: n))
        }
        self.fieldIds = fields

        // method_ids（8 字节：class(u16) / proto(u16) / name(u32)）
        var methods: [SDRDexMethodId] = []
        methods.reserveCapacity(Int(header.methodIdsSize))
        for i in 0..<Int(header.methodIdsSize) {
            r.seek(Int(header.methodIdsOff) + i * 8)
            guard let c = r.u16(), let p = r.u16(), let n = r.u32() else { break }
            methods.append(SDRDexMethodId(classIdx: UInt32(c), protoIdx: UInt32(p), nameIdx: n))
        }
        self.methodIds = methods

        // class_defs（32 字节）
        var defs: [SDRDexClassDef] = []
        defs.reserveCapacity(Int(header.classDefsSize))
        for i in 0..<Int(header.classDefsSize) {
            r.seek(Int(header.classDefsOff) + i * 32)
            guard let c = r.u32(), let af = r.u32(), let sc = r.u32(), let itf = r.u32(),
                  let sf = r.u32(), let ann = r.u32(), let cd = r.u32(), let sv = r.u32() else { break }
            defs.append(SDRDexClassDef(classIdx: c, accessFlags: af, superclassIdx: sc,
                                       interfacesOff: itf, sourceFileIdx: sf,
                                       annotationsOff: ann, classDataOff: cd, staticValuesOff: sv))
        }
        self.classDefs = defs

        if Int(header.methodIdsSize) != methods.count {
            throw SDRAppError(.dexBadMagic,
                              "method_ids 表截断：声明 \(header.methodIdsSize) 实读 \(methods.count)")
        }
        if Int(header.classDefsSize) != defs.count {
            throw SDRAppError(.dexBadMagic,
                              "class_defs 表截断：声明 \(header.classDefsSize) 实读 \(defs.count)")
        }
    }

    // MARK: - 描述符

    /// type_idx → 原始描述符（如 "Ljava/lang/String;" / "[I" / "I"）
    public func typeDescriptor(at idx: UInt32) -> String {
        guard Int(idx) < typeIds.count else { return "?" }
        let si = Int(typeIds[Int(idx)])
        guard si < strings.count else { return "?" }
        return strings[si]
    }

    /// 描述符 → 人类可读名（"Ljava/lang/String;" → "java.lang.String"）
    public static func humanDescriptor(_ descriptor: String) -> String {
        var s = descriptor
        var arrays = 0
        while s.hasPrefix("[") { arrays += 1; s.removeFirst() }
        var base: String
        if s.hasPrefix("L") && s.hasSuffix(";") && s.count >= 2 {
            base = String(s.dropFirst().dropLast()).replacingOccurrences(of: "/", with: ".")
        } else {
            base = primitiveName(s)
        }
        return base + String(repeating: "[]", count: arrays)
    }

    public static func primitiveName(_ short: String) -> String {
        switch short {
        case "V": return "void"
        case "Z": return "boolean"
        case "B": return "byte"
        case "S": return "short"
        case "C": return "char"
        case "I": return "int"
        case "J": return "long"
        case "F": return "float"
        case "D": return "double"
        default: return short
        }
    }

    /// proto_idx → "(I I)J" 风格的参数/返回描述串（dex 原始描述符）
    public func protoString(at idx: UInt32) -> String {
        guard Int(idx) < protoIds.count else { return "()V" }
        let proto = protoIds[Int(idx)]
        var params: [String] = []
        for t in parameterTypeIndices(proto) { params.append(typeDescriptor(at: t)) }
        return "(" + params.joined() + ")" + typeDescriptor(at: proto.returnTypeIdx)
    }

    /// 参数类型索引列表（按 type_list 顺序展开）
    public func parameterTypeIndices(_ proto: SDRDexProtoId) -> [UInt32] {
        guard proto.parametersOff != 0 else { return [] }
        var r = SDRByteReader(data, littleEndian: header.isLittleEndian)
        r.seek(Int(proto.parametersOff))
        guard let size = r.u32() else { return [] }
        var out: [UInt32] = []
        for i in 0..<Int(size) {
            r.seek(Int(proto.parametersOff) + 4 + i * 2)
            guard let t = r.u16() else { break }
            out.append(UInt32(t))
        }
        return out
    }

    /// 方法签名："LProbe;->i2l(I)J"
    public func methodSignature(at idx: UInt32) -> String {
        guard Int(idx) < methodIds.count else { return "?->?(?)?" }
        let m = methodIds[Int(idx)]
        let cls = typeDescriptor(at: m.classIdx)
        let name = Int(m.nameIdx) < strings.count ? strings[Int(m.nameIdx)] : "?"
        return cls + "->" + name + protoString(at: m.protoIdx)
    }

    /// 方法签名拆分：(类描述符, 方法名, 原型串)
    public func methodParts(at idx: UInt32) -> (cls: String, name: String, proto: String) {
        guard Int(idx) < methodIds.count else { return ("?", "?", "()V") }
        let m = methodIds[Int(idx)]
        let cls = typeDescriptor(at: m.classIdx)
        let name = Int(m.nameIdx) < strings.count ? strings[Int(m.nameIdx)] : "?"
        return (cls, name, protoString(at: m.protoIdx))
    }

    /// 字段签名："LProbe;->seed:I"
    public func fieldSignature(at idx: UInt32) -> String {
        guard Int(idx) < fieldIds.count else { return "?->?:?" }
        let f = fieldIds[Int(idx)]
        let cls = typeDescriptor(at: f.classIdx)
        let name = Int(f.nameIdx) < strings.count ? strings[Int(f.nameIdx)] : "?"
        return cls + "->" + name + ":" + typeDescriptor(at: f.typeIdx)
    }

    // MARK: - 查找

    public func findMethodIndex(_ signature: String) -> UInt32? { signatureIndex[signature] }

    /// 方法是否静态（决定调用点是否占用 this 寄存器、解释器是否装配 receiver）
    ///
    /// DEX 的 `method_idx` 只指向 proto/cls/name，访问标志必须回到 class_data 的 encoded_method 反查；
    /// 首次查询时全量扫描一遍并常驻 `methodAccessFlags`，之后为 O(1)。
    /// 未在 class_data 中出现的方法（外部方法 / native）按静态处理——它们不进入解释器的方法体装配路径。
    public func isStaticMethod(at idx: UInt32) -> Bool {
        if !methodAccessIndexBuilt {
            for def in classDefs where def.classDataOff != 0 {
                for m in methods(ofClass: typeDescriptor(at: def.classIdx)) {
                    methodAccessFlags[m.methodIdx] = m.accessFlags
                }
            }
            methodAccessIndexBuilt = true
        }
        guard let flags = methodAccessFlags[idx] else { return true }
        return (flags & 0x0008) != 0
    }

    /// 虚方法表索引化入口：按 receiver 实际类型解析覆写目标
    ///
    /// 语义（阶段四口径）：
    ///   1. 从 `receiverDescriptor` 自身出发沿超类链上行，逐层用「类描述符 + 调用点的方法尾（`->name(proto)ret`）」拼签名查表；
    ///   2. 首次命中即为**最具体覆写**（Java 单继承下的虚分派结果），直接返回其 `method_idx`；
    ///   3. 链上出现 dex 之外的类型（`java.lang.*` 等）或链深超过 32 层即判定「无覆写」，返回 nil，
    ///      由调用方沿用调用点声明的 method_idx —— 只可能落到声明实现或「外部方法无实现」的显式报错，
    ///      **绝不静默返回 0**。
    ///
    /// - Note: 只做「同名 + 同 proto」精确匹配，不展开接口实现关系（接口方法由实现类的同名方法命中，
    ///         阶段五接入 Java 运行时后再交由其类型系统处理协变等高级语义）。
    public func resolveVirtualMethod(declaredSignature: String,
                                     receiverDescriptor: String) -> UInt32? {
        guard let arrow = declaredSignature.range(of: "->") else { return nil }
        let tail = String(declaredSignature[arrow.lowerBound...])   // "->name(proto)ret"
        var current = receiverDescriptor
        var depth = 0
        while depth < 32 && !current.isEmpty {
            depth += 1
            if let hit = signatureIndex[current + tail] { return hit }
            guard let def = findClassDef(current) else { return nil }
            let superDesc = typeDescriptor(at: def.superclassIdx)
            if superDesc == current { break }
            current = superDesc
        }
        return nil
    }

    /// 内建 JDK 类型层次（dex 之外的类型链，异常族为 catch 匹配主力）
    ///
    /// 说明：DEX 只携带自身类层次，`java.lang.*` 的类型链需由运行时补齐；
    /// 未列出的外部类型退化为「仅精确匹配」，不会误伤已实现语义。
    public static let builtinSuperTypes: [String: String] = [
        "Ljava/lang/ArithmeticException;": "Ljava/lang/RuntimeException;",
        "Ljava/lang/NullPointerException;": "Ljava/lang/RuntimeException;",
        "Ljava/lang/ClassCastException;": "Ljava/lang/RuntimeException;",
        "Ljava/lang/IllegalStateException;": "Ljava/lang/RuntimeException;",
        "Ljava/lang/IllegalArgumentException;": "Ljava/lang/RuntimeException;",
        "Ljava/lang/NegativeArraySizeException;": "Ljava/lang/RuntimeException;",
        "Ljava/lang/ArrayIndexOutOfBoundsException;": "Ljava/lang/IndexOutOfBoundsException;",
        "Ljava/lang/IndexOutOfBoundsException;": "Ljava/lang/RuntimeException;",
        "Ljava/lang/RuntimeException;": "Ljava/lang/Exception;",
        "Ljava/lang/Exception;": "Ljava/lang/Throwable;",
        "Ljava/lang/Error;": "Ljava/lang/Throwable;",
        "Ljava/lang/StackTraceElement;": "Ljava/lang/Object;",
        "Ljava/lang/String;": "Ljava/lang/Object;",
        "Ljava/lang/Object;": "",
    ]

    /// 引用类型可赋值性判定（catch 类型匹配 / instance-of）
    ///
    /// 先沿 class_defs 的超类链上行（覆盖 dex 内自定义异常类），命中外部描述符时
    /// 回落 `builtinSuperTypes` 内建层次；`java.lang.Object` 视为万能父类。
    /// 接口实现关系不在本方法内展开（阶段四接入 Java 运行时后由其类型系统接管）。
    public func isAssignable(_ descriptor: String, to target: String) -> Bool {
        if descriptor == target { return true }
        if target == "Ljava/lang/Object;" { return true }
        var current = descriptor
        var depth = 0
        while depth < 32 && !current.isEmpty {
            depth += 1
            if let def = findClassDef(current) {
                let superDesc = typeDescriptor(at: def.superclassIdx)
                if superDesc == current { break }
                current = superDesc
            } else if let up = SDRDexFile.builtinSuperTypes[current] {
                current = up
            } else {
                break
            }
            if current == target { return true }
        }
        return false
    }

    public func findClassDef(_ descriptor: String) -> SDRDexClassDef? {
        guard let i = classIndex[descriptor] else { return nil }
        return classDefs[i]
    }

    /// 某个类的方法体列表（含直接/虚方法）
    public func methods(ofClass descriptor: String) -> [SDRDexEncodedMethod] {
        guard let def = findClassDef(descriptor), def.classDataOff != 0,
              let cd = try? classData(at: def.classDataOff) else { return [] }
        return cd.allMethods
    }

    /// 全量方法体（遍历所有类，供单元测试对拍使用）
    public func allEncodedMethods() -> [SDRDexEncodedMethod] {
        var out: [SDRDexEncodedMethod] = []
        for def in classDefs where def.classDataOff != 0 {
            if let cd = try? classData(at: def.classDataOff) { out.append(contentsOf: cd.allMethods) }
        }
        return out
    }

    // MARK: - code_item / class_data

    public func codeItem(at off: UInt32) throws -> SDRDexCodeItem {
        guard off != 0, Int(off) < data.count else {
            throw SDRAppError(.dexBadMagic, "code_item 偏移非法：\(off)")
        }
        var r = SDRByteReader(data, littleEndian: header.isLittleEndian)
        r.seek(Int(off))
        guard let regs = r.u16(), let ins = r.u16(), let outs = r.u16(), let tries = r.u16(),
              let dbg = r.u32(), let size = r.u32() else {
            throw SDRAppError(.dexBadMagic, "code_item 头解析失败 @\(off)")
        }
        let byteCount = Int(size) * 2
        guard let raw = r.bytes(byteCount) else {
            throw SDRAppError(.dexBadMagic, "code_item 指令区截断 @\(off)（声明 \(size) code unit）")
        }
        var insns = [UInt16](repeating: 0, count: Int(size))
        for i in 0..<Int(size) {
            insns[i] = UInt16(raw[i * 2]) | (UInt16(raw[i * 2 + 1]) << 8)
        }
        return SDRDexCodeItem(registersSize: regs, insSize: ins, outsSize: outs,
                              triesSize: tries, debugInfoOff: dbg,
                              insnsSize: size, insns: insns,
                              tries: parseTryBlocks(off: off, insnsSize: size,
                                                    triesSize: tries, insns: insns))
    }

    /// 解析 code_item 尾部的异常表：try_item[] + encoded_catch_handler_list
    ///
    /// 布局（官方 `code_item` 定义）：
    ///   insns[insns_size] → [padding（insns_size 为奇数时 2 字节）] →
    ///   try_item[tries_size]（8 字节/条）→ encoded_catch_handler_list
    /// 其中 `handler_off` 是相对 encoded_catch_handler_list 起点的字节偏移。
    private func parseTryBlocks(off: UInt32, insnsSize: UInt32,
                                triesSize: UInt16, insns: [UInt16]) -> [SDRDexTryBlock] {
        guard triesSize > 0 else { return [] }
        var r = SDRByteReader(data, littleEndian: header.isLittleEndian)
        let insnsEnd = Int(off) + 16 + Int(insnsSize) * 2
        r.seek(insnsEnd)
        if insnsSize % 2 == 1 { _ = r.u16() }                       // 4 字节对齐填充
        let triesStart = r.offset
        let handlerListStart = triesStart + Int(triesSize) * 8

        var raw: [SDRDexTryItem] = []
        raw.reserveCapacity(Int(triesSize))
        for i in 0..<Int(triesSize) {
            r.seek(triesStart + i * 8)
            guard let sa = r.u32(), let ic = r.u16(), let ho = r.u16() else { break }
            raw.append(SDRDexTryItem(startAddr: sa, insnCount: ic, handlerOff: ho))
        }

        var blocks: [SDRDexTryBlock] = []
        blocks.reserveCapacity(raw.count)
        for item in raw {
            var hr = SDRByteReader(data, littleEndian: header.isLittleEndian)
            hr.seek(handlerListStart + Int(item.handlerOff))
            guard let count = hr.sleb128() else { continue }
            let typedCount = abs(Int(count))
            var targets: [SDRDexCatchTarget] = []
            for _ in 0..<typedCount {
                guard let typeIdx = hr.uleb128(), let addr = hr.uleb128() else { break }
                targets.append(SDRDexCatchTarget(typeDescriptor: typeDescriptor(at: typeIdx),
                                                address: Int(addr)))
            }
            if count <= 0, let catchAll = hr.uleb128() {
                targets.append(SDRDexCatchTarget(typeDescriptor: nil, address: Int(catchAll)))
            }
            blocks.append(SDRDexTryBlock(startAddr: Int(item.startAddr),
                                         endAddr: Int(item.startAddr) + Int(item.insnCount),
                                         targets: targets))
        }
        _ = insns
        return blocks
    }

    public func classData(at off: UInt32) throws -> SDRDexClassData {
        guard off != 0, Int(off) < data.count else {
            throw SDRAppError(.dexBadMagic, "class_data 偏移非法：\(off)")
        }
        var r = SDRByteReader(data, littleEndian: header.isLittleEndian)
        r.seek(Int(off))
        guard let staticCount = r.uleb128(), let instanceCount = r.uleb128(),
              let directCount = r.uleb128(), let virtualCount = r.uleb128() else {
            throw SDRAppError(.dexBadMagic, "class_data 头解析失败 @\(off)")
        }

        func readFields(_ count: UInt32) -> [SDRDexEncodedField] {
            var out: [SDRDexEncodedField] = []
            var idx: UInt32 = 0
            for _ in 0..<Int(count) {
                guard let diff = r.uleb128(), let flags = r.uleb128() else { break }
                idx &+= diff
                out.append(SDRDexEncodedField(fieldIdx: idx, accessFlags: flags))
            }
            return out
        }

        func readMethods(_ count: UInt32) -> [SDRDexEncodedMethod] {
            var out: [SDRDexEncodedMethod] = []
            var idx: UInt32 = 0
            for _ in 0..<Int(count) {
                guard let diff = r.uleb128(), let flags = r.uleb128(), let code = r.uleb128() else { break }
                idx &+= diff
                out.append(SDRDexEncodedMethod(methodIdx: idx, accessFlags: flags, codeOff: code))
            }
            return out
        }

        let staticFields = readFields(staticCount)
        let instanceFields = readFields(instanceCount)
        let directMethods = readMethods(directCount)
        let virtualMethods = readMethods(virtualCount)
        return SDRDexClassData(staticFields: staticFields, instanceFields: instanceFields,
                               directMethods: directMethods, virtualMethods: virtualMethods)
    }
}

public enum SDRDexParser {

    public static let magic: [UInt8] = [0x64, 0x65, 0x78, 0x0A, 0x30, 0x33, 0x35, 0x00] // "dex\n035\0"

    public static func parseHeader(_ data: [UInt8]) throws -> SDRDexHeader {
        guard data.count >= 112, Array(data[0..<4]) == [0x64, 0x65, 0x78, 0x0A] else {
            throw SDRAppError(.dexBadMagic, "DEX 魔数不匹配")
        }
        let versionBytes = Array(data[4..<7])
        let version = String(bytes: versionBytes, encoding: .utf8) ?? "035"

        var r = SDRByteReader(data)
        r.seek(32)
        guard let fileSize = r.u32(), let headerSize = r.u32(), let endianTag = r.u32(),
              let linkSize = r.u32(), let linkOff = r.u32(), let mapOff = r.u32(),
              let stringIdsSize = r.u32(), let stringIdsOff = r.u32(),
              let typeIdsSize = r.u32(), let typeIdsOff = r.u32(),
              let protoIdsSize = r.u32(), let protoIdsOff = r.u32(),
              let fieldIdsSize = r.u32(), let fieldIdsOff = r.u32(),
              let methodIdsSize = r.u32(), let methodIdsOff = r.u32(),
              let classDefsSize = r.u32(), let classDefsOff = r.u32(),
              let dataSize = r.u32(), let dataOff = r.u32() else {
            throw SDRAppError(.dexBadMagic, "DEX 头解析失败")
        }

        let header = SDRDexHeader(version: version, fileSize: fileSize, headerSize: headerSize,
                                  endianTag: endianTag, linkSize: linkSize, linkOff: linkOff,
                                  mapOff: mapOff,
                                  stringIdsSize: stringIdsSize, stringIdsOff: stringIdsOff,
                                  typeIdsSize: typeIdsSize, typeIdsOff: typeIdsOff,
                                  protoIdsSize: protoIdsSize, protoIdsOff: protoIdsOff,
                                  fieldIdsSize: fieldIdsSize, fieldIdsOff: fieldIdsOff,
                                  methodIdsSize: methodIdsSize, methodIdsOff: methodIdsOff,
                                  classDefsSize: classDefsSize, classDefsOff: classDefsOff,
                                  dataSize: dataSize, dataOff: dataOff)

        guard header.isLittleEndian else {
            throw SDRAppError(.dexBadMagic,
                              String(format: "不支持的端序标记 0x%08X（DEX 只允许小端）", endianTag))
        }
        return header
    }

    /// 读取字符串表（用于日志与调试展示）
    public static func strings(_ data: [UInt8], header: SDRDexHeader, limit: Int = 50) -> [String] {
        var r = SDRByteReader(data, littleEndian: header.isLittleEndian)
        var result: [String] = []
        for i in 0..<min(Int(header.stringIdsSize), limit) {
            r.seek(Int(header.stringIdsOff) + i * 4)
            guard let offset = r.u32() else { break }
            r.seek(Int(offset))
            guard let _ = r.uleb128() else { break }
            var raw: [UInt8] = []
            while let b = r.u8(), b != 0 { raw.append(b) }
            result.append(String(decoding: raw, as: UTF8.self))
        }
        return result
    }
}
