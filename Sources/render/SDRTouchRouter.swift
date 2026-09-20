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

// MARK: - Android MotionEvent 语义（阶段四 §4.4 触控优化）

/// Android `MotionEvent` 动作码子集。语义与 guest 侧 `android.view.MotionEvent` 常量对齐，
/// 宿主只做触点归并与事件合成，不解释 View 树命中测试。
public enum SDRMotionAction: Int32 {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
    case pointerDown = 5
    case pointerUp = 6

    public var displayName: String {
        switch self {
        case .down: return "ACTION_DOWN"
        case .up: return "ACTION_UP"
        case .move: return "ACTION_MOVE"
        case .cancel: return "ACTION_CANCEL"
        case .pointerDown: return "ACTION_POINTER_DOWN"
        case .pointerUp: return "ACTION_POINTER_UP"
        }
    }
}

/// 单个触点。坐标已折算为 guest 侧像素坐标（= UIKit 点 × contentsScale）。
public struct SDRTouchContact: Equatable {
    public let id: Int
    public let x: Double
    public let y: Double
    public let pressure: Double

    public init(id: Int, x: Double, y: Double, pressure: Double = 1.0) {
        self.id = id
        self.x = x
        self.y = y
        self.pressure = pressure
    }
}

/// 宿主侧触摸阶段（与 UIKit 的 began/moved/ended/cancelled 一一对应）
public enum SDRTouchPhase {
    case began
    case moved
    case ended
    case cancelled
}

/// 合成后的触控事件：一次派发 = 一个 guest 侧 `MotionEvent`。
public struct SDRTouchEvent: Equatable {
    public let action: SDRMotionAction
    /// 多指动作（POINTER_DOWN / POINTER_UP）对应的触点序号，其余动作恒为 0
    public let actionIndex: Int
    /// 事件时刻全部活动触点（Android 语义：MOVE / POINTER_UP 一并携带其余指针坐标）
    public let contacts: [SDRTouchContact]
    public let timestampMillis: Double

    public var primary: SDRTouchContact? { contacts.first }
    public var pointerCount: Int { contacts.count }
}

/// 触控路由统计（供设置页调试面板与 CI 验收读取）
public struct SDRTouchStats: Equatable, Encodable {
    public var dispatched = 0
    public var droppedBySlop = 0
    public var longPressCount = 0
    public var doubleTapCount = 0
    public var cancelCount = 0
    public var maxPointerCount = 0
}

/// 触控路由器：UIKit 触点流 → Android `MotionEvent` 流。
///
/// 设计要点：
/// - **归并**：UIKit 每次回调携带全部触点，本层按 id 维护活动集合，逐点产出 DOWN / POINTER_DOWN；
/// - **抖动抑制**：主触点位移未越过 touch slop 前不派发 MOVE，避免 guest 侧收到密集无效事件；
/// - **手势识别**：长按（500ms）与双击（300ms / 40px）在本层完成判定，guest 侧不再重复计时；
/// - **像素对齐**：坐标乘以 contentsScale 并取整，保证 guest 侧像素网格与绘制命令一致；
/// - **投递出口**：`onDispatch` 闭包 —— guest Java 侧投递（JNI 阶段）接入前默认仅记录日志，
///   严禁在此层伪造命中测试结果。
public final class SDRTouchRouter {

    // MARK: - 常量

    /// 抖动阈值（guest 像素）：小于该位移的 MOVE 不派发
    public static let touchSlop: Double = 8.0
    /// 长按判定阈值（毫秒）
    public static let longPressMillis: Double = 500.0

    /// 主线程单次处理告警阈值（毫秒，对齐单帧触控预算 60ms）
    public static let mainThreadWarnMillis: Double = 60.0

    /// 合并触点回推的时间窗（毫秒）：UIKit 单帧聚合窗口约 1 个刷新周期
    public static let coalescedWindowMillis: Double = 16.0
    /// 双击间隔上限（毫秒）
    public static let doubleTapMillis: Double = 300.0
    /// 双击位置容差（guest 像素）
    public static let doubleTapSlop: Double = 40.0
    /// 点击时长上限（毫秒）：超过则不计入双击候选
    public static let tapMaxMillis: Double = 200.0
    /// 同时活动触点上限：超出直接截断，防御异常多指输入
    public static let maxContacts = 10
    /// 速度采样窗口（帧数）
    public static let velocitySampleCount = 5

    /// 供 guest 侧 host-call 表注册的符号名清单（与 SDRRenderBridge.hostSymbols 同构）
    public static let hostSymbols: [String] = [
        "touch.dispatch", "touch.setMetrics", "touch.setScale",
        "touch.velocity", "touch.statistics", "touch.reset"
    ]

    // MARK: - 配置与出口

    /// 宿主点 → guest 像素的比例（= 视图 contentsScale）
    public var contentsScale: Double = 1.0
    /// 事件出口：由宿主装配层注入（默认为空，仅统计不投递）
    public var onDispatch: ((SDRTouchEvent) -> Void)?
    /// 长按回调（触点已越过判定阈值时触发一次）
    public var onLongPress: ((SDRTouchContact) -> Void)?
    /// 双击回调
    public var onDoubleTap: ((SDRTouchContact) -> Void)?

    // MARK: - 状态

    public private(set) var stats = SDRTouchStats()

    /// 主线程单次触控处理耗时峰值（毫秒）：用于自检 Android ANR 5 秒红线（文档 §4.4）
    public private(set) var mainThreadStallMillis: Double = 0

    private var active: [Int: SDRTouchContact] = [:]
    /// 触点 id 的按下顺序，保证 actionIndex 稳定
    private var order: [Int] = []
    private var downContact: SDRTouchContact?
    private var downMillis: Double = 0
    private var maxTravel: Double = 0
    private var longPressFired = false
    private var lastTapMillis: Double?
    private var lastTapContact: SDRTouchContact?
    private var velocitySamples: [(millis: Double, x: Double, y: Double)] = []

    public init(contentsScale: Double = 1.0) {
        self.contentsScale = contentsScale
    }

    // MARK: - 活动触点视图

    public var activeContacts: [SDRTouchContact] {
        order.compactMap { active[$0] }
    }

    public var pointerCount: Int { order.count }

    /// 主触点即时速度（guest 像素 / 秒），样本不足时返回 0
    public var velocity: (x: Double, y: Double) {
        guard let last = velocitySamples.last, let first = velocitySamples.first, velocitySamples.count >= 2 else {
            return (0, 0)
        }
        let dt = (last.millis - first.millis) / 1000.0
        guard dt > 0 else { return (0, 0) }
        return ((last.x - first.x) / dt, (last.y - first.y) / dt)
    }

    // MARK: - 入口

    /// 投喂一轮宿主触点状态。`contacts` 为当前全部触点（UIKit 回调语义）。
    public func handle(phase: SDRTouchPhase, contacts: [SDRTouchContact], timestampMillis: Double) {
        let scaled = contacts.prefix(SDRTouchRouter.maxContacts).map { contact -> SDRTouchContact in
            SDRTouchContact(id: contact.id,
                            x: (contact.x * contentsScale).rounded(),
                            y: (contact.y * contentsScale).rounded(),
                            pressure: min(max(contact.pressure, 0), 1))
        }
        stats.maxPointerCount = max(stats.maxPointerCount, scaled.count)

        switch phase {
        case .began: handleBegan(scaled, timestampMillis: timestampMillis)
        case .moved: handleMoved(scaled, timestampMillis: timestampMillis)
        case .ended: handleEnded(scaled, timestampMillis: timestampMillis)
        case .cancelled: handleCancelled()
        }
    }

    /// 清空全部状态（Activity 销毁 / 视图移除时调用）
    public func reset() {
        active.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        downContact = nil
        downMillis = 0
        maxTravel = 0
        longPressFired = false
        lastTapMillis = nil
        lastTapContact = nil
        velocitySamples.removeAll(keepingCapacity: true)
    }

    /// 登记一次主线程处理耗时并更新峰值，返回是否越过告警阈值
    @discardableResult
    public func recordMainThreadCost(_ millis: Double) -> Bool {
        mainThreadStallMillis = max(mainThreadStallMillis, millis)
        return millis >= SDRTouchRouter.mainThreadWarnMillis
    }

    /// 历史（合并）触点批量投喂：仅补速度样本，不产生 MotionEvent（文档 §4.2 历史事件批处理）。
    ///
    /// UIKit 会把一个刷新周期内的多次采样合并投递，直接用合并后坐标估算速度会在快速滑动时偏低；
    /// 这里把窗口内采样按等间隔回推时间戳，得到与逐点采样一致的估算口径。
    public func ingestHistoricalSamples(_ samples: [SDRTouchContact], timestampMillis: Double) {
        guard samples.count > 1 else { return }
        let span = SDRTouchRouter.coalescedWindowMillis
        let step = span / Double(max(samples.count - 1, 1))
        for (index, sample) in samples.enumerated() {
            let scaled = SDRTouchContact(id: sample.id,
                                         x: (sample.x * contentsScale).rounded(),
                                         y: (sample.y * contentsScale).rounded(),
                                         pressure: min(max(sample.pressure, 0), 1))
            recordVelocitySample(scaled,
                                 timestampMillis: timestampMillis - span + step * Double(index))
        }
    }

    public func statisticsSnapshot() -> SDRTouchStats { stats }

    /// 统计快照 JSON（与渲染层 statisticsJSON 同口径，便于统一上报）
    public func statisticsJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stats),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - 阶段处理

    private func handleBegan(_ contacts: [SDRTouchContact], timestampMillis: Double) {
        for contact in contacts where active[contact.id] == nil {
            let isFirst = order.isEmpty
            let index = order.count
            order.append(contact.id)
            active[contact.id] = contact

            if isFirst {
                downContact = contact
                downMillis = timestampMillis
                maxTravel = 0
                longPressFired = false
                velocitySamples.removeAll(keepingCapacity: true)
                velocitySamples.append((timestampMillis, contact.x, contact.y))
            }
            dispatch(SDRTouchEvent(action: isFirst ? .down : .pointerDown,
                                   actionIndex: index,
                                   contacts: activeContacts,
                                   timestampMillis: timestampMillis))
        }
    }

    private func handleMoved(_ contacts: [SDRTouchContact], timestampMillis: Double) {
        guard !order.isEmpty else { return }

        for contact in contacts where active[contact.id] != nil {
            active[contact.id] = contact
        }
        guard let primary = active[order[0]] else { return }

        if let origin = downContact {
            let travel = hypot(primary.x - origin.x, primary.y - origin.y)
            maxTravel = max(maxTravel, travel)
        }

        // 长按：越过时长阈值且仍在容差内，只触发一次
        if !longPressFired, maxTravel <= SDRTouchRouter.touchSlop,
           timestampMillis - downMillis >= SDRTouchRouter.longPressMillis {
            longPressFired = true
            stats.longPressCount += 1
            onLongPress?(primary)
        }

        // 抖动抑制：未越过 slop 的位移不入队，避免 guest 侧事件洪泛
        if maxTravel < SDRTouchRouter.touchSlop {
            stats.droppedBySlop += 1
            return
        }

        recordVelocitySample(primary, timestampMillis: timestampMillis)
        dispatch(SDRTouchEvent(action: .move,
                               actionIndex: 0,
                               contacts: activeContacts,
                               timestampMillis: timestampMillis))
    }

    private func handleEnded(_ contacts: [SDRTouchContact], timestampMillis: Double) {
        for contact in contacts {
            guard let index = order.firstIndex(of: contact.id) else { continue }
            let isLast = order.count == 1
            let current = active[contact.id] ?? contact

            // POINTER_UP / UP 事件按 Android 语义仍携带其余指针坐标
            dispatch(SDRTouchEvent(action: isLast ? .up : .pointerUp,
                                   actionIndex: index,
                                   contacts: isLast ? [current] : activeContacts,
                                   timestampMillis: timestampMillis))

            order.remove(at: index)
            active.removeValue(forKey: contact.id)

            if isLast {
                resolveTapAndLongPress(current, timestampMillis: timestampMillis)
                downContact = nil
                maxTravel = 0
                longPressFired = false
                velocitySamples.removeAll(keepingCapacity: true)
            }
        }
    }

    private func handleCancelled() {
        guard !order.isEmpty else { return }
        let contacts = activeContacts
        dispatch(SDRTouchEvent(action: .cancel,
                               actionIndex: 0,
                               contacts: contacts,
                               timestampMillis: downMillis))
        stats.cancelCount += 1
        reset()
    }

    // MARK: - 手势判定

    private func resolveTapAndLongPress(_ contact: SDRTouchContact, timestampMillis: Double) {
        // 已判过长按，不再参与双击
        if longPressFired { return }
        let duration = timestampMillis - downMillis
        guard duration <= SDRTouchRouter.tapMaxMillis, maxTravel <= SDRTouchRouter.touchSlop else { return }

        if let previousMillis = lastTapMillis, let previousContact = lastTapContact {
            let gap = timestampMillis - previousMillis
            let distance = hypot(contact.x - previousContact.x, contact.y - previousContact.y)
            if gap <= SDRTouchRouter.doubleTapMillis, distance <= SDRTouchRouter.doubleTapSlop {
                stats.doubleTapCount += 1
                onDoubleTap?(contact)
                lastTapMillis = nil
                lastTapContact = nil
                return
            }
        }
        lastTapMillis = timestampMillis
        lastTapContact = contact
    }

    private func recordVelocitySample(_ contact: SDRTouchContact, timestampMillis: Double) {
        velocitySamples.append((timestampMillis, contact.x, contact.y))
        if velocitySamples.count > SDRTouchRouter.velocitySampleCount {
            velocitySamples.removeFirst(velocitySamples.count - SDRTouchRouter.velocitySampleCount)
        }
    }

    private func dispatch(_ event: SDRTouchEvent) {
        stats.dispatched += 1
        onDispatch?(event)
    }
}
