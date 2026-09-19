// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// 设置持久化冒烟（阶段二 · 步骤三配套）
// 覆盖历史缺陷：App 侧载配置退出后台即丢失（设置未落盘 + 刷新率反向依赖 UIKit 无法进 CI）。
// 用法: settings-smoke

import Foundation
#if canImport(Darwin)
import Darwin
#endif

var totalChecks = 0
var failedChecks = 0

func check(_ condition: Bool, _ label: String) {
    totalChecks += 1
    if condition {
        print("ok   \(label)")
    } else {
        failedChecks += 1
        print("FAIL \(label)")
    }
}

// 独立 suite，避免污染真实用户设置
guard let defaults = UserDefaults(suiteName: "nebuladex.smoke.settings.\(UUID().uuidString)") else {
    print("FAIL 无法创建测试用 UserDefaults suite")
    exit(1)
}

let store = SDRSettingsStore(defaults: defaults)

// MARK: - 刷新率

check(store.hasExplicitRefreshRate == false, "全新安装未标记显式设置")
check(store.refreshRate > 0, "未设置过刷新率时回落到平台默认值（实得 \(store.refreshRate)）")
check(store.refreshRate == 60, "无 UIKit 适配器（CI/命令行）环境下默认刷新率为 60")

store.persistRefreshRate(123)
store.markRefreshRateExplicit()
check(store.refreshRate == 123, "刷新率落盘后可读回（实得 \(store.refreshRate)）")
check(store.hasExplicitRefreshRate, "用户显式设置标记已落盘")

// 新的实例：模拟进程退出后台后被回收、重新进入
let reopened = SDRSettingsStore(defaults: defaults)
check(reopened.refreshRate == 123, "重建实例后刷新率仍为 123（退出后台不丢失）")
check(reopened.hasExplicitRefreshRate, "重建实例后显式设置标记保留")

// MARK: - 低电量降级开关

check(reopened.lowPowerDowngrade == false, "低电量降级默认关闭")
reopened.lowPowerDowngrade = true
let reopened2 = SDRSettingsStore(defaults: defaults)
check(reopened2.lowPowerDowngrade, "低电量降级开关持久化生效")

// MARK: - 设备能力探测快照

let report = SDRDeviceCapabilityReport(
    systemVersion: "iOS 18.0",
    machineIdentifier: "iPhone17,1",
    physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
    availableMemoryBytes: 3 * 1024 * 1024 * 1024,
    residentFootprintBytes: 256 * 1024 * 1024,
    virtualSizeBytes: 16 * 1024 * 1024 * 1024,
    maxContiguousMapBytes: 6 * 1024 * 1024 * 1024,
    increasedMemoryLimit: .active,
    extendedVirtualAddressing: .active,
    probedAt: Date(timeIntervalSince1970: 1_780_000_000)
)

store.saveProbeReport(report)
let restored = store.loadProbeReport()
check(restored != nil, "探测报告可解码读回")
check(restored == report, "探测报告字段逐个一致（含 Date 与枚举）")
if let restored = restored {
    check(restored.probedAt == report.probedAt, "probedAt 按秒精度往返一致")
}

store.clearProbeReport()
check(store.loadProbeReport() == nil, "clearProbeReport 后快照为空")

// MARK: - 收口

print("NebulaDex 设置持久化冒烟：\(totalChecks) 项检查，失败 \(failedChecks) 项")
if failedChecks > 0 {
    FileHandle.standardError.write("设置持久化冒烟未通过\n".data(using: .utf8)!)
    exit(1)
}
exit(0)
