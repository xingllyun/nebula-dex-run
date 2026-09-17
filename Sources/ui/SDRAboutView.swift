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

/// 关于页：设备能力、侧载权限探测结论、内存预算与版权声明
public struct SDRAboutView: View {
    @State private var report: SDRDeviceCapabilityReport
    @State private var plan: SDRMemoryBudget.Plan
    @State private var pressureLevel: String = SDRMemoryPressureMonitor.shared.level.rawValue

    public init() {
        let probed = SDRSystemProbe.report(performAddressProbe: false)
        _report = State(initialValue: probed)
        _plan = State(initialValue: SDRMemoryBudget.makePlan(report: probed))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("应用") {
                    LabeledContent("名称", value: SDRLicense.projectName)
                    LabeledContent("包标识", value: SDRConst.bundleID)
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("适配范围", value: "iOS \(SDRConst.minOS) ~ \(SDRConst.maxVerifiedOS)")
                }

                Section("设备（iOS 26 机型适配）") {
                    LabeledContent("机型标识", value: report.machineIdentifier)
                    LabeledContent("系统版本", value: report.systemVersion)
                    LabeledContent("物理内存", value: report.physicalMemoryDescription)
                    LabeledContent("可用内存", value: report.availableMemoryDescription)
                    LabeledContent("内存档位", value: SDRVersionAdapter.deviceMemoryTierLabel)
                    LabeledContent("外观", value: SDRVersionAdapter.usesLiquidGlassDesign ? "Liquid Glass（iOS 26 新外观）" : "兼容外观")
                }

                Section("侧载证书权限（两项）") {
                    LabeledContent("大内存", value: report.increasedMemoryLimit.displayName)
                    LabeledContent("大地址空间", value: report.extendedVirtualAddressing.displayName)
                    LabeledContent("最大连续映射", value: report.maxContiguousMapDescription)
                    Text("大内存 = com.apple.developer.kernel.increased-memory-limit（iOS 15.0+）；大地址空间 = com.apple.developer.kernel.extended-virtual-addressing（iOS 14.0+）。两项均由重签工具写入签名，未生效时运行时自动降档，不会因超限被系统终止。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("内存预算") {
                    LabeledContent("档位", value: plan.tier.displayName)
                    LabeledContent("常驻上限", value: bytesDescription(plan.residentLimitBytes))
                    LabeledContent("地址空间上限", value: bytesDescription(plan.addressSpaceLimitBytes))
                    LabeledContent("DEX 缓存上限", value: bytesDescription(plan.dexCacheLimitBytes))
                    LabeledContent("SO 段上限", value: bytesDescription(plan.soSegmentLimitBytes))
                    LabeledContent("寄存器栈深度", value: "\(plan.registerStackDepth)")
                    LabeledContent("内存压力", value: pressureLevel)
                    Button("重新探测") {
                        refresh()
                    }
                }

                Section("版权") {
                    Text(SDRLicense.briefDeclaration)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NavigationLink("查看完整 MIT 许可证") {
                        SDRLicenseTextView()
                    }
                }
            }
            .navigationTitle("关于")
            .onAppear {
                SDRMemoryPressureMonitor.shared.start()
                pressureLevel = SDRMemoryPressureMonitor.shared.level.rawValue
            }
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func bytesDescription(_ bytes: UInt64) -> String {
        if bytes >= 1073741824 {
            return String(format: "%.2f GB", Double(bytes) / 1073741824.0)
        }
        return String(format: "%.0f MB", Double(bytes) / 1048576.0)
    }

    private func refresh() {
        let probed = SDRSystemProbe.report(performAddressProbe: true)
        report = probed
        plan = SDRMemoryBudget.refresh()
        pressureLevel = SDRMemoryPressureMonitor.shared.level.rawValue
    }
}

/// 完整 MIT 许可证文本页
public struct SDRLicenseTextView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            Text(SDRLicense.mitText)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("MIT License")
        .navigationBarTitleDisplayMode(.inline)
    }
}
