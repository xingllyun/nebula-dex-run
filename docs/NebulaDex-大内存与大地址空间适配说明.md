# NebulaDex 大内存 / 大地址空间适配说明

> 适用版本：v0.2.0 及以后 ｜ 目标机型：iPhone（iOS 26.x）侧载安装

## 1. 两项权限到底是什么

侧载证书设置里的“大内存 / 大空间”，对应 Apple 的两个内核 entitlement：

| 项目 | 大内存 | 大地址空间 |
| --- | --- | --- |
| 权限键 | `com.apple.developer.kernel.increased-memory-limit` | `com.apple.developer.kernel.extended-virtual-addressing` |
| 最低系统 | iOS 15.0 | iOS 14.0 |
| 类型 | Boolean | Boolean |
| 提升对象 | 常驻物理内存（resident）上限，放宽 jetsam 阈值 | 进程虚拟地址空间上限 |
| 典型收益 | 6 GB 机型约 2.5–3 GB → 约 4.5 GB；8 GB 机型约可到 6 GB | 允许更大、更多的 `mmap` 区域，缓解地址空间碎片 |
| 解决的首个瓶颈 | 物理内存先被占满 → 被系统终止 | 虚拟地址空间先耗尽 → `mmap` 返回 ENOMEM |

要点：

1. 两者**不叠加放大**：开启两项不会让峰值内存翻倍，但能同时消掉两类不同瓶颈。
2. 大内存**不突破物理内存**，只是提高系统允许单个 App 使用的额度；不开时约为物理内存的一半。
3. iPhone 11 及更早（4 GB 物理内存）机型，Apple 明确说明即使开启也不会提升上限。
4. 权限由**签名**决定：必须重签并重装后生效，不会对已安装实例回溯生效。
5. SideStore / AltStore 免费签名会忽略该权限，需用 `GetMoreRam` 追加 `Increased Memory Limit` 后重装；或改用 PlumeImpactor / 全能签 / 轻松签。

## 2. NebulaDex 如何适配

### 2.1 声明

- `Entitlements/NebulaDex.entitlements`：工程内声明两项权限 + App Group
- `Entitlements/NebulaDex-Sideload-Minimal.entitlements`：侧载重签最小模板（仅两项权限）

### 2.2 运行时探测

`SDRSystemProbe` 在启动与「关于」页展示时采集：

| 指标 | 来源 | 用途 |
| --- | --- | --- |
| 可用内存 | `os_proc_available_memory()` | 实时可用额度（不可缓存，随 footprint 变化） |
| 常驻/虚拟用量 | `task_info(TASK_VM_INFO)` | phys_footprint 与 virtual_size |
| 最大连续映射 | `mmap(PROT_NONE, MAP_NORESERVE)` 逐档探测后立即释放 | 反映地址空间扩展效果 |
| 大内存判定 | 可用内存 / 物理内存 比值（>0.55 生效、<0.48 未生效） | 参考判定 |
| 大地址空间判定 | 最大连续映射 ≥ 16 GB 记为生效 | 参考判定 |

iOS 未提供“查询本进程是否具备某 entitlement”的公开接口，因此判定为启发式；结论为“无法判定”时按下限档位分配预算，属安全降级。

### 2.3 预算映射

`SDRMemoryBudget` 把探测结果翻译成运行时配额：

| 档位 | 触发条件 | 常驻上限 | SO 段上限 | DEX 缓存上限 | 寄存器栈深度 |
| --- | --- | --- | --- | --- | --- |
| 受限 | 两项均未探测到 | 物理内存 × 42% | 常驻上限 50% | 常驻上限 25% | 256 |
| 标准 | 仅大内存生效 | 物理内存 × 60% | 常驻上限 50% | 常驻上限 25% | 512 |
| 扩展 | 两项均生效 | 物理内存 × 65% | 常驻上限 50% | 常驻上限 25% | 1024 |

上限同时受 `os_proc_available_memory() × 85%` 挤压，取更小值，避免逼近 jetsam 阈值。

### 2.4 超限保护与内存压力

- `SDRMemoryGuard.map()` 超预算时拒绝映射并记录 `MEMORY_BUDGET_EXCEEDED`，不再让进程被系统直接终止
- `SDRMemoryPressureMonitor` 监听系统内存压力，`warning` / `critical` 时通过事件总线广播，上层收缩缓存
- `SDRMemoryGuard` 提供 `releaseAll()`，停止运行时释放软件段

## 3. iOS 26 机型适配清单

| 项 | 处理 |
| --- | --- |
| 版本判定 | 改为语义化比较（主+次版本），覆盖 26.0 / 26.2 / 26.4 等分点版本 |
| 外观 | iOS 26 默认采用 Liquid Glass；未设 `UIDesignRequiresCompatibility` 即采用新外观 |
| 内存策略 | 引入预算档位与内存压力联动，jetsam 更激进下自动降档而非崩溃 |
| 刷新率 | ProMotion 机型按 30/60/120 生效，非 ProMotion 保持 30/60 |
| 后台任务 | iOS 26 支持 `BGContinuedProcessingTask`，由 `supportsContinuedProcessing` 判定后启用 |
| 部署目标 | 保持 iOS 16.0 起，向上适配至 26.x |
| 机型标识 | `uname()` 读取机型标识，「关于」页展示，便于按机型排查 |

## 4. 验证方法

1. 侧载重签时导入 `Entitlements/NebulaDex-Sideload-Minimal.entitlements`
2. 重装 App → 打开「关于」页
3. 检查“侧载证书权限（两项）”两行是否为“已生效”，并记录“最大连续映射”实测值
4. 对照“内存预算”档位：两项均生效应为“扩展”

---

Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
