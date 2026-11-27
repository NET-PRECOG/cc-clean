/// CcCleanMetrics：MetricsService、SMCSampler、IOKitSampler、ProcessSampler、历史降采样。
/// 实现自 S12 起（任务拆解 S12-2 ~ S12-5）；本文件为包骨架占位。
/// 红线：本包不得依赖 FS/Ops（监控要在未授权全盘访问时独立工作）。
public enum CcCleanMetricsInfo {
    public static let version = "0.1.0"
    public static let moduleName = "CcCleanMetrics"
}