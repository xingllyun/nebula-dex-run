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

/// 宿主侧 Metal 设备与资源基座。
///
/// 职责边界（阶段四 §4.1）：Skia / Metal 属宿主侧渲染库，直接链接，不参与 guest ELF 加载；
/// 本类只负责设备、命令队列与着色器库的幂等初始化，不做任何绘制决策。
public final class SDRRenderDevice {

    public static let shared = SDRRenderDevice()

    /// 在途帧上限：3 帧（对应 CAMetalLayer.maximumDrawableCount）
    public static let maxFramesInFlight = 3

    private let lock = NSLock()
    private var _device: MTLDevice?
    private var _commandQueue: MTLCommandQueue?
    private var _library: MTLLibrary?
    private var _isPrepared = false

    public private(set) var pixelFormat: SDRPixelFormat = .bgra8Unorm
    /// 是否支持 memoryless 渲染目标（iOS GPU Family Apple3 起，覆盖部署目标全部机型）
    public private(set) var supportsMemorylessStorage = true
    public private(set) var deviceLabel = "未初始化"
    public private(set) var shaderCompileMillis: Double = 0

    private init() {}

    public var device: MTLDevice? { lock.lock(); defer { lock.unlock() }; return _device }
    public var commandQueue: MTLCommandQueue? { lock.lock(); defer { lock.unlock() }; return _commandQueue }
    public var library: MTLLibrary? { lock.lock(); defer { lock.unlock() }; return _library }
    public var isPrepared: Bool { lock.lock(); defer { lock.unlock() }; return _isPrepared }

    /// GPU 建议工作集上限（纹理池预算参考）
    public var recommendedWorkingSetBytes: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _device?.recommendedMaxWorkingSetSize ?? 0
    }

    /// 幂等初始化：设备 → 命令队列 → 着色器库。
    /// 着色器采用运行期编译（见 SDRShaderSource 说明），编译耗时计入 shaderCompileMillis。
    @discardableResult
    public func prepare() throws -> MTLDevice {
        lock.lock()
        if _isPrepared, let existing = _device {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let createdDevice = MTLCreateSystemDefaultDevice() else {
            SDRLogger.e("render", "Metal 设备不可用，渲染层降级")
            throw SDRRenderError.metalDeviceUnavailable
        }
        guard let queue = createdDevice.makeCommandQueue() else {
            throw SDRRenderError.commandQueueUnavailable
        }
        queue.label = "com.xingyun.NebulaDex.render.queue"

        let compileOptions = MTLCompileOptions()
        compileOptions.fastMathEnabled = true

        let started = DispatchTime.now().uptimeNanoseconds
        let shaderLibrary: MTLLibrary
        do {
            shaderLibrary = try createdDevice.makeLibrary(source: SDRShaderSource.source, options: compileOptions)
        } catch {
            SDRLogger.e("render", "着色器编译失败：\(error)")
            throw SDRRenderError.shaderCompileFailed(String(describing: error))
        }
        let compileMillis = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0

        lock.lock()
        _device = createdDevice
        _commandQueue = queue
        _library = shaderLibrary
        _isPrepared = true
        supportsMemorylessStorage = createdDevice.supportsFamily(.apple3)
        deviceLabel = createdDevice.name
        shaderCompileMillis = compileMillis
        lock.unlock()

        SDRLogger.i("render", "Metal 就绪：\(deviceLabel)，着色器编译 \(String(format: "%.1f", compileMillis))ms")
        return createdDevice
    }

    /// 取着色器函数（缺失即视为渲染层不可用，属致命配置错误）
    public func makeFunction(_ name: String) throws -> MTLFunction {
        try prepare()
        lock.lock()
        let shaderLibrary = _library
        lock.unlock()
        guard let function = shaderLibrary?.makeFunction(name: name) else {
            throw SDRRenderError.functionMissing(name)
        }
        return function
    }

    /// 抽象像素格式 → Metal 像素格式
    public func metalPixelFormat(_ format: SDRPixelFormat) -> MTLPixelFormat {
        switch format {
        case .bgra8Unorm: return .bgra8Unorm
        case .bgra8UnormSRGB: return .bgra8Unorm_srgb
        case .rgba8Unorm: return .rgba8Unorm
        case .r8Unorm: return .r8Unorm
        case .rgba16Float: return .rgba16Float
        }
    }
}
