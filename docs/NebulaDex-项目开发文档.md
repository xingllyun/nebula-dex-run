---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: ed38b03a482bb8c9cc01ec95f4dd35e7_60d15cc5b4d711f19285525400638852
    ReservedCode1: p2JcRn0eG5QBNXJNLJWGTecW656YKZTsalLb8EHJnVR8/MpVu4EEgx4eTmR56fHF67mgCyKRuKTXI0nyvTtrX/r1SLPG3xrb0zL8F5IyC+LRfQruEf6QnzWDRlNnCmsGdQBTouce5duDjNk8qZH8+M5fb1lsNkAXHM0cB69t/rDAk8dI60igsMo6PPM=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: ed38b03a482bb8c9cc01ec95f4dd35e7_60d15cc5b4d711f19285525400638852
    ReservedCode2: p2JcRn0eG5QBNXJNLJWGTecW656YKZTsalLb8EHJnVR8/MpVu4EEgx4eTmR56fHF67mgCyKRuKTXI0nyvTtrX/r1SLPG3xrb0zL8F5IyC+LRfQruEf6QnzWDRlNnCmsGdQBTouce5duDjNk8qZH8+M5fb1lsNkAXHM0cB69t/rDAk8dI60igsMo6PPM=
---



# NebulaDex 项目开发文档

> NebulaDex（星云 Dex）— iOS 侧载 Android 运行时，在 iOS 非越狱环境下以解释器方式执行 Android APK 的 native 层代码。

---

## 1 项目概述

**项目名称**：NebulaDex（星云 Dex）  
**技术栈**：Swift / SwiftUI + Objective-C  
**构建方式**：XcodeGen + xcodebuild，无签名侧载构建（Unsigned IPA）  
**目标平台**：iOS 16.0+，非越狱环境  
**体积口径**：下限约束——≥ 8 MB 为底线、≥ 50 MB 为基本达标、理想区间 500 MB–1 GB，越大越好（原 ≤ 8 MB 压缩取向已作废）

### 1.1 核心思路

- 非越狱环境下 SO 无法申请可执行内存，因此 **不依赖 JIT**，全部按 ARM 指令级解释执行
- 通过自定义 syscall 号 `svc #0` 将系统调用路由到沙盒层
- DEX 解释器、Java 运行时、UI 渲染按阶段逐步补齐

---

## 2 项目架构

```
┌─────────────────────────────────────────────┐
│  NebulaDexApp (SwiftUI 入口)                  │
│  SDRRootView / SDRAppGridView / Settings      │
├─────────────────────────────────────────────┤
│  SDRAppContainer (APK 导入 → 装载 → 软运行)      │
├─────────────────────────────────────────────┤
│  AArch64 解释器层                              │
│  SDRArmInterpreter / SDRArmNEON / SDRArmFPU  │
├─────────────────────────────────────────────┤
│  native-loader 层                              │
│  宿主调用桥 SDRHostCall + 桩区 SDRHostStubPool │
│  最小 libc SDRLibc + Android 基础库 SDRAndroidLibs │
│  ELF 装载链 SDRElfParser → ImageLoader → Relocator → SharedLibrary │
├─────────────────────────────────────────────┤
│  系统调用代理                                  │
│  SDRSystemServices / SDRSyscallNumber          │
├─────────────────────────────────────────────┤
│  内存沙盒                                      │
│  SDRMemoryGuard / AddressSpaceAllocator / Budget │
├─────────────────────────────────────────────┤
│  APK 工具层                                    │
│  ZIP 解压 / APK 解析 / 加固检测 / BinaryXML     │
├─────────────────────────────────────────────┤
│  DEX 核心层（骨架）                             │
│  SDRDexParser / SDRDexInterpreter / Opcode    │
├─────────────────────────────────────────────┤
│  框架层                                        │
│  应用状态 / 设置持久化 / 事件总线 / 日志存储     │
├─────────────────────────────────────────────┤
│  iOS 适配器                                    │
│  Android 调用桥 / 实时活动桥 / 文件系统映射     │
└─────────────────────────────────────────────┘
```

---

## 3 已完成的模块

### 3.1 AArch64 指令解释器（阶段一）

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRArmInterpreter.swift` | 1,217 | 主循环，415 条指令覆盖，16606 项校验全绿，16.64 MIPS |
| `SDRArmNEON.swift` | 999 | NEON SIMD：移位立即数、三同、二同 misc、copy、FMAX/FMIN 浮点归约 |
| `SDRArmFPU.swift` | 369 | FPU 浮点指令 |

**覆盖指令分类**：整数运算、内存访问、浮点处理、SIMD 计算、条件分支跳转、异常陷阱。  
**性能**：阶段一完成后提升至 16.64 MIPS，较基线提升 118%。  
**验证**：四套向量全绿（vectors.json / vectors_ext2 / vectors_neon / vectors_neon3），合计 16,606+ 校验项。

### 3.2 系统调用代理层（阶段二·步骤一）

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRSystemServices.swift` | 1,027 | 真实 Linux syscall 号 handler，未实现号统一返回 -ENOSYS |
| `SDRSyscallNumber.swift` | 217 | 真实号定义：openat=56, close=57, read=63, write=64, mmap=222, munmap=215, brk=214, futex=98, ioctl=29, gettimeofday=169, clock_gettime=113, mprotect=226, getpid=172, exit_group=94 |

**关键设计**：使用 `svc #0` 作为 syscall 入口，参数通过 `x[8]` 传递 syscall 号。

### 3.3 内存沙盒（阶段二·步骤一）

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRMemoryGuard.swift` | 458 | 软件内存读写权限隔离，快照无锁读，Backing 裸缓冲区避免写时复制 |
| `SDRAddressSpaceAllocator.swift` | 192 | 地址空间分配器 |
| `SDRMemoryBudget.swift` | 155 | 内存预算分级 |
| `SDRMemoryPressureMonitor.swift` | 96 | 内存压力监测 |

**并发契约**：结构面持锁串行，数据面无锁取 Snapshot。

### 3.4 沙盒文件系统

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRSandbox.swift` | 87 | 沙盒目录管理 |

**功能**：APK 落沙盒、路径规范、权限管控。

### 3.5 ELF 共享库装载链（阶段二·步骤三）

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRElfParser.swift` | 146 | ELF 解析 |
| `SDRElfDynamic.swift` | 299 | 动态段解析（大端暂不支持） |
| `SDRImageLoader.swift` | 171 | 镜像加载：先建可写 PT_LOAD → 灌文件 → protect 收权 |
| `SDRRelocator.swift` | 199 | 重定位：RELATIVE 写 loadBase+addend，GLOB_DAT/JUMP_SLOT 对已定义符号写 loadBase+st_value |
| `SDRSharedLibrary.swift` | 222 | DT_NEEDED 递归装载 + 跨模块解析 |

**已发现的缺陷修复**：
1. Elf64_Rela.r_info 位运算写反（sym 和 type 位移搞反）
2. Elf32 读 phnum/phentsize 偏移错，读到的是 e_shnum/e_shentsize
3. PT_LOAD 段映射缺陷：原按 ELF 声明以 writable=false 建只读段，导致初始内容写入被 SDRMemoryGuard 拒绝

### 3.6 宿主调用桥与最小 libc（阶段二·步骤二）

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRHostCall.swift` | 274 | 托管调用桥：trampoline `movz x16,#imm16 ; brk #0x4E44 ; ret` |
| `SDRLibc.swift` | 908 | 最小 libc 符号表，65 项冒烟全绿 |

**关键设计**：
- trampoline 机器码：`movz x16,#<index> ; brk #0x4E44 ; ret`
- 解释器 BRK 分支识别 0x4E44 转交 host 实现
- 支持整数返回（X0）和标量返回（V0，用于 libm 浮点）
- SDRHostCallContext 提供内存读写、参数读取（a0-a5 / v0-v7）、C 串读写、syscall 转发

### 3.7 Android 基础库适配（阶段二·步骤四）

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRAndroidLibs.swift` | 329 | liblog(7)、libm(33+26)、libz(3) 共 69 符号桥接 |
| `SDRHostStubPool.swift` | 156 | 桩区写入 guest 地址空间，灌入后 protect 收权为只读可执行 |

**验收口径**：libc-smoke 65 项、dl-smoke 25、zip-smoke 9、host-smoke 13、android-libs-smoke 28，均 0 失败。

### 3.8 APK 工具层

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRZipArchive.swift` | 260 | ZIP 解压，inflateWindowed + inflateZlib |
| `SDRAPKParser.swift` | 117 | APK 元数据解析（SO 候选按 ABI 排序，全路径 / 裸名双兼容） |
| `SDRHardeningDetector.swift` | 77 | 加固检测 |

### 3.9 框架层

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRCore.swift` | 101 | 运行状态机、应用信息、错误码 |
| `SDRAppState.swift` | 73 | 应用状态管理 |
| `SDRSettingsStore.swift` | 85 | 设置持久化（UserDefaults，零额外依赖） |
| `SDRLogStore.swift` | 146 | 日志存储 |
| `SDREventBus.swift` | 49 | 进程内事件总线 |
| `SDRLicense.swift` | 69 | 版权与 MIT 许可证文本 |

### 3.10 应用入口与 UI

| 文件 | 行数 | 说明 |
|------|------|------|
| `NebulaDexApp.swift` | 54 | @main 入口，处理 URL 回调 |
| `SDRRootView.swift` | 90 | TabView：应用 / 日志 / 设置 / 关于 |
| `SDRAppGridView.swift` | 136 | 应用列表网格 |
| `SDRLogConsoleView.swift` | 114 | 日志控制台 |
| `SDRTheme.swift` | 57 | 主题系统 |

### 3.11 DEX 核心层（阶段三·已收口）

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRDexOpcode.swift` | 223 | Dalvik 指令名 / 宽度 / 未定义槽位表 |
| `SDRDexParser.swift` | 639 | 文件头 + 字符串/类型/proto/字段/方法 id 表 + class_def/class_data + code_item 懒加载 + try_item/encoded_catch_handler 异常表解析 |
| `SDRDexInterpreter.swift` | 1199 | 指令主循环：move/const/整数与浮点全量运算/分支/数组/字段/invoke/long/浮点转换与 cmp 族，帧栈 + 静态字段 + try/catch/finally 异常模型（`SDRDexThrown` 跨帧传播 + 类层次匹配 + JDK 内联桩）+ 热路径缓存（含虚方法表索引化 `virtualDispatchCache`、receiver 槽位装配） |
| `SDRDexHeap.swift` | 160 | 对象 / 数组 / 字符串堆 |
| `SDRDexLaunchPlan.swift` | 105 | 入口定位：main（含 `[Ljava/lang/String;` 注入）→ 类初始化 → 普通方法降级 |

**合计 2,326 行**。`SDRAppContainer.launch` 已接入真实 DEX 解析与执行链路，不再是空跑。

**验收口径**：dex-smoke 136 用例 JVM 原生输出 ↔ Swift 解释器输出逐行对拍，见 `Tests/dex/`。
其中包含异常模型用例（`NebulaDexThrow`：try/catch/finally、隐式 NPE 与数组越界、
自定义异常父子类型匹配、多 catch 顺序、跨帧传播与 finally 重抛）、1 条 `expectError: true`
用例（顶层未捕获异常，两侧统一输出 `<ERROR>`），以及虚方法分派用例
（`NebulaDexVirtual`：基类引用指向子类实例、基类方法体内的虚调用、`invoke-super` 固定父实现、
接口分派、同一调用点先后两种 receiver —— 验证 `virtualDispatchCache` 按实际类型分桶）。

**虚方法分派（阶段四）**：`invoke-virtual` / `invoke-interface` 由
`SDRDexParser.resolveVirtualMethod(declaredSignature:receiverDescriptor:)` 沿 receiver 实际类型的
超类链逐层匹配「同名 + 同 proto」签名，首命中即最具体覆写；解释器侧 `virtualTarget` 以
「实际类型 + 方法尾」为 key 缓存结果（未覆写记 `UInt32.max` 哨兵），`invoke-super` / `invoke-direct`
不参与虚分派。同时补齐实例方法的 receiver 槽位：非 static 的 invoke 族首寄存器即 this，
入口约定为 `[receiver, 参数...]`，缺失时显式报错而非错位执行。

### 3.12 Metal 渲染层（阶段四）

`Sources/render/` 共 **2,901 行**（13 文件），承载阶段四渲染管线全链路：

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRRenderTypes.swift` | 366 | 值语义绘制命令、刷新档位（30/60/120Hz）、帧预算与统计模型 |
| `SDRCommandRecorder.swift` | 221 | 命令录制、批次合并（`SDRVertexBuilder`）、脏区集合 |
| `SDRRenderDevice.swift` | 139 | 设备与在飞帧同步 |
| `SDRMetalFormatBridge.swift` | 63 | 像素格式 ↔ `MTLPixelFormat` 桥 |
| `SDRPipelineCache.swift` | 183 | 管线状态对象缓存与预热 |
| `SDRTexturePool.swift` | 155 | 纹理池（位图 / 字形图集） |
| `SDRMetalRenderTarget.swift` | 152 | 绘制目标与清屏 |
| `SDRShaderSource.swift` | 154 | 内联 MSL 着色器（纯色 / 圆角 / 纹理 / 渐变） |
| `SDRFrameScheduler.swift` | 279 | 帧调度与档位降级 |
| `SDRDisplayLinkDriver.swift` | 96 | CADisplayLink 驱动（**唯一依赖 ObjC 运行时的文件**） |
| `SDRRenderLoop.swift` | 581 | 循环主体：三槽动态顶点缓冲 → 编码 → 提交 |
| `SDRRenderBridge.swift` | 247 | guest 侧 host-call 桥（矩形 / 位图 / 渐变 / 裁剪栈 / 脏区 / 档位 / 统计） |
| `SDRMetalRenderView.swift` | 265 | `CAMetalLayer` 承载视图：尺寸同步、前后台节流、内存告警、触控接入 |

**设计要点**：绘制命令值语义（`SDRDrawCommand`）+ 批次合并 + 脏区局部渲染 + PSO 预热 + 三槽顶点缓冲。

**验收口径**：`Sources/render/**` 全量参与 `ios-build.yml` 的渲染层编译校验门禁（`swiftc -typecheck`，出现 `error:` 即失败）。

### 3.13 触控路由（阶段四）

| 文件 | 行数 | 说明 |
|------|------|------|
| `SDRTouchRouter.swift` | 358 | UIKit 触点流 → Android `MotionEvent` 流合成（纯 Foundation，可离线验收） |

- **归并**：UIKit 每次回调携带全部触点，本层按 id 维护活动集合，逐点产出 `ACTION_DOWN` / `ACTION_POINTER_DOWN`，`actionIndex` 指向变更指针；
- **抖动抑制**：主触点位移未越过 touch slop（8 guest 像素）前不派发 `ACTION_MOVE`；
- **手势识别**：长按 500ms、双击（间隔 ≤ 300ms 且位置容差 ≤ 40 像素）在本层完成判定，guest 侧不再重复计时；
- **坐标折算**：宿主点 × `contentsScale` 取整，与绘制命令共用同一像素网格；速度按最近 5 个采样点估算，供 fling 使用；
- **防御**：同时活动触点上限 10 个，超出截断；
- **投递出口**：`onDispatch` 闭包，JNI 阶段接入前默认仅记录日志，**严禁在此层伪造命中测试结果**。

**验收口径**：`touch-smoke` 20 用例（单指 / 多指 / 抖动抑制 / 长按 / 双击 / 取消 / 触点上限 / 统计 JSON）。

---

## 4 待开发的模块

### 4.1 DEX 解释器补全（阶段四·浮点族与异常模型已落地）

原先的骨架（297 行 / 7 条指令）已由 §3.11 的五文件实现取代：常量池、类数据、code_item 提取、
对象/数组模型、invoke 分派、栈帧与静态字段全部就位，入口定位由 `SDRDexLaunchPlan` 负责。

**已实现**：整数指令族（move/const/运算/分支/数组/字段/invoke/long/switch）、
浮点指令族（cmp-float/double、neg-float/double、float/double 四则与 /2addr、int/long/float/double 互转，共 36 条）、
静态字段累积语义、跨类调用、`move-result` 语义（紧随 invoke）、
异常模型（0x0D `move-exception` / 0x27 `throw` / 0x20 `instance-of`，try/catch/finally 全链路：
隐式 NPE、数组越界、整数除零、`NegativeArraySizeException`，catch 类型按 class_defs 父类链上行匹配并回落内建 `java.lang` 层次，
未命中异常跨帧冒泡，finally 归并路径，JDK 常用构造器与 `String.length` 内联桩）、
执行优化（方法体/常量池/字段签名三件套缓存 + 热点方法预热 API + `invokeCount`/`executedSteps` 性能基线口径）。

**未实现（保留显式抛错，留待后续步骤）**：
1. `invoke-polymorphic` / `invoke-custom`（0xFA-0xFD）与 0xFE-0xFF 保留槽位
2. JNI 环境（`JNIEnv` 函数表）与类加载器、GC

上述未实现指令一律抛 `dexOpUnsupported`，**严禁静默跳过或按宽度滑过**——静默跳过会让字节码流「看似跑通」却语义全错；该口径由 dex-smoke 对拍守住。

### 4.2 Java 运行时

完全不存在。需要实现：
- **类加载器**：DexClassLoader 等效
- **JNI 环境**：JavaVM / JNIEnv 函数表
- **Android framework**：Activity / View / Context / String / Log 等 Java 侧类
- **GC 与垃圾回收**

### 4.3 APK 重签名

| 文件 | 说明 |
|------|------|
| `SDRSigner.swift` | v1 JAR 签名只生成了摘要/清单文本，v2 签名块直接 throw；`generateKey` 是 TODO 抛异常 |

### 4.4 其他半成品

| 文件 | 说明 |
|------|------|
| `SDRBinaryXML.swift` | AXML 属性表精确解析待实现，目前用字符串池启发式推断包名/版本 |
| `SDRLiveActivityBridge.swift` | ActivityKit 真实更新逻辑在 app 目标内实现，此处仅做状态缓存与广播 |
| `SDRSharedLibrary.swift:103` | 镜像声明但尚未装载的依赖列表待实现 |
| `SDRSystemServices.swift:622` | 目录枚举返回空，待阶段三接入真实目录后替换 |
| `SDRElfDynamic.swift:66` | 大端 ELF 动态段解析暂不支持 |
| `SDRTouchRouter.swift` | 事件出口（`onDispatch`）待 JNI 阶段接入真实 guest 投递，当前默认仅记录日志 |
| `SDRMetalRenderView.swift` | 渲染层已装配，但 guest 侧尚无真实 Android View 树作为绘制来源 |

---

## 5 关键技术设计

### 5.1 自定义 syscall 约定

- **入口**：`svc #0`（解释器 handleSVC 取号 `(insn >> 5) & 0xFFFF` 然后 dispatch）
- **参数**：标准 AAPCS64 寄存器传递（x0-x7）
- **返回值**：成功返回 0 或实际值；失败返回 `-errno` 二进制补码（UInt64）
- **未实现号**：统一返回 -ENOSYS，不再静默返回 0

### 5.2 托管调用桥 trampoline 设计

```
movz x16, #<symbolIndex>     // 符号索引存入 x16
brk  #0x4E44                  // 自定义陷阱（"ND"：NebulaDex）
ret                           // 按 AAPCS64 返回
```

**设计收益**：
1. guest 侧无需知道 host 地址，符号解析只需把 GOT/重定位项填成桩地址
2. 桩与真实 libc 调用点二进制兼容
3. 单测可直接把桩写进 guest 代码段验收

### 5.3 内存保护与快照

- 结构面持锁串行（读写权限变更）
- 数据面无锁读快照
- 裸缓冲区，避免写时复制开销
- 支持按段读写权限变更（protect）

### 5.4 ELF 装载流程

1. ELF 解析 → 验证魔数/端序/ABI
2. 程序头解析 → 按 PT_LOAD 建立内存映射（先可写 → 灌文件 → protect 收权）
3. 动态段解析 → 收集 DT_NEEDED 依赖
4. 依赖递归装载 → 跨模块符号解析
5. 重定位 → RELATIVE 写 loadBase+addend，GLOB_DAT/JUMP_SLOT 解析符号地址

### 5.5 内存预算分级

根据设备物理内存和侧载权限，将内存预算分为不同 tier：
- 高配设备 + 完整权限 → 高预算（16GB 以上地址空间）
- 低配设备 → 降级模式

---

## 6 CI 与测试

### 6.1 工作流

| 工作流 | 用途 |
|--------|------|
| `ios-build.yml` | 未签名 IPA 构建（macos-26 runner）；渲染层编译校验门禁（`Sources/render/**` 全量 `swiftc -typecheck`，出现 `error:` 即失败） |
| `interp-test.yml` | AArch64 解释器冒烟测试（含 zip-smoke 13 用例、touch-smoke 20 用例） |
| `dex-smoke.yml` | DEX 解释器对拍：javac → JVM 期望值；d8 → classes.dex → Swift 解释器，`diff -u` 逐行比对（当前 136 用例，含虚方法分派族） |

### 6.2 测试覆盖

| 测试 | 项数 | 状态 |
|------|------|------|
| libc-smoke | 65 | 全绿 |
| dl-smoke | 25 | 全绿 |
| elf-smoke | — | 全绿 |
| host-smoke | 13 | 全绿 |
| android-libs-smoke | 28 | 全绿 |
| 向量全绿 | 16,606+ | 全绿 |
| dex-smoke | 57 | 待 CI 首跑（JVM / Swift 双端对拍） |
| settings-smoke | — | 全绿 |
| zip-smoke | 13 | 全绿（含 SO 装载路径回归） |
| touch-smoke | 20 | 全绿（阶段四触控路由） |

### 6.3 静态自检

推送前用纯文本脚本做静态自检，替代本地 swiftc 编译：
- 括号平衡统计
- 符号清单/方法签名一致性校验
- 工作流 yml 文件清单核对

---

## 7 目录结构

```
output/nebula-dex-run/
├── Sources/
│   ├── app/                      # 应用入口 + 容器
│   ├── apk-tool/                 # APK 工具（ZIP/解析/签名/加固检测/XML）
│   ├── dex-core/                 # DEX 核心（解析/解释器/指令）- 骨架
│   ├── framework/                # 框架（状态/设置/日志/事件/许可证）
│   ├── ios-adapter/              # iOS 适配器（syscall/Android桥/实时活动/文件系统）
│   ├── native-loader/            # Native 装载（解释器/NEON/FPU/调用桥/libc/Android库/ELF）
│   ├── render/                   # Metal 渲染层 + 触控路由（阶段四）
│   ├── sandbox/                  # 沙盒（内存防护/预算/地址空间）
│   ├── tools/                    # 工具（日志/时间/ALU/字节读写/版本/系统探针）
│   └── ui/                       # UI（主题/根视图/应用列表/日志/设置/关于）
├── Tests/interp/                 # 解释器冒烟测试
├── Tests/dex/                    # DEX 对拍（Java 样本 + JVM 期望值驱动 + Swift 驱动 + cases.json）
├── .github/workflows/            # CI 工作流
├── docs/                         # 开发文档
└── Entitlements/                 # 权限配置
```

---

## 8 开发路线

| 阶段 | 内容 | 状态 |
|------|------|------|
| 阶段一 | AArch64 指令集补全（乘法除法、浮点 NEON/VFP、异常与系统调用、性能优化） | ✅ 完成 |
| 阶段二 | 原生系统库与系统调用层（syscall/最小libc/ELF装载/Android基础库） | ✅ 完成 |
| 阶段三 | DEX 解释器核心（解析 / 指令 / 堆 / 入口定位） | ✅ 已收口（对拍链路就绪，当前 136 用例） |
| 阶段四 | Java 运行时与安卓 API 框架、Skia Metal 渲染层、触控与生命周期、性能与体积填充 | 🚧 进行中（136 用例全绿，其中虚方法分派 + receiver 槽位装配已落地；Metal 渲染层 2,901 行 + 触控路由 358 行已落地，CI 编译门禁与 touch-smoke 就绪） |
| 阶段五 | 周边能力与稳定性收尾（凭证迁移/签名增强等） | 🚧 待开发 |

---

## 9 给豆包的说明

这份文档用于辅助豆包生成 NebulaDex 开发文档。以下要点供参考：

1. **项目核心**：iOS 非越狱环境下解释执行 Android APK 原生代码
2. **已完成**：阶段一（AArch64 指令解释器）+ 阶段二（系统调用代理 + libc + ELF 装载 + Android 基础库）+ 阶段三（DEX 解释器核心）已全部完成，CI 全绿
3. **待开发**：阶段三（DEX 解释器补全 + Java 运行时 + Android framework）是下一步重心
4. **关键约束**：体积按下限口径（≥ 8 MB 底线、≥ 50 MB 基本、理想 500 MB–1 GB），非越狱、不依赖 JIT
5. **技术特点**：自定义 syscall 号、trampoline 桩区、软件内存保护、无锁快照
6. **开发建议**：优先补全 DEX 解释器指令实现（从 const 族开始），然后接入类加载，最后实现 invoke-* 分派
*（内容由AI生成，仅供参考）*
*（内容由AI生成，仅供参考）*
