/*
 Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
 Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
*/

import Foundation

/// 轻量持久化层：运行设置 + 设备能力探测快照
/// 走 UserDefaults，零额外依赖、体积零增长；退出（含后台被系统回收）后仍保留
public final class SDRSettingsStore {

    public static let shared = SDRSettingsStore()

    private enum Key {
        static let refreshRate = "nebuladex.settings.refreshRate"
        static let refreshRateExplicit = "nebuladex.settings.refreshRate.explicit"
        static let lowPowerDowngrade = "nebuladex.settings.lowPowerDowngrade"
        static let probeReport = "nebuladex.probe.report"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    // MARK: - 运行设置

    /// 平台缺省刷新率：UIKit 适配器不可用（命令行/CI 冒烟）时返回 60。
    /// 该持久化层不得反向硬依赖 UIKit，否则无法进入 CI 编译清单，
    /// “退出后台丢设置”的修复将永远拿不到回归保护。
    private static var platformDefaultRefreshRate: Int {
        #if canImport(UIKit)
        return SDRVersionAdapter.defaultRefreshRate
        #else
        return 60
        #endif
    }

    /// 刷新率：未设置过时返回机型默认值
    public var refreshRate: Int {
        let stored = defaults.integer(forKey: Key.refreshRate)
        return stored > 0 ? stored : Self.platformDefaultRefreshRate
    }

    /// 仅落盘数值，不标记“用户显式设置”（供程序按默认档写入）
    public func persistRefreshRate(_ value: Int) {
        defaults.set(value, forKey: Key.refreshRate)
    }

    /// 用户在设置页主动改过刷新率
    public var hasExplicitRefreshRate: Bool {
        defaults.bool(forKey: Key.refreshRateExplicit)
    }

    /// 设置页交互触发，标记为用户显式选择
    public func markRefreshRateExplicit() {
        defaults.set(true, forKey: Key.refreshRateExplicit)
    }

    public var lowPowerDowngrade: Bool {
        get { defaults.bool(forKey: Key.lowPowerDowngrade) }
        set { defaults.set(newValue, forKey: Key.lowPowerDowngrade) }
    }

    // MARK: - 设备能力探测快照

    public func saveProbeReport(_ report: SDRDeviceCapabilityReport) {
        guard let data = try? encoder.encode(report) else { return }
        defaults.set(data, forKey: Key.probeReport)
    }

    public func loadProbeReport() -> SDRDeviceCapabilityReport? {
        guard let data = defaults.data(forKey: Key.probeReport) else { return nil }
        return try? decoder.decode(SDRDeviceCapabilityReport.self, from: data)
    }

    public func clearProbeReport() {
        defaults.removeObject(forKey: Key.probeReport)
    }
}
