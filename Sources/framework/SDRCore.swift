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

/// 运行状态机（UI 三态）
public enum SDRRunState: Equatable {
    case idle
    case loading(step: String, progress: Double)
    case running
    case failed(reason: String)
}

/// 已导入的 APK 应用信息
public struct SDRAppInfo: Identifiable, Codable, Equatable {
    public let id: String            // 包名 + 版本
    public var packageName: String
    public var label: String
    public var versionName: String
    public var versionCode: Int
    public var abis: [String]
    public var sizeBytes: Int64
    public var installPath: String
    public var importedAt: Date

    public init(packageName: String, label: String, versionName: String, versionCode: Int,
                abis: [String], sizeBytes: Int64, installPath: String, importedAt: Date = Date()) {
        self.id = "\(packageName)@\(versionCode)"
        self.packageName = packageName
        self.label = label
        self.versionName = versionName
        self.versionCode = versionCode
        self.abis = abis
        self.sizeBytes = sizeBytes
        self.installPath = installPath
        self.importedAt = importedAt
    }
}

/// 统一错误码
public enum SDRCode: String {
    case apkBadZip = "APK_BAD_ZIP"
    case apkNoDex = "APK_NO_DEX"
    case apkHardened = "APK_HARDENED"
    case dexBadMagic = "DEX_BAD_MAGIC"
    case dexOpUnsupported = "DEX_OP_UNSUPPORTED"
    case soElfBadMagic = "SO_ELF_BAD_MAGIC"
    case soAbiMismatch = "SO_ABI_MISMATCH"
    case soRelocFailed = "SO_RELOC_FAILED"
    case soSymbolMissing = "SO_SYMBOL_MISSING"
    case soImageInvalid = "SO_IMAGE_INVALID"
    case soJniFailed = "SO_JNI_FAILED"
    case soExecUnsupported = "SO_EXEC_UNSUPPORTED"
    case sandboxDenied = "SANDBOX_DENIED"
    case renderFailed = "RENDER_FAILED"
    case memoryBudgetExceeded = "MEMORY_BUDGET_EXCEEDED"
    case memoryPressureCritical = "MEMORY_PRESSURE_CRITICAL"
}

public struct SDRAppError: LocalizedError {
    public let code: SDRCode
    public let message: String
    public var errorDescription: String? { "[\(code.rawValue)] \(message)" }
    public init(_ code: SDRCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// 全局常量
public enum SDRConst {
    public static let bundleID = "com.xingyun.NebulaDex"
    public static let minOS = "16.0"
    public static let maxVerifiedOS = "26.x"
}
