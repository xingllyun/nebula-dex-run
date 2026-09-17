import SwiftUI

public struct SDRLogConsoleView: View {
    @EnvironmentObject private var logs: SDRLogStore
    @State private var minLevel: SDRLogLevel = .verbose
    @State private var shareItem: SDRShareItem?

    public init() {}

    private var filtered: [SDRLogEntry] {
        logs.entries.filter { $0.level.rawValue >= minLevel.rawValue }
    }

    public var body: some View {
        NavigationStack {
            List(filtered) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.level.label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color(for: entry.level))
                        Text(entry.module).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(entry.text).font(.footnote.monospaced())
                }
            }
            .listStyle(.plain)
            .navigationTitle("运行日志")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(SDRLogLevel.allCases, id: \.self) { level in
                            Button(level.label) { minLevel = level }
                        }
                    } label: {
                        Text(minLevel.label).font(.footnote)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导出") { if let url = logs.export() { shareItem = SDRShareItem(url: url) } }
                        Button("清空", role: .destructive) { logs.clear() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private func color(for level: SDRLogLevel) -> Color {
        switch level {
        case .verbose, .debug: return .secondary
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }
}

/// UIActivityViewController 包装
public struct ShareSheet: UIViewControllerRepresentable {
    public let items: [Any]

    public init(items: [Any]) { self.items = items }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    public func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 导出面板的呈现项
public struct SDRShareItem: Identifiable {
    public let id = UUID()
    public let url: URL

    public init(url: URL) { self.url = url }
}
