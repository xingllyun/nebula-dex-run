---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: ed38b03a482bb8c9cc01ec95f4dd35e7_d31c5642b4b311f19285525400638852
    ReservedCode1: BQRW8Of4k37oZDnSKMGb+8BmybHzewSyqstwgTezX8O6GwpuvW0HNiyEW61H78edC34gRePt5DwtHd4DrNqNfYxcICPIcm2L/nLUuP72naBf4m5x3CX64uA5MTmSt5UfzNt2ZMbZDI5XpTkIzDsFZ2QsxZSvMK43eox/4203y+CjtZ/VyITxvhZjxD8=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: ed38b03a482bb8c9cc01ec95f4dd35e7_d31c5642b4b311f19285525400638852
    ReservedCode2: BQRW8Of4k37oZDnSKMGb+8BmybHzewSyqstwgTezX8O6GwpuvW0HNiyEW61H78edC34gRePt5DwtHd4DrNqNfYxcICPIcm2L/nLUuP72naBf4m5x3CX64uA5MTmSt5UfzNt2ZMbZDI5XpTkIzDsFZ2QsxZSvMK43eox/4203y+CjtZ/VyITxvhZjxD8=
---

# NebulaDex 全链路升级执行文档（V4.0.0 · 双官网核查合并版）

| 项目 | 内容 |
|---|---|
| 项目名称 | NebulaDex（星云 Dex）——iOS 端 Android 兼容运行环境 |
| 文档归属 | 星云云络科技 |
| 文档版本 | V4.0.0（双官网核查合并版） |
| 基线版本 | 阶段四执行文档 V2.1（0548279 / 69f06e3）；主文档 V3.0.0 |
| 编制日期 | 2026 年 9 月 20 日 |
| 文档密级 | 内部 |
| 合并来源 | ① 本批开发文档《NebulaDex 全链路升级执行文档 V2.1》 ② Apple Developer 官方文档 / WWDC 技术文档 ③ Android Developers / AOSP 官方文档 |

---

## 0 本版修订说明（相对阶段四 V2.1）

本次为**双官网（Apple Developer + Android Developers）核查后的合并修订版**。原文正文技术路线不变，修订集中在「官方依据补齐、性能与流畅度拉满、体积口径改写、依赖与工具显性化」四类。

| # | 修订项 | V2.1 原表述 | V4.0.0 修订后 | 依据 |
|---|---|---|---|---|
| 1 | **体积口径（关键）** | 8MB 底线、25MB 当前目标、按需扩展；"Skia 裁剪编译、控制原生库体积、strip 调试符号" | **体积为下限约束**：绝对底线 ≥8MB，基本要求 ≥50MB，理想 500MB–1GB，**越大越好**；撤销裁剪/压缩取向，改为主动"往里塞"资源与依赖 | 用户最新指令（2026-09-20） |
| 2 | 渲染层官方规范 | Metal 最佳实践 5 项（memoryless、dontCare、脏区、MSAA、命令缓冲批提交） | 扩充为 Apple 官方 11 项，新增 TBDR pass 合并、Imageblocks、drawable 池与获取时机、`framebufferOnly`/`drawableSize`、`CAMetalDisplayLink`、`MTLHeap`、MPS Tuning Hints（CPU/GPU 并发） | Apple Developer：Choosing a Resource Storage Mode；WWDC23 10125；Drawable Objects；Achieving smooth frame rates with a Metal display link；Reducing the memory footprint of Metal apps；MPS Tuning Hints |
| 3 | 高刷适配 | CADisplayLink range + Surface.setFrameRate 双端对照 | 补齐落地细节：`CADisableMinimumFrameDurationOnPhone`（iPhone >60Hz 生效前提）、`Display.getSupportedModes()` + 刷新率变化监听、`SurfaceControl.Transaction.setFrameTimeline()`（API 35+）、`preferredDisplayModeId` 回退口径 | Apple Developer：Optimizing for ProMotion displays；Android Developers：Frame rate；SurfaceControl.Transaction |
| 4 | 触控延迟消除 | delaysContentTouches=false + touchesShouldCancelInContentView | 补齐官方配套：`canCancelContentTouches` / `touchesShouldCancel(in:)` 取舍、`requestUnbufferedDispatch` 降缓冲、`getHistoricalX/Y` + `VelocityTracker` 历史事件批处理、事件分发层做减法 | Apple Developer：delaysContentTouches；Android Developers：Slow rendering / Input latency |
| 5 | 触摸与主线程红线 | 未显式约束 | 新增：主线程 5 秒未响应输入触发 ANR 红线，I/O 与重计算一律移出主线程 | Android Developers：Keep your app responsive |
| 6 | 运行时机制 | dexopt / quicken / d8 简述 | 补 d8 参数口径（`--release`/`--min-api`/`--main-dex-list`/`--file-per-class`）、R8 发布链、dex2oat 编译器过滤器（verify/quicken/speed/speed-profile/everything） | Android Developers：d8；AOSP：Configure ART / ART Service |
| 7 | 性能验证 | 三项基线纳入测试输出 | 新增独立章节「性能验证与门禁」，双端剖析工具直接作为每版发布门槛 | Apple：Instruments Game Performance / Metal System Trace / Metal Performance HUD；Android：Perfetto / Macrobenchmark / Microbenchmark / Simpleperf |
| 8 | 依赖与工具 | 散落各处 | 新增独立章节「依赖与工具链」，显性化"有依赖用依赖、有工具用工具、不重复造轮子" | 用户最新指令 + 双官网工具链 |

> 修订原则：不改变项目目标与产品形态；只把官方可直接落地的机制补进执行口径，并把体积策略从"压缩"翻转为"下限约束、越大越好"。

---

## 1 总体执行原则与实现力度分配

### 1.1 总体原则

1. **自底向上，不跳步**：字节码解释器 → Java 运行时 → Framework → 渲染层逐层推进，下层验证通过再向上搭建。
2. **可验证交付**：每个模块配套冒烟用例，接入 CI 门禁，不做无验收的占位代码。
3. **稳定区禁动**：底层 `native-loader`、`sandbox`、`syscall 代理`、ELF 装载链已闭环且有 CI 门禁，非架构重构严禁修改。
4. **能用依赖用依赖、有工具用工具**：优先复用成熟工具链（Android build-tools / d8 / R8、Skia、Metal、Perfetto、Instruments），不重复造轮子。
5. **性能与流畅度最大化（硬约束）**：渲染单帧有效重绘 ≤60ms（最优 ≤30ms），触控全链路 ≤60ms（最优 ≤40ms），绝对上限 200ms；高刷档位按第 3.8 节预算收紧。
6. **体积为下限约束（越大越好）**：绝对底线 ≥8MB，基本要求 ≥50MB，理想 500MB–1GB；优先保障性能与能力，不因体积做功能裁剪。

### 1.2 实现力度分配

| 模块 | 实现力度 | 说明 |
|---|---|---|
| DEX 解释器 | 最大可用 | 完成第三阶段全量补全，覆盖日常开发 90% 以上字节码场景 |
| 渲染层（显示链路） | 最大可用 | Skia Metal GPU 加速，完整打通 Android View → Canvas → 上屏 |
| 触控与输入链路 | 最大可用 | 官方延迟消除机制全量落地，指标硬约束 |
| Android 生命周期 | 最小可用 | 仅实现六回调最小流转，支撑 Activity 可启动可退出 |
| 安卓对接 API | 最小可用 | 仅提供渲染链路必需的最小 API 集，其余后续补全 |
| 底层稳定区 | 保持不动 | native-loader、sandbox、syscall 代理、ELF 装载链 |
| 资源与依赖体积 | 主动填充 | 依赖、资源、工具链按"越大越好"策略主动引入（见第 6 章） |

---

## 2 第三阶段 DEX 解释器全量补全（最大可用）

### 2.1 当前收尾四项

在开始全量补全前，先闭环当前批次遗留的四项工程化工作，将现有整数核心能力串成可用链路：

| 序号 | 工作项 | 核心内容 | 验收标准 |
|---|---|---|---|
| 1 | `SDRAppContainer.launch()` 接入真实执行 | 替换 `run(code: [])` 空跑逻辑，串联「DEX 加载 → 类解析 → 入口方法定位 → 解释执行」全流程 | 基础整数逻辑 DEX 可自动加载执行 |
| 2 | Swift 侧 DEX 对拍测试入口 | 搭建 `Tests/dex/main.swift`，加载 d8 生成的真实 DEX 样本，执行结果与 Java 原生输出校验 | 对拍结果一致 |
| 3 | CI 集成 d8 编译链 | 打通「Java 测试源码 → javac → d8 → DEX → 冒烟测试」自动化流程，复用 Android build-tools 依赖 | CI 全链路自动运行 |
| 4 | 开发文档口径修订 | 统一体积口径为 **≥8MB 底线、≥50MB 基本要求、500MB–1GB 理想** | 文档口径一致 |

### 2.2 指令集全量覆盖

所有 opcode 严格按 Dalvik 官方指令格式解析（16 位 code unit 对齐，35c/3rc 等格式按官方位域定义处理），未实现指令统一抛出 `DEX_OP_UNSUPPORTED`，保留日志语义，禁止静默按宽度跳过。指令宽度、寄存器位序、常量池索引解析均以 AOSP 官方 Dalvik bytecode 与 dex-format 为基准。

| 指令族 | 覆盖范围 | 关键实现点 |
|---|---|---|
| 整数指令 | 四则运算、位运算、比较、类型转换、移位全族 | 乘法溢出回绕、除零语义、符号扩展 |
| 长整数指令 | long 型加减乘除、移位、比较 | 寄存器对操作，64 位数据边界对齐 |
| 浮点指令 | float/double 四则运算、比较、类型转换 | 对接底层 FPU/NEON 浮点能力，原生指令映射 |
| 数组指令 | new-array、array-length、aget-*/aput-* 全类型 | 统一数组寻址模型，边界检查前置并抛异常 |
| 对象指令 | new-instance、instance-of、check-cast | 对象内存布局、类引用绑定、类型安全校验 |
| 字段指令 | iget-*/iput-*/sget-*/sput-* 全系列 | 实例字段偏移寻址、静态字段全局寻址、类型一致性校验 |
| 方法调用 | invoke-static/direct/virtual/interface、move-result 系列 | 完整栈帧创建销毁、参数按序传递、嵌套调用、返回值回写 |
| 控制流 | if 系列、goto 全档、packed-switch/sparse-switch | 分支偏移精确计算、分支表解析、循环支持 |
| 异常指令 | throw、try-catch-finally 全链路 | 栈回溯寻址、异常表（try_item）快速匹配 |
| 多态调用 | invoke-polymorphic 等高级调用 | 统一抛 `DEX_OP_UNSUPPORTED`，保留扩展接口 |

**验收标准**：基础指令覆盖率 ≥150 条；含整数运算、分支循环、数组、字段读写、方法嵌套调用的 DEX 用例执行结果与 Java 原生输出完全一致；`dex-smoke` 用例全绿，存量 native 层、系统调用层功能不回退。

### 2.3 执行性能优化（借鉴 dexopt quickening）

参考 Android 官方 Dalvik dexopt 优化器与 ART quicken 模式的公开机制，在解释器层做前置优化，降低运行期解析开销。官方 dexopt / ART Service 核心思路为：常量池解析前置、将运行期字符串查找替换为直接偏移、按 JIT profile 做热点方法 AOT。

| 优化项 | 做法 | 官方依据 |
|---|---|---|
| 常量池预解析 | 类加载阶段提前解析字段/方法常量池索引，替换为直接偏移量，执行期跳过字符串查找 | dexopt 将常量池解析前置，替换索引为直接偏移 |
| 虚方法表索引化 | invoke-virtual 的方法索引在类加载期改写为 vtable 索引，运行期直接查表 | dexopt 将虚方法索引替换为 vtable 索引 |
| 小类型合并 | boolean/byte/char/short 字段读写按 32 位合并形式处理，减少指令分支 | dexopt 将小类型合并为单一 32-bit 形式，提升 I-cache 效率 |
| 常用小方法内联 | String.length() 等高频小方法做内联缓存 | dexopt 对高频简单方法内联，减少调用开销 |
| 热点方法快速路径 | 渲染、循环等热点方法启用指令译码快速路径，减少栈帧开销 | ART quicken 面向解释器性能的指令优化 |
| 静态字段缓存 | 静态字段地址常驻缓存，避免每次访问重复类查找 | dexopt 字段偏移化思路的延伸 |
| 热点方法 AOT（新增） | 以 JIT profile 为输入，对热点方法走 `speed-profile` 预编译路径，减少解释执行占比 | AOSP：ART Service —— `bg-dexopt` 默认 `speed-profile` 过滤器 |

### 2.4 配套工程化

复用 Android build-tools 的 d8 工具生成真实 DEX 测试样本，避免手写字节码的低效与易错。d8 是 Android 官方命令行工具，输入已编译 Java 字节码（.class 文件或 JAR），输出 DEX 字节码，支持 Java 8 语言特性。

- **CI 集成**：安装 Android build-tools，配置 `javac + d8` 编译流水线，Java 测试源码自动编译为 DEX 后喂给冒烟用例。
- **d8 参数口径**：调试构建用 d8 默认参数；发布链路加 `--release`；按需使用 `--min-api`（最低 API 约束）、`--main-dex-list`（启动关键类编入主 dex）、`--file-per-class`（增量构建）；发布混淆/压缩统一走 R8。
- **用例扩充**：覆盖新增全类型指令，每类指令对应独立 Java 测试源码，自动编译、执行、结果校验。
- **全量门禁**：`dex-smoke` 纳入 CI 门禁，存量 native 层、系统调用层用例全量回归。
- **性能基线输出**：整数运算 MIPS、方法调用耗时、类加载耗时三项基线纳入测试输出；基线用 Microbenchmark 口径在循环内复跑降噪，端到端场景（启动、滚动）用 Macrobenchmark 口径度量。

---

## 3 Skia Metal GPU 加速渲染层（最大可用）

### 3.1 技术路线与架构修正

渲染加速路径确定为 **Skia Metal 后端**：Skia 官方支持 iOS Metal 硬件加速渲染（SkiaSharp 生态中的 SKMetalView 即基于此提供硬件加速视图），相比软件光栅通常可获得数倍性能提升（经验估计，最终以实测基线为准）。Skia 在 iOS 上的最低部署目标为 iOS 12（Xcode 15）。

**架构修正**：Skia 属于宿主侧渲染库，应作为宿主原生依赖直接链接（静态库或 Framework），通过 JNI 桥接暴露给 guest Java 层；guest 侧 ELF 加载链仅用于加载 APK 内自带的 Android `.so` 库（如应用 lib 目录下的原生库），两者职责分离，不得混用。

### 3.2 渲染管线分层

| 层 | 职责 | 说明 |
|---|---|---|
| Android View 体系 | 布局、测量、绘制命令生成 | guest 侧 Java 层，解释器执行 |
| Canvas API | drawText/drawRect/drawBitmap 等绘制调用 | JNI 批量下发到宿主侧 |
| Skia（Metal 后端） | GPU 加速光栅化 | 宿主侧直接链接，Metal 渲染管线 |
| CAMetalLayer | 最终上屏 | iOS 原生图层，避免中间位图拷贝 |

**双端渲染模型对齐（新增）**：Android 侧硬件加速由 Display List / RenderNode 承载，主线程只构造显示列表、渲染交 RenderThread；本项目在宿主侧以「Skia 录制（SkPicture/RenderNode 等价物）+ 后台渲染线程提交」对齐该模型，主线程仅负责事件响应与最终上屏。

### 3.3 Apple 官方 Metal 渲染规范（本次合并，11 项）

严格遵循 Apple 官方 Metal 最佳实践，逐项落地：

| # | 优化项 | 做法 | 依据 |
|---|---|---|---|
| 1 | Memoryless 渲染目标 | 临时渲染缓冲区采用 `MTLStorageMode.memoryless`，内容仅驻留 GPU tile memory，不分配系统内存 | Choosing a Resource Storage Mode for Apple GPUs |
| 2 | Load/Store Action 优化 | 中间渲染目标 load/store action 设为 `dontCare`，仅最终上屏目标执行 store | Setting Load and Store Actions |
| 3 | TBDR pass 合并 | 同类命令（graphics/compute/blit）合并进同一 render pass，共享 render target 时合为单 pass，clear 用 `LoadActionClear` 替代空 encoder，把 tile↔system memory 往返降到 1 次 | WWDC23 10125 |
| 4 | Imageblocks / Tile Shaders | 在 tile memory 内定义 per-pixel 结构，让 fragment 与 tile 阶段共享本地内存，渲染+计算留在单 pass | About Imageblocks（GPU Family 4） |
| 5 | Drawable 获取与释放时机 | 尽量晚取 `nextDrawable()`（编码上屏 pass 前）、尽快释放强引用，避免阻塞到下一刷新间隔；渲染循环包 `@autoreleasepool` | Drawable Objects / CAMetalLayer |
| 6 | `framebufferOnly` / `drawableSize` | 设 `framebufferOnly = YES` 让层针对显示优化纹理；按 `nativeScale/nativeBounds` 计算 `drawableSize` 精确匹配屏幕像素，避免额外采样 | Metal Programming Guide: Render Context |
| 7 | CAMetalDisplayLink（iOS 17+） | 用 `CAMetalDisplayLink(metalLayer:)` 替代 CADisplayLink，配合 `preferredFrameRateRange` 与 `preferredFrameLatency` 取得精确时序与最低输入延迟 | Achieving Smooth Frame Rates with a Metal Display Link |
| 8 | MTLHeap 共享分配 | 每帧生产消费的瞬态资源用 `MTLHeap` 共享同一块内存分配 | Reducing the Memory Footprint of Metal Apps |
| 9 | CPU/GPU 并发 | 不等待 `waitUntilCompleted()` 再编码下一命令缓冲（空 buffer 过管线可达 2.5ms 延迟），让 CPU/GPU 并发；预分配复用 `MTLResource`；批处理 compute 减少 encoder 切换 | Metal Performance Shaders Tuning Hints |
| 10 | MSAA 优化 | 4 倍 MSAA 时多重采样附件使用 memoryless 存储，Apple 原生高效解析 | Reducing the Memory Footprint of Metal Apps |
| 11 | 命令缓冲区批量提交 | 收集绘制指令批量提交 GPU，减少 CPU-GPU 调度开销 | WWDC20：Optimize Metal Performance |

### 3.4 着色器 PSO 预热

Skia Metal 模式在首次遇到新绘制配置时会运行时编译着色器（Pipeline State Object），造成 20～100ms 的首帧卡顿（业界对 Skia 在 iOS 上 first-run jank 的实测范围）。按行业通用方案做启动期预热：

- 启动页/加载阶段创建离屏 Canvas，预先执行常用绘制操作（圆角矩形、文本、渐变、裁剪、阴影），提前编译常用 PSO。
- 基础绘制对应的管线状态对象常驻缓存，不重复编译。

**验收目标**：交互场景着色器命中 100%，无运行时编译阻塞。

### 3.5 资源与绘制优化

- **纹理复用池**：图片、位图资源建立 GPU 纹理复用池，避免重复创建与上传。
- **绘制对象复用**：SkPaint、SkPath 等绘制对象全局复用，减少对象创建销毁。
- **资源预加载**：启动阶段提前加载常用字体、图标资源到 GPU，绘制时直接调用。
- **布局解析缓存**：同个 Activity 不重复解析布局 XML，解析结果常驻缓存。
- **图层缓存**：动画/拖拽期间将控件内容缓存为 GPU 纹理（等价 `LAYER_TYPE_HARDWARE`），过程中只移纹理不重绘。

### 3.6 上屏链路优化

- 采用 **CAMetalLayer 直接承载渲染结果**，避免中间位图拷贝与格式转换。
- 渲染计算在后台渲染线程执行，主线程仅负责最终上屏与事件响应。
- 垂直同步对齐屏幕刷新率，避免画面撕裂与多余帧渲染。
- 帧呈现时间精确化：高刷与可预测时序场景使用 Metal Display Link / 帧时间线机制（见 3.8）。

### 3.7 刷新率适配（30/60/120 三档对齐）

设置项提供 30/60/120Hz 三档刷新率可选，渲染管线必须对齐所选档位，做到最大性能、最流畅，同时兼顾省电与低端设备兼容。以下机制为**双端官方方案合并**：

| 维度 | iOS 官方机制（Apple Developer） | Android 官方机制（Android Developers） |
|---|---|---|
| 帧率控制 | `CADisplayLink.preferredFrameRateRange`（iOS 15+），通过 `CAFrameRateRange(minimum, maximum, preferred)` 指定允许刷新区间 | `Surface.setFrameRate()`（API 30+）显式指定目标帧率 |
| 能力查询 | `UIScreen.main.maximumFramesPerSecond` 查询设备最高帧率；ProMotion 设备最高 120Hz | `Display.getRefreshRate()` / `Display.getSupportedModes()`；NDK 可用 `AChoreographer_registerRefreshRateCallback()` 注册刷新率回调 |
| 驱动模型 | CADisplayLink 按 VSync 回调驱动渲染循环 | Choreographer 按 VSync 事件驱动绘制 |
| 帧呈现 | CAMetalDisplayLink（iOS 17+）提供精确时序与 `preferredFrameLatency` | `SurfaceControl.Transaction.setFrameTimeline(vsyncId)`（API 35+）按期望呈现时间上屏 |
| 兼容回退 | `preferredFramesPerSecond` 已废弃，改用 `preferredFrameRateRange` | `preferredDisplayModeId` 为旧版回退（官方不推荐），仅 setFrameRate 不可用时退用 |
| 前提/注意 | **iPhone 需在 Info.plist 加 `CADisableMinimumFrameDurationOnPhone`**，>60Hz 帧率提示才生效；高影响动画才用 80～120Hz，小动画用低帧率省电 | 传确切帧率（如 29.97 而非四舍五入为 30），系统按帧率倍数选择刷新率；暂停/结束传 0 清除 |
| 禁用项 | 自定义渲染循环必须用 CADisplayLink，禁止用 Timer | 自渲染线程必须用 Choreographer（`postFrameCallback`），禁止用 Timer |

三档配置如下，渲染循环按所选档位设定帧时间预算；设备不支持更高档时自动降级到支持档位：

| 档位 | 单帧预算 | iOS CADisplayLink range | Android setFrameRate | 适用场景 |
|---|---|---|---|---|
| 30fps | 33.3ms | (30, 30, 30) | 30.0f | 省电、低端设备、静态界面 |
| 60fps | 16.7ms | (60, 60, 60) | 60.0f | 标准流畅档 |
| 120fps | 8.3ms | (80, 120, 120) | 120.0f | 最大流畅：高影响动画、列表快速滑动（仅 ProMotion/高刷设备） |

**帧时间预算与性能目标对齐**：120fps 档每帧仅 8.3ms，是最大性能目标下的硬预算；60fps 档 16.7ms 为标准预算；原单帧 ≤60ms 的硬约束在 30fps 档即半帧，在 60/120 高刷新档按上表收紧预算。切换档位时通过首选区间动态协商，保证不撕裂、不抖动、不丢帧。

---

## 4 触控全链路性能优化

### 4.1 系统层延迟消除

承载渲染视图的滚动容器默认延迟触摸分发（`delaysContentTouches` 默认 `true`，系统需约 150ms 判断是否为滑动意图），设置为 `false` 后立即分发触摸事件，可消除该段系统级延迟。

- 将滚动容器的 `delaysContentTouches` 设为 `false`，消除默认约 150ms 的滑动判断延迟。
- 可点击控件重写触摸取消逻辑（`touchesShouldCancelInContentView`），禁止滚动容器取消控件触摸。
- **官方配套（新增）**：与 `delaysContentTouches=false` 配套设置 `canCancelContentTouches` 语义并重写 `touchesShouldCancel(in:)`，在拖动手势真正触发时把触摸交还滚动容器，避免"点了按钮拖不动"。
- **副作用与平衡**：关闭延迟后轻微手指移动可能被误判为点击、快速滑动可能误触按钮，故仅在按钮密集、滑动需求少的场景启用；需要滚动的区域保留默认行为，仅在可点击控件区域关闭延迟。

### 4.2 事件转换与命中检测

- **极简事件转换**：iOS 原生触摸事件 → Android MotionEvent 仅做坐标转换与动作映射（DOWN/MOVE/UP），无中间对象、无队列缓存，单事件转换 ≤5ms。
- **轻量命中检测**：最小可用阶段控件数量少，采用线性遍历 + 矩形相交命中检测，仅检测可见区域控件，不可见、GONE 状态直接跳过。
- **历史事件批处理（新增）**：高频绘制/滑动路径使用 `getHistoricalX/Y` 取批量历史坐标，用 `VelocityTracker` 计算速度，禁止自存 List 计算。
- **降低输入缓冲（新增）**：绘图类交互调用 `view.requestUnbufferedDispatch(event)` 降低事件缓冲延迟；高刷场景配合请求 `preferredRefreshRate`。
- **事件分发层做减法（新增）**：复杂手势识别逻辑放到 `ACTION_UP` 一次性结算，`ACTION_MOVE` 高频路径只收集坐标并 `invalidate`，曲线拟合等重算法移至绘制阶段，避免在分发链路塞重活放大延迟。

### 4.3 响应与局部刷新

- **同步回调执行**：点击命中后主线程同步执行 `onClick` 回调，不做线程调度，最小化调度延迟。
- **局部状态刷新**：按钮按下/抬起状态变化仅重绘控件自身脏区（对应 RenderNode 局部更新），不触发父布局与全界面重绘，状态反馈 ≤20ms。
- **视图属性动画**：位移/缩放类变换使用属性动画路径（等价 `setTranslationX` / `ViewPropertyAnimator`），避免全量重录与重绘。

### 4.4 主线程红线（新增）

- 主线程（UI 线程）**5 秒内未响应输入事件即触发 ANR 级故障**，本项目按同一红线自检：解释执行、类加载、资源解析等重计算任务一律不得长时间占用主线程，必要时切片执行或转移至工作线程。
- 输入链路禁止同步 I/O、数据库查询、锁竞争等待。

### 4.5 性能指标

| 指标 | 目标值 | 绝对上限 | 测试场景 |
|---|---|---|---|
| 单帧有效重绘耗时 | ≤60ms（最优 ≤30ms） | 200ms | 按钮状态切换、文本更新等局部变化 |
| 首屏完整渲染耗时 | ≤150ms | 200ms | 启动 Activity 加载布局并完成首次上屏 |
| 触控响应全链路耗时 | ≤60ms（最优 ≤40ms） | 200ms | 手指按下 → 状态刷新 → onClick 执行完成 |
| 连续滑动帧率 | 对齐 30/60/120 三档设置，高刷档目标满档帧率 | 不低于所选档位的一半 | 列表匀速滑动 |
| 输入事件转换耗时 | ≤5ms | — | 单事件 iOS → MotionEvent 转换 |

---

## 5 Android 生命周期与框架对接（最小可用）

### 5.1 Activity 生命周期六回调最小实现

以 Android Developers 官方生命周期模型为基准，实现最小可用流转。Activity 提供六个核心回调：`onCreate`、`onStart`、`onResume`、`onPause`、`onStop`、`onDestroy`，系统在 Activity 进入新状态时依次调用。最小实现仅保证状态机可流转、回调可被应用代码重写，不实现多窗口、旋转重建、进程回收等扩展场景。

| 回调 | 触发时机 | 最小实现职责 |
|---|---|---|
| onCreate | 系统首次创建 Activity | 执行一次性初始化：绑定布局、初始化视图与数据 |
| onStart | onCreate 之后，Activity 对用户可见 | 进入可见状态的准备 |
| onResume | Activity 开始与用户交互，位于栈顶 | 开始接收用户输入，主流程启动 |
| onPause | Activity 失去焦点但仍可见 | 暂停交互，保存轻量状态 |
| onStop | Activity 完全不可见 | 释放可见性相关资源 |
| onDestroy | Activity 被销毁 | 释放全部资源，结束生命周期 |

### 5.2 框架类最小集

仅实现渲染链路必需的最小框架类，其余框架类延后补全：

| 框架类 | 最小实现范围 | 说明 |
|---|---|---|
| android.content.Context | getResources、getPackageName、startActivity 桩 | 上下文入口，资源访问 |
| android.app.Activity | 生命周期六回调、setContentView、findViewById | 界面载体 |
| android.view.View / ViewGroup | 测量、布局、绘制流程、触摸分发入口 | 控件基类 |
| TextView / Button / ImageView | 文本绘制、点击回调、图片显示 | 首批基础控件 |
| LinearLayout | 水平/垂直排列基础布局 | 首批布局 |
| android.util.Log | v/d/i/w/e 日志输出 | 对接现有日志桥 |
| java.lang.String / Object / Class | 基础对象模型与字符串操作 | 运行时最小核心类 |

### 5.3 安卓对接 API 最小集

安卓对接 API 遵循最小可用原则，仅覆盖显示闭环必需的能力，并全部复用现有 native 侧实现：

| API 类别 | 最小实现 | 复用基础 |
|---|---|---|
| 资源访问 | getString/getColor/getDimension，resources.arsc 基础解析 | AXML 精确解析、资源解析前置 |
| 界面构建 | setContentView、findViewById、setOnClickListener | View 体系 + 触控分发 |
| 生命周期驱动 | launch() 创建 Activity 并驱动六回调 | SDRAppContainer 入口链路 |
| 日志与调试 | Log 系列输出到现有日志系统 | Android 基础库 liblog 桥 |
| 原生调用 | native 方法经 JNI 桥接到底层符号 | 宿主调用桥、libc/Android 基础库 |

---

## 6 体积策略（下限约束 · 越大越好）

### 6.1 体积目标

| 档位 | 目标体积 | 说明 |
|---|---|---|
| 底线 | **≥8MB** | 最低交付标准（不可低于） |
| 基本要求 | **≥50MB** | 完整 DEX 解释器 + Metal 渲染 + 基础 View 体系的实际交付线 |
| 理想区间 | **500MB ~ 1GB** | 主动填充完整 Skia 能力、扩展系统库与资源包、内置样本与素材 |

### 6.2 体积策略（主动填充，不做压缩）

原「裁剪编译、按需加载、strip 符号」等压缩取向**全部作废**。体积按"往里塞"策略主动扩容，手段包括但不限于：

- **完整 Skia 编译**：Metal 后端 + 全部 2D 绘制/文本/图像编解码模块全量编入，不做组件裁剪。
- **完整系统库与运行时常量**：扩展 Android 系统库覆盖范围、预置资源包与语言数据，不因体积删减能力。
- **资源全集打包**：字体、图标、纹理与素材资源按全集打包，不因体积改为按需下载。
- **符号与调试信息保留**：发布构建保留调试符号与必要元数据，便于线上问题定位。
- **多架构与预置样本**：按需保留多 slice 与预置测试 APK / DEX 样本库，服务验证与回归。
- **依赖照单引入**：能靠成熟依赖与工具提升效率与能力的，直接引入，不以体积为由拒绝。

> 原则：**性能与流畅度优先，能力优先，体积不设上限**。仅当体积异常膨胀到影响安装/启动时，才做定向排查。

---

## 7 依赖与工具链（有依赖用依赖、有工具用工具）

| 用途 | 采用依赖 / 工具 | 官方来源 |
|---|---|---|
| DEX 编译与发布优化 | Android build-tools：**d8**（调试/默认）、**R8**（发布） | Android Developers：d8 |
| 设备端编译参考 | dex2oat / ART Service（`verify` / `quicken`（已弃用）/ `space` / `speed` / `speed-profile` / `everything` 过滤器） | AOSP：Configure ART、ART Service |
| 渲染引擎 | **Skia**（Metal 后端，宿主侧静态库/Framework 链接） | Skia / SkiaSharp SKMetalView |
| 图形与上屏 | **Metal / MetalKit / CAMetalLayer / CAMetalDisplayLink**、QuartzCore | Apple Developer：Metal、CAMetalLayer |
| iOS 性能剖析 | **Instruments**（Game Performance、Metal System Trace、Metal Resource Allocations）、Metal Debugger、Metal Performance HUD | Apple Developer：Metal developer workflows |
| Android 侧系统追踪 | **Perfetto**（跨进程长时段系统追踪）、Systrace（遗留） | Android Developers：Tracing |
| 端到端与函数级基准 | **Macrobenchmark**（启动/滚动/交互）、**Microbenchmark**（热点函数）、Simpleperf（native 剖析） | Android Developers：Benchmarking |
| 触摸链路分析 | 主线程响应与输入延迟检查、ANR 红线自检 | Android Developers：Keep your app responsive |
| 构建与 CI | XcodeGen、GitHub Actions（`macos-26`） | 既有 CI 配置 |

---

## 8 性能验证与门禁（新增）

### 8.1 验证门禁

| 门禁 | 工具 | 通过标准 |
|---|---|---|
| DEX 正确性 | d8 + dex-smoke 对拍 | 与 Java 原生输出完全一致，覆盖率 ≥150 条指令 |
| 解释执行性能基线 | Microbenchmark 口径 | 整数 MIPS、方法调用耗时、类加载耗时三项基线不劣化 |
| 渲染帧率与卡顿 | Instruments（Game Performance / Metal System Trace）+ Metal Performance HUD | 高刷档满档或 ≥ 档位一半；无 PSO 运行时编译阻塞 |
| 交互端到端 | Macrobenchmark 口径 + 自建触控指标 | 单帧重绘 ≤60ms、首屏 ≤150ms、触控全链路 ≤60ms |
| 系统级追踪 | Perfetto（长时段跨进程追踪） | 无主线程长阻塞、无 VSync 缺失导致的掉帧 |
| 存量回归 | CI 全量用例 | native-loader / sandbox / syscall 代理 / ELF 装载链全回归通过 |

### 8.2 测试输出

每版构建输出：指令覆盖率、对拍通过率、三项性能基线（MIPS / 方法调用耗时 / 类加载耗时）、首屏耗时、帧率分布、触控全链路耗时、体积实测值（对照第 6 章档位）。

---

## 9 执行顺序与验收节点

严格自底向上执行，不跳步：

| 步骤 | 内容 | 验收标准 | 体积参考（累计） |
|---|---|---|---|
| 第一步 | 完成第三阶段 DEX 解释器收尾四项 | CI 全量验证通过 | ≥12MB |
| 第二步 | DEX 解释器全量指令补全与性能优化 | 指令覆盖率 ≥150 条，dex-smoke 全绿 | ≥20MB |
| 第三步 | Skia Metal 渲染通道打通 | 基础图形文字 GPU 加速渲染上屏 | ≥30MB |
| 第四步 | 最小 View 体系与触控交互 | 基础控件可显示可点击，性能达标 | ≥40MB |
| 第五步 | APK 完整加载 → 启动 → 显示闭环 | 导入测试 APK 可启动、显示、交互 | **≥50MB（不设上限，向 500MB–1GB 填充）** |

**验收总目标**：最小可用测试版可导入 APK、可启动、可显示界面、可基础交互，整条链路无断点；渲染与触控性能满足第 4.5 节指标；存量 native 层功能全量回归通过。

---

## 附录 A 双官网核查结论与来源（本次合并）

### A-1 阶段四 V2.1 原有核查结论（保留）

| 技术点 | 核查结论 | 权威来源 |
|---|---|---|
| Skia iOS Metal 后端 | Skia 官方支持 iOS Metal 硬件加速渲染，SKMetalView 为硬件加速视图 | Microsoft Learn：SkiaSharp.Views.iOS.SKMetalView |
| Metal memoryless 临时渲染目标 | MTLStorageMode.memoryless 避免分配系统内存，临时目标驻留 GPU tile memory | Apple Developer：Reducing the memory footprint of Metal apps |
| Metal dontCare storeAction | 中间渲染目标不写回系统内存，减少带宽与写回 | Apple WWDC 2020：Optimize Metal Performance |
| Skia 运行时着色器编译卡顿 | 首次出现新效果时运行时编译着色器，产生约 20～100ms 首帧卡顿 | eCorpIT / MVP Factory 对 Skia on iOS 的实测分析 |
| 着色器 PSO 预热方案 | 启动期离屏 Canvas 触发常用绘制，前置 PSO 编译，消除首次交互卡顿 | MVP Factory：Compose Multiplatform Skia on iOS Profiling |
| UIScrollView 触摸延迟 | delaysContentTouches 默认 true，系统约 150ms 判断滑动意图；设 false 立即分发 | Apple Developer：delaysContentTouches 文档 |
| Dalvik dexopt 优化机制 | 虚方法索引→vtable 索引、字段索引→字节偏移、小类型合并 32-bit、常用小方法内联 | Debian sources：Dalvik Optimization and Verification With dexopt |
| ART quicken 模式 | Android 11 及以下对 DEX 指令做解释器性能优化 | AOSP：Configure ART（quicken） |
| d8 命令行工具 | 输入 .class 字节码输出 DEX，支持 Java 8 特性，官方工具 | Android Developers：d8 工具文档 |
| Activity 生命周期六回调 | onCreate/onStart/onResume/onPause/onStop/onDestroy | Android Developers：Activity 生命周期官方文档 |
| Dalvik 指令格式 | 指令为 16 位 code unit 倍数，35c/3rc 等格式按位域定义 | AOSP：Dalvik bytecode format |
| DEX try_item 结构 | start_addr/insn_count/handler_off 字段定义 | AOSP：Dalvik executable format |
| Android View 绘制流程 | 框架请求根节点绘制，遍历测量与绘制布局树 | Android Developers：How Android Draws Views |
| iOS CADisplayLink 帧率控制 | iOS 15+ 用 preferredFrameRateRange（CAFrameRateRange），preferredFramesPerSecond 已废弃 | Apple Developer：CADisplayLink.preferredFrameRateRange |
| iOS ProMotion 120Hz 优化 | UIScreen.maximumFramesPerSecond 查询能力，高影响动画用 80～120Hz 区间 | Apple WWDC2021 10147 / Optimizing ProMotion displays |
| Android 帧率控制 | Surface.setFrameRate（API 30+）传确切帧率，系统按倍数选择刷新率 | Android Developers：帧速率（Frame rate）官方文档 |
| Android VSync/Choreographer | 渲染由 VSync 事件驱动，多刷新率 90/120Hz 由 SurfaceFlinger 协商 | AOSP：Multiple refresh rate / Choreographer |

### A-2 Apple Developer 官网核查清单（本次新增）

| # | 官方机制 | 一句话做法 | 来源 |
|---|---|---|---|
| 1 | MTLStorageMode.memoryless | 单 pass 内临时纹理（depth/stencil/MSAA）设 memoryless，只驻 tile memory 不占系统内存 | developer.apple.com/documentation/metal/choosing-a-resource-storage-mode-for-apple-gpus |
| 2 | Load/Store Actions | 中间目标用 dontCare load/store，仅最终 attachment 用 store；memoryless 禁止 load/store | developer.apple.com/documentation/metal/setting-load-and-store-actions |
| 3 | TBDR 管线组织 | 同类命令合并进同一 render pass，clear 用 LoadActionClear，tile↔system memory 往返降为 1 次 | developer.apple.com/videos/play/wwdc2023/10125 |
| 4 | Imageblocks / Tile Shaders | tile memory 内定义 per-pixel 结构，fragment 与 tile 阶段共享本地内存 | developer.apple.com/documentation/metal/.../about_imageblocks |
| 5 | CAMetalLayer | 用 nextDrawable() + presentDrawable: 上屏，渲染循环包 @autoreleasepool | developer.apple.com/documentation/quartzcore/cametallayer |
| 6 | Drawable 池管理 | 尽量晚取 drawable、尽快释放强引用，避免 nextDrawable 阻塞到下一刷新 | developer.apple.com/documentation/metal/drawable_objects |
| 7 | framebufferOnly / drawableSize | 设 framebufferOnly=YES，按 nativeScale/nativeBounds 精确匹配屏幕像素 | developer.apple.com/documentation/metal（Render Context 章节） |
| 8 | CAMetalDisplayLink（iOS 17+） | 替代 CADisplayLink，配合 preferredFrameRateRange / preferredFrameLatency 取得精确时序 | developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link |
| 9 | CADisplayLink.preferredFrameRateRange | 用 CAFrameRateRange(minimum,maximum,preferred) 给出帧率提示（如 80/120/120） | developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays |
| 10 | CADisableMinimumFrameDurationOnPhone | iPhone Info.plist 加该键，>60Hz 提示才生效（iPad Pro 不需要） | 同上（Optimizing for ProMotion displays） |
| 11 | CADisplayLink 取代 Timer | 自定义渲染循环必须用 CADisplayLink，相近时序动画合并同一 displayLink | 同上 |
| 12 | delaysContentTouches | 默认 true 延迟约 150ms 派发 touch-down；需即时高亮的按钮设 false | developer.apple.com/documentation/uikit/uiscrollview/delayscontenttouches |
| 13 | canCancelContentTouches / touchesShouldCancel(in:) | 与 delaysContentTouches=false 配套，拖动手势触发时把触摸交还 scrollView | 同上 |
| 14 | Metal 内存清单（官方） | 用 Memory Report / Metal Resource Allocations 监测，配压缩纹理、volatile、heap、memoryless 降本 | developer.apple.com/documentation/metal/reducing-the-memory-footprint-of-metal-apps |
| 15 | MTLHeap | 多个不并用的瞬态资源共享同一块内存分配 | 同上 |
| 16 | MPS Tuning Hints | 不等 waitUntilCompleted 再编码下一命令缓冲，CPU/GPU 并发；预分配复用资源；批处理 compute | developer.apple.com/documentation/metalperformanceshaders/tuning-hints |
| 17 | 帧率提示与系统调度协同 | 选用能达成视觉流畅的最低帧率省电，并向系统提供时序提示以做节能/热缓解调度 | developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link |
| 18 | Game Performance Template（Instruments） | Product > Profile 选 Game Performance，定位异常长 display 实例与 GPU 过载 | developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app |
| 19 | Metal System Trace / Metal developer workflows | CPU/GPU 并行时间线与内存占用可视化，配合 Metal Debugger 定位瓶颈 | developer.apple.com/documentation/xcode/metal-developer-workflows |
| 20 | Metal Performance HUD | 运行期叠层查看 FPS/内存/frame interval，可用 developerHUDProperties 自定义 | 同上 |
| 21 | OSSignposter + Metal System Trace | 用 OSSignposter 标记 CPU 区间，与 GPU 执行放在同一时间线定位卡顿 | Apple 工程师实践（OSSignpost + Metal Trace） |

### A-3 Android Developers 官网核查清单（本次新增）

| # | 官方机制 | 一句话做法 | 来源 |
|---|---|---|---|
| 1 | Surface.setFrameRate()（API 30+） | 声明目标帧率，系统据所有 Surface 提示选择刷新率；传精确小数，暂停/结束传 0 清除 | developer.android.com/media/optimize/performance/frame-rate |
| 2 | Display.getSupportedModes() / getRefreshRate() | 安全查询支持刷新率集合，注册 DisplayManager 监听或 NDK AChoreographer_registerRefreshRateCallback，勿硬编码 60Hz | 同上 |
| 3 | preferredDisplayModeId（旧版回退） | setFrameRate 不可用时退用；因不告知渲染意图，官方不推荐 | 同上 |
| 4 | SurfaceControl.Transaction.setFrameTimeline()（API 35+） | 取 vsyncId 后调用，让 SurfaceFlinger 按期望呈现时间上屏 | developer.android.com/reference/android/view/SurfaceControl.Transaction |
| 5 | Choreographer | postFrameCallback 把渲染对齐 VSync，动画/输入/绘制统一编排；自渲染线程禁用 Timer | developer.android.com/reference/android/view/Choreographer |
| 6 | Choreographer.postVsyncCallback（API 33+） | 接收含 deadline 与 expected present time 的 FrameData，按延迟需求选帧 | developer.android.com/reference/android/view/Choreographer.VsyncCallback |
| 7 | Android Frame Pacing 库 | 游戏/自定义渲染器处理多刷新率下的正确帧 pacing，配 eglPresentationTimeANDROID 加深管线 | Android 高刷渲染官方实践 |
| 8 | Hardware Acceleration | 目标 API ≥14 默认开启，View Canvas 绘制走 GPU（会多占 RAM） | developer.android.com/guide/topics/graphics/hardware-accel |
| 9 | Display List / RenderNode | 硬件加速下以 RenderNode 构建可独立更新的渲染层级，仅重录变更节点；变换用属性避免重录 | developer.android.com/reference/android/graphics/RenderNode |
| 10 | setLayerType(LAYER_TYPE_HARDWARE) | 拖拽/动画期间把视图缓存为 GPU 纹理，结束恢复 NONE | developer.android.com/guide/topics/graphics/hardware-accel |
| 11 | RenderThread（Android 5.0+） | 主线程只构造 Display List，渲染交 RenderThread，主线程专注输入 | 同上 |
| 12 | 主线程非阻塞（ANR 红线） | 5 秒未响应输入即 ANR，I/O 与重计算移出主线程 | developer.android.com/topic/performance/anrs/keep-your-app-responsive |
| 13 | DiffUtil / SortedList | 计算最小更新替代 notifyDataSetChanged，消除列表滚动卡顿 | developer.android.com/topic/performance/vitals/render |
| 14 | getHistoricalX/Y + VelocityTracker | 触摸事件批量发送，用历史坐标画平滑轨迹，用 VelocityTracker 算速度 | developer.android.com/topic/performance/vitals/render |
| 15 | requestUnbufferedDispatch + preferredRefreshRate | 绘图交互降低事件缓冲延迟，并请求高刷 | developer.android.com/topic/performance/vitals/render |
| 16 | 事件分发层做减法 | 复杂手势在 ACTION_UP 一次性结算，MOVE 路径只收集坐标，重算法移到绘制阶段 | developer.android.com/topic/performance/vitals/render |
| 17 | d8 | Java/Kotlin 字节码编译为优化 DEX；发布加 --release，配 --min-api/--main-dex-list/--file-per-class | developer.android.com/tools/d8 |
| 18 | dexopt / ART Service（Android 14+） | 后台空闲按 JIT profile 做 speed-profile 编译（bg-dexopt） | source.android.google.cn/docs/core/runtime/configure/art-service |
| 19 | dex2oat | 设备端 .dex → .oat/.vdex/.art，支持 --compiler-filter=speed-profile --instruction-set=arm64 | 同上 |
| 20 | Perfetto（Android 10+） | 跨进程长时段系统追踪，ui.perfetto.dev 分析 | developer.android.com/topic/performance/tracing |
| 21 | Systrace（遗留） | Android 10 前命令行短时段追踪，Perfetto UI 可兼容打开 | 同上 |
| 22 | Macrobenchmark | 外部注入事件测启动/滚动/动画端到端场景，可入 CI 防回归 | developer.android.com/topic/performance/benchmarking/benchmarking-overview |
| 23 | Microbenchmark | 循环内基准热点函数/算法，先 Profiler 定位再复跑降噪 | 同上 |
| 24 | Memory / CPU Profiler + Simpleperf | 查内存压力与泄漏、看线程活动、剖析 Java 与 C++ 原生代码 | developer.android.com/topic/performance/inspecting-overview |

### A-4 本次合并引入的落地项索引

| 落地位置 | 引入的官方机制 |
|---|---|
| 3.3 Metal 渲染规范 | A-2 #1–#9、#15、#16（memoryless、load/store、TBDR、imageblocks、drawable 池、framebufferOnly、Metal Display Link、MTLHeap、CPU/GPU 并发） |
| 3.7 刷新率适配 | A-2 #9–#11、#17；A-3 #1–#4、#5–#7 |
| 4.1–4.4 触控链路 | A-2 #12、#13；A-3 #12、#14–#16 |
| 2.3 / 2.4 解释器与工程化 | A-3 #17–#19 |
| 第 8 章 性能验证 | A-2 #18–#21；A-3 #20–#24 |

---

**文档结束**。本版为阶段四 V2.1 与双官网核查结论的合并稿，供审阅；审阅确认后再决定是否进入实施阶段。
*（内容由AI生成，仅供参考）*

---

## 附录 B  执行优先级、后端架构与商业化规划（V4.1 追加）

> 本附录为 2026-09-20 追加内容，原文正文不作任何修改。

### B.1  执行优先级（去阶段化，按落地先后排序）

| 优先级 | 内容 | 说明 |
|---|---|---|
| 第一优先级 | DEX 解释器全量闭环 | 先收尾四项（launch() 接真实执行、Swift 侧 DEX 对拍入口、d8 集成 CI、体积口径修订），再补全指令集与执行优化；渲染、交互、APK 加载全部依赖此底座 |
| 第二优先级 | Metal 渲染 + 触控 + 三档刷新率 + 最小可用生命周期 | Skia Metal 通道、11 项官方最佳实践、30/60/120 三档适配、触控全链路、基础 View 体系，产出"能跑、能显、能点"版本 |
| 第三优先级 | 全量补齐 + 包体拉满 + 工程化门禁 + 商业化体系 | 见 B.1.1 |

#### B.1.1  第三优先级全量补齐清单

1. **DEX 解释器剩余指令全量补全**：浮点、长整型、异常处理、多态调用、全类型数组等无遗漏补完。
2. **原生 SO 库全量补齐**：libc 剩余函数、全量系统调用、Skia 完整功能库、全部依赖原生库一并编译补齐。
3. **生命周期升级为完整**：从最小可用升级为完整 Activity 生命周期，覆盖启动、前后台切换、配置变更、销毁全节点。
4. **包体体积拉满**：完整 Skia 全功能编译、系统库与资源全集、保留调试符号、预置样本库、全量依赖引入，按目标体量做满。
5. **工程化与性能门禁**：官方工具链全量对接，双端性能剖析工具作为发布验收门槛，达标方可放行。
6. **商业化体系**：见 B.3。

### B.2  后端双节点架构

| 节点 | 技术栈 | 职责 |
|---|---|---|
| API 节点 | Java | 对外 API 接口服务，APP 主对接入口 |
| 后台节点 | PHP | 后台管理显示页（管理端 Web） |

- **双节点并行**：Java API 节点与 PHP 后台节点双节点部署，各司其职。
- **APP 侧预留**：NebulaDex 客户端预留双 API 节点对接位，支持主备切换与分流。
- **落地必备**：域名、数据库、服务器落点必须齐备，不悬空。
- **技术栈对齐**：沿用此前半成品情侣项目的后端架构模式（Java API + PHP 后台 + 数据库），保持技术栈一致，降低维护成本。

### B.3  商业化与分发体系

| 模块 | 内容 |
|---|---|
| 闭源版本架构 | 核心代码闭源，保护运行时与渲染实现 |
| 网络更新服务 | OTA 在线更新，客户端拉取最新版本 |
| 公告推送 | 服务端下发公告，客户端展示 |
| 强制更新 | 版本低于最低支持版时拦截旧版本，引导强制升级 |
| VIP 权限体系 | 会员权益分级，按等级开放功能与服务 |

---

**文档结束（V4.1 追加版）**。
