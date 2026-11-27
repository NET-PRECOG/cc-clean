/// CcCleanPrivileged：XPC 协议、Codable DTO、HelperClient、路径白名单校验器。
/// 红线（基线 5.2）：只含协议、DTO、白名单校验，不含任何业务实现；
/// Helper 因此不会把扫描/UI 代码带进 root 进程。
/// 实现自 S9 起（任务拆解 S9-2 ~ S9-4）；本文件为包骨架占位。
public enum CcCleanPrivilegedInfo {
    public static let version = "0.1.0"
    public static let moduleName = "CcCleanPrivileged"
}