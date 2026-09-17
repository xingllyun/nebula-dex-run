import SwiftUI
import UniformTypeIdentifiers

public struct SDRAppGridView: View {
    @EnvironmentObject private var state: SDRAppState
    @State private var showImporter = false
    @State private var errorText: String?

    public init() {}

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: SDRTheme.padding)]

    public var body: some View {
        NavigationStack {
            Group {
                if state.apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("尚未导入应用").font(.headline)
                        Text("选择本机 .apk 文件导入后即可软运行")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: SDRTheme.padding) {
                            ForEach(state.apps) { app in
                                SDRAppTile(info: app)
                            }
                        }
                        .padding(SDRTheme.padding)
                    }
                }
            }
            .background(SDRTheme.background)
            .navigationTitle("NebulaDex")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        try SDRAppContainer.shared.importAPK(url: url)
                    } catch {
                        errorText = error.localizedDescription
                    }
                case .failure(let error):
                    errorText = error.localizedDescription
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } })) {
                Button("知道了", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }
}

struct SDRAppTile: View {
    let info: SDRAppInfo
    @EnvironmentObject private var state: SDRAppState
    @State private var showActions = false

    var body: some View {
        Button {
            showActions = true
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: SDRTheme.corner, style: .continuous)
                    .fill(SDRTheme.card)
                    .frame(height: 72)
                    .overlay(
                        Text(String(info.label.prefix(1)).uppercased())
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(SDRTheme.accent)
                    )
                Text(info.label).font(.caption).lineLimit(1)
                Text(info.versionName).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .confirmationDialog(info.label, isPresented: $showActions, titleVisibility: .visible) {
            Button("启动") { SDRAppContainer.shared.launch(info) }
            Button("停止") { SDRAppContainer.shared.stop() }
            Button("卸载", role: .destructive) { SDRAppContainer.shared.uninstall(info) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(info.packageName) · \(info.abis.joined(separator: ", "))")
        }
    }
}
