import Foundation

/// 应用安装来源（A7，基线 8.2 install_source 口径）。
public enum InstallSource: String, Codable, Sendable {
    case appStore
    case homebrewCask
    case pkgInstaller
    case dragAndDrop
    case system
    case unknown
}

/// 签名状态（基线 8.2 signature 口径）。
public enum SignatureState: String, Codable, Sendable {
    case appleSystem
    case developerIDNotarized
    case developerID
    case adHoc
    case unsigned
    case unknown
}

/// 应用台账记录（基线 8.2 app_record 表的内存形态）。
public struct AppRecord: Codable, Sendable, Equatable, Identifiable {

    public var id: String { bundleId }

    public var bundleId: String
    public var bundlePath: String
    public var displayName: String
    public var bundleName: String?
    public var executableName: String?
    public var shortVersion: String?
    public var buildVersion: String?
    public var teamIdentifier: String?
    public var minimumSystem: String?
    public var installSource: InstallSource
    public var signature: SignatureState
    public var architecture: String?
    public var sizeBytes: Int64?
    public var dataBytes: Int64?
    public var cacheBytes: Int64?
    public var installDate: Date?
    /// 3=exact 2=spotlight 1=fileSystem 0=unknown（基线 8.2 install_confidence 口径）
    public var installConfidence: Int
    public var lastUsedDate: Date?
    public var isProtected: Bool
    public var isRunning: Bool
    public var scannedAt: Date

    public init(
        bundleId: String,
        bundlePath: String,
        displayName: String,
        bundleName: String? = nil,
        executableName: String? = nil,
        shortVersion: String? = nil,
        buildVersion: String? = nil,
        teamIdentifier: String? = nil,
        minimumSystem: String? = nil,
        installSource: InstallSource = .unknown,
        signature: SignatureState = .unknown,
        architecture: String? = nil,
        sizeBytes: Int64? = nil,
        dataBytes: Int64? = nil,
        cacheBytes: Int64? = nil,
        installDate: Date? = nil,
        installConfidence: Int = 0,
        lastUsedDate: Date? = nil,
        isProtected: Bool = false,
        isRunning: Bool = false,
        scannedAt: Date = Date()
    ) {
        self.bundleId = bundleId
        self.bundlePath = bundlePath
        self.displayName = displayName
        self.bundleName = bundleName
        self.executableName = executableName
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.teamIdentifier = teamIdentifier
        self.minimumSystem = minimumSystem
        self.installSource = installSource
        self.signature = signature
        self.architecture = architecture
        self.sizeBytes = sizeBytes
        self.dataBytes = dataBytes
        self.cacheBytes = cacheBytes
        self.installDate = installDate
        self.installConfidence = installConfidence
        self.lastUsedDate = lastUsedDate
        self.isProtected = isProtected
        self.isRunning = isRunning
        self.scannedAt = scannedAt
    }
}