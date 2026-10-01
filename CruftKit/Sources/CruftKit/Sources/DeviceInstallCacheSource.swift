import Foundation

/// CoreDevice's app-install delta cache. Xcode keeps a copy of every build it
/// installs on a physical device, so the next install can send only the
/// difference. Without it, the next install sends the whole app once.
public struct DeviceInstallCacheSource: CacheSource {
    public static let id = CategoryID("device-install-cache")
    public let displayName = "Device Install Cache"
    /// CoreDeviceService can hold a delta open during an install.
    public let requiresLiveUseCheck = true

    static let cacheRelativePath =
        "Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas"

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [context.home.appending(path: Self.cacheRelativePath)]
    }

    /// Lists the root so a privacy refusal surfaces as "no access" during
    /// discovery, instead of as a failed measurement later.
    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = context.home.appending(path: Self.cacheRelativePath)
        guard TemporaryDerivedDataValidator.isRealDirectory(root) else { return [] }
        _ = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        return [CacheItem(
            categoryID: Self.id, url: root, label: "App install deltas", deletionMode: .contentsOnly)]
    }
}
