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
import QuartzCore

/// 纹理句柄注册表：guest 侧只持有 UInt32 句柄，避免跨层传递 Objective-C 对象。
public final class SDRTextureRegistry {

    private let lock = NSLock()
    private var storage: [UInt32: MTLTexture] = [:]

    public init() {}

    public func register(id: UInt32, texture: MTLTexture) {
        lock.lock()
        storage[id] = texture
        lock.unlock()
    }

    public func texture(for id: UInt32) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    public func unregister(id: UInt32) {
        lock.lock()
        storage.removeValue(forKey: id)
        lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    public func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

/// 渲染主循环：VSync 驱动 → 命令消费 → 批次编码 → 提交上屏（阶段四 §4.1 / §4.3）。
///
/// 线程模型：
///   - CADisplayLink 在主 RunLoop 触发 tick，回调立即把编码工作甩到串行渲染队列；
///   - 渲染队列按 3 帧在途信号量节流，避免 CPU 超发导致 1–2 帧延迟；
///   - 命令录制器由 guest 线程写入，锁粒度只在入队/出队，不做长持有。
public final class SDRRenderLoop {

    public static let shared = SDRRenderLoop(deviceProvider: .shared)

    /// 动态顶点缓冲槽数（与在途帧数一致）
    private static let vertexSlotCount = SDRRenderDevice.maxFramesInFlight
    /// 单槽动态顶点缓冲容量（字节）
    private static let vertexSlotBytes = 1 << 21

    private let deviceProvider: SDRRenderDevice
    public let recorder = SDRCommandRecorder()
    public let textureRegistry = SDRTextureRegistry()

    private let renderQueue = DispatchQueue(label: "com.xingyun.NebulaDex.render.loop", qos: .userInteractive)
    private let inFlight = DispatchSemaphore(value: SDRRenderDevice.maxFramesInFlight)
    private let stateLock = NSLock()

    private var target: SDRMetalRenderTarget?
    private var pipelineCache: SDRPipelineCache?
    private var texturePool: SDRTexturePool?
    private var scheduler: SDRFrameScheduler?
    private var sampler: MTLSamplerState?
    private var vertexSlots: [MTLBuffer] = []
    private var vertexSlotIndex = 0

    private var encodedCommands = 0
    private var warmupMillis: Double = 0
    private var warmupPipelines = 0
    private var needsFullRedraw = true
    private var firstScreenRecorded = false
    private var running = false

    /// 背景清屏色（宿主侧底色，位于 guest 内容之下）
    public var clearColor: SDRColor = SDRColor(r: 0.05, g: 0.06, b: 0.08, a: 1)
    /// 是否启用脏区局部渲染（§4.3）；关闭则每帧整屏重绘
    public var dirtyRectRenderingEnabled = true
    /// MSAA 采样数（1 表示关闭抗锯齿）
    public var sampleCount = 4

    private init(deviceProvider: SDRRenderDevice) {
        self.deviceProvider = deviceProvider
    }

    /// 独立实例工厂（供渲染层自检注入替身设备层）
    public static func make(deviceProvider: SDRRenderDevice) -> SDRRenderLoop {
        SDRRenderLoop(deviceProvider: deviceProvider)
    }

    /// 供上传通路使用的 Metal 设备（guest 位图 / 字形图集）
    public var device: MTLDevice? { deviceProvider.device }

    /// 当前上屏像素格式
    public var pixelFormat: SDRPixelFormat { deviceProvider.pixelFormat }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    public var statistics: SDRRenderStats {
        scheduler?.statisticsSnapshot() ?? SDRRenderStats()
    }

    public var refreshTier: SDRRefreshTier? { scheduler?.tier }

    // MARK: - 装配

    /// 绑定上屏 layer 并完成渲染资源装配（设备、着色器、PSO 预热、纹理池）
    public func attach(layer: CAMetalLayer,
                       requestedTier: SDRRefreshTier,
                       deviceMaximumFrameRate: Int,
                       drawableSize: CGSize = .zero,
                       contentsScale: CGFloat = 1) throws {
        let device = try deviceProvider.prepare()
        guard let library = deviceProvider.library else {
            throw SDRRenderError.shaderCompileFailed("着色器库未初始化")
        }

        let cache = SDRPipelineCache(device: device, library: library)
        let pool = SDRTexturePool(device: device)
        let renderTarget = SDRMetalRenderTarget(device: device,
                                                layer: layer,
                                                pixelFormat: deviceProvider.pixelFormat,
                                                sampleCount: sampleCount,
                                                supportsMemoryless: deviceProvider.supportsMemorylessStorage)
        if drawableSize.width > 0, drawableSize.height > 0 {
            renderTarget.updateDrawableSize(drawableSize, contentsScale: contentsScale)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.label = "render.sampler"
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        let samplerState = device.makeSamplerState(descriptor: samplerDescriptor)

        let driver = SDRDisplayLinkDriver()
        let frameScheduler = SDRFrameScheduler(source: driver,
                                               requestedTier: requestedTier,
                                               deviceMaximumFrameRate: deviceMaximumFrameRate)
        frameScheduler.onFrame = { [weak self] tick in
            guard let self = self else { return }
            let queue = self.renderQueue
            queue.async { self.renderFrame(tick) }
        }
        frameScheduler.onStatisticsChanged = { [weak self] _ in
            self?.syncCounters()
        }

        stateLock.lock()
        self.target = renderTarget
        self.pipelineCache = cache
        self.texturePool = pool
        self.scheduler = frameScheduler
        self.sampler = samplerState
        self.vertexSlots = []
        self.vertexSlotIndex = 0
        self.needsFullRedraw = true
        stateLock.unlock()

        try warmup()
    }

    public func updateDrawableSize(_ size: CGSize, contentsScale: CGFloat) {
        stateLock.lock()
        let renderTarget = target
        stateLock.unlock()
        renderTarget?.updateDrawableSize(size, contentsScale: contentsScale)
        requestFullRedraw()
    }

    public func start() {
        stateLock.lock()
        let frameScheduler = scheduler
        running = frameScheduler != nil
        stateLock.unlock()
        frameScheduler?.start()
    }

    public func stop() {
        stateLock.lock()
        running = false
        let frameScheduler = scheduler
        stateLock.unlock()
        frameScheduler?.stop()
    }

    public func setPaused(_ paused: Bool) {
        stateLock.lock()
        let frameScheduler = scheduler
        stateLock.unlock()
        frameScheduler?.setPaused(paused)
    }

    /// 设置页切档；返回实际生效档位
    @discardableResult
    public func setTier(_ tier: SDRRefreshTier) -> SDRRefreshTier {
        stateLock.lock()
        let frameScheduler = scheduler
        stateLock.unlock()
        requestFullRedraw()
        return frameScheduler?.apply(requestedTier: tier) ?? tier
    }

    public func requestFullRedraw() {
        stateLock.lock()
        needsFullRedraw = true
        stateLock.unlock()
    }

    /// 内存告警：释放纹理池与句柄表
    public func handleMemoryPressure() {
        stateLock.lock()
        let pool = texturePool
        stateLock.unlock()
        pool?.purge()
        textureRegistry.removeAll()
        SDRLogger.w("render", "内存告急：纹理池与句柄表已回收")
    }

    // MARK: - 预热（阶段四 §4.2）

    /// 启动期预热：PSO 全组合构建 + 一次离屏真实绘制，把着色器与驱动侧间接成本前移。
    public func warmup() throws {
        let device = try deviceProvider.prepare()
        guard let cache = pipelineCache, let sampler = sampler else {
            throw SDRRenderError.targetNotConfigured
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let format = deviceProvider.pixelFormat
        let result = cache.warmup(format: format, sampleCount: max(sampleCount, 1))
        let drawn = try performWarmupDraw(device: device, cache: cache, sampler: sampler)
        let millis = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0

        stateLock.lock()
        warmupMillis = millis
        warmupPipelines = result.pipelineCount
        stateLock.unlock()

        SDRLogger.i("render", "渲染层预热完成：管线 \(result.pipelineCount) 条，离屏绘制 \(drawn) 批，总耗时 \(String(format: "%.1f", millis))ms")
    }

    /// 离屏 8x8 目标上把每种绘制种类各画一次，确保 PSO 与着色器在真机上完全就绪
    private func performWarmupDraw(device: MTLDevice, cache: SDRPipelineCache,
                                   sampler: MTLSamplerState) throws -> Int {
        let format = deviceProvider.pixelFormat
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format.metalValue,
                                                                       width: 8, height: 8, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor) else {
            throw SDRRenderError.textureAllocationFailed("预热离屏目标")
        }
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MTLPixelFormat.r8Unorm,
                                                                        width: 4, height: 4, mipmapped: false)
        sourceDescriptor.usage = .shaderRead
        sourceDescriptor.storageMode = .private
        let sourceTexture = device.makeTexture(descriptor: sourceDescriptor)

        let pass = MTLRenderPassDescriptor()
        guard let passAttachment = pass.colorAttachments[0] else {
            throw SDRRenderError.textureAllocationFailed("预热离屏颜色附件不可用")
        }
        passAttachment.texture = colorTexture
        passAttachment.loadAction = .clear
        passAttachment.storeAction = .store
        passAttachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.renderTargetWidth = 8
        pass.renderTargetHeight = 8

        guard let queue = deviceProvider.commandQueue,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass),
              let vertexSlot = makeVertexSlot(device: device) else {
            throw SDRRenderError.commandQueueUnavailable
        }
        encoder.label = "render.warmup"

        var drawn = 0
        var slotOffset = 0
        let warmupRect = CGRect(x: 0, y: 0, width: 8, height: 8)
        for kind in SDRDrawKind.allCases {
            let command = SDRDrawCommand(kind: kind,
                                         frame: warmupRect,
                                         color: SDRColor(r: 1, g: 1, b: 1, a: 1),
                                         endColor: SDRColor(r: 0, g: 0, b: 0, a: 1),
                                         cornerRadius: 2,
                                         textureID: kind == .bitmap || kind == .text ? 1 : 0)
            let vertices = SDRVertexBuilder.quadVertices(for: command)
            let byteCount = vertices.count * MemoryLayout<SDRVertex>.stride
            vertices.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    vertexSlot.contents().advanced(by: slotOffset).copyMemory(from: base, byteCount: raw.count)
                }
            }
            let pipeline = try cache.pipelineState(kind: kind,
                                                   format: format,
                                                   sampleCount: max(sampleCount, 1),
                                                   blend: SDRVertexBuilder.blendMode(for: kind))
            let uniforms = SDRShaderSource.Uniforms(viewportSize: SIMD2<Float>(8, 8))
            encoder.setRenderPipelineState(pipeline)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: 8, height: 8, znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: 8, height: 8))
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(vertexSlot, offset: slotOffset, index: 0)
            withUnsafePointer(to: uniforms) { pointer in
                encoder.setVertexBytes(pointer, length: MemoryLayout<SDRShaderSource.Uniforms>.stride, index: 1)
            }
            if kind == .bitmap || kind == .text {
                encoder.setFragmentTexture(sourceTexture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            drawn += 1
            slotOffset += (byteCount + 255) / 256 * 256
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return drawn
    }

    // MARK: - 帧渲染

    private func renderFrame(_ tick: SDRVSyncTick) {
        stateLock.lock()
        let renderTarget = target
        let cache = pipelineCache
        let frameScheduler = scheduler
        let localSampler = sampler
        let fullRedraw = needsFullRedraw
        stateLock.unlock()

        guard let renderTarget = renderTarget,
              let cache = cache,
              let frameScheduler = frameScheduler else { return }

        let frameStarted = DispatchTime.now().uptimeNanoseconds
        let bounds = CGRect(origin: .zero, size: renderTarget.drawableSize)
        let commands = recorder.drain()
        let dirtyRects = recorder.dirtyRects(clippedTo: bounds)

        if commands.isEmpty, dirtyRects.isEmpty, !fullRedraw {
            // 无脏区：不产生多余帧，直接空转（省电，也符合"避免多余帧渲染"）
            frameScheduler.recordSkipped()
            return
        }
        recorder.resetDirty()

        inFlight.wait()
        var completed = false
        defer {
            if !completed {
                inFlight.signal()
            }
        }

        do {
            let (pass, drawable) = try renderTarget.makePass(clearColor: clearColor)
            guard let queue = deviceProvider.commandQueue,
                  let commandBuffer = queue.makeCommandBuffer() else {
                throw SDRRenderError.commandQueueUnavailable
            }
            commandBuffer.label = "render.frame"

            let batches = SDRVertexBuilder.batches(from: commands)
            let scissor = scissorRect(fullRedraw: fullRedraw, dirtyRects: dirtyRects, bounds: bounds)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw SDRRenderError.commandQueueUnavailable
            }
            encoder.label = "render.encoder"
            encode(batches: batches, encoder: encoder, cache: cache,
                   sampler: localSampler, scissor: scissor,
                   viewportSize: SDRRenderLoop.viewportVector(renderTarget.drawableSize))
            encoder.endEncoding()

            let completion = inFlight
            commandBuffer.addCompletedHandler { _ in completion.signal() }
            completed = true
            commandBuffer.present(drawable)
            commandBuffer.commit()

            let wasFullRedraw = fullRedraw
            if wasFullRedraw {
                stateLock.lock()
                needsFullRedraw = false
                stateLock.unlock()
            }

            let millis = Double(DispatchTime.now().uptimeNanoseconds - frameStarted) / 1_000_000.0
            stateLock.lock()
            encodedCommands += commands.count
            let firstScreen = !firstScreenRecorded
            if firstScreen { firstScreenRecorded = true }
            stateLock.unlock()

            frameScheduler.recordPresented(frameMillis: millis)
            if firstScreen {
                frameScheduler.recordFirstScreen(millis: millis)
            }
        } catch {
            SDRLogger.e("render", "帧渲染失败：\(error)")
        }
    }

    /// 脏区取舍：整屏重绘或脏区过多时退化为包围盒，单脏区使用精确 scissor（§4.3）
    private func scissorRect(fullRedraw: Bool, dirtyRects: [CGRect], bounds: CGRect) -> MTLScissorRect {
        guard dirtyRectRenderingEnabled, !fullRedraw, !dirtyRects.isEmpty else {
            return MTLScissorRect(x: 0, y: 0,
                                  width: Int(max(bounds.width, 1)),
                                  height: Int(max(bounds.height, 1)))
        }
        if dirtyRects.count == 1 {
            return MTLScissorRect(x: Int(dirtyRects[0].minX), y: Int(dirtyRects[0].minY),
                                  width: Int(max(dirtyRects[0].width, 1)),
                                  height: Int(max(dirtyRects[0].height, 1)))
        }
        var union = dirtyRects[0]
        for rect in dirtyRects.dropFirst() { union = union.union(rect) }
        return MTLScissorRect(x: Int(union.minX), y: Int(union.minY),
                              width: Int(max(union.width, 1)), height: Int(max(union.height, 1)))
    }

    /// 批次编码：绑定管线 → 顶点 → 纹理 → 绘制
    private func encode(batches: [SDRDrawBatch], encoder: MTLRenderCommandEncoder,
                        cache: SDRPipelineCache, sampler: MTLSamplerState?,
                        scissor: MTLScissorRect, viewportSize: SIMD2<Float>) {
        guard !batches.isEmpty else { return }
        let format = deviceProvider.pixelFormat
        let uniforms = SDRShaderSource.Uniforms(viewportSize: viewportSize)

        encoder.setCullMode(.none)
        // scissor 负责把绘制限制在脏区；viewport 必须是整屏尺寸，
        // 否则 NDC 映射基准错误，脏区内的图元会被拉伸。
        encoder.setScissorRect(scissor)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(viewportSize.x), height: Double(viewportSize.y),
                                        znear: 0, zfar: 1))
        withUnsafePointer(to: uniforms) { pointer in
            encoder.setVertexBytes(pointer, length: MemoryLayout<SDRShaderSource.Uniforms>.stride, index: 1)
        }

        let slot = dynamicVertexSlot()
        var slotOffset = 0

        for batch in batches {
            guard let pipeline = try? cache.pipelineState(kind: batch.kind,
                                                          format: format,
                                                          sampleCount: max(sampleCount, 1),
                                                          blend: batch.blend) else {
                continue
            }
            encoder.setRenderPipelineState(pipeline)

            let byteCount = SDRVertexBuilder.vertexBytes(for: batch)
            let aligned = (byteCount + 255) / 256 * 256

            if let slot = slot, slotOffset + byteCount <= SDRRenderLoop.vertexSlotBytes {
                writeVertices(batch.vertices, to: slot, offset: slotOffset)
                encoder.setVertexBuffer(slot, offset: slotOffset, index: 0)
                slotOffset += aligned
            } else if let device = deviceProvider.device,
                      let transient = makeTransientVertexBuffer(device: device, vertices: batch.vertices) {
                encoder.setVertexBuffer(transient, offset: 0, index: 0)
            } else {
                continue
            }

            if batch.textureID != 0, let texture = textureRegistry.texture(for: batch.textureID) {
                encoder.setFragmentTexture(texture, index: 0)
                if let sampler = sampler {
                    encoder.setFragmentSamplerState(sampler, index: 0)
                }
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: batch.vertices.count)
        }
    }

    private func dynamicVertexSlot() -> MTLBuffer? {
        guard let device = deviceProvider.device else { return nil }
        stateLock.lock()
        defer { stateLock.unlock() }
        if vertexSlots.isEmpty {
            for _ in 0..<SDRRenderLoop.vertexSlotCount {
                guard let slot = makeVertexSlot(device: device) else { continue }
                vertexSlots.append(slot)
            }
        }
        guard !vertexSlots.isEmpty else { return nil }
        let slot = vertexSlots[vertexSlotIndex % vertexSlots.count]
        vertexSlotIndex = (vertexSlotIndex + 1) % vertexSlots.count
        return slot
    }

    private func makeVertexSlot(device: MTLDevice) -> MTLBuffer? {
        let buffer = device.makeBuffer(length: SDRRenderLoop.vertexSlotBytes, options: .storageModeShared)
        buffer?.label = "render.vertex.slot"
        return buffer
    }

    private func makeTransientVertexBuffer(device: MTLDevice, vertices: [SDRVertex]) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        return vertices.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
    }

    private func writeVertices(_ vertices: [SDRVertex], to buffer: MTLBuffer, offset: Int) {
        guard !vertices.isEmpty else { return }
        let destination = buffer.contents().advanced(by: offset)
        vertices.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            destination.copyMemory(from: base, byteCount: raw.count)
        }
    }

    /// 把渲染循环内部计数器并入调度器统计（对外只暴露一份 SDRRenderStats）
    private func syncCounters() {
        stateLock.lock()
        let commands = encodedCommands
        let warmMillis = warmupMillis
        let pipelines = warmupPipelines
        let pool = texturePool
        let cache = pipelineCache
        stateLock.unlock()

        scheduler?.mergeCounters(pipelineHits: cache?.hits ?? 0,
                                 pipelineMisses: cache?.misses ?? 0,
                                 textureHits: pool?.hits ?? 0,
                                 textureMisses: pool?.misses ?? 0,
                                 encodedCommands: commands,
                                 warmupMillis: warmMillis,
                                 warmupCount: pipelines)
    }

    /// CGSize → SIMD2<Float>
    static func viewportVector(_ size: CGSize) -> SIMD2<Float> {
        SIMD2<Float>(Float(max(size.width, 1)), Float(max(size.height, 1)))
    }
}
