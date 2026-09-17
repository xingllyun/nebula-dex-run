import Foundation
import Combine

/// 全局应用状态（驱动 UI 与运行显示页三态）
public final class SDRAppState: ObservableObject {
    public static let shared = SDRAppState()

    @Published public var apps: [SDRAppInfo] = []
    @Published public var runState: SDRRunState = .idle
    @Published public var currentApp: SDRAppInfo?
    @Published public var refreshRate: Int = 60
    @Published public var lowPowerDowngrade: Bool = false

    private init() {}

    public func reloadApps() {
        apps = SDRSandbox.shared.scanInstalledApps()
        SDRLogger.i("state", "已安装应用数 = \(apps.count)")
    }

    public func setState(_ state: SDRRunState) {
        DispatchQueue.main.async {
            self.runState = state
            switch state {
            case .loading(let step, let progress):
                SDRLogger.i("state", "加载中：\(step) \(Int(progress * 100))%")
            case .running:
                SDRLogger.i("state", "运行中：\(self.currentApp?.label ?? "-")")
            case .failed(let reason):
                SDRLogger.e("state", "失败：\(reason)")
            case .idle:
                SDRLogger.i("state", "空闲")
            }
        }
    }
}
