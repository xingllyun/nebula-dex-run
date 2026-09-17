import Foundation

/// DEX 文件头与基础表解析
public struct SDRDexHeader {
    public var version: String
    public var fileSize: UInt32
    public var headerSize: UInt32
    public var endianTag: UInt32
    public var mapOff: UInt32
    public var stringIdsSize: UInt32
    public var stringIdsOff: UInt32
    public var typeIdsSize: UInt32
    public var protoIdsSize: UInt32
    public var fieldIdsSize: UInt32
    public var methodIdsSize: UInt32
    public var classDefsSize: UInt32

    public var isLittleEndian: Bool { endianTag == 0x12345678 }
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
              let _ = r.u32(), let mapOff = r.u32() else {
            throw SDRAppError(.dexBadMagic, "DEX 头解析失败")
        }
        let little = endianTag == 0x12345678
        r.littleEndian = little
        r.seek(56)
        guard let stringIdsSize = r.u32(), let stringIdsOff = r.u32(),
              let typeIdsSize = r.u32(), let _ = r.u32(),
              let protoIdsSize = r.u32(), let _ = r.u32(),
              let fieldIdsSize = r.u32(), let _ = r.u32(),
              let methodIdsSize = r.u32(), let _ = r.u32(),
              let classDefsSize = r.u32() else {
            throw SDRAppError(.dexBadMagic, "DEX 头解析失败")
        }

        return SDRDexHeader(version: version, fileSize: fileSize, headerSize: headerSize,
                            endianTag: endianTag, mapOff: mapOff,
                            stringIdsSize: stringIdsSize, stringIdsOff: stringIdsOff,
                            typeIdsSize: typeIdsSize, protoIdsSize: protoIdsSize,
                            fieldIdsSize: fieldIdsSize, methodIdsSize: methodIdsSize,
                            classDefsSize: classDefsSize)
    }

    /// 读取字符串表（用于日志与调试展示）
    public static func strings(_ data: [UInt8], header: SDRDexHeader, limit: Int = 50) -> [String] {
        var r = SDRByteReader(data, littleEndian: header.isLittleEndian)
        var result: [String] = []
        for i in 0..<min(Int(header.stringIdsSize), limit) {
            r.seek(Int(header.stringIdsOff) + i * 4)
            guard let offset = r.u32() else { break }
            r.seek(Int(offset))
            guard let _ = r.uleb128(), let count = r.uleb128() else { break }
            guard let raw = r.bytes(Int(count) + 1) else { break }
            if let s = String(bytes: raw.dropLast(), encoding: .utf8) { result.append(s) }
        }
        return result
    }
}
