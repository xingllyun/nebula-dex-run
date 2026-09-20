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
import UIKit
import QuartzCore

/// 触控链路调节项（文档 §4.1–§4.4）。
///
/// 说明：本视图不是 UIScrollView，不存在 delaysContentTouches 默认约 150ms 的
/// 滑动意图判定延迟；后续若在渲染视图外引入滚动容器，必须显式设置
/// `delaysContentTouches = false` 与 `canCancelContentTouches = true`
/// （文档附录 A-2 #12 / #13）。
public struct SDRTouchTuning {

    /// 按下时请求无缓冲分发，降低系统侧事件聚合延迟（附录 A-3 #15）
    public var unbufferedDispatch = true
    /// 把合并触点作为历史采样补入速度估算，避免快速滑动下的速度突变（附录 A-3 #14）
    public var coalescedSamples = true
    /// 单次主线程触控处理告警阈值（毫秒，对齐单帧触控预算）
    public var mainThreadWarnMillis: Double = 60
    /// 主线程停滞红线（毫秒，对齐 ANR 5 秒红线自检）
    public var mainThreadAnrMillis: Double = 5000

    public init() {}
}

/// 宿主侧承载视图：CAMetalLayer 上屏容器（阶段四 §4.1 渲染管线最上层）。
///
/// guest 的 Android View 树不在这里解释——它由 guest 侧布局后经 SDRRenderBridge
/// 转成绘制命令；本视图只负责尺寸同步、前后台节流与档位下发。
public final class SDRMetalRenderView: UIView {

    /// 宿主事件泵转发的通知名（避免本层直接依赖 UIApplication 生命周期常量）
    public static let didEnterBackgroundNotification = Notification.Name("SDRHostDidEnterBackground")
    public static let willEnterForegroundNotification = Notification.Name("SDRHostWillEnterForeground")
    public static let memoryWarningNotification = Notification.Name("SDRHostMemoryWarning")

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public private(set) var renderAttached = false
    public private(set) var requestedTier: SDRRefreshTier = .standard60

    private let loop: SDRRenderLoop
    private var observers: [NSObjectProtocol] = []

    private var metalLayer: CAMetalLayer {
        guard let layer = layer as? CAMetalLayer else {
            // layerClass 已固定为 CAMetalLayer，此分支仅防御运行时异常
            return CAMetalLayer()
        }
        return layer
    }

    public override init(frame: CGRect) {
        self.loop = .shared
        super.init(frame: frame)
        configureLayer()
    }

    public required init?(coder: NSCoder) {
        self.loop = .shared
        super.init(coder: coder)
        configureLayer()
    }

    deinit {
        releaseObservers()
    }

    /// 测试注入用构造：允许指定渲染循环实例
    public init(frame: CGRect, loop: SDRRenderLoop) {
        self.loop = loop
        super.init(frame: frame)
        configureLayer()
    }

    // MARK: - 装配

    /// 装配渲染层并启动帧循环
    public func attachRenderer(tier: SDRRefreshTier = .standard60,
                               maximumFrameRate: Int = UIScreen.main.maximumFramesPerSecond) throws {
        guard !renderAttached else { return }
        requestedTier = tier

        let target = metalLayer
        target.device = loop.device
        target.pixelFormat = loop.pixelFormat.metalValue
        target.framebufferOnly = true
        target.presentsWithTransaction = false
        target.allowsNextDrawableTimeout = false
        target.maximumDrawableCount = SDRRenderDevice.maxFramesInFlight
        target.isOpaque = true

        try loop.attach(layer: target,
                        requestedTier: tier,
                        deviceMaximumFrameRate: maximumFrameRate,
                        drawableSize: drawableSize(for: bounds),
                        contentsScale: contentScaleFactor)
        renderAttached = true
        touchRouter.contentsScale = Double(max(contentScaleFactor, 1))
        touchRouter.onDispatch = { event in
            SDRLogger.v("render", "触控事件 \(event.action.displayName) 指针数：\(event.pointerCount)")
        }
        loop.start()
        SDRLogger.i("render", "渲染层已装配：档位 \(tier.displayName)，绘制区 \(Int(drawableSize(for: bounds).width))x\(Int(drawableSize(for: bounds).height))")
    }

    public func detachRenderer() {
        loop.stop()
        touchRouter.reset()
        renderAttached = false
    }

    // MARK: - 尺寸与档位

    public override func layoutSubviews() {
        super.layoutSubviews()
        // 分屏 / 缩放场景下 contentScaleFactor 可能变化，触控坐标需同步折算
        touchRouter.contentsScale = Double(max(contentScaleFactor, 1))
        guard renderAttached else { return }
        loop.updateDrawableSize(drawableSize(for: bounds), contentsScale: contentScaleFactor)
    }

    /// 切换刷新档位，返回实际生效档位（可能被设备上限或调度器降档）
    @discardableResult
    public func setRefreshTier(_ tier: SDRRefreshTier) -> SDRRefreshTier {
        requestedTier = tier
        return loop.setTier(tier)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard renderAttached else { return }
        if window == nil {
            loop.setPaused(true)
        } else {
            loop.setPaused(false)
            loop.requestFullRedraw()
        }
    }

    // MARK: - 触控路由（阶段四 §4.4）

    /// 触控路由器：UIKit 触点流 → Android MotionEvent 流。
    /// guest 侧 Java 投递（JNI 阶段）接入前，默认出口仅记录日志，不做任何命中测试。
    public let touchRouter = SDRTouchRouter()

    /// 触控链路调节项（无缓冲分发 / 合并触点 / 主线程红线）
    public var touchTuning = SDRTouchTuning()

    private var touchIdentifiers: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touchTuning.unbufferedDispatch, let event = event {
            // 手指按下即请求无缓冲分发，跳过系统侧的延迟聚合
            requestUnbufferedDispatch(event)
        }
        route(.began, touches: touches, event: event)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        route(.moved, touches: touches, event: event)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        route(.ended, touches: touches, event: event)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        route(.cancelled, touches: touches, event: event)
    }

    private func route(_ phase: SDRTouchPhase, touches: Set<UITouch>, event: UIEvent?) {
        let started = CACurrentMediaTime()
        defer { recordMainThreadCost(since: started) }

        let contacts = touches.map { contact(for: $0) }
        if touchTuning.coalescedSamples, phase == .moved, let event = event {
            // 合并触点批处理：把一帧内的历史采样补入速度估算
            ingestCoalescedTouches(touches, event: event)
        }
        if phase == .ended || phase == .cancelled {
            // 触点 id 随手指抬起释放，避免长会话下映射表无限增长
            for touch in touches {
                touchIdentifiers.removeValue(forKey: ObjectIdentifier(touch))
            }
        }
        guard renderAttached else { return }
        touchRouter.handle(phase: phase, contacts: contacts, timestampMillis: timestampMillis(event))
    }

    /// UITouch → 内部触点（位置为视图坐标，比例折算在路由层完成）
    private func contact(for touch: UITouch) -> SDRTouchContact {
        let key = ObjectIdentifier(touch)
        let id: Int
        if let existing = touchIdentifiers[key] {
            id = existing
        } else {
            id = nextTouchID
            nextTouchID += 1
            touchIdentifiers[key] = id
        }
        let point = touch.location(in: self)
        return SDRTouchContact(id: id,
                               x: Double(point.x),
                               y: Double(point.y),
                               pressure: Double(touch.force))
    }

    /// 合并触点批处理：UIKit 将一帧内的多次采样合并后投递，历史坐标补入速度估算，
    /// 避免快速滑动下速度估算偏低（文档 §4.2 / 附录 A-3 #14）。
    private func ingestCoalescedTouches(_ touches: Set<UITouch>, event: UIEvent) {
        var samples: [SDRTouchContact] = []
        for touch in touches {
            // 历史采样复用当前触点 id，但不注册新的映射，避免污染触点表
            guard let id = touchIdentifiers[ObjectIdentifier(touch)],
                  let history = event.coalescedTouches(for: touch) else { continue }
            for past in history {
                let point = past.location(in: self)
                samples.append(SDRTouchContact(id: id,
                                               x: Double(point.x),
                                               y: Double(point.y),
                                               pressure: Double(past.force)))
            }
        }
        guard samples.count > 1 else { return }
        touchRouter.ingestHistoricalSamples(samples, timestampMillis: event.timestamp * 1000.0)
    }

    /// 主线程触控处理耗时自检：对齐 Android「5 秒不响应输入即 ANR」红线（文档 §4.4）
    private func recordMainThreadCost(since started: CFTimeInterval) {
        let millis = (CACurrentMediaTime() - started) * 1000.0
        if millis >= touchTuning.mainThreadAnrMillis {
            SDRLogger.e("render", "触控分发主线程耗时 \(Int(millis))ms，已达 ANR 红线（文档 §4.4）")
        } else if millis >= touchTuning.mainThreadWarnMillis {
            SDRLogger.w("render", "触控分发主线程耗时 \(Int(millis))ms，超出单帧触控预算")
        }
        touchRouter.recordMainThreadCost(millis)
    }

    /// 事件时间戳（毫秒）：优先取 UIEvent，回落 CADisplayLink 同时基
    private func timestampMillis(_ event: UIEvent?) -> Double {
        let stamp = event?.timestamp ?? CACurrentMediaTime()
        return stamp * 1000.0
    }

    // MARK: - 生命周期事件（由宿主事件泵调用或转发通知）

    public func applicationDidEnterBackground() {
        loop.setPaused(true)
    }

    public func applicationWillEnterForeground() {
        loop.setPaused(false)
        loop.requestFullRedraw()
    }

    public func handleMemoryWarning() {
        loop.handleMemoryPressure()
    }

    // MARK: - 内部

    private func configureLayer() {
        backgroundColor = UIColor.black
        isUserInteractionEnabled = true
        // 多指手势（缩放 / 旋转）需要全部触点，统一交由 SDRTouchRouter 归并为 Android 事件
        isMultipleTouchEnabled = true
        touchRouter.contentsScale = Double(max(contentScaleFactor, 1))
        observeLifecycle()
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let background = center.addObserver(forName: SDRMetalRenderView.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.applicationDidEnterBackground()
        }
        let foreground = center.addObserver(forName: SDRMetalRenderView.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.applicationWillEnterForeground()
        }
        let memory = center.addObserver(forName: SDRMetalRenderView.memoryWarningNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.handleMemoryWarning()
        }
        observers = [background, foreground, memory]
    }

    private func releaseObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func drawableSize(for bounds: CGRect) -> CGSize {
        let scale = max(contentScaleFactor, 1)
        return CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
    }
}
