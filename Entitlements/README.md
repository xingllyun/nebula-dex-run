# Entitlements（侧载证书权限说明）

NebulaDex 需要两项内核权限才能在 iOS 26 上稳定运行大型 APK/SO 负载：

| 权限键 | 通俗叫法 | 作用域 | 最低系统 | 作用 |
| --- | --- | --- | --- | --- |
| `com.apple.developer.kernel.increased-memory-limit` | 大内存 | 常驻物理内存上限 | iOS 15.0 | 把单 App 常驻内存上限从约 50% 物理内存放宽到约 75% |
| `com.apple.developer.kernel.extended-virtual-addressing` | 大地址空间 | 进程虚拟地址空间 | iOS 14.0 | 扩展进程可用的虚拟地址空间，缓解大量 `mmap` 造成的碎片化 |

两者互不替代：**大内存**解决“物理内存先到顶被 jetsam 杀掉”，**大地址空间**解决“虚拟地址空间先耗尽导致 mmap 失败”。

## 文件说明

- `NebulaDex.entitlements`：工程构建声明（无签名构建阶段不生效）
- `NebulaDex-Sideload-Minimal.entitlements`：侧载重签最小模板（仅两项内存权限，建议优先使用）

## 注入方式

1. 全能签 / 轻松签：重签界面导入 `NebulaDex-Sideload-Minimal.entitlements` 后签名安装
2. SideStore / AltStore 免费证书：**会忽略**该权限，需配合 `GetMoreRam` 之类的工具为已签名 App 追加 `Increased Memory Limit` 后重装
3. 注入后必须**重装 App**（权限随签名生效，不会对已安装实例回溯生效）

## 生效校验

安装后打开 App → 「关于」页 → 「侧载证书权限（两项）」，查看两项状态与“最大连续映射”实测值。
状态为“无法判定”时运行时按受限档位分配预算，属安全降级。

---

Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
