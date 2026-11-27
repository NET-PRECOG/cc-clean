# CcClean V1.0 发布门槛检查单（RG-V1.0）

> 依据基线第 3.6 节五条 + 第 14.6 节检查单生成。发布前全部项必须勾选，
> 自动化部分由 `scripts/regression-v1.sh` 与 `scripts/release.sh` 承担。

## ① 状态门槛（基线 3.6-1）

- [ ] V1.0 全部项状态「已验收」：A1 A4 A5 A7 A9 · B1 B2 B3 B5 · C1 C2 C3 C4 C5 C6 C9 C10 C12 C13 C15 · D1 D2 D3 起步（D 组归属见任务拆解矛盾①裁决）
- [ ] 验收标准逐条可举证（基线第 4 章逐项）

## ② 回归门槛（基线 3.6-2）

- [ ] `scripts/regression-v1.sh` 全绿（R9 撤销 / R5 体积 / R10 检出 / R4 零误伤 / R1 保护名单）
- [ ] 真机人工清单：R1 向日葵完整复现（本体 + 4 Daemon + HAL 驱动 + 2 receipt + 6 用户级残留）
- [ ] R1 误删判定零命中（任何「其他应用路径」被清理即回归失败）
- [ ] R10 检出率 ≥ 90%（5 款样本应用）
- [ ] 安全类回归零例外（不做全能杀毒，I 组不在 V1.0）

## ③ 规则门槛（基线 3.6-3）

- [ ] 24 条内置规则通过 RuleValidator 三校验（`bundledRulesValid` 测试）
- [ ] 每条规则有 positive/negative fixture（`perRuleFixtures` 测试）
- [ ] 高危规则全部 defaultSelected=false 且 UI Hold to confirm 生效

## ④ 崩溃门槛（基线 3.6-4）

- [ ] 崩溃收集后台 7 天 crash-free ≥ 99.0%（首版安装期口径）

## ⑤ 文档同步（基线 3.6-5）

- [ ] 基线第 4 章状态列同步
- [ ] 基线第 15 章进度列同步
- [ ] CHANGELOG.md 更新
- [ ] 基线矛盾变更单归档：D 组归属裁决 / RuleAction `.report` / `/private/var/folders` 例外

## ⑥ 发布工程（基线 14.6）

- [ ] `scripts/release.sh` 全程跑通：archive → 签名验证 → DMG → notarytool → stapler → spctl
- [ ] 干净机器（新建用户）安装冒烟 6 项全过
- [ ] 卸载无残留（安装器自身卸载验证）
- [ ] Sparkle appcast 骨架与 EdDSA 签名就绪（S14/自动更新接入前先就位）
- [ ] Homebrew Cask PR 模板与 zap 清单核对（14.4）
- [ ] 回滚方案：上一个版本 DMG + appcast 回退演练

## ⑦ 未完成项声明（进 V1.1）

- D5/D6/D7/D10（基线矛盾①裁决后归属）
- C3 关联状态完整清理 / C13 Keychain 真实检查（S10 Helper 后）
- D4/D8/D9/D12（提前消化至 S15 的 V1.4 项）
