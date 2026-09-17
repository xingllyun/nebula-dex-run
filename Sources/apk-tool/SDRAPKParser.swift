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

/// APK 元数据
public struct SDRAPKMeta {
    public var packageName: String
    public var label: String
    public var versionName: String
    public var versionCode: Int
    public var abis: [String]
    public var dexFiles: [String]
    public var soFiles: [String]
    public var hasSignature: Bool
}

/// APK 解析：解压、清单提取、DEX/SO 清点
public final class SDRAPKParser {
    private let archive: SDRZipArchive

    public init(apkURL: URL) throws {
        archive = try SDRZipArchive(url: apkURL)
    }

    public func parse() throws -> SDRAPKMeta {
        let dexFiles = archive.entries
            .filter { $0.name.hasSuffix(".dex") && !$0.name.contains("/") }
            .map(\.name)
            .sorted()

        guard !dexFiles.isEmpty else {
            throw SDRAppError(.apkNoDex, "APK 内未找到 classes*.dex")
        }

        let soFiles = archive.entries
            .filter { $0.name.hasPrefix("lib/") && $0.name.hasSuffix(".so") }
            .map(\.name)

        let abis = Array(Set(soFiles.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            return parts.count >= 2 ? String(parts[1]) : nil
        })).sorted()

        let manifest = try? archive.extract("AndroidManifest.xml")
        let strings = manifest.map { SDRBinaryXML.stringPool($0) } ?? []
        let packageName = SDRManifestReader.packageName(from: strings) ?? "unknown.package"
        let versionName = SDRManifestReader.versionName(from: strings) ?? "0.0"

        return SDRAPKMeta(packageName: packageName,
                          label: packageName.split(separator: ".").last.map(String.init) ?? "App",
                          versionName: versionName,
                          versionCode: Int(versionName.replacingOccurrences(of: ".", with: "")) ?? 0,
                          abis: abis,
                          dexFiles: dexFiles,
                          soFiles: soFiles,
                          hasSignature: archive.entries.contains { $0.name.hasPrefix("META-INF/") })
    }

    public func extractDex(_ name: String) throws -> [UInt8] { try archive.extract(name) }

    public func extractSo(_ name: String, abi: String) throws -> [UInt8]? {
        guard abis.contains(abi) else { return nil }
        return try archive.extract("lib/\(abi)/\(name)")
    }

    public var abis: [String] {
        Array(Set(archive.entries.compactMap { e -> String? in
            guard e.name.hasPrefix("lib/"), e.name.hasSuffix(".so") else { return nil }
            let parts = e.name.split(separator: "/")
            return parts.count >= 2 ? String(parts[1]) : nil
        })).sorted()
    }
}
