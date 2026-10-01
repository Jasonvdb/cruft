import Darwin
import Foundation

/// View-only answers to "where did my space go?" for space that cruft does
/// not clean: swap, a downloaded macOS update, protected Device Support,
/// system-owned simulator caches, and large app data. Nothing here is ever
/// handed to a deleter; every entry carries the action the user can take.
public struct StorageOverview: Sendable, Equatable {
    public struct Entry: Sendable, Identifiable, Equatable {
        public let id: String
        public let title: String
        /// What frees the space, in one short sentence.
        public let note: String
        public let bytes: Int64

        public init(id: String, title: String, note: String, bytes: Int64) {
            self.id = id
            self.title = title
            self.note = note
            self.bytes = bytes
        }
    }

    public let volumeTotalBytes: Int64?
    public let volumeAvailableBytes: Int64?
    /// Largest first. Entries under `minimumBytes` are left out.
    public let entries: [Entry]
    public let measuredAt: Date?

    public init(
        volumeTotalBytes: Int64?,
        volumeAvailableBytes: Int64?,
        entries: [Entry],
        measuredAt: Date?
    ) {
        self.volumeTotalBytes = volumeTotalBytes
        self.volumeAvailableBytes = volumeAvailableBytes
        self.entries = entries
        self.measuredAt = measuredAt
    }

    public static let empty = StorageOverview(
        volumeTotalBytes: nil, volumeAvailableBytes: nil, entries: [], measuredAt: nil)

    public var totalEntryBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
}

/// Measures the overview. Read-only: directory walks, one `sysctl`, and
/// volume capacity values. System areas are measured only for the real home,
/// so fixture homes never look outside themselves.
public struct StorageOverviewProbe: Sendable {
    /// Smaller entries are noise in a menu-bar utility.
    public static let minimumBytes: Int64 = 100 * 1024 * 1024

    struct Area: Sendable {
        let id: String
        let title: String
        let note: String
        let urls: [URL]
    }

    private let home: URL
    private let includesSystemAreas: Bool
    private let measurer: any DirectoryMeasurer
    private let swapUsedBytes: @Sendable () -> Int64?

    public init(home: URL) {
        self.init(
            home: home,
            includesSystemAreas: FlowRunArtifactSource.isRealHome(home),
            measurer: FoundationMeasurer(),
            swapUsedBytes: StorageOverviewProbe.systemSwapUsedBytes)
    }

    init(
        home: URL,
        includesSystemAreas: Bool,
        measurer: any DirectoryMeasurer,
        swapUsedBytes: @escaping @Sendable () -> Int64?
    ) {
        self.home = home
        self.includesSystemAreas = includesSystemAreas
        self.measurer = measurer
        self.swapUsedBytes = swapUsedBytes
    }

    public func load(now: Date = Date()) async -> StorageOverview {
        var entries: [StorageOverview.Entry] = []
        if includesSystemAreas, let swap = swapUsedBytes(), swap > 0 {
            entries.append(StorageOverview.Entry(
                id: "swap",
                title: "Swap",
                note: "macOS uses this as extra memory. A restart frees it.",
                bytes: swap))
        }
        for area in areas() {
            if Task.isCancelled { break }
            let bytes = await measure(area.urls)
            entries.append(StorageOverview.Entry(
                id: area.id, title: area.title, note: area.note, bytes: bytes))
        }
        if includesSystemAreas, !Task.isCancelled {
            let bytes = await measure(otherTemporaryItems())
            entries.append(StorageOverview.Entry(
                id: "other-temp",
                title: "Other temporary files",
                note: "Other tools made these in /private/tmp. cruft cannot tell if they are still needed.",
                bytes: bytes))
        }

        let capacity = Self.volumeCapacity(of: home)
        return StorageOverview(
            volumeTotalBytes: capacity.total,
            volumeAvailableBytes: capacity.available,
            entries: entries
                .filter { $0.bytes >= Self.minimumBytes }
                .sorted { $0.bytes > $1.bytes },
            measuredAt: now)
    }

    func areas() -> [Area] {
        var areas = [
            Area(
                id: "device-support",
                title: "Device Support",
                note: "Protected. Xcode copies it again from a device when needed. Old versions can go in Xcode › Devices.",
                urls: ["iOS", "watchOS", "tvOS", "visionOS", "xrOS"].map {
                    home.appending(path: "Library/Developer/Xcode/\($0) DeviceSupport")
                }),
            Area(
                id: "claude-vm",
                title: "Claude desktop virtual machine",
                note: "The Claude app downloads it again if it is removed.",
                urls: [home.appending(path: "Library/Application Support/Claude/vm_bundles")]),
            Area(
                id: "android-sdk",
                title: "Android SDK",
                note: "Remove unused platforms and images in Android Studio › SDK Manager.",
                urls: [home.appending(path: "Library/Android/sdk")]),
            Area(
                id: "android-avd",
                title: "Android emulators",
                note: "Delete unused emulators in Android Studio › Device Manager.",
                urls: [home.appending(path: ".android/avd")]),
        ]
        if includesSystemAreas {
            areas += [
                Area(
                    id: "macos-update",
                    title: "Downloaded macOS update",
                    note: "Install the update in System Settings › General › Software Update to free it.",
                    urls: [URL(filePath: "/System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate")]),
                Area(
                    id: "simulator-dyld-cache",
                    title: "System simulator cache",
                    note: "Owned by macOS. It shrinks when you delete simulator runtimes.",
                    urls: [URL(filePath: "/Library/Developer/CoreSimulator/Caches")]),
            ]
        }
        return areas
    }

    /// Direct /private/tmp children that no cruft category covers.
    private func otherTemporaryItems() -> [URL] {
        let root = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [])
        else { return [] }
        return entries
            .map { root.appending(path: $0.lastPathComponent) }
            .filter { url in
                url.lastPathComponent != "flow-runs"
                    && !TemporaryDerivedDataValidator.hasXcodeSignature(url)
            }
    }

    /// Sums allocated bytes. Missing roots count as zero; unreadable entries
    /// are skipped, so a total can only be low, never high.
    private func measure(_ urls: [URL]) async -> Int64 {
        var total: Int64 = 0
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            else { continue }
            if let size = try? await measurer.measure(url, partial: { _ in }) {
                total += size.allocatedBytes
            }
        }
        return total
    }

    static func volumeCapacity(of url: URL) -> (total: Int64?, available: Int64?) {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (nil, nil) }
        return (values.volumeTotalCapacity.map(Int64.init), values.volumeAvailableCapacityForImportantUsage)
    }

    @Sendable static func systemSwapUsedBytes() -> Int64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Int64(usage.xsu_used)
    }
}
