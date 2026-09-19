// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// 阶段二 · 步骤四：Android 运行时基础库适配（liblog / libm / libz）
//
// 步骤三解决了「SO 依赖装载 + 跨模块符号解析 + 宿主桩绑定」，本步骤把 Android NDK 下
// 最常被 JNI 代码依赖的三类系统库接到宿主实现：
//
//   liblog：__android_log_* 族 → SDRLogger（含优先级映射，便于日志控制台统一展示）
//   libm  ：sqrt/pow/fmod… 双精度族与 sqrtf/powf… 单精度族 → 宿主数学库
//           实参经 V0..V7 读取（SDRHostCallContext.floatArg / singleFloatArg），
//           返回值经托管调用陷阱写回 V0（SDRHostCall.Outcome.scalar）
//   libz  ：crc32 / adler32（纯 Swift 实现，保证与 zlib 一致）+ uncompress（宿主 inflate，windowBits=15）
//
// 仍然遵守「guest 不知道任何宿主地址」：本类只做桥注册，符号地址由 SDRHostStubPool 在
// guest 地址空间内生成的 trampoline 提供，两者以同一 SDRHostCall 的符号索引对齐。

import Foundation

public final class SDRAndroidLibs {
    public static let shared = SDRAndroidLibs()

    // MARK: 符号清单（文档与冒烟断言共用）

    public static let libLogSymbols: [String] = [
        "__android_log_write",
        "__android_log_print",
        "__android_log_vprint",
        "__android_log_buf_write",
        "__android_log_buf_print",
        "__android_log_assert",
        "__android_log_is_loggable",
    ]

    /// 双精度（实参 V0/V1，返回 V0）
    public static let mathDoubleSymbols: [String] = [
        "sqrt", "fabs", "floor", "ceil", "trunc", "round", "rint", "nearbyint",
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
        "sinh", "cosh", "tanh", "exp", "exp2", "log", "log10", "log2",
        "pow", "fmod", "remainder", "hypot", "copysign", "fmin", "fmax",
        "cbrt", "erf", "ldexp",
    ]

    /// 单精度（实参 S0/S1，返回 S0）
    public static let mathFloatSymbols: [String] = [
        "sqrtf", "fabsf", "floorf", "ceilf", "truncf", "roundf", "rintf",
        "sinf", "cosf", "tanf", "asinf", "acosf", "atanf", "atan2f",
        "expf", "exp2f", "logf", "log10f", "log2f",
        "powf", "fmodf", "hypotf", "copysignf", "fminf", "fmaxf", "cbrtf",
    ]

    public static var libMathSymbols: [String] { mathDoubleSymbols + mathFloatSymbols }

    public static let libZSymbols: [String] = ["crc32", "adler32", "uncompress"]

    /// zlib 返回码（与 zlib.h 一致）
    public static let zOk: Int32 = 0
    public static let zDataError: Int32 = -3
    public static let zBufError: Int32 = -5

    // MARK: 状态

    public private(set) var registeredSymbols: [String] = []
    private var installedBridge: ObjectIdentifier?

    /// 日志桥观测点：已转发条数与最近一条内容（供冒烟与排障使用）。
    public private(set) var emittedMessageCount = 0
    public private(set) var lastMessage: String?

    private static let probeLock = NSLock()

    public init() {}

    // MARK: 安装

    /// 幂等安装：同一桥重复安装不重复注册，返回当前已注册符号数。
    @discardableResult
    public func install(into bridge: SDRHostCall = .shared) -> Int {
        if let installed = installedBridge, installed == ObjectIdentifier(bridge) {
            return registeredSymbols.count
        }
        registeredSymbols.removeAll(keepingCapacity: true)
        installLogFamily(bridge)
        installMathFamily(bridge)
        installZlibFamily(bridge)
        installedBridge = ObjectIdentifier(bridge)
        return registeredSymbols.count
    }

    /// 一步装配：注册实现 + 在 guest 内存中建立对应桩区（返回已注册符号数）。
    @discardableResult
    public func install(into bridge: SDRHostCall, pool: SDRHostStubPool, memory: SDRMemoryGuard) -> Int {
        let count = install(into: bridge)
        _ = pool.prepare(in: memory, bridge: bridge)
        return count
    }

    private func add(_ bridge: SDRHostCall, _ name: String, _ body: @escaping SDRHostCall.Body) {
        _ = bridge.register(name, body: body)
        registeredSymbols.append(name)
    }

    private func addScalar(_ bridge: SDRHostCall, _ name: String, _ body: @escaping SDRHostCall.ScalarBody) {
        _ = bridge.registerScalar(name, body: body)
        registeredSymbols.append(name)
    }

    // MARK: liblog

    /// android_LogPriority → 宿主日志级别（2=VERBOSE…7=FATAL）。
    public static func emit(priority: Int32, tag: String, message: String) {
        let line = tag.isEmpty ? message : "[\(tag)] \(message)"
        switch priority {
        case 2: SDRLogger.v("guest.log", line)
        case 3: SDRLogger.d("guest.log", line)
        case 4: SDRLogger.i("guest.log", line)
        case 5: SDRLogger.w("guest.log", line)
        case 6, 7: SDRLogger.e("guest.log", line)
        default: SDRLogger.i("guest.log", line)
        }
        probeLock.lock()
        shared.emittedMessageCount += 1
        shared.lastMessage = line
        probeLock.unlock()
    }

    public func resetProbe() {
        Self.probeLock.lock()
        emittedMessageCount = 0
        lastMessage = nil
        Self.probeLock.unlock()
    }

    static func string(_ ctx: SDRHostCallContext, _ address: UInt64) -> String {
        guard let bytes = ctx.readCStringBytes(address) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func installLogFamily(_ bridge: SDRHostCall) {
        // __android_log_write(int prio, const char* tag, const char* text) → 写入字节数
        add(bridge, "__android_log_write") { ctx in
            SDRAndroidLibs.emit(priority: Int32(truncatingIfNeeded: ctx.arg(0)),
                                tag: SDRAndroidLibs.string(ctx, ctx.arg(1)),
                                message: SDRAndroidLibs.string(ctx, ctx.arg(2)))
            let length = ctx.readCStringBytes(ctx.arg(2))?.count ?? 0
            return UInt64(length + 1)
        }
        // __android_log_print(int prio, const char* tag, const char* fmt, ...)
        // 变参无法在宿主侧还原：记录 tag 与格式串本身，数值实参不回填。
        add(bridge, "__android_log_print") { ctx in
            let tag = SDRAndroidLibs.string(ctx, ctx.arg(1))
            let format = SDRAndroidLibs.string(ctx, ctx.arg(2))
            SDRAndroidLibs.emit(priority: Int32(truncatingIfNeeded: ctx.arg(0)), tag: tag, message: format)
            return UInt64(format.utf8.count + 1)
        }
        // __android_log_vprint(int prio, const char* tag, const char* fmt, va_list ap)：同上
        add(bridge, "__android_log_vprint") { ctx in
            let tag = SDRAndroidLibs.string(ctx, ctx.arg(1))
            let format = SDRAndroidLibs.string(ctx, ctx.arg(2))
            SDRAndroidLibs.emit(priority: Int32(truncatingIfNeeded: ctx.arg(0)), tag: tag, message: format)
            return UInt64(format.utf8.count + 1)
        }
        // __android_log_buf_write(int bufID, int prio, const char* tag, const char* text)
        add(bridge, "__android_log_buf_write") { ctx in
            SDRAndroidLibs.emit(priority: Int32(truncatingIfNeeded: ctx.arg(1)),
                                tag: SDRAndroidLibs.string(ctx, ctx.arg(2)),
                                message: SDRAndroidLibs.string(ctx, ctx.arg(3)))
            let length = ctx.readCStringBytes(ctx.arg(3))?.count ?? 0
            return UInt64(length + 1)
        }
        // __android_log_buf_print(int bufID, int prio, const char* tag, const char* fmt, ...)
        add(bridge, "__android_log_buf_print") { ctx in
            let tag = SDRAndroidLibs.string(ctx, ctx.arg(2))
            let format = SDRAndroidLibs.string(ctx, ctx.arg(3))
            SDRAndroidLibs.emit(priority: Int32(truncatingIfNeeded: ctx.arg(1)), tag: tag, message: format)
            return UInt64(format.utf8.count + 1)
        }
        // __android_log_assert(const char* cond, const char* tag, const char* fmt, ...)
        add(bridge, "__android_log_assert") { ctx in
            let condition = SDRAndroidLibs.string(ctx, ctx.arg(0))
            let tag = SDRAndroidLibs.string(ctx, ctx.arg(1))
            let format = SDRAndroidLibs.string(ctx, ctx.arg(2))
            SDRAndroidLibs.emit(priority: 7, tag: tag,
                                message: condition.isEmpty ? format : "assert(\(condition)): \(format)")
            return 0
        }
        // __android_log_is_loggable(int prio, const char* tag, int defaultPrio) → 恒可记录
        add(bridge, "__android_log_is_loggable") { _ in 1 }
    }

    // MARK: libm

    private func installMathFamily(_ bridge: SDRHostCall) {
        let unaryDouble: [(String, (Double) -> Double)] = [
            ("sqrt", sqrt), ("fabs", fabs), ("floor", floor), ("ceil", ceil),
            ("trunc", trunc), ("round", round), ("rint", rint), ("nearbyint", nearbyint),
            ("sin", sin), ("cos", cos), ("tan", tan),
            ("asin", asin), ("acos", acos), ("atan", atan),
            ("sinh", sinh), ("cosh", cosh), ("tanh", tanh),
            ("exp", exp), ("exp2", exp2), ("log", log), ("log10", log10), ("log2", log2),
            ("cbrt", cbrt), ("erf", erf),
        ]
        for (name, function) in unaryDouble {
            addScalar(bridge, name) { ctx in function(ctx.floatArg(0)) }
        }

        let binaryDouble: [(String, (Double, Double) -> Double)] = [
            ("atan2", atan2), ("pow", pow), ("fmod", fmod), ("remainder", remainder),
            ("hypot", hypot), ("copysign", copysign), ("fmin", fmin), ("fmax", fmax),
        ]
        for (name, function) in binaryDouble {
            addScalar(bridge, name) { ctx in function(ctx.floatArg(0), ctx.floatArg(1)) }
        }

        // ldexp(double, int)：double 在 V0、整数在 X0（AAPCS64 整数/浮点寄存器独立编号）
        addScalar(bridge, "ldexp") { ctx in
            ldexp(ctx.floatArg(0), Int32(truncatingIfNeeded: ctx.arg(0)))
        }

        let unaryFloat: [(String, (Float) -> Float)] = [
            ("sqrtf", sqrtf), ("fabsf", fabsf), ("floorf", floorf), ("ceilf", ceilf),
            ("truncf", truncf), ("roundf", roundf), ("rintf", rintf),
            ("sinf", sinf), ("cosf", cosf), ("tanf", tanf),
            ("asinf", asinf), ("acosf", acosf), ("atanf", atanf),
            ("expf", expf), ("exp2f", exp2f), ("logf", logf), ("log10f", log10f), ("log2f", log2f),
            ("cbrtf", cbrtf),
        ]
        for (name, function) in unaryFloat {
            addScalar(bridge, name) { ctx in Double(function(ctx.singleFloatArg(0))) }
        }

        let binaryFloat: [(String, (Float, Float) -> Float)] = [
            ("atan2f", atan2f), ("powf", powf), ("fmodf", fmodf),
            ("hypotf", hypotf), ("copysignf", copysignf), ("fminf", fminf), ("fmaxf", fmaxf),
        ]
        for (name, function) in binaryFloat {
            addScalar(bridge, name) { ctx in Double(function(ctx.singleFloatArg(0), ctx.singleFloatArg(1))) }
        }
    }

    // MARK: libz

    /// zlib crc32（反射多项式 0xEDB88320，初值与结果均取反）。
    public static func crc32(_ crc: UInt64, _ bytes: [UInt8]) -> UInt64 {
        var value = UInt32(truncatingIfNeeded: crc) ^ 0xFFFF_FFFF
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
        }
        return UInt64(value ^ 0xFFFF_FFFF)
    }

    /// zlib adler32（模 65521）。
    public static func adler32(_ adler: UInt64, _ bytes: [UInt8]) -> UInt64 {
        let seed = UInt32(truncatingIfNeeded: adler)
        var a = seed & 0xFFFF
        var b = (seed >> 16) & 0xFFFF
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return UInt64((b << 16) | a)
    }

    private func installZlibFamily(_ bridge: SDRHostCall) {
        add(bridge, "crc32") { ctx in
            let length = Int(min(ctx.arg(2), SDRLibc.maxTransferBytes))
            guard let bytes = ctx.read(ctx.arg(1), count: length) else { return 0 }
            return SDRAndroidLibs.crc32(ctx.arg(0), bytes)
        }
        add(bridge, "adler32") { ctx in
            let length = Int(min(ctx.arg(2), SDRLibc.maxTransferBytes))
            guard let bytes = ctx.read(ctx.arg(1), count: length) else { return 1 }
            return SDRAndroidLibs.adler32(ctx.arg(0), bytes)
        }
        // uncompress(Bytef* dest, uLongf* destLen, const Bytef* source, uLong sourceLen) → int
        add(bridge, "uncompress") { ctx in
            let dest = ctx.arg(0)
            let destLenAddress = ctx.arg(1)
            let source = ctx.arg(2)
            let sourceLength = min(ctx.arg(3), SDRLibc.maxTransferBytes)
            guard let input = ctx.read(source, count: Int(sourceLength)) else {
                return UInt64(bitPattern: Int64(SDRAndroidLibs.zBufError))
            }
            let capacity = Int(ctx.readScalar(destLenAddress, count: 8))
            guard capacity > 0 else {
                return UInt64(bitPattern: Int64(SDRAndroidLibs.zBufError))
            }
            guard let output = try? SDRZipArchive.inflateZlib(input, expected: min(capacity, 1 << 20)) else {
                return UInt64(bitPattern: Int64(SDRAndroidLibs.zDataError))
            }
            guard output.count <= capacity else {
                return UInt64(bitPattern: Int64(SDRAndroidLibs.zBufError))
            }
            guard ctx.write(dest, output) else {
                return UInt64(bitPattern: Int64(SDRAndroidLibs.zBufError))
            }
            guard ctx.writeScalar(destLenAddress, UInt64(output.count), count: 8) else {
                return UInt64(bitPattern: Int64(SDRAndroidLibs.zBufError))
            }
            return UInt64(SDRAndroidLibs.zOk)
        }
    }
}
