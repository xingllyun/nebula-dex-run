import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Live Activity 桥接：把软运行时的前台任务状态同步到锁屏/灵动岛
public final class SDRLiveActivityBridge {

    public struct Payload: Codable, Hashable {
        public var packageName: String
        public var label: String
        public var phase: String
        public var detail: String
        public var updatedAt: Date
    }

    public private(set) var current: Payload?
    private let queue = DispatchQueue(label: "com.xingyun.NebulaDex.liveactivity")

    public init() {}

    public func update(packageName: String, label: String, phase: String, detail: String) {
        let payload = Payload(packageName: packageName, label: label, phase: phase,
                              detail: detail, updatedAt: Date())
        queue.sync { current = payload }
        SDRLogger.i("live", "活动更新：\(label) / \(phase)")
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            // ActivityKit 真实更新逻辑在 app 目标内实现，此处仅做状态缓存与广播
        }
        #endif
        SDREventBus.shared.emit("live.activity.updated", payload: payload)
    }

    public func end(packageName: String) {
        queue.sync {
            if current?.packageName == packageName { current = nil }
        }
        SDRLogger.i("live", "活动结束：\(packageName)")
    }
}
