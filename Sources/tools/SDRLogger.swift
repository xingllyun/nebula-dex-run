import Foundation

/// 日志门面：调用点无需关心存储实现
public enum SDRLogger {
    public static var minLevel: SDRLogLevel = .info
    public static var fileOutputEnabled = false

    public static func v(_ module: String, _ text: String) { SDRLogStore.shared.log(.verbose, module, text) }
    public static func d(_ module: String, _ text: String) { SDRLogStore.shared.log(.debug, module, text) }
    public static func i(_ module: String, _ text: String) { SDRLogStore.shared.log(.info, module, text) }
    public static func w(_ module: String, _ text: String) { SDRLogStore.shared.log(.warn, module, text) }
    public static func e(_ module: String, _ text: String) { SDRLogStore.shared.log(.error, module, text) }
}
