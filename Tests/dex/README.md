---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: ed38b03a482bb8c9cc01ec95f4dd35e7_b2f0d6ebb4b711f19ef152540024e231
    ReservedCode1: j3Hu9Wrf/ga3lTESe9iyHV9WAcxZ2bG2GrUyNRkY7ldEL7yu3kdiUayQOIYRYobw/MxYAnJsjI2iLx6rcRS9CBst8q8N4xBII8DKxVxzmvTVVmsR8QUZXHAUd6v5h/OzyGhupYEmnZTpYWWVrCOIXTRZ2/EPlXs1+wsEE5Q3hDyHgQP03ryBkLOpB9o=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: ed38b03a482bb8c9cc01ec95f4dd35e7_b2f0d6ebb4b711f19ef152540024e231
    ReservedCode2: j3Hu9Wrf/ga3lTESe9iyHV9WAcxZ2bG2GrUyNRkY7ldEL7yu3kdiUayQOIYRYobw/MxYAnJsjI2iLx6rcRS9CBst8q8N4xBII8DKxVxzmvTVVmsR8QUZXHAUd6v5h/OzyGhupYEmnZTpYWWVrCOIXTRZ2/EPlXs1+wsEE5Q3hDyHgQP03ryBkLOpB9o=
---

# Tests/dex —— DEX 解释器对拍验收

阶段三收口验收：同一批 Java 样本，一路交给 JVM 原生执行、一路交给 NebulaDex 的 DEX 解释器执行，
两份「签名=值」清单必须**逐行完全一致**。这是 DEX 语义正确性的唯一硬口径——不做近似、不做容差。

## 资产构成

| 文件 | 作用 |
|------|------|
| `src/*.java` | Java 样本（`NebulaDexProbe` / `NebulaDexFlow` / `NebulaDexSwitch` / `NebulaDexWide`），覆盖常量装载、int/long 二元运算、控制流、数组、静态字段、跨类调用、分支表 |
| `src/DexExpect.java` | 期望值驱动：在 JVM 上按固定顺序调用样本方法，打印 `签名=值` |
| `cases.json` | 用例清单（签名 + 实参），顺序与 `DexExpect.java` **严格一致**；静态字段跨用例累积，顺序即语义 |
| `main.swift` | Swift 侧驱动：装载 d8 产出的 `classes.dex`，逐用例执行并打印同格式清单 |

当前规模：**57 个用例**。

## 运行方式

### CI（首选）

推送到 `main`（或触发 `DEX Smoke` 工作流）后自动执行 `.github/workflows/dex-smoke.yml`：

1. `javac --release 8` 编译 Java 样本
2. `java DexExpect > build/expect.txt`（JVM 原生期望值）
3. 解析 d8 位置（Android build-tools 优先，缺省回退到 Google Maven 的 r8 jar）
4. `d8 --min-api 24 --output build/dex-out build/dex-classes/*.class`
5. `swiftc -O` 编译 `Sources/dex-core/*` + `Tests/dex/main.swift` 为 `build/dex-smoke`
6. `diff -u build/expect.txt build/actual.txt`

任一步失败即红，失败产物（两份清单）作为 artifact 上传。

### 本地手跑

```sh
mkdir -p build/dex-classes build/dex-out
javac --release 8 -d build/dex-classes Tests/dex/src/*.java
java -cp build/dex-classes DexExpect > build/expect.txt
d8 --min-api 24 --output build/dex-out build/dex-classes/*.class
swiftc -swift-version 5 -O -o build/dex-smoke \
    Sources/tools/SDRByteReader.swift Sources/tools/SDRLogger.swift \
    Sources/framework/SDRCore.swift \
    Sources/dex-core/*.swift Tests/dex/main.swift
./build/dex-smoke build/dex-out/classes.dex Tests/dex/cases.json > build/actual.txt
diff -u build/expect.txt build/actual.txt && echo PASS
```

## 增补用例规则

1. 先在 `src/` 里加样本方法（保持 `public static`，语义自包含，不依赖 Android/Java 标准库）；
2. 在 `DexExpect.java` 里按**追加顺序**补一行 `p("L类;->方法(proto)ret", 类.方法(实参));`
3. 在 `cases.json` 的 `cases` 数组**同一位置**补同一签名与实参（数组用 `{"intarray": [...]}`）；
4. 两侧顺序必须一致——静态字段会跨用例累积，顺序错位会导致后续期望值整体偏移；
5. 未实现指令必须继续抛 `dexOpUnsupported`，**严禁**为让对拍变绿而静默跳过指令。
*（内容由AI生成，仅供参考）*
