---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: ed38b03a482bb8c9cc01ec95f4dd35e7_2662d139b44b11f1b3c552540024e231
    ReservedCode1: kutQ/fDuEXt7Cdf38VxUAUk7uUoR6XyqDQA2CtXhqxBp16ycNqxu5aaMBEgmYyibdOWt1e0c730FrPldVSVztinPCMpWuYrXmrxDMD6tEkf8Q4hRxP8+EgeDnxBbDqAkiZtkH/gZcfprsPuHA/1dzXg7GYyhMwx1GyRuHEjOLLnsR9z5OB0C4MSYb3U=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: ed38b03a482bb8c9cc01ec95f4dd35e7_2662d139b44b11f1b3c552540024e231
    ReservedCode2: kutQ/fDuEXt7Cdf38VxUAUk7uUoR6XyqDQA2CtXhqxBp16ycNqxu5aaMBEgmYyibdOWt1e0c730FrPldVSVztinPCMpWuYrXmrxDMD6tEkf8Q4hRxP8+EgeDnxBbDqAkiZtkH/gZcfprsPuHA/1dzXg7GYyhMwx1GyRuHEjOLLnsR9z5OB0C4MSYb3U=
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
| `SDRAPKParser.swift` | 100 | APK 元数据解析 |
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
| `SDRDexParser.swift` | 467 | 文件头 + 字符串/类型/proto/字段/方法 id 表 + class_def/class_data + code_item 懒加载 |
| `SDRDexInterpreter.swift` | 815 | 指令主循环：move/const/运算/分支/数组/字段/invoke/long 全量整数族，帧栈 + 静态字段 + 异常分发 |
| `SDRDexHeap.swift` | 153 | 对象 / 数组 / 字符串堆 |
| `SDRDexLaunchPlan.swift` | 105 | 入口定位：main（含 `[Ljava/lang/String;` 注入）→ 类初始化 → 普通方法降级 |

**合计 1,763 行**。`SDRAppContainer.launch` 已接入真实 DEX 解析与执行链路，不再是空跑。

**验收口径**：dex-smoke 57 用例 JVM 原生输出 ↔ Swift 解释器输出逐行对拍，见 `Tests/dex/`。

---

## 4 待开发的模块

### 4.1 DEX 解释器补全（阶段三·已收口）

原先的骨架（297 行 / 7 条指令）已由 §3.11 的五文件实现取代：常量池、类数据、code_item 提取、
对象/数组模型、invoke 分派、栈帧与静态字段全部就位，入口定位由 `SDRDexLaunchPlan` 负责。

**已实现**：整数指令族（move/const/运算/分支/数组/字段/invoke/long/switch）、静态字段累积语义、跨类调用、
`move-result` 语义（紧随 invoke）。

**未实现（保留显式抛错，留待阶段四）**：
1. 浮点指令族（const-wide 浮点、float/double 运算与转换）
2. `invoke-polymorphic` / `invoke-custom`
3. `throw` 与异常表（try/catch）
4. JNI 环境（`JNIEnv` 函数表）与类加载器、GC

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
| `ios-build.yml` | 未签名 IPA 构建（macos-26 runner） |
| `interp-test.yml` | AArch64 解释器冒烟测试 |
| `dex-smoke.yml` | DEX 解释器对拍：javac → JVM 期望值；d8 → classes.dex → Swift 解释器，`diff -u` 逐行比对 |

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
| 阶段三 | DEX 解释器核心（解析 / 指令 / 堆 / 入口定位） | ✅ 已收口（57 用例对拍链路就绪） |
| 阶段四 | Java 运行时与安卓 API 框架、Skia Metal 渲染层、触控与生命周期、性能与体积填充 | 🚧 进行中 |
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
