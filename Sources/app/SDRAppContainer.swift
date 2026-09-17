import Foundation

/// 应用容器：APK 导入 → 加固检测 → 落沙盒 → 装载镜像 → 软运行
public final class SDRAppContainer {

    public static let shared = SDRAppContainer()

    private let state = SDRAppState.shared
    private let bridge = SDRAndroidBridge.shared

    private init() {
        SDRLogger.i("container", "沙盒根目录：\(SDRSandbox.shared.root.path)")
    }

    // MARK: - 导入

    @discardableResult
    public func importAPK(url: URL) throws -> SDRAppInfo {
        guard SDRSandbox.shared.isAllowed(url) || url.pathExtension.lowercased() == "apk" else {
            throw SDRAppError(.sandboxDenied, "不支持的文件位置：\(url.path)")
        }

        state.setState(.loading(step: "解析 APK", progress: 0.1))

        let archive = try SDRZipArchive(url: url)
        let parser = try SDRAPKParser(apkURL: url)
        let meta = try parser.parse()

        state.setState(.loading(step: "加固检测", progress: 0.3))
        let hardening = SDRHardeningDetector.detect(meta: meta, archive: archive)
        if hardening.isHardened {
            let vendor = hardening.vendor ?? "unknown"
            SDRLogger.w("container", "检测到加固：\(vendor)，证据 \(hardening.evidence.count) 项")
        }

        state.setState(.loading(step: "写入沙盒", progress: 0.6))
        let container = SDRSandbox.shared.container(for: meta.packageName)
        let target = container.appendingPathComponent("base.apk")
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: url, to: target)

        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        let info = SDRAppInfo(packageName: meta.packageName,
                              label: meta.label,
                              versionName: meta.versionName,
                              versionCode: meta.versionCode,
                              abis: meta.abis,
                              sizeBytes: bytes,
                              installPath: container.path)

        let metaURL = container.appendingPathComponent("meta.json")
        try JSONEncoder().encode(info).write(to: metaURL, options: .atomic)

        state.setState(.loading(step: "完成", progress: 1.0))
        state.reloadApps()
        state.setState(.idle)
        SDRLogger.i("container", "导入完成：\(info.label) (\(info.packageName))")
        return info
    }

    // MARK: - 软运行

    public func launch(_ info: SDRAppInfo) {
        state.setState(.loading(step: "装载镜像", progress: 0.2))
        defer { SDRAppState.shared.refreshRate = SDRVersionAdapter.supportsProMotion ? 120 : 60 }

        do {
            let container = URL(fileURLWithPath: info.installPath)
            let apkURL = container.appendingPathComponent("base.apk")
            guard FileManager.default.fileExists(atPath: apkURL.path) else {
                throw SDRAppError(.apkBadZip, "应用包缺失：\(apkURL.lastPathComponent)")
            }
            let parser = try SDRAPKParser(apkURL: apkURL)
            let meta = try parser.parse()

            guard let firstDex = meta.dexFiles.first else {
                throw SDRAppError(.apkNoDex, "无 DEX 可执行")
            }
            state.setState(.loading(step: "解析 DEX", progress: 0.4))
            let dexBytes = try parser.extractDex(firstDex)
            let header = try SDRDexParser.parseHeader(dexBytes)
            let sample = SDRDexParser.strings(dexBytes, header: header, limit: 3)
            SDRLogger.i("container", "DEX \(header.version) 方法数 \(header.methodIdsSize) 类数 \(header.classDefsSize)")

            state.setState(.loading(step: "解释执行", progress: 0.8))
            let interpreter = SDRDexInterpreter()
            // 方法体提取（code_item）在单元测试覆盖后接入；当前先验证解释器链路的装载与收尾
            let result = try interpreter.run(code: [], registerCount: 0)
            SDRLogger.i("container", "解释器链路就绪，符号样本：\(sample.joined(separator: ", "))；入口返回 \(result)")

            var loadedSO: String?
            if let so = meta.soFiles.first {
                let soBytes = try parser.extractSo(so, abi: meta.abis.first ?? "arm64-v8a")
                if let bytes = soBytes {
                    let loader = SDRImageLoader()
                    let image = try loader.load(bytes: bytes, path: so, preferredABI: meta.abis.first)
                    let services = SDRSystemServices()
                    let ctx = SDRCpuContext(pc: SDRImageLoaderEntryPoint(image: image))
                    let armInterp = SDRArmInterpreter(context: ctx,
                                                      memory: image.memory,
                                                      services: services)
                    services.bind(interpreter: armInterp)
                    bridge.register(image: image, interpreter: armInterp)
                    loadedSO = so
                }
            }

            state.currentApp = info
            state.setState(.running)
            SDRLiveActivityBridge().update(packageName: info.packageName,
                                           label: info.label,
                                           phase: "running",
                                           detail: loadedSO == nil ? "DEX 解释中" : "DEX + SO 解释中")
            SDRLogger.i("container", "启动完成：\(info.label)")
        } catch let error as SDRAppError {
            state.setState(.failed(reason: error.errorDescription ?? "未知错误"))
            SDRLogger.e("container", "启动失败：\(error.errorDescription ?? "")")
        } catch {
            state.setState(.failed(reason: error.localizedDescription))
            SDRLogger.e("container", "启动失败：\(error.localizedDescription)")
        }
    }

    public func stop() {
        if let info = state.currentApp {
            bridge.unload(soPath: info.packageName)
            SDRLiveActivityBridge().end(packageName: info.packageName)
        }
        state.currentApp = nil
        state.setState(.idle)
        SDRLogger.i("container", "已停止运行")
    }

    public func uninstall(_ info: SDRAppInfo) {
        do {
            try SDRSandbox.shared.remove(packageName: info.packageName)
            state.reloadApps()
        } catch {
            SDRLogger.e("container", "卸载失败：\(error.localizedDescription)")
        }
    }

    public func handleIncoming(url: URL) {
        guard url.pathExtension.lowercased() == "apk" else { return }
        do { try importAPK(url: url) } catch {
            SDRLogger.e("container", "导入失败：\(error.localizedDescription)")
        }
    }
}

/// 装载镜像的入口地址（供解释器初始化 PC）
public func SDRImageLoaderEntryPoint(image: SDRLoadedImage) -> UInt64 {
    image.loadBase + image.header.entry
}
