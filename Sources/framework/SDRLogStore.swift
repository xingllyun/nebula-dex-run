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

public enum SDRLogLevel: Int, Codable, CaseIterable {
    case verbose = 0, debug, info, warn, error

    public var label: String {
        switch self {
        case .verbose: return "VERBOSE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }
}

public struct SDRLogEntry: Identifiable, Codable {
    public let id = UUID()
    public let date: Date
    public let level: SDRLogLevel
    public let module: String
    public let text: String
}

/// 实时日志：内存环形缓冲 + 可选文件落盘
public final class SDRLogStore: ObservableObject {
    public static let shared = SDRLogStore()

    @Published public private(set) var entries: [SDRLogEntry] = []

    private let capacity: Int
    private let queue = DispatchQueue(label: "com.xingyun.NebulaDex.log")
    private var fileHandle: FileHandle?

    public init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    public func log(_ level: SDRLogLevel, _ module: String, _ text: String) {
        guard level.rawValue >= SDRLogger.minLevel.rawValue else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let entry = SDRLogEntry(date: Date(), level: level, module: module, text: text)
            DispatchQueue.main.async {
                self.entries.append(entry)
                if self.entries.count > self.capacity {
                    self.entries.removeFirst(self.entries.count - self.capacity)
                }
            }
            self.writeToFileIfNeeded(entry)
        }
    }

    public func clear() {
        DispatchQueue.main.async { self.entries.removeAll() }
    }

    public func export() -> URL? {
        let text = snapshot().map { e in
            "[\(SDRTime.format(e.date))] [\(e.level.label)] [\(e.module)] \(e.text)"
        }.joined(separator: "\n")
        let name = "NebulaDex-\(Int(Date().timeIntervalSince1970)).log"
        let url = SDRSandbox.shared.logsDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            log(.error, "log", "导出日志失败：\(error.localizedDescription)")
            return nil
        }
    }

    public func snapshot() -> [SDRLogEntry] {
        var result: [SDRLogEntry] = []
        DispatchQueue.main.sync { result = self.entries }
        return result
    }

    // MARK: - 文件落盘（20 MB 上限，超出滚动）

    private func writeToFileIfNeeded(_ entry: SDRLogEntry) {
        guard SDRLogger.fileOutputEnabled else { return }
        let dir = SDRSandbox.shared.logsDirectory
        let url = dir.appendingPathComponent("NebulaDex.log")
        let line = "[\(SDRTime.format(entry.date))] [\(entry.level.label)] [\(entry.module)] \(entry.text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if fileHandle == nil {
            fileHandle = try? FileHandle(forWritingTo: url)
            fileHandle?.seekToEndOfFile()
        }
        fileHandle?.write(data)
        rollIfNeeded(current: url)
    }

    private func rollIfNeeded(current: URL) {
        let limit: UInt64 = 20 * 1024 * 1024
        let attrs = try? FileManager.default.attributesOfItem(atPath: current.path)
        let size = (attrs?[.size] as? UInt64) ?? 0
        guard size > limit else { return }
        try? fileHandle?.close()
        fileHandle = nil
        let backup = current.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: current, to: backup)
    }
}
