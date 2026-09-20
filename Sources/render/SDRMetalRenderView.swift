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

    private var touchIdentifiers: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
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
        let contacts = touches.map { contact(for: $0) }
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
