# Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
# Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License

## 变更说明

<!-- 一句话说清改了什么、为什么改 -->

## 影响面

- [ ] 触碰稳定区（`Sources/native-loader` / `Sources/sandbox`）——需说明为何必要
- [ ] 修改渲染层（`Sources/render`）
- [ ] 修改构建脚本或 CI（`.github/workflows`）
- [ ] 需要同步更新文档（`docs/`）

## 门禁自检

推 CI 前请确认：

- [ ] 渲染层与全量源文件通过 iOS 类型检查门禁（`ios-build.yml` → Type-check Swift sources）
- [ ] `interp-test.yml` 中相关 smoke 用例新增/更新（若有行为变化）
- [ ] `dex-smoke.yml` 仍通过（涉及解释器时）
- [ ] 未引入平台误用（例如把 Android 专有 API 写进 iOS 分支）

## 关联

<!-- Closes #xxx / 关联文档章节 §x.x -->
