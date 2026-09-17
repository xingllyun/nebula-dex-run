import Foundation

/// 大小端字节读取器（ELF / DEX / ZIP 结构解析共用）
public struct SDRByteReader {
    public let data: [UInt8]
    public var littleEndian: Bool
    public private(set) var offset: Int = 0

    public init(_ data: [UInt8], littleEndian: Bool = true) {
        self.data = data
        self.littleEndian = littleEndian
    }

    public init(_ data: Data, littleEndian: Bool = true) {
        self.init([UInt8](data), littleEndian: littleEndian)
    }

    public var remaining: Int { data.count - offset }
    public var isEOF: Bool { offset >= data.count }

    public mutating func seek(_ value: Int) { offset = max(0, min(value, data.count)) }
    public mutating func skip(_ count: Int) { seek(offset + count) }

    public mutating func u8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    public mutating func u16() -> UInt16? {
        guard let b = bytes(2) else { return nil }
        return littleEndian
            ? UInt16(b[0]) | (UInt16(b[1]) << 8)
            : (UInt16(b[0]) << 8) | UInt16(b[1])
    }

    public mutating func u32() -> UInt32? {
        guard let b = bytes(4) else { return nil }
        var v: UInt32 = 0
        if littleEndian {
            for i in (0..<4).reversed() { v = (v << 8) | UInt32(b[i]) }
        } else {
            for i in 0..<4 { v = (v << 8) | UInt32(b[i]) }
        }
        return v
    }

    public mutating func u64() -> UInt64? {
        guard let b = bytes(8) else { return nil }
        var v: UInt64 = 0
        if littleEndian {
            for i in (0..<8).reversed() { v = (v << 8) | UInt64(b[i]) }
        } else {
            for i in 0..<8 { v = (v << 8) | UInt64(b[i]) }
        }
        return v
    }

    /// DEX 专用的 ULEB128
    public mutating func uleb128() -> UInt32? {
        var result: UInt32 = 0
        var shift = 0
        while true {
            guard let byte = u8() else { return nil }
            result |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 28 { return nil }
        }
        return result
    }
}

public enum SDRByteOrder {
    public static func isLittleEndian(_ magic: [UInt8]) -> Bool { true }
    public static func toArray(_ data: Data) -> [UInt8] { [UInt8](data) }
}
