import Foundation

/// 系统服务代理：解释器发出的 SVC 在此处被翻译为 iOS 原生调用
/// 对应文档 §4.4「syscall 代理层」
public final class SDRSystemServices {

    public struct Descriptor {
        public let number: UInt32
        public let name: String
        public let handler: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, SDRArmInterpreter) throws -> UInt64
    }

    private var table: [UInt32: Descriptor] = [:]
    public private(set) var callCount: [String: Int] = [:]

    public init() {
        registerBuiltins()
    }

    public func register(number: UInt32, name: String,
                         handler: @escaping (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, SDRArmInterpreter) throws -> UInt64) {
        table[number] = Descriptor(number: number, name: name, handler: handler)
    }

    public func dispatch(syscall number: UInt32, context: SDRCpuContext) throws -> UInt64 {
        guard let desc = table[number] else {
            SDRLogger.w("syscall", "未实现的系统调用号：\(number)")
            return 0
        }
        callCount[desc.name, default: 0] += 1
        return try desc.handler(context.x[0], context.x[1], context.x[2],
                                context.x[3], context.x[4], context.x[5], interpreterStub)
    }

    /// 解释器在 dispatch 期间由调用方注入，避免循环持有
    private weak var interpreterRef: SDRArmInterpreter?
    private var interpreterStub: SDRArmInterpreter {
        interpreterRef ?? SDRArmInterpreter(context: SDRCpuContext(), memory: SDRMemoryGuard(), services: self)
    }
    public func bind(interpreter: SDRArmInterpreter) { interpreterRef = interpreter }

    private func registerBuiltins() {
        register(number: 0x1001, name: "open") { pathPtr, flags, _, _, _, _, _ in
            SDRLogger.d("syscall", "open(path=0x\(String(pathPtr, radix: 16)), flags=\(flags))")
            return 3
        }
        register(number: 0x1002, name: "read") { fd, buf, count, _, _, _, _ in
            SDRLogger.d("syscall", "read(fd=\(fd), len=\(count))")
            return 0
        }
        register(number: 0x1003, name: "write") { fd, buf, count, _, _, _, _ in
            SDRLogger.d("syscall", "write(fd=\(fd), len=\(count))")
            return count
        }
        register(number: 0x1004, name: "close") { _, _, _, _, _, _, _ in 0 }
        register(number: 0x1005, name: "clock_gettime") { _, ptr, _, _, _, _, _ in
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            SDRLogger.d("syscall", "clock_gettime -> \(now)")
            _ = ptr
            return now
        }
        register(number: 0x1006, name: "getpid") { _, _, _, _, _, _, _ in 4242 }
        register(number: 0x1007, name: "futex") { _, _, _, _, _, _, _ in 0 }
    }
}
