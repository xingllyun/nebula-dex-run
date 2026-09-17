import Foundation
import UIKit

/// 系统版本与能力适配层：iOS 27 等未来版本集中在此扩展
public enum SDRVersionAdapter {
    public static var systemVersion: String { UIDevice.current.systemVersion }

    public static var majorVersion: Int {
        Int(systemVersion.split(separator: ".").first ?? "16") ?? 16
    }

    public static var isIOS26OrLater: Bool { majorVersion >= 26 }
    public static var isIOS27OrLater: Bool { majorVersion >= 27 }

    /// 是否支持 iOS 26 的 BGContinuedProcessingTask
    public static var supportsContinuedProcessing: Bool {
        if #available(iOS 26.0, *) { return true } else { return false }
    }

    /// 是否支持 ProMotion（120Hz）
    public static var supportsProMotion: Bool {
        UIScreen.main.maximumFramesPerSecond > 60
    }

    public static func availableRefreshRates() -> [Int] {
        supportsProMotion ? [30, 60, 120] : [30, 60]
    }
}
