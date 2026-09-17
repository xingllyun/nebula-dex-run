import SwiftUI

public struct SDRRootView: View {
    @EnvironmentObject private var state: SDRAppState

    public init() {}

    public var body: some View {
        TabView {
            SDRAppGridView()
                .tabItem { Label("应用", systemImage: "square.stack.3d.up") }

            SDRLogConsoleView()
                .tabItem { Label("日志", systemImage: "terminal") }

            SDRSettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(SDRTheme.accent)
    }
}

public struct SDRSettingsView: View {
    @EnvironmentObject private var state: SDRAppState

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("运行时") {
                    Picker("刷新率", selection: $state.refreshRate) {
                        ForEach(SDRVersionAdapter.availableRefreshRates(), id: \.self) { rate in
                            Text("\(rate) Hz").tag(rate)
                        }
                    }
                    Toggle("低电量降级", isOn: $state.lowPowerDowngrade)
                }

                Section("环境") {
                    LabeledContent("系统版本", value: SDRVersionAdapter.systemVersion)
                    LabeledContent("已验证上限", value: SDRConst.maxVerifiedOS)
                    LabeledContent("包标识", value: SDRConst.bundleID)
                }

                Section("架构说明") {
                    Text("非越狱环境下 SO 无法申请可执行内存，全部按 ARM 指令级解释执行，不依赖 JIT。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}
