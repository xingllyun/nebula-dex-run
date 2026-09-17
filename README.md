# NebulaDex（星云 Dex）

iOS 侧载环境下**自研的 Android APK 运行时**：纯字节码解释执行，无 JIT、无需越狱。

> 当前版本：v0.1.0（从零重建的工程骨架，开发文档见 [docs/NebulaDex-开发文档-v3.0.0.md](docs/NebulaDex-开发文档-v3.0.0.md)）

## 特性

- **APK 解析**：解压、清单解析、加固检测、签名校验
- **DEX 解释执行**：32/64 位自动识别，逐条解释 Dalvik 字节码
- **原生 SO 支持**：ARM/ARM64 **指令级解释执行**（非越狱下无法映射可执行内存，故不做原生跳转）
- **安卓 API 映射**：按需映射至 iOS 原生能力（组件生命周期、基础控件、存储、网络、通知等）
- **界面渲染**：原生控件映射优先 + 位图缓冲兜底的双路径管线
- **本地重签名**：APK v1 + v2 签名工具
- **云打包**：GitHub Actions 无签名打包，自动发布 `build-<run_number>` Release

## 目录结构

```
Sources/
  app/           应用入口与根视图
  ui/            六页界面（列表 / 运行显示 / 签名 / 日志 / 设置 / 关于）+ 自定义顶栏
  apk-tool/      APK 解析、加固检测、签名与重签名
  dex-core/      DEX 解析与字节码解释器
  native-loader/ ELF 解析、软件镜像装载、重定位、ARM 指令解释器
  ios-adapter/   安卓 API → iOS 能力映射层
  framework/     核心模型、状态、事件总线
  sandbox/       沙盒容器、文件系统隔离、软件内存模型
  tools/         通用工具（重试 / 字节序 / 时间 / 摘要）
Resources/       资源（含赞赏码）
Entitlements/    权限描述
docs/            开发文档
```

## 构建

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 驱动，无需提交 `.xcodeproj`：

```bash
brew install xcodegen
xcodegen generate
xcodebuild build -scheme NebulaDex -sdk iphoneos -configuration Release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

## 云打包

推送到 `main` 或在 Actions 中手动触发 `iOS Unsigned Build`，产物为 `NebulaDex-unsigned.ipa`，
并自动创建 `build-<run_number>` Release。构建环境：`macos-26` + Xcode 26.x。

## 安装

下载 IPA 后用全能签 / 轻松签等工具重签安装。证书需开启：

- `increased-memory-limit`（大内存）
- `extended-virtual-addressing`（大地址空间）

未开启这两项会出现黑屏或闪退。

## 兼容性

- 最低 iOS 16.0，适配至 iOS 26.x（iOS 27 未适配，产物可装不承诺）
- 不做 App Store 上架，仅面向侧载场景

## 许可

MIT License，见 [LICENSE](LICENSE)。
