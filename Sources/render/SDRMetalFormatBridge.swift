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

import Metal

/// 渲染层像素格式与 Metal 原生格式的统一桥接点。
public extension SDRPixelFormat {
    /// 映射到 Metal 原生像素格式
    var metalValue: MTLPixelFormat {
        switch self {
        case .bgra8Unorm: return .bgra8Unorm
        case .bgra8UnormSRGB: return .bgra8Unorm_srgb
        case .rgba8Unorm: return .rgba8Unorm
        case .r8Unorm: return .r8Unorm
        case .rgba16Float: return .rgba16Float
        }
    }
}

/// 渲染管线颜色附件配置：把抽象混合模式落到 Metal 混合因子。
public enum SDRBlendConfigurator {
    /// 将混合模式写入管线颜色附件描述符
    public static func apply(_ mode: SDRBlendMode, to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        switch mode {
        case .none:
            attachment.isBlendingEnabled = false
        case .sourceOver:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
    }
}
