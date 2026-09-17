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
