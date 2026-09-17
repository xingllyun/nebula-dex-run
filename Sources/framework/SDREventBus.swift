import Foundation

/// 进程内事件总线（对应安卓 BroadcastReceiver 的替代实现）
public final class SDREventBus {
    public static let shared = SDREventBus()
    private var handlers: [String: [(Any) -> Void]] = [:]
    private let lock = NSLock()

    public func on(_ event: String, handler: @escaping (Any) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers[event, default: []].append(handler)
    }

    public func emit(_ event: String, payload: Any? = nil) {
        lock.lock()
        let list = handlers[event] ?? []
        lock.unlock()
        list.forEach { $0(payload as Any) }
    }
}
