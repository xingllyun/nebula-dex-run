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

/// 一批同管线、同纹理的绘制（相邻命令合并，减少状态切换与 draw call）
public struct SDRDrawBatch {
    public let kind: SDRDrawKind
    public let textureID: UInt32
    public let blend: SDRBlendMode
    public let clipRect: CGRect?
    public var vertices: [SDRVertex]
    /// 合并进本批的命令条数
    public var commandCount: Int

    public init(kind: SDRDrawKind, textureID: UInt32, blend: SDRBlendMode, clipRect: CGRect?) {
        self.kind = kind
        self.textureID = textureID
        self.blend = blend
        self.clipRect = clipRect
        self.vertices = []
        self.commandCount = 0
    }

    public var quadCount: Int { vertices.count / SDRVertexBuilder.verticesPerQuad }
}

/// 绘制命令录制器：guest 线程写入，渲染线程按帧消费。
public final class SDRCommandRecorder {

    private let lock = NSLock()
    private var pending: [SDRDrawCommand] = []
    private var dirty = SDRDirtyRectSet()

    public init() {}

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    public var dirtyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return dirty.rects.count
    }

    /// 记录一条绘制命令，同时把其矩形计入脏区
    public func enqueue(_ command: SDRDrawCommand) {
        lock.lock()
        pending.append(command)
        dirty.add(command.frame)
        lock.unlock()
    }

    public func enqueue(contentsOf commands: [SDRDrawCommand]) {
        guard !commands.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: commands)
        for command in commands {
            dirty.add(command.frame)
        }
        lock.unlock()
    }

    /// 标记脏区（不含绘制命令，用于 guest 主动请求局部重绘）
    public func markDirty(_ rect: CGRect) {
        lock.lock()
        dirty.add(rect)
        lock.unlock()
    }

    /// 整屏重绘（首帧、旋转、切档）
    public func markFullRedraw(_ bounds: CGRect) {
        lock.lock()
        dirty.addFullRedraw(bounds)
        lock.unlock()
    }

    /// 取出本帧脏区（已裁剪到渲染目标内）
    public func dirtyRects(clippedTo bounds: CGRect) -> [CGRect] {
        lock.lock(); defer { lock.unlock() }
        return dirty.clippedRects(to: bounds)
    }

    /// 消费本帧命令
    public func drain() -> [SDRDrawCommand] {
        lock.lock()
        let commands = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        return commands
    }

    public func resetDirty() {
        lock.lock()
        dirty.reset()
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        dirty.reset()
        lock.unlock()
    }
}

/// 绘制命令 → GPU 顶点。纯函数，可在离线环境独立校验。
public enum SDRVertexBuilder {

    /// 每个四边形 6 个顶点（两个三角形）
    public static let verticesPerQuad = 6

    /// 命令序列 → 批次序列（相邻同 kind / 同纹理 / 同裁剪者合并）
    public static func batches(from commands: [SDRDrawCommand]) -> [SDRDrawBatch] {
        var result: [SDRDrawBatch] = []
        for command in commands {
            let blend = blendMode(for: command.kind)
            if var last = result.last,
               last.kind == command.kind,
               last.textureID == command.textureID,
               last.clipRect == command.clipRect,
               last.blend == blend,
               last.quadCount < maxQuadsPerBatch {
                last.vertices.append(contentsOf: quadVertices(for: command))
                last.commandCount += 1
                result[result.count - 1] = last
            } else {
                var batch = SDRDrawBatch(kind: command.kind,
                                         textureID: command.textureID,
                                         blend: blend,
                                         clipRect: command.clipRect)
                batch.vertices = quadVertices(for: command)
                batch.commandCount = 1
                result.append(batch)
            }
        }
        return result
    }

    /// 单批四边形上限：受顶点缓冲分片大小约束（每顶点 64 字节）
    public static let maxQuadsPerBatch = 4096

    /// 混合模式：当前 Canvas 最小集统一走 SrcOver
    public static func blendMode(for kind: SDRDrawKind) -> SDRBlendMode {
        switch kind {
        case .fillRect, .roundedRect, .text, .bitmap, .gradient:
            return .sourceOver
        }
    }

    /// 单个四边形 → 6 顶点（三角形列表）
    public static func quadVertices(for command: SDRDrawCommand) -> [SDRVertex] {
        let rect = command.frame
        let x0 = Float(rect.minX)
        let y0 = Float(rect.minY)
        let x1 = Float(rect.maxX)
        let y1 = Float(rect.maxY)
        let w = Float(max(rect.width, 0))
        let h = Float(max(rect.height, 0))

        let shapeKind: Float = (command.kind == .roundedRect && command.cornerRadius > 0) ? 1 : 0
        let shape = SIMD2<Float>(Float(command.cornerRadius), shapeKind)
        let size = SIMD2<Float>(w, h)

        let topColor = SIMD4<Float>(command.color.r, command.color.g, command.color.b, command.color.a)
        let bottomColor: SIMD4<Float>
        if command.kind == .gradient {
            bottomColor = SIMD4<Float>(command.endColor.r, command.endColor.g, command.endColor.b, command.endColor.a)
        } else {
            bottomColor = topColor
        }

        // 上左 / 上右 / 下左 / 下右
        let topLeft = SDRVertex(position: SIMD2<Float>(x0, y0), texCoord: SIMD2<Float>(0, 0),
                                color: topColor, localPos: SIMD2<Float>(0, 0),
                                localSize: size, shape: shape)
        let topRight = SDRVertex(position: SIMD2<Float>(x1, y0), texCoord: SIMD2<Float>(1, 0),
                                 color: topColor, localPos: SIMD2<Float>(w, 0),
                                 localSize: size, shape: shape)
        let bottomLeft = SDRVertex(position: SIMD2<Float>(x0, y1), texCoord: SIMD2<Float>(0, 1),
                                   color: bottomColor, localPos: SIMD2<Float>(0, h),
                                   localSize: size, shape: shape)
        let bottomRight = SDRVertex(position: SIMD2<Float>(x1, y1), texCoord: SIMD2<Float>(1, 1),
                                    color: bottomColor, localPos: SIMD2<Float>(w, h),
                                    localSize: size, shape: shape)

        return [topLeft, topRight, bottomLeft, topRight, bottomRight, bottomLeft]
    }

    /// 批次顶点总字节数（用于顶点缓冲容量规划）
    public static func vertexBytes(for batch: SDRDrawBatch) -> Int {
        batch.vertices.count * MemoryLayout<SDRVertex>.stride
    }
}
