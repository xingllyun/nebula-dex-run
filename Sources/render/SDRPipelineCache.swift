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
import Dispatch
import Metal

/// 渲染管线状态（PSO）缓存键
public struct SDRPipelineKey: Hashable {
    public let kind: SDRDrawKind
    public let format: SDRPixelFormat
    public let sampleCount: Int
    public let blend: SDRBlendMode

    public init(kind: SDRDrawKind, format: SDRPixelFormat, sampleCount: Int, blend: SDRBlendMode) {
        self.kind = kind
        self.format = format
        self.sampleCount = sampleCount
        self.blend = blend
    }

    public var debugName: String {
        "pso.\(kind).\(format.rawValue).msaa\(sampleCount).\(blend.rawValue)"
    }
}

/// 渲染管线缓存 + 启动期 PSO 预热（阶段四 §4.2）。
///
/// 预热目标：把首帧可能触发的 PSO 编译（20–100ms 量级）全部前移到启动期，
/// 交互期只做字典命中查找，命中率验收目标 100%。
public final class SDRPipelineCache {

    private let device: MTLDevice
    private let library: MTLLibrary
    private let lock = NSLock()
    private var storage: [SDRPipelineKey: MTLRenderPipelineState] = [:]

    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    public var cachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    public var cachedKeys: [SDRPipelineKey] {
        lock.lock(); defer { lock.unlock() }
        return Array(storage.keys)
    }

    /// 取管线：命中直接返回，未命中则构建并回填缓存
    public func pipelineState(for key: SDRPipelineKey) throws -> MTLRenderPipelineState {
        lock.lock()
        if let cached = storage[key] {
            hits += 1
            lock.unlock()
            return cached
        }
        lock.unlock()

        let built = try buildPipeline(for: key)

        lock.lock()
        storage[key] = built
        misses += 1
        lock.unlock()
        return built
    }

    /// 便捷取用：按绘制种类取管线
    public func pipelineState(kind: SDRDrawKind, format: SDRPixelFormat,
                              sampleCount: Int, blend: SDRBlendMode) throws -> MTLRenderPipelineState {
        try pipelineState(for: SDRPipelineKey(kind: kind, format: format,
                                              sampleCount: sampleCount, blend: blend))
    }

    /// 启动期预热：遍历「绘制种类 × 混合模式」全组合，把 PSO 编译成本一次性吃掉。
    /// - Returns: 预热管线数量与耗时（毫秒）
    @discardableResult
    public func warmup(format: SDRPixelFormat, sampleCount: Int,
                       blends: [SDRBlendMode] = SDRBlendMode.allCases) -> (pipelineCount: Int, millis: Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        var built = 0
        var failures: [String] = []

        for kind in SDRDrawKind.allCases {
            for blend in blends {
                let key = SDRPipelineKey(kind: kind, format: format, sampleCount: sampleCount, blend: blend)
                do {
                    _ = try pipelineState(for: key)
                    built += 1
                } catch {
                    failures.append(key.debugName)
                }
            }
        }

        let millis = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
        if failures.isEmpty {
            SDRLogger.i("render", "PSO 预热完成：\(built) 条管线，\(String(format: "%.1f", millis))ms")
        } else {
            SDRLogger.w("render", "PSO 预热存在失败项：\(failures.joined(separator: ","))")
        }
        return (built, millis)
    }

    public func reset() {
        lock.lock()
        storage.removeAll()
        hits = 0
        misses = 0
        lock.unlock()
    }

    // MARK: - 构建

    /// 绘制种类 → 片元函数名
    static func fragmentFunctionName(for kind: SDRDrawKind) -> String {
        switch kind {
        case .fillRect, .roundedRect: return SDRShaderSource.solidFragmentName
        case .gradient: return SDRShaderSource.gradientFragmentName
        case .bitmap: return SDRShaderSource.textureFragmentName
        case .text: return SDRShaderSource.glyphFragmentName
        }
    }

    private func buildPipeline(for key: SDRPipelineKey) throws -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: SDRShaderSource.vertexFunctionName) else {
            throw SDRRenderError.functionMissing(SDRShaderSource.vertexFunctionName)
        }
        let fragmentName = SDRPipelineCache.fragmentFunctionName(for: key.kind)
        guard let fragmentFunction = library.makeFunction(name: fragmentName) else {
            throw SDRRenderError.functionMissing(fragmentName)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = max(key.sampleCount, 1)

        guard let attachment = descriptor.colorAttachments[0] else {
            throw SDRRenderError.pipelineBuildFailed("\(key.debugName)：颜色附件不可用")
        }
        attachment.pixelFormat = key.format.metalValue
        SDRBlendConfigurator.apply(key.blend, to: attachment)

        do {
            // MTLRenderPipelineDescriptor 无 label，MTLRenderPipelineState.label 只读：
            // 管线标识统一走 key.debugName（日志侧），不在状态对象上设标签
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw SDRRenderError.pipelineBuildFailed("\(key.debugName)：\(error)")
        }
    }
}
