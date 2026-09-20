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

/// 一次垂直同步滴答
public struct SDRVSyncTick {
    /// 当前帧 vsync 时间戳（秒）
    public let timestamp: Double
    /// 预期下一帧时间戳（秒），用于估算本帧可用预算
    public let targetTimestamp: Double
    /// 相邻 vsync 间隔（秒）
    public let duration: Double

    public init(timestamp: Double, targetTimestamp: Double, duration: Double) {
        self.timestamp = timestamp
        self.targetTimestamp = targetTimestamp
        self.duration = duration
    }

    /// 本帧可用的硬件刷新间隔（毫秒）
    public var intervalMillis: Double {
        max(targetTimestamp - timestamp, 0) * 1000.0
    }
}

/// VSync 源抽象：把 CADisplayLink 交互隔离在实现侧，
/// 调度器本身只依赖协议，保证离线类型检查可覆盖调度逻辑全部分支。
public protocol SDRVSyncSource: AnyObject {
    var onTick: ((SDRVSyncTick) -> Void)? { get set }
    func start(tier: SDRRefreshTier)
    func update(tier: SDRRefreshTier)
    func stop()
    func setPaused(_ paused: Bool)
}

/// 帧调度器：档位解析、预算判定、掉帧统计与自适应降档（阶段四 §4.6）。
///
/// 自适应策略（迟滞双阈值，避免档位震荡）：
///   - 连续 30 帧超档位预算 → 降一档（120 → 60 → 30）；
///   - 连续 180 帧且均帧低于预算 50% → 回升一档，但绝不超过用户设定档位；
///   - 每次调整都写日志，统计中保留当前档位标签，不做静默变更。
public final class SDRFrameScheduler {

    /// 降档触发：连续超预算帧数
    public static let degradeThreshold = 30
    /// 升档触发：连续稳定帧数
    public static let upgradeThreshold = 180
    /// 统计回调节流：每多少帧回报一次
    public static let statisticsInterval = 30

    private let lock = NSLock()
    private let source: SDRVSyncSource
    private let deviceMaximumFrameRate: Int
    private let autoAdjustEnabled: Bool

    public let requestedTier: SDRRefreshTier

    public private(set) var tier: SDRRefreshTier
    public private(set) var statistics = SDRRenderStats()

    public var onFrame: ((SDRVSyncTick) -> Void)?
    public var onStatisticsChanged: ((SDRRenderStats) -> Void)?

    private var samples: [Double] = []
    private let sampleWindow = 60
    private var consecutiveOverBudget = 0
    private var consecutiveWithinBudget = 0
    private var lastTick: SDRVSyncTick?

    public init(source: SDRVSyncSource,
                requestedTier: SDRRefreshTier,
                deviceMaximumFrameRate: Int,
                autoAdjustEnabled: Bool = true) {
        self.source = source
        self.requestedTier = requestedTier
        self.deviceMaximumFrameRate = deviceMaximumFrameRate
        self.autoAdjustEnabled = autoAdjustEnabled
        self.tier = SDRRefreshTier.resolve(requested: requestedTier, deviceMaximumFrameRate: deviceMaximumFrameRate)
        self.statistics.tierLabel = self.tier.displayName
    }

    /// 当前帧预算
    public var budget: SDRFrameBudget { SDRFrameBudget(tier: tier) }

    public var lastTickTimestamp: Double? {
        lock.lock(); defer { lock.unlock() }
        return lastTick?.timestamp
    }

    // MARK: - 生命周期

    public func start() {
        source.onTick = { [weak self] tick in
            self?.dispatch(tick)
        }
        source.start(tier: tier)
        SDRLogger.i("render", "帧调度启动：\(tier.displayName)，预算 \(String(format: "%.2f", budget.frameBudgetMillis))ms")
    }

    public func stop() {
        source.onTick = nil
        source.stop()
    }

    public func setPaused(_ paused: Bool) {
        source.setPaused(paused)
    }

    /// 设置页切换档位：请求档位与设备能力取交集，返回实际生效档位
    @discardableResult
    public func apply(requestedTier: SDRRefreshTier) -> SDRRefreshTier {
        let resolved = SDRRefreshTier.resolve(requested: requestedTier, deviceMaximumFrameRate: deviceMaximumFrameRate)
        lock.lock()
        tier = resolved
        statistics.tierLabel = resolved.displayName
        consecutiveOverBudget = 0
        consecutiveWithinBudget = 0
        lock.unlock()
        source.update(tier: resolved)
        SDRLogger.i("render", "刷新档位切换：\(resolved.displayName)")
        return resolved
    }

    // MARK: - 统计回填

    /// 渲染循环完成一帧后回填耗时
    public func recordPresented(frameMillis: Double) {
        lock.lock()
        statistics.framesPresented += 1
        statistics.lastFrameMillis = frameMillis
        samples.append(frameMillis)
        if samples.count > sampleWindow {
            samples.removeFirst(samples.count - sampleWindow)
        }
        let total = samples.reduce(0, +)
        statistics.averageFrameMillis = total / Double(samples.count)
        statistics.worstFrameMillis = max(statistics.worstFrameMillis, frameMillis)

        let currentBudget = SDRFrameBudget(tier: tier)
        if currentBudget.violatesHardLimit(frameMillis) {
            statistics.framesOverHardLimit += 1
        }
        if currentBudget.exceedsFrameBudget(frameMillis) {
            statistics.framesOverBudget += 1
            consecutiveOverBudget += 1
            consecutiveWithinBudget = 0
        } else {
            consecutiveOverBudget = 0
            consecutiveWithinBudget += 1
        }
        let shouldReport = statistics.framesPresented % SDRFrameScheduler.statisticsInterval == 0
        let snapshot = statistics
        let adjustment = evaluateTierAdjustmentLocked()
        lock.unlock()

        if let next = adjustment {
            source.update(tier: next)
        }
        if shouldReport {
            onStatisticsChanged?(snapshot)
        }
    }

    /// 无脏区导致的跳帧（未渲染，属省电行为，不计入掉帧）
    public func recordSkipped() {
        lock.lock()
        statistics.framesSkipped += 1
        lock.unlock()
    }

    /// 首屏完整渲染耗时（验收指标 ≤150ms）
    public func recordFirstScreen(millis: Double) {
        lock.lock()
        statistics.firstScreenMillis = millis
        lock.unlock()
        if budget.violatedFirstScreenLimit(millis) {
            SDRLogger.w("render", "首屏渲染 \(String(format: "%.1f", millis))ms 超出 §5.4 硬约束 150ms")
        }
    }

    /// 合并渲染循环内部的统计（PSO 命中、纹理池、编码命令数等）
    public func mergeCounters(pipelineHits: Int, pipelineMisses: Int,
                              textureHits: Int, textureMisses: Int,
                              encodedCommands: Int, warmupMillis: Double, warmupCount: Int) {
        lock.lock()
        statistics.pipelineCacheHits = pipelineHits
        statistics.pipelineCacheMisses = pipelineMisses
        statistics.texturePoolHits = textureHits
        statistics.texturePoolMisses = textureMisses
        statistics.drawCommandsEncoded = encodedCommands
        statistics.warmupMillis = warmupMillis
        statistics.warmupPipelineCount = warmupCount
        lock.unlock()
    }

    public func statisticsSnapshot() -> SDRRenderStats {
        lock.lock(); defer { lock.unlock() }
        return statistics
    }

    // MARK: - 内部

    private func dispatch(_ tick: SDRVSyncTick) {
        lock.lock()
        lastTick = tick
        lock.unlock()
        onFrame?(tick)
    }

    /// 自适应档位评估；返回非 nil 表示需要下发新档位
    private func evaluateTierAdjustmentLocked() -> SDRRefreshTier? {
        guard autoAdjustEnabled else { return nil }

        if consecutiveOverBudget >= SDRFrameScheduler.degradeThreshold {
            consecutiveOverBudget = 0
            guard let lower = SDRFrameScheduler.lowerTier(below: tier) else { return nil }
            tier = lower
            statistics.tierLabel = lower.displayName
            consecutiveWithinBudget = 0
            SDRLogger.w("render", "持续超预算，档位自适应下调至 \(lower.displayName)")
            return lower
        }

        if consecutiveWithinBudget >= SDRFrameScheduler.upgradeThreshold {
            consecutiveWithinBudget = 0
            guard let higher = SDRFrameScheduler.higherTier(above: tier, cap: requestedTier) else { return nil }
            tier = higher
            statistics.tierLabel = higher.displayName
            SDRLogger.i("render", "帧率稳定，档位回升至 \(higher.displayName)")
            return higher
        }
        return nil
    }

    static func lowerTier(below tier: SDRRefreshTier) -> SDRRefreshTier? {
        switch tier {
        case .pro120: return .standard60
        case .standard60: return .eco30
        case .eco30: return nil
        }
    }

    static func higherTier(above tier: SDRRefreshTier, cap: SDRRefreshTier) -> SDRRefreshTier? {
        let candidate: SDRRefreshTier
        switch tier {
        case .eco30: candidate = .standard60
        case .standard60: candidate = .pro120
        case .pro120: return nil
        }
        return candidate.rawValue <= cap.rawValue ? candidate : nil
    }
}
