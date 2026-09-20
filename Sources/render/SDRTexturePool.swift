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

/// 纹理池键：按 64 像素对齐分桶，尺寸相近的纹理互相复用，避免频繁分配。
public struct SDRTextureKey: Hashable {
    public let width: Int
    public let height: Int
    public let format: SDRPixelFormat

    public init(width: Int, height: Int, format: SDRPixelFormat) {
        self.width = width
        self.height = height
        self.format = format
    }
}

/// 纹理复用池。
///
/// guest 侧同一批绘制（图集、离屏层、位图缓存）频繁申请同尺寸纹理，
/// 池化后只保留「首次分配」的显存代价；空闲纹理超过预算时整体回收。
public final class SDRTexturePool {

    private let device: MTLDevice
    private let bucketSize: Int
    private let budgetBytes: Int
    private let lock = NSLock()

    private var idle: [SDRTextureKey: [MTLTexture]] = [:]

    public private(set) var hits = 0
    public private(set) var misses = 0
    public private(set) var residentBytes = 0

    public init(device: MTLDevice, budgetBytes: Int = 128 << 20, bucketSize: Int = 64) {
        self.device = device
        self.budgetBytes = max(budgetBytes, 1 << 20)
        self.bucketSize = max(bucketSize, 1)
    }

    public var idleTextureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return idle.values.reduce(0) { $0 + $1.count }
    }

    public var snapshot: (hits: Int, misses: Int, residentBytes: Int, idleCount: Int) {
        lock.lock(); defer { lock.unlock() }
        return (hits, misses, residentBytes, idle.values.reduce(0) { $0 + $1.count })
    }

    /// 申请纹理：优先取空闲池，未命中则新建。
    public func acquire(width: Int, height: Int, format: SDRPixelFormat,
                        usage: MTLTextureUsage = [.shaderRead, .renderTarget]) throws -> (texture: MTLTexture, reused: Bool) {
        let key = SDRTextureKey(width: bucketSize(of: width), height: bucketSize(of: height), format: format)

        lock.lock()
        if var bucket = idle[key], let reusable = bucket.popLast() {
            idle[key] = bucket
            hits += 1
            lock.unlock()
            return (reusable, true)
        }
        lock.unlock()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format.metalValue,
            width: key.width,
            height: key.height,
            mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private

        guard let created = device.makeTexture(descriptor: descriptor) else {
            throw SDRRenderError.textureAllocationFailed("\(key.width)x\(key.height) \(format.rawValue)")
        }
        // MTLTextureDescriptor 无 label：标签只能在纹理创建后设在资源对象上
        created.label = "render.pool.\(key.width)x\(key.height).\(format.rawValue)"

        lock.lock()
        misses += 1
        residentBytes += estimateBytes(key)
        lock.unlock()
        return (created, false)
    }

    /// 归还纹理：超出预算时先整体回收空闲纹理再入池
    public func recycle(_ texture: MTLTexture) {
        guard let format = SDRTexturePool.abstractFormat(texture.pixelFormat) else { return }
        let key = SDRTextureKey(width: texture.width, height: texture.height, format: format)

        lock.lock()
        if residentBytes > budgetBytes {
            for (releasedKey, list) in idle {
                residentBytes -= list.count * estimateBytes(releasedKey)
            }
            idle.removeAll(keepingCapacity: true)
        }
        idle[key, default: []].append(texture)
        lock.unlock()
    }

    /// 全量回收：设置切档、进入后台或内存告警时调用
    public func purge() {
        lock.lock()
        idle.removeAll(keepingCapacity: true)
        residentBytes = 0
        lock.unlock()
    }

    // MARK: - 内部

    private func bucketSize(of value: Int) -> Int {
        let clamped = max(value, 1)
        return ((clamped + bucketSize - 1) / bucketSize) * bucketSize
    }

    private func estimateBytes(_ key: SDRTextureKey) -> Int {
        key.width * key.height * key.format.bytesPerPixel
    }

    /// Metal 像素格式 → 抽象格式（仅识别渲染层使用的格式）
    static func abstractFormat(_ metal: MTLPixelFormat) -> SDRPixelFormat? {
        for format in SDRPixelFormat.allCases where format.metalValue == metal {
            return format
        }
        return nil
    }
}
