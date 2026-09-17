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
