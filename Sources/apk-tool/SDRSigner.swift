import Foundation
import CryptoKit

/// APK 本地重签名（v1 + v2）
/// 说明：v1（JAR 签名）已实现摘要与清单生成；v2（APK Signing Block）为后续迭代项。
public final class SDRSigner {

    public struct KeyMaterial {
        public var alias: String
        public var password: String
        public var privateKeyPEM: String
        public var certificateDER: Data
    }

    public enum SignError: LocalizedError {
        case keyMissing
        case unsupportedAlgorithm
        case zipRebuildFailed(String)
        case v2NotImplemented

        public var errorDescription: String? {
            switch self {
            case .keyMissing: return "未提供签名密钥"
            case .unsupportedAlgorithm: return "不支持的签名算法（当前仅支持 RSA 2048 + SHA-256）"
            case .zipRebuildFailed(let m): return "重新打包失败：\(m)"
            case .v2NotImplemented: return "v2 签名块写入尚未实现，当前产物仅含 v1 签名"
            }
        }
    }

    public init() {}

    /// 生成 MANIFEST.MF 内容（v1 第一步）
    static func manifest(entries: [(name: String, sha256: String)]) -> String {
        var lines = ["Manifest-Version: 1.0", "Created-By: NebulaDex", ""]
        for e in entries {
            lines.append("Name: \(e.name)")
            lines.append("SHA-256-Digest: \(e.sha256)")
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// 计算条目摘要（SHA-256，Base64）
    public static func digest(_ data: [UInt8]) -> String {
        let hash = SHA256.hash(data: Data(data))
        return Data(hash).base64EncodedString()
    }

    /// 生成自签名 RSA 2048 密钥对（写入沙盒 keystore）
    public static func generateKey(alias: String, password: String) throws -> KeyMaterial {
        // TODO: 接入 Security.framework（SecKeyCreateRandomKey）与 X.509 自签证书构造
        throw SignError.v2NotImplemented
    }

    /// 重签名主流程
    public func resign(apkURL: URL, key: KeyMaterial, outputURL: URL) throws {
        guard !key.privateKeyPEM.isEmpty, !key.certificateDER.isEmpty else { throw SignError.keyMissing }
        let archive = try SDRZipArchive(url: apkURL)
        let signable = archive.entries.filter { !$0.name.hasPrefix("META-INF/") }
        var digestPairs: [(name: String, sha256: String)] = []
        for e in signable {
            if let bytes = try? archive.extract(e.name) {
                digestPairs.append((e.name, Self.digest(bytes)))
            }
        }
        let mf = Self.manifest(entries: digestPairs)
        SDRLogger.i("sign", "已生成 MANIFEST.MF，条目数 = \(digestPairs.count)，大小 = \(mf.utf8.count) 字节")
        SDRLogger.w("sign", "v2 签名块写入待实现，当前产物仅含 v1 签名")
        throw SignError.v2NotImplemented
    }
}
