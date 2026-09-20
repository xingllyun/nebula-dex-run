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
import Metal

/// guest Java 层 → 宿主 Metal 渲染层的桥接面。
///
/// 定位（阶段四 §4.1）：Android View / Canvas 调用在 guest 侧被截获，
/// 经本桥转为值语义绘制命令；宿主侧不做 Android 语义解释，只负责光栅化与上屏。
/// 所有入参均为标量，避免跨层传对象；纹理以 UInt32 句柄传递。
public final class SDRRenderBridge {

    public static let shared = SDRRenderBridge()

    /// 裁剪栈深度上限：超出时丢弃最内层压栈，防御 guest 侧异常递归
    public static let maxClipDepth = 16
    /// 单帧绘制命令上限：防止 guest 侧死循环刷爆编码队列
    public static let maxCommandsPerFrame = 20000

    public let loop: SDRRenderLoop
    private let lock = NSLock()
    private var clipStack: [CGRect] = []
    private var commandsThisFrame = 0

    /// 供 guest 侧 host-call 表注册的符号名清单
    public static let hostSymbols: [String] = [
        "render.drawRect", "render.drawRoundRect", "render.drawBitmap",
        "render.drawText", "render.drawGradient", "render.clipPush",
        "render.clipPop", "render.clipReset", "render.invalidate",
        "render.registerBitmap", "render.unregisterBitmap", "render.setRefreshTier",
        "render.statistics", "render.recycle"
    ]

    public init(loop: SDRRenderLoop = .shared) {
        self.loop = loop
    }

    // MARK: - 绘制入口

    /// 矩形填充
    public func drawRect(x: Double, y: Double, width: Double, height: Double, argb: UInt32) {
        enqueue(kind: .fillRect, x: x, y: y, width: width, height: height,
                color: SDRColor(argb: argb), endColor: .clear, cornerRadius: 0, textureID: 0)
    }

    /// 圆角矩形填充
    public func drawRoundRect(x: Double, y: Double, width: Double, height: Double,
                              cornerRadius: Double, argb: UInt32) {
        enqueue(kind: .roundedRect, x: x, y: y, width: width, height: height,
                color: SDRColor(argb: argb), endColor: .clear,
                cornerRadius: cornerRadius, textureID: 0)
    }

    /// 位图绘制（textureID 由 registerBitmap 返回）
    public func drawBitmap(textureID: UInt32, x: Double, y: Double, width: Double, height: Double,
                           alpha: Double = 1.0) {
        let color = SDRColor(r: 1, g: 1, b: 1, a: Float(max(min(alpha, 1.0), 0.0)))
        enqueue(kind: .bitmap, x: x, y: y, width: width, height: height,
                color: color, endColor: .clear, cornerRadius: 0, textureID: textureID)
    }

    /// 文本绘制：字形由 guest 侧渲染进图集（textureID），宿主只做采样合成
    public func drawText(textureID: UInt32, x: Double, y: Double, width: Double, height: Double, argb: UInt32) {
        enqueue(kind: .text, x: x, y: y, width: width, height: height,
                color: SDRColor(argb: argb), endColor: .clear, cornerRadius: 0, textureID: textureID)
    }

    /// 线性渐变填充（vertical = true 时自上而下）
    public func drawGradient(x: Double, y: Double, width: Double, height: Double,
                             startARGB: UInt32, endARGB: UInt32, vertical: Bool) {
        let start = SDRColor(argb: vertical ? startARGB : endARGB)
        let end = SDRColor(argb: vertical ? endARGB : startARGB)
        enqueue(kind: .gradient, x: x, y: y, width: width, height: height,
                color: start, endColor: end, cornerRadius: 0, textureID: 0)
    }

    // MARK: - 裁剪栈

    /// 压入裁剪矩形（与已有裁剪求交后入栈）
    @discardableResult
    public func clipPush(_ rect: CGRect) -> CGRect {
        lock.lock()
        defer { lock.unlock() }
        let effective: CGRect
        if let current = clipStack.last {
            effective = current.intersection(rect)
        } else {
            effective = rect
        }
        if clipStack.count < SDRRenderBridge.maxClipDepth {
            clipStack.append(effective)
        }
        return effective
    }

    /// 弹出裁剪矩形
    public func clipPop() {
        lock.lock()
        if !clipStack.isEmpty { clipStack.removeLast() }
        lock.unlock()
    }

    /// 清空裁剪栈（guest 侧 Activity 销毁时调用）
    public func clipReset() {
        lock.lock()
        clipStack.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public var currentClip: CGRect? {
        lock.lock(); defer { lock.unlock() }
        return clipStack.last
    }

    // MARK: - 失效与纹理

    /// 局部失效重绘（§4.3 脏区渲染入口）
    public func invalidate(x: Double, y: Double, width: Double, height: Double) {
        loop.recorder.markDirty(CGRect(x: x, y: y, width: width, height: height))
    }

    /// 整屏失效重绘
    public func invalidateAll() {
        loop.requestFullRedraw()
    }

    /// 注册 guest 上传的位图 / 字形图集（RGBA8 或 R8，按通道数推断）
    @discardableResult
    public func registerBitmap(id: UInt32, width: Int, height: Int,
                               bytes: UnsafeRawPointer, byteCount: Int, channels: Int) -> Bool {
        guard width > 0, height > 0, byteCount >= width * height * max(channels, 1) else {
            SDRLogger.w("render", "位图注册参数非法：\(width)x\(height) ch\(channels)")
            return false
        }
        guard let device = loop.device else { return false }

        let format: SDRPixelFormat = channels >= 4 ? .rgba8Unorm : .r8Unorm
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format.metalValue,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        // iOS 无 .managed（仅 macOS）：位图上传需 CPU 可见，走 .shared
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return false }

        texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                          size: MTLSize(width: width, height: height, depth: 1)),
                        mipmapLevel: 0,
                        withBytes: bytes,
                        bytesPerRow: width * max(channels, 1))
        loop.textureRegistry.register(id: id, texture: texture)
        return true
    }

    public func unregisterBitmap(id: UInt32) {
        loop.textureRegistry.unregister(id: id)
    }

    // MARK: - 档位与统计

    /// 设置刷新档位，返回实际生效档位（30 / 60 / 120）
    @discardableResult
    public func setRefreshTier(_ tier: Int) -> Int {
        let requested = SDRRefreshTier.fromStoredValue(tier)
        return loop.setTier(requested).rawValue
    }

    /// 统计快照 JSON（供 guest 侧调试面板与 CI 验收读取）
    public func statisticsJSON() -> String {
        let stats = loop.statistics
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stats),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public func statistics() -> SDRRenderStats {
        loop.statistics
    }

    /// 帧边界回调：guest 侧每完成一帧提交后调用，重置帧内配额
    public func beginFrame() {
        lock.lock()
        commandsThisFrame = 0
        lock.unlock()
    }

    /// 内存告警透传
    public func handleMemoryPressure() {
        loop.handleMemoryPressure()
    }

    // MARK: - 内部

    private func enqueue(kind: SDRDrawKind, x: Double, y: Double, width: Double, height: Double,
                         color: SDRColor, endColor: SDRColor, cornerRadius: Double, textureID: UInt32) {
        guard width > 0, height > 0 else { return }

        lock.lock()
        if commandsThisFrame >= SDRRenderBridge.maxCommandsPerFrame {
            lock.unlock()
            SDRLogger.w("render", "单帧绘制命令超过上限 \(SDRRenderBridge.maxCommandsPerFrame)，已丢弃")
            return
        }
        commandsThisFrame += 1
        let clip = clipStack.last
        lock.unlock()

        let command = SDRDrawCommand(kind: kind,
                                     frame: CGRect(x: x, y: y, width: width, height: height),
                                     color: color,
                                     endColor: endColor,
                                     cornerRadius: CGFloat(max(cornerRadius, 0)),
                                     textureID: textureID,
                                     clipRect: clip)
        loop.recorder.enqueue(command)
    }
}
