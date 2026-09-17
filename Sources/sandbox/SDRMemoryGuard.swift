import Foundation

/// 软件内存模型：段表 + 访存校验（对应 SO 指令解释执行的内存抽象）
public final class SDRMemoryGuard {
    public struct Segment {
        public var name: String
        public var base: UInt64
        public var size: UInt64
        public var readable: Bool
        public var writable: Bool
        public var executable: Bool
    }

    private var segments: [Segment] = []
    private var storage: [UInt64: [UInt8]] = [:]
    private let lock = NSLock()

    public init() {}

    public func map(name: String, base: UInt64, size: UInt64,
                    readable: Bool, writable: Bool, executable: Bool) {
        lock.lock(); defer { lock.unlock() }
        segments.append(Segment(name: name, base: base, size: size,
                                readable: readable, writable: writable, executable: executable))
        storage[base] = [UInt8](repeating: 0, count: Int(size))
    }

    public func segment(for address: UInt64) -> Segment? {
        segments.first { address >= $0.base && address < $0.base + $0.size }
    }

    public func read(_ address: UInt64, count: Int) throws -> [UInt8] {
        guard let seg = segment(for: address), seg.readable else {
            throw SDRAppError(.sandboxDenied, "非法读：0x\(String(address, radix: 16))")
        }
        guard var buf = storage[seg.base] else {
            throw SDRAppError(.soImageInvalid, "段无后备存储：\(seg.name)")
        }
        let start = Int(address - seg.base)
        guard start + count <= buf.count else {
            throw SDRAppError(.sandboxDenied, "越界读：\(start)+\(count) > \(buf.count)")
        }
        return Array(buf[start..<(start + count)])
    }

    public func write(_ address: UInt64, bytes: [UInt8]) throws {
        guard let seg = segment(for: address), seg.writable else {
            throw SDRAppError(.sandboxDenied, "非法写：0x\(String(address, radix: 16))")
        }
        guard var buf = storage[seg.base] else {
            throw SDRAppError(.soImageInvalid, "段无后备存储：\(seg.name)")
        }
        let start = Int(address - seg.base)
        guard start + bytes.count <= buf.count else {
            throw SDRAppError(.sandboxDenied, "越界写：\(start)+\(bytes.count) > \(buf.count)")
        }
        buf.replaceSubrange(start..<(start + bytes.count), with: bytes)
        storage[seg.base] = buf
    }

    /// 取代码段字节区间，供指令解释器取指（不申请可执行内存）
    public func codeBytes(segment name: String) -> [UInt8] {
        guard let seg = segments.first(where: { $0.name == name }) else { return [] }
        return storage[seg.base] ?? []
    }
}
