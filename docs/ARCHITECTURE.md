# CcClean 架构模块地图

> 分层原则：依赖只允许自上而下（App → Ops/FS/Metrics → Core），禁止反向依赖与横向依赖（Metrics 不得依赖 FS/Ops）。

## 目录结构

```
Targets/                  可执行产物层（仅组装，不写业务）
  CcCleanApp/             SwiftUI 主应用
    CcCleanApp.swift      @main 入口
    Shared/               跨功能公共件
      Theme/              设计令牌与统一样式（Theme.swift）
      State/              跨功能共享 ViewModel（CapabilityViewModel.swift）
    Features/             按功能垂直分块，一功能一目录
      Home/               首页总览
      Monitor/            系统监控（MonitorViews + StatusPanel）
      SmartClean/         智能清理（SmartScan + JunkPreview）
      Space/              空间分析（SpaceView + FileTree）
      AppManager/         应用管理（AppInventory / IconGrid / Uninstall / StartupItems）
      DevTools/           开发者工具（DevTools + MultiPackageManager）
      Security/           安全中心
      UpdateCenter/       更新中心
      Settings/           设置
  CcCleanCLI/             命令行工具
  CcCleanHelper/          特权 Helper 可执行
  CcCleanWidget/          Widget 扩展

Packages/                 功能模块层（SwiftPM 本地包，独立可测）
  CcCleanCore/            基础内核：日志、路径、进程执行、数据库、能力探测
    Logging/  Paths/  Process/  Data/  Capability/  Privileged/  Diagnostics/
  CcCleanFS/              文件系统域：索引、应用盘点、残留扫描、规则、launchd 解析
    Index/  Apps/  Residue/  Rules/  Launchd/  Space/
  CcCleanOps/             操作执行域：卸载、清理、服务管理、版本更新、监控联动
    Ops/  Uninstall/  Clean/  Services/  Versions/  Monitor/  Security/  Startup/  DevTools/  AppHealth/
  CcCleanMetrics/         监控采样域：CPU/内存/网络采样、告警评估
    Samplers/  Evaluate/  Services/
  CcCleanPrivileged/      特权通道域：XPC DTO/Client/Executor、路径校验
    XPC/

Shared/Resources/         跨 Target 共享资源（规则、保护路径、喂价等）
Assets/                   应用图标等 UI 资产
scripts/                  红线检查、回归、发布脚本
```

## 公共管理约定

- 每个包的公共入口与版本号为 `CcCleanXxxInfo.swift`（如 `CcCleanCoreInfo`），聚合包元信息。
- 包名即模块边界：跨包访问必须 `import` 对应模块，禁止文件级 hack。
- UI 设计令牌统一收敛在 `Shared/Theme/Theme.swift`，Feature 内不得私建样式常量。
- 新增功能：在 `Features/` 下建独立目录，跨功能状态放 `Shared/State/`。
- 各包测试位于 `Packages/<pkg>/Tests/`，与源码子域一一对应。