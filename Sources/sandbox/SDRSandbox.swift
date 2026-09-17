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

/// 沙盒容器：各 APK 独立目录，卸载即清理
public final class SDRSandbox {
    public static let shared = SDRSandbox()

    public let root: URL
    public let appsDirectory: URL
    public let logsDirectory: URL
    public let tempDirectory: URL

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NebulaDex", isDirectory: true)
        root = base
        appsDirectory = base.appendingPathComponent("apps", isDirectory: true)
        logsDirectory = base.appendingPathComponent("logs", isDirectory: true)
        tempDirectory = base.appendingPathComponent("tmp", isDirectory: true)
        for dir in [root, appsDirectory, logsDirectory, tempDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 为指定包名创建独立沙盒目录
    public func container(for packageName: String) -> URL {
        let safe = packageName.replacingOccurrences(of: "/", with: "_")
        let dir = appsDirectory.appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func scanInstalledApps() -> [SDRAppInfo] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: appsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return items.compactMap { dir -> SDRAppInfo? in
            let manifest = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: manifest),
                  let info = try? JSONDecoder().decode(SDRAppInfo.self, from: data) else { return nil }
            return info
        }.sorted { $0.label < $1.label }
    }

    public func remove(packageName: String) throws {
        let dir = container(for: packageName)
        guard dir.path.hasPrefix(appsDirectory.path) else {
            throw SDRAppError(.sandboxDenied, "拒绝访问沙盒外路径：\(dir.path)")
        }
        try FileManager.default.removeItem(at: dir)
        SDRLogger.i("sandbox", "已清理沙盒：\(packageName)")
    }

    /// 路径越界校验：所有文件访问必须经此
    public func isAllowed(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path)
    }
}
