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

/// 内存预算策略：把实测设备能力翻译成解释器可安全使用的配额
public enum SDRMemoryBudget {

    public enum Tier: String {
        case constrained
        case standard
        case extended

        public var displayName: String {
            switch self {
            case .constrained:
                return "受限（未探测到大内存权限）"
            case .standard:
                return "标准（大内存权限已生效）"
            case .extended:
                return "扩展（大内存 + 大地址空间均已生效）"
            }
        }
    }

    public struct Plan: Equatable {
        public var tier: Tier
        public var residentLimitBytes: UInt64
        public var addressSpaceLimitBytes: UInt64
        public var dexCacheLimitBytes: UInt64
        public var soSegmentLimitBytes: UInt64
        public var registerStackDepth: Int
        public var allowsWideAddressArena: Bool
        public var basedOnPhysicalBytes: UInt64
        public var basedOnAvailableBytes: UInt64
    }

    private static var cached: Plan?
    private static let lock = NSLock()

    /// 取当前预算（首次调用时探测，之后走缓存）
    public static func current() -> Plan {
        lock.lock()
        if let plan = cached {
            lock.unlock()
            return plan
        }
        lock.unlock()
        return refresh()
    }

    /// 重新探测并刷新预算
    @discardableResult
    public static func refresh() -> Plan {
        SDRMemoryPressureMonitor.shared.start()
        let report = SDRSystemProbe.report(performAddressProbe: true)
        let plan = makePlan(report: report)
        lock.lock()
        cached = plan
        lock.unlock()
        SDRLogger.i("memory", "内存预算档位 \(plan.tier.rawValue)：常驻上限 \(plan.residentLimitBytes / 1048576) MB，SO 段上限 \(plan.soSegmentLimitBytes / 1048576) MB")
        SDREventBus.shared.emit("memory.budget.updated", payload: plan.tier.rawValue)
        return plan
    }

    /// 按设备能力生成预算（纯函数，便于测试与展示）
    public static func makePlan(report: SDRDeviceCapabilityReport) -> Plan {
        let physical = report.physicalMemoryBytes
        let available = report.availableMemoryBytes

        let tier: Tier
        let residentRatio: Double
        switch (report.increasedMemoryLimit, report.extendedVirtualAddressing) {
        case (SDRCapabilityStatus.active, SDRCapabilityStatus.active):
            tier = .extended
            residentRatio = 0.65
        case (SDRCapabilityStatus.active, _):
            tier = .standard
            residentRatio = 0.60
        case (_, SDRCapabilityStatus.active):
            tier = .standard
            residentRatio = 0.55
        default:
            tier = .constrained
            residentRatio = 0.42
        }

        var residentLimit = UInt64(Double(physical) * residentRatio)
        if available > 0 {
            let availableCap = UInt64(Double(available) * 0.85)
            if availableCap < residentLimit {
                residentLimit = availableCap
            }
        }
        let floorBytes: UInt64 = 256 * 1048576
        if residentLimit < floorBytes {
            residentLimit = floorBytes
        }

        var addressLimit: UInt64 = 4 * 1073741824
        var wideArena = false
        if report.extendedVirtualAddressing == SDRCapabilityStatus.active {
            let measured = report.maxContiguousMapBytes > 8 * 1073741824 ? report.maxContiguousMapBytes : 8 * 1073741824
            addressLimit = measured * 4
            wideArena = true
        }

        return Plan(tier: tier,
                    residentLimitBytes: residentLimit,
                    addressSpaceLimitBytes: addressLimit,
                    dexCacheLimitBytes: residentLimit / 4,
                    soSegmentLimitBytes: residentLimit / 2,
                    registerStackDepth: registerStackDepth(for: tier),
                    allowsWideAddressArena: wideArena,
                    basedOnPhysicalBytes: physical,
                    basedOnAvailableBytes: available)
    }

    private static func registerStackDepth(for tier: Tier) -> Int {
        switch tier {
        case .constrained:
            return 256
        case .standard:
            return 512
        case .extended:
            return 1024
        }
    }
}
