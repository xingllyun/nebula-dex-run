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

// MARK: - 刷新率档位（阶段四 §4.6：30 / 60 / 120 三档对齐）

/// 刷新率档位。原始值与 Hz 一致，便于与设置项持久化数值直接互转。
public enum SDRRefreshTier: Int, CaseIterable, Codable {
    case eco30 = 30
    case standard60 = 60
    case pro120 = 120

    public var displayName: String {
        switch self {
        case .eco30: return "30Hz（省电档）"
        case .standard60: return "60Hz（标准档）"
        case .pro120: return "120Hz（高刷档）"
        }
    }

    /// 单帧预算：33.3ms / 16.7ms / 8.3ms（对应文档表 7-2）
    public var frameBudgetMillis: Double {
        switch self {
        case .eco30: return 1000.0 / 30.0
        case .standard60: return 1000.0 / 60.0
        case .pro120: return 1000.0 / 120.0
        }
    }

    /// CADisplayLink 首选刷新区间（Apple 官方机制，文档表 7-1）
    /// 120Hz 档按官方建议上报 (80, 120, 120)，其余档位上报固定值。
    public var cadenceRange: (minimum: Float, maximum: Float, preferred: Float) {
        switch self {
        case .eco30: return (30, 30, 30)
        case .standard60: return (60, 60, 60)
        case .pro120: return (80, 120, 120)
        }
    }

    /// 向后兼容的旧属性名映射（preferredFramesPerSecond 已废弃，仅作兜底）
    public var legacyPreferredFramesPerSecond: Int { rawValue }

    /// 设备不支持更高档位时自动降级：按设备最高帧率向下取档
    public static func resolve(requested: SDRRefreshTier, deviceMaximumFrameRate: Int) -> SDRRefreshTier {
        let cap = max(deviceMaximumFrameRate, SDRRefreshTier.eco30.rawValue)
        var best = SDRRefreshTier.eco30
        for tier in SDRRefreshTier.allCases where tier.rawValue <= cap && tier.rawValue <= requested.rawValue {
            if tier.rawValue > best.rawValue {
                best = tier
            }
        }
        return best
    }

    /// 由设置项持久化数值构造（非法值回落到 60Hz 标准档）
    public static func fromStoredValue(_ value: Int) -> SDRRefreshTier {
        SDRRefreshTier(rawValue: value) ?? .standard60
    }
}

// MARK: - 帧预算（阶段四 §5.4 性能指标）

/// 帧时间预算与硬上限，供渲染循环判定是否超预算。
public struct SDRFrameBudget: Equatable {
    /// 单帧有效重绘硬约束：≤60ms（最优 ≤30ms），绝对上限 200ms（文档表 8）
    public static let redrawHardLimitMillis: Double = 60.0
    public static let redrawOptimalMillis: Double = 30.0
    public static let absoluteLimitMillis: Double = 200.0
    /// 首屏完整渲染：≤150ms，绝对上限 200ms
    public static let firstScreenHardLimitMillis: Double = 150.0

    public let tier: SDRRefreshTier

    public init(tier: SDRRefreshTier) {
        self.tier = tier
    }

    /// 当前档位单帧预算（120Hz 档仅 8.3ms，为最大性能目标下的硬预算）
    public var frameBudgetMillis: Double { tier.frameBudgetMillis }

    /// 超预算判定：以档位预算为基准，同时不越过 §5.4 的 60ms 硬约束
    public func exceedsFrameBudget(_ millis: Double) -> Bool {
        millis > frameBudgetMillis
    }

    /// 越过 §5.4 硬约束（>60ms）即判定为不合格帧
    public func violatesHardLimit(_ millis: Double) -> Bool {
        millis > SDRFrameBudget.redrawHardLimitMillis
    }

    public func violatedFirstScreenLimit(_ millis: Double) -> Bool {
        millis > SDRFrameBudget.firstScreenHardLimitMillis
    }
}

// MARK: - 颜色与顶点

/// RGBA 颜色（线性数值直传 GPU，不走 UIColor，避免主线程依赖）
public struct SDRColor: Equatable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// 由 Android 侧 0xAARRGGBB 整数构造
    public init(argb: UInt32) {
        self.a = Float((argb >> 24) & 0xFF) / 255.0
        self.r = Float((argb >> 16) & 0xFF) / 255.0
        self.g = Float((argb >> 8) & 0xFF) / 255.0
        self.b = Float(argb & 0xFF) / 255.0
    }

    public static let clear = SDRColor(r: 0, g: 0, b: 0, a: 0)
    public static let opaqueBlack = SDRColor(r: 0, g: 0, b: 0, a: 1)
    public static let opaqueWhite = SDRColor(r: 1, g: 1, b: 1, a: 1)
}

/// GPU 顶点布局：与 MSL 侧 `SDRVertex` 严格一一对应（stride 64 字节）
public struct SDRVertex {
    /// 目标像素坐标（左上原点，CPU 侧完成 y 轴对齐前的换算）
    public var position: SIMD2<Float>
    /// 纹理坐标（0..1）
    public var texCoord: SIMD2<Float>
    /// 顶点色（预乘前）
    public var color: SIMD4<Float>
    /// 局部坐标（相对图元左上角，用于圆角 SDF）
    public var localPos: SIMD2<Float>
    /// 图元尺寸（用于圆角 SDF）
    public var localSize: SIMD2<Float>
    /// x = 圆角半径，y = 形状类型（0 直角 / 1 圆角）
    public var shape: SIMD2<Float>

    public init(position: SIMD2<Float>, texCoord: SIMD2<Float>, color: SIMD4<Float>,
                localPos: SIMD2<Float>, localSize: SIMD2<Float>, shape: SIMD2<Float>) {
        self.position = position
        self.texCoord = texCoord
        self.color = color
        self.localPos = localPos
        self.localSize = localSize
        self.shape = shape
    }
}

// MARK: - 绘制命令（guest Canvas API 的最小集）

/// 绘制命令种类，与 shader 侧 fragment 函数一一对应
public enum SDRDrawKind: UInt8, CaseIterable, Codable {
    case fillRect = 0
    case roundedRect = 1
    case text = 2
    case bitmap = 3
    case gradient = 4

    public var displayName: String {
        switch self {
        case .fillRect: return "矩形填充"
        case .roundedRect: return "圆角矩形"
        case .text: return "文本"
        case .bitmap: return "位图"
        case .gradient: return "线性渐变"
        }
    }
}

/// 一条绘制命令。宿主侧不保留 guest 对象引用，全部转为值语义，避免 GC 交互。
public struct SDRDrawCommand {
    public var kind: SDRDrawKind
    /// 目标矩形（像素坐标）
    public var frame: CGRect
    public var color: SDRColor
    /// 渐变终止色
    public var endColor: SDRColor
    public var cornerRadius: CGFloat
    /// 纹理句柄（位图 / 文本图集），0 表示无纹理
    public var textureID: UInt32
    /// 裁剪矩形（nil 表示无裁剪）
    public var clipRect: CGRect?

    public init(kind: SDRDrawKind, frame: CGRect, color: SDRColor,
                endColor: SDRColor = .clear, cornerRadius: CGFloat = 0,
                textureID: UInt32 = 0, clipRect: CGRect? = nil) {
        self.kind = kind
        self.frame = frame
        self.color = color
        self.endColor = endColor
        self.cornerRadius = cornerRadius
        self.textureID = textureID
        self.clipRect = clipRect
    }
}

// MARK: - 脏区集合（阶段四 §4.3 脏区局部渲染）

/// 脏区收集与合并：控制重绘面积，减少 GPU 绘制像素量。
public struct SDRDirtyRectSet {
    /// 合并上限：超过后合并为包围盒（避免 scissor 频繁切换）
    public let mergeLimit: Int
    public private(set) var rects: [CGRect] = []

    public init(mergeLimit: Int = 8) {
        self.mergeLimit = mergeLimit
    }

    public var isEmpty: Bool { rects.isEmpty }

    /// 全屏脏标记：整帧重绘
    public mutating func addFullRedraw(_ bounds: CGRect) {
        rects = [bounds]
    }

    public mutating func add(_ rect: CGRect) {
        guard !rect.isNull, !rect.isEmpty else { return }
        if rects.contains(where: { $0.contains(rect) }) {
            return
        }
        rects.removeAll { rect.contains($0) }
        rects.append(rect)
        if rects.count > mergeLimit {
            if let merged = rects.first {
                var union = merged
                for r in rects.dropFirst() {
                    union = union.union(r)
                }
                rects = [union]
            }
        }
    }

    /// 与目标矩形求交并裁剪到边界内（scissor 必须落在渲染目标内）
    public func clippedRects(to bounds: CGRect) -> [CGRect] {
        rects.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
    }

    public mutating func reset() {
        rects.removeAll(keepingCapacity: true)
    }
}

// MARK: - 渲染统计与错误

/// 渲染层运行时统计（供设置页与验收脚本读取）
public struct SDRRenderStats: Codable, Equatable {
    public var tierLabel: String = ""
    public var framesPresented: Int = 0
    public var framesSkipped: Int = 0
    public var framesOverBudget: Int = 0
    public var framesOverHardLimit: Int = 0
    public var lastFrameMillis: Double = 0
    public var averageFrameMillis: Double = 0
    public var worstFrameMillis: Double = 0
    public var firstScreenMillis: Double = 0
    public var pipelineCacheHits: Int = 0
    public var pipelineCacheMisses: Int = 0
    public var texturePoolHits: Int = 0
    public var texturePoolMisses: Int = 0
    public var warmupMillis: Double = 0
    public var warmupPipelineCount: Int = 0
    public var drawCommandsEncoded: Int = 0

    public init() {}

    /// 管线命中率：验收目标为交互场景 100%（文档 §4.2）
    public var pipelineHitRate: Double {
        let total = pipelineCacheHits + pipelineCacheMisses
        guard total > 0 else { return 1.0 }
        return Double(pipelineCacheHits) / Double(total)
    }

    public var summary: String {
        String(format: "档位 %@ | 出帧 %d | 超预算 %d | 均帧 %.2fms | 最差 %.2fms | 管线命中 %.1f%%",
               tierLabel, framesPresented, framesOverBudget,
               averageFrameMillis, worstFrameMillis, pipelineHitRate * 100.0)
    }
}

/// 渲染层错误
public enum SDRRenderError: Error, CustomStringConvertible, Equatable {
    case metalDeviceUnavailable
    case commandQueueUnavailable
    case shaderCompileFailed(String)
    case functionMissing(String)
    case pipelineBuildFailed(String)
    case drawableUnavailable
    case targetNotConfigured
    case textureAllocationFailed(String)

    public var description: String {
        switch self {
        case .metalDeviceUnavailable: return "Metal 设备不可用"
        case .commandQueueUnavailable: return "Metal 命令队列创建失败"
        case .shaderCompileFailed(let detail): return "着色器编译失败：\(detail)"
        case .functionMissing(let name): return "着色器函数缺失：\(name)"
        case .pipelineBuildFailed(let detail): return "渲染管线创建失败：\(detail)"
        case .drawableUnavailable: return "CAMetalLayer 当前无可用 drawable"
        case .targetNotConfigured: return "渲染目标尚未配置"
        case .textureAllocationFailed(let detail): return "纹理分配失败：\(detail)"
        }
    }
}

// MARK: - 像素格式（与 MTLPixelFormat 解耦，便于缓存键与离线自检）

/// 渲染层使用的像素格式抽象
public enum SDRPixelFormat: String, CaseIterable, Codable {
    case bgra8Unorm
    case bgra8UnormSRGB
    case rgba8Unorm
    case r8Unorm
    case rgba16Float

    /// 是否可作为 CAMetalLayer 的上屏格式
    public var isPresentable: Bool {
        switch self {
        case .bgra8Unorm, .bgra8UnormSRGB, .rgba16Float: return true
        case .rgba8Unorm, .r8Unorm: return false
        }
    }

    /// 单像素字节数，用于纹理池容量核算
    public var bytesPerPixel: Int {
        switch self {
        case .bgra8Unorm, .bgra8UnormSRGB, .rgba8Unorm: return 4
        case .r8Unorm: return 1
        case .rgba16Float: return 8
        }
    }
}

// MARK: - 混合模式

/// 混合模式：对应 Canvas 的 SrcOver（预乘）与 Src 覆盖两种最小集
public enum SDRBlendMode: String, CaseIterable, Codable {
    case none
    case sourceOver
}
