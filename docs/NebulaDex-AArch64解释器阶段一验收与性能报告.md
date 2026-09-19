# NebulaDex AArch64 解释器：阶段一验收与性能报告

> 适用范围：`Sources/native-loader/SDRArmInterpreter.swift`、`SDRArmNEON.swift`、`SDRArmFPU.swift`
> 与 `Sources/sandbox/SDRMemoryGuard.swift`（阶段一解释器执行链路）。
> 验收方式：指令级黄金向量对拍 + 吞吐量基准，全部可在无 iOS 模拟器的 macOS runner 上复现。

## 1. 结论摘要

| 项目 | 状态 |
| --- | --- |
| 黄金向量用例 | 252 个用例 / 16606 项校验，**全部通过** |
| 解释器吞吐量（混合负载） | 7.61 MIPS → **16.64 MIPS**（+118.7%） |
| CI 门禁 | 四套向量串行执行，任一失败即构建失败 |
| 已知缺口 | 浮点/by-element/归约 等高级 NEON 形态、多条 NEON 串联用例未覆盖 |

## 2. 指令覆盖范围

阶段一聚焦 AArch64 解释器的**整数通路**（标量 + NEON 高级 SIMD 整数），分簇如下：

| 分簇 | 顶层分派 | 覆盖内容 |
| --- | --- | --- |
| 移位立即数 | `bits[28:24] = 0b01111` | SHL / SSHR / USHR / SRI / SLI / SHL、SHRN / RSHRN / SSHLL / USHLL 等窄化与加宽 |
| 三同（three-same） | `bits[28:24] = 0b01110`，`bit21 = 1` | ADD/SUB 系列、逻辑（AND/ORR/EOR/BIC/ORN/EOR）、比较（CMGT/CMGE/CMEQ/CMHI…）、最小最大、ABS/NEG、MUL 等 |
| 二同 misc | `0b01110`，`bit10 = 1` | REV64/REV32/REV16、CNT、CLS/CLZ、NOT、XTN/XTN2、SHLL、ADDV 类归约入口 |
| copy | `0b01110`，`bit11 = 1` | DUP（元素/通用）、INS（元素）、SMOV/UMOV 等 |
| 越界保护 | 未命中的编码 | 顶层分派统一 `return false`，交由上层报「未实现指令」 |

标量侧沿用阶段一的实现：算术/逻辑/移位（含立即数）、乘除、位域（BFM/UBFX）、加载存储（含 LDP/STP 与写回）、
分支与调用栈、条件选择与标志位（CSEL/CCMP 等）、标量浮点（`SDRArmFPU`：运算/转换/比较/立即数）。

## 3. 测试体系

四套向量各自独立生成、独立对拍，互不覆盖同一期望值来源，用于防止「按期望值反推公式」的过拟合。

| 向量文件 | 生成脚本 | 用例数 | 校验项 | 定位 |
| --- | --- | --- | --- | --- |
| `Tests/interp/vectors.json` | （阶段一手写基线） | 5 | 325 | 基线骨架：算术、访存、分支、浮点冒烟 |
| `Tests/interp/vectors_hardening.json` | `gen_vectors_hardening.py` | 27 | 1755 | 加固回归：字段边界、写回、立即数边界 |
| `Tests/interp/vectors_neon.json` | `gen_vectors_neon.py` | 113 | 7464 | NEON 整数主通路（四类分簇全覆盖） |
| `Tests/interp/vectors_neon2.json` | `gen_vectors_neon2.py` | 107 | 7062 | NEON 参数空间扩展（移位越界、size 选择器、索引边界） |

向量生成链路：`clang --target=aarch64-linux-gnu` 交叉汇编单条指令 → unicorn 注入初值并模拟执行
→ 读取寄存器/内存终态作为黄金值 → 落 JSON；`interp-test` 逐条执行同一机器码并逐项断言。

生成脚本均以脚本自身位置定位输出（`HERE = os.path.dirname(os.path.abspath(__file__))`），
可在任意机器重复生成，三份产物哈希与仓库提交值完全一致（可复现）。

## 4. 性能优化

### 4.1 热点定位

以同一热循环（12 指令/轮：6 条标量 ALU + 2 条 NEON + 1 对 `str/ldr` + 循环控制）切片测量，
逐层剥离负载以确定瓶颈：

| 负载变体 | 每轮指令数 | 吞吐量 | 判读 |
| --- | --- | --- | --- |
| 无访存（去掉 `str/ldr`） | 10 | 18.38 MIPS | 上限参考 |
| 含访存、无 NEON | 12 | 7.56 MIPS | 与 mixed 基本持平 → NEON 不是瓶颈 |
| 混合负载（full） | 12 | 7.65 MIPS | 访存路径是绝对瓶颈 |

结论：`SDRMemoryGuard.write` 原先通过 `guard var buf = storage[seg.base]` 取值后 `replaceSubrange` 回写，
在字典仍持有该数组时触发**整段写时复制**——单次写代价为 O(段大小)（栈段 64 KiB 即每次拷 64 KiB）。

### 4.2 已落地优化

| 优化项 | 位置 | 做法 |
| --- | --- | --- |
| 访存原地写入 | `SDRMemoryGuard.write` | 改用字典下标的 mutating 访问器 + `memcpy` 直写底层缓冲，单次写由 O(段大小) 降为 O(写入字节数) |
| 标量访存快路径 | `SDRMemoryGuard.readScalar/writeScalar` | 新增 1/2/4/8 字节免分配读写接口，语义与 `read/write` 完全一致（同样的权限与越界校验、同样的错误文本） |
| 解释器访存改道 | `SDRArmInterpreter.readBytes/writeBytes` | `count <= 8` 走标量接口，消除每次访存的临时数组分配 |
| 译码缓存 | `SDRArmInterpreter` | 4096 槽译码缓存（`decodeSlotKeys/Kinds`），命中率 100.00%，跳过重复分类链 |
| 取指窗口 | `SDRArmInterpreter.fetch` | 取指窗口扩大至 1 KiB，命中判定改为 `pc &- base` 单比较，规避溢出分支 |
| 热路径内联 | `SDRArmInterpreter` | `fetch`、寄存器取用辅助函数加 `@inline(__always)` |

### 4.3 基准结果

同一 `bench.json`（60 万指令），macOS/Linux 同源编译（`swiftc -O`），取 3 次最好值：

| 构建 | 解释器 | 内存模型 | 吞吐量 | 相对基线 |
| --- | --- | --- | --- | --- |
| 基线 | 优化前 | 优化前 | 7.61 MIPS | — |
| 中间态 | 优化前 | 优化后 | 13.16 MIPS | +72.9% |
| 当前 | 优化后 | 优化后 | **16.64 MIPS** | **+118.7%** |

分解：内存模型修复贡献约 +72.9%，解释器侧（译码缓存/内联/取指窗口 + 标量读路径）再贡献约 +26.5%。
回归确认：四套向量在优化构建与优化前构建下均全绿，优化未改变语义。

## 5. 复现方式

CI（`.github/workflows/interp-test.yml`，`macos-26`）在每次推送到 `main` 时执行：
编译 `interp-test` 与 `bench` → 依次跑四套向量（门禁）→ 跑一轮吞吐基准（信息性）。

本地复现等价命令：

```bash
swiftc -swift-version 5 -O -o interp-test <解释器所需源文件列表> Tests/interp/main.swift
./interp-test Tests/interp/vectors.json
./interp-test Tests/interp/vectors_hardening.json
./interp-test Tests/interp/vectors_neon.json
./interp-test Tests/interp/vectors_neon2.json

swiftc -swift-version 5 -O -o bench <同上> Tests/interp/bench.swift
./bench Tests/interp/bench.json 3
```

向量可自行重生成（需 `clang`、`python3`、`unicorn`）：

```bash
python3 Tests/interp/gen_vectors_hardening.py
python3 Tests/interp/gen_vectors_neon.py
python3 Tests/interp/gen_vectors_neon2.py
python3 Tests/interp/gen_bench.py
```

## 6. 遗留与后续

- NEON 浮点、by-element（按元素移位/乘加）、归约（ADDV/SMAXV 等）与 128 位访存形态尚未纳入向量。
- 多条 NEON 指令串联（寄存器依赖链）的向量缺失，当前以单指令隔离验证为主。
- 标量浮点与 NEON 混跑场景未做长度充分的基准。
- 访存路径仍有优化空间：段查找为线性扫描（`segments.first`），后续可考虑段区间索引或最近段缓存，
  但需先明确 `SDRMemoryGuard` 的并发使用契约（当前 `read/write` 未加锁，`map/releaseAll` 加锁）。

---

Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
