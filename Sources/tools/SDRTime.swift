import Foundation

public enum SDRTime {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func format(_ date: Date) -> String { formatter.string(from: date) }
    public static func formatFull(_ date: Date) -> String { full.string(from: date) }
}
