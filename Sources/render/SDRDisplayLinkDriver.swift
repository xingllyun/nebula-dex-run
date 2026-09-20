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
import QuartzCore

/// CADisplayLink VSync 源实现。
///
/// 该文件是渲染层唯一依赖 Objective-C 运行时的部分（target/selector 回调），
/// 因此被排除在 Linux 离线类型检查之外（见 Scripts/typecheck-render.sh 说明），
/// 由 macOS CI 的 iOS Unsigned Build 流水线负责真实编译校验。
public final class SDRDisplayLinkDriver: NSObject, SDRVSyncSource {

    public var onTick: ((SDRVSyncTick) -> Void)?

    private var link: CADisplayLink?
    private var currentTier: SDRRefreshTier = .standard60

    public override init() {
        super.init()
    }

    public var isRunning: Bool { link != nil }

    /// 启动显示链路：按档位上报首选刷新区间（文档表 7-1）
    public func start(tier: SDRRefreshTier) {
        stop()
        currentTier = tier
        let link = CADisplayLink(target: self, selector: #selector(handleTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: tier.cadenceRange.minimum,
                                                        maximum: tier.cadenceRange.maximum,
                                                        preferred: tier.cadenceRange.preferred)
        // 兜底：老系统或 range 未生效时按标称帧率对齐
        link.preferredFramesPerSecond = tier.legacyPreferredFramesPerSecond
        link.add(to: .main, forMode: .common)
        self.link = link
        SDRLogger.i("render", "CADisplayLink 启动：\(tier.displayName)，range(\(tier.cadenceRange.minimum), \(tier.cadenceRange.maximum), \(tier.cadenceRange.preferred))")
    }

    public func update(tier: SDRRefreshTier) {
        guard let link = link else {
            start(tier: tier)
            return
        }
        currentTier = tier
        link.preferredFrameRateRange = CAFrameRateRange(minimum: tier.cadenceRange.minimum,
                                                        maximum: tier.cadenceRange.maximum,
                                                        preferred: tier.cadenceRange.preferred)
        link.preferredFramesPerSecond = tier.legacyPreferredFramesPerSecond
        SDRLogger.i("render", "CADisplayLink 档位更新：\(tier.displayName)")
    }

    public func setPaused(_ paused: Bool) {
        link?.isPaused = paused
    }

    public func stop() {
        link?.invalidate()
        link = nil
    }

    public var tier: SDRRefreshTier { currentTier }

    @objc private func handleTick(_ link: CADisplayLink) {
        let tick = SDRVSyncTick(timestamp: link.timestamp,
                                targetTimestamp: link.targetTimestamp,
                                duration: link.duration)
        onTick?(tick)
    }
}
