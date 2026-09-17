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

            SDRAboutView()
                .tabItem { Label("关于", systemImage: "info.circle") }
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
