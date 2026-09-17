import SwiftUI

/// 视觉常量（深色优先，跟随系统）
public enum SDRTheme {
    public static let accent = Color(red: 0.36, green: 0.55, blue: 1.0)
    public static let card = Color(uiColor: .secondarySystemGroupedBackground)
    public static let background = Color(uiColor: .systemGroupedBackground)
    public static let corner: CGFloat = 16
    public static let padding: CGFloat = 16

    public static func stateColor(_ state: SDRRunState) -> Color {
        switch state {
        case .idle: return .secondary
        case .loading: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }

    public static func stateText(_ state: SDRRunState) -> String {
        switch state {
        case .idle: return "待机"
        case .loading(let step, let progress): return "\(step) \(Int(progress * 100))%"
        case .running: return "运行中"
        case .failed(let reason): return "失败：\(reason)"
        }
    }
}
