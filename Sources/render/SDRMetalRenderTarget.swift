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

import Foundation
import QuartzCore
import Metal

/// CAMetalLayer 渲染目标封装（阶段四 §4.1）。
///
/// 上屏链路：guest Canvas 绘制 → 离屏 MSAA 目标 → resolve → drawable.texture → CAMetalLayer 扫描输出。
/// 关键取舍：
///   1. MSAA 4x，减少文本与圆角边缘锯齿，符合 iOS 原生观感；
///   2. MSAA 附件使用 memoryless 存储，绝不落 DRAM，显著降低带宽与显存占用；
///   3. framebufferOnly = true，禁止对 drawable 纹理做采样/读写回灌，走最优上屏路径。
public final class SDRMetalRenderTarget {

    public private(set) var layer: CAMetalLayer
    public let pixelFormat: SDRPixelFormat
    public let sampleCount: Int

    private let device: MTLDevice
    private let supportsMemoryless: Bool
    private var msaaTexture: MTLTexture?

    /// MSAA 附件重建次数（尺寸变化触发），用于定位旋转 / 分屏导致的抖动
    public private(set) var multisampleReallocations = 0
    public private(set) var drawableAcquireFailures = 0

    public init(device: MTLDevice, layer: CAMetalLayer,
                pixelFormat: SDRPixelFormat = .bgra8Unorm,
                sampleCount: Int = 4,
                supportsMemoryless: Bool = true) {
        self.device = device
        self.layer = layer
        self.pixelFormat = pixelFormat
        self.sampleCount = max(sampleCount, 1)
        self.supportsMemoryless = supportsMemoryless

        layer.device = device
        layer.pixelFormat = pixelFormat.metalValue
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = SDRRenderDevice.maxFramesInFlight
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
    }

    public var drawableSize: CGSize { layer.drawableSize }

    /// 更新上屏尺寸（点 → 像素由 contentsScale 决定）
    public func updateDrawableSize(_ size: CGSize, contentsScale: CGFloat) {
        let scale = contentsScale > 0 ? contentsScale : 1
        let pixelSize = CGSize(width: max(size.width * scale, 1), height: max(size.height * scale, 1))
        guard pixelSize != layer.drawableSize else { return }
        layer.drawableSize = pixelSize
        layer.contentsScale = scale
        // 尺寸变化后 MSAA 附件失效，交由下一次 makePass 惰性重建
        msaaTexture = nil
    }

    /// 组装一帧的 render pass：清屏 + 可选 MSAA resolve 到 drawable
    public func makePass(clearColor: SDRColor) throws -> (descriptor: MTLRenderPassDescriptor, drawable: CAMetalDrawable) {
        guard let drawable = layer.nextDrawable() else {
            drawableAcquireFailures += 1
            throw SDRRenderError.drawableUnavailable
        }

        let descriptor = MTLRenderPassDescriptor()
        let attachment = descriptor.colorAttachments[0]
        attachment.clearColor = MTLClearColor(red: Double(clearColor.r),
                                              green: Double(clearColor.g),
                                              blue: Double(clearColor.b),
                                              alpha: Double(clearColor.a))
        attachment.loadAction = .clear

        if sampleCount > 1 {
            let multisample = try ensureMultisampleTexture(width: drawable.texture.width,
                                                           height: drawable.texture.height)
            attachment.texture = multisample
            attachment.resolveTexture = drawable.texture
            attachment.storeAction = .multisampleResolve
        } else {
            attachment.texture = drawable.texture
            attachment.storeAction = .store
        }

        descriptor.renderTargetWidth = drawable.texture.width
        descriptor.renderTargetHeight = drawable.texture.height
        // MTLRenderPassDescriptor 无 label：pass 标识由渲染编码器标签承担（见 SDRRenderLoop）
        return (descriptor, drawable)
    }

    /// 释放渲染目标持有的附件
    public func teardown() {
        msaaTexture = nil
    }

    // MARK: - 内部

    /// 惰性创建 / 复用 MSAA 附件；支持 memoryless 时绝不驻留 DRAM
    private func ensureMultisampleTexture(width: Int, height: Int) throws -> MTLTexture {
        if let existing = msaaTexture, existing.width == width, existing.height == height {
            return existing
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DMultisample
        descriptor.pixelFormat = pixelFormat.metalValue
        descriptor.width = max(width, 1)
        descriptor.height = max(height, 1)
        descriptor.depth = 1
        descriptor.mipmapLevelCount = 1
        descriptor.arrayLength = 1
        descriptor.sampleCount = sampleCount
        descriptor.usage = .renderTarget
        descriptor.storageMode = supportsMemoryless ? .memoryless : .private

        guard let created = device.makeTexture(descriptor: descriptor) else {
            throw SDRRenderError.textureAllocationFailed("MSAA \(width)x\(height) x\(sampleCount)")
        }
        created.label = "render.msaa.\(width)x\(height)"
        msaaTexture = created
        multisampleReallocations += 1
        return created
    }
}
