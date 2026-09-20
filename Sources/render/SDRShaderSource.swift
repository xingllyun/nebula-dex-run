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

/// Metal 着色器源码（阶段四 §4.1 渲染管线：Canvas 绘制调用 → GPU 加速光栅化）
///
/// 采用运行期编译（`MTLDevice.makeLibrary(source:options:)`）而非构建期 metallib：
///   - 无需 Xcode 的 Metal 工具链组件参与构建，CI 上零额外依赖；
///   - 渲染层源码与着色器同仓同版本，不存在 metallib 与 Swift 结构体布局漂移的窗口期；
///   - PSO 预热在启动期一次性完成（§4.2），运行期编译成本被预热吸收。
public enum SDRShaderSource {

    /// 顶点函数：像素坐标 → NDC，并透传局部坐标供圆角 SDF 使用
    public static let vertexFunctionName = "sdr_vertex_main"
    /// 片元：纯色填充（含圆角 SDF 与脏区外的 alpha 裁剪）
    public static let solidFragmentName = "sdr_fragment_solid"
    /// 片元：线性渐变（顶点色插值实现，无额外 uniform）
    public static let gradientFragmentName = "sdr_fragment_gradient"
    /// 片元：纹理采样（位图，采样值 × 顶点色）
    public static let textureFragmentName = "sdr_fragment_texture"
    /// 片元：字形图集采样（R8 单通道作为 alpha）
    public static let glyphFragmentName = "sdr_fragment_glyph"

    /// 全部函数名，供预热遍历与离线自检比对
    public static var functionNames: [String] {
        [vertexFunctionName, solidFragmentName, gradientFragmentName, textureFragmentName, glyphFragmentName]
    }

    /// MSL 源码
    public static let source: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct SDRVertex {
        float2 position;
        float2 texCoord;
        float4 color;
        float2 localPos;
        float2 localSize;
        float2 shape;
    };

    struct SDRUniforms {
        float2 viewportSize;
        float2 padding;
    };

    struct SDRVertexOut {
        float4 position [[position]];
        float2 texCoord;
        float4 color;
        float2 localPos;
        float2 localSize;
        float2 shape;
    };

    // 顶点：像素坐标 → NDC；y 轴翻转以贴合 Android 左上原点约定
    vertex SDRVertexOut sdr_vertex_main(const device SDRVertex *vertices [[buffer(0)]],
                                        constant SDRUniforms &uniforms [[buffer(1)]],
                                        uint vid [[vertex_id]]) {
        SDRVertex v = vertices[vid];
        SDRVertexOut out;
        float2 viewport = max(uniforms.viewportSize, float2(1.0));
        float2 ndc = float2((v.position.x / viewport.x) * 2.0 - 1.0,
                            1.0 - (v.position.y / viewport.y) * 2.0);
        out.position = float4(ndc, 0.0, 1.0);
        out.texCoord = v.texCoord;
        out.color = v.color;
        out.localPos = v.localPos;
        out.localSize = v.localSize;
        out.shape = v.shape;
        return out;
    }

    // 圆角覆盖度：shape.y >= 0.5 时按圆角矩形 SDF 计算，否则整块覆盖
    static inline float sdr_round_coverage(thread const SDRVertexOut &v) {
        if (v.shape.y < 0.5) {
            return 1.0;
        }
        float2 halfSize = max(v.localSize, float2(0.0)) * 0.5;
        float radius = clamp(v.shape.x, 0.0, min(halfSize.x, halfSize.y));
        float2 p = v.localPos - halfSize;
        float2 inner = halfSize - radius;
        float2 d = abs(p) - inner;
        float dist = length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0) - radius;
        return 1.0 - smoothstep(-1.0, 1.0, dist);
    }

    // 纯色填充
    fragment float4 sdr_fragment_solid(SDRVertexOut v [[stage_in]]) {
        return float4(v.color.rgb, v.color.a * sdr_round_coverage(v));
    }

    // 线性渐变：顶点色插值给出，直接复用圆角覆盖
    fragment float4 sdr_fragment_gradient(SDRVertexOut v [[stage_in]]) {
        return float4(v.color.rgb, v.color.a * sdr_round_coverage(v));
    }

    // 位图：纹理采样 × 顶点色
    fragment float4 sdr_fragment_texture(SDRVertexOut v [[stage_in]],
                                         texture2d<float> tex [[texture(0)]],
                                         sampler smp [[sampler(0)]]) {
        float4 sampled = tex.sample(smp, v.texCoord);
        float4 tinted = sampled * v.color;
        return float4(tinted.rgb, tinted.a * sdr_round_coverage(v));
    }

    // 文本字形：图集 R8 通道作为 alpha
    fragment float4 sdr_fragment_glyph(SDRVertexOut v [[stage_in]],
                                       texture2d<float> atlas [[texture(0)]],
                                       sampler smp [[sampler(0)]]) {
        float alpha = atlas.sample(smp, v.texCoord).r;
        return float4(v.color.rgb, v.color.a * alpha);
    }
    """

    /// 顶点着色器 uniform：视口尺寸（像素）
    public struct Uniforms {
        public var viewportSize: SIMD2<Float>
        public var padding: SIMD2<Float>

        public init(viewportSize: SIMD2<Float>) {
            self.viewportSize = viewportSize
            self.padding = SIMD2<Float>(0, 0)
        }
    }
}
