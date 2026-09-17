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
