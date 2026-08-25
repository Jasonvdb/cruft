import Foundation

/// Injectable lookup for the standard name of each CoreSimulator device type.
/// Tests provide a fixed map. Production obtains the same public facts from
/// `xcrun simctl list devicetypes --json` without using a shell.
protocol SimulatorDeviceTypeNameProviding: Sendable {
    func standardNamesByIdentifier() -> [String: String]
}

struct SystemSimulatorDeviceTypeNameProvider: SimulatorDeviceTypeNameProviding {
    private let processRunner: any DirectProcessRunning

    init(processRunner: any DirectProcessRunning = BoundedDirectProcessRunner()) {
        self.processRunner = processRunner
    }

    func standardNamesByIdentifier() -> [String: String] {
        guard let result = try? processRunner.run(
            executable: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devicetypes", "--json"]),
            result.status == 0,
            !result.outputWasTruncated,
            let document = try? JSONDecoder().decode(
                DeviceTypesDocument.self, from: result.standardOutput)
        else { return [:] }
        return Dictionary(
            document.devicetypes.map { ($0.identifier, $0.name) },
            uniquingKeysWith: { first, _ in first })
    }

    private struct DeviceTypesDocument: Decodable {
        let devicetypes: [DeviceType]
    }

    private struct DeviceType: Decodable {
        let identifier: String
        let name: String
    }
}

/// One strict parser and classifier for CoreSimulator `device.plist`. Scan
/// discovery and delete-time validation both use this implementation.
struct SimulatorDeviceMetadataReader: Sendable {
    private static let maximumMetadataBytes = 64 * 1024
    private static let maximumDeviceNameLength = 80
    private static let maximumIdentifierLength = 200
    private static let shutdownState = 1
    private static let bootedState = 3

    func metadata(
        in directory: URL,
        leafUDID: String,
        standardNames: [String: String]
    ) -> SimulatorDeviceMetadata {
        guard let dictionary = safeMetadataDictionary(in: directory) else {
            return unknownMetadata(udid: leafUDID)
        }

        let name = safeString(
            dictionary["name"], maximumLength: Self.maximumDeviceNameLength,
            disallowSlash: true)
        let deviceType = safeString(
            dictionary["deviceType"], maximumLength: Self.maximumIdentifierLength)
        let runtime = safeString(
            dictionary["runtime"], maximumLength: Self.maximumIdentifierLength)
        let metadataUDID = safeString(dictionary["UDID"], maximumLength: 36)
        let state = safeState(dictionary["state"])
        let runtimeLabel = runtime.flatMap(Self.runtimeLabel) ?? "Unknown"
        let udidMatches = metadataUDID.flatMap(UUID.init(uuidString:))
            == UUID(uuidString: leafUDID)
        let validState = state.map { (0...4).contains($0) } == true
        let standardName = deviceType.flatMap { standardNames[$0] }

        let group: SimulatorDeviceMetadata.MainGroup
        if let name, let standardName,
            runtimeLabel != "Unknown", udidMatches, validState
        {
            group = name == standardName ? .xcode : .other
        } else {
            group = .unknown
        }
        let isBooted = state == Self.bootedState
        return SimulatorDeviceMetadata(
            udid: leafUDID,
            name: name,
            deviceTypeIdentifier: deviceType,
            runtimeIdentifier: runtime,
            mainGroup: group,
            runtimeLabel: runtimeLabel,
            isBooted: isBooted,
            isDeletable: group != .unknown && state == Self.shutdownState)
    }

    private func unknownMetadata(udid: String) -> SimulatorDeviceMetadata {
        SimulatorDeviceMetadata(
            udid: udid,
            mainGroup: .unknown,
            runtimeLabel: "Unknown",
            isBooted: false,
            isDeletable: false)
    }

    private func safeMetadataDictionary(in directory: URL) -> [String: Any]? {
        let metadata = directory.appending(path: "device.plist")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? metadata.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize <= Self.maximumMetadataBytes,
            let data = try? Data(contentsOf: metadata),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else { return nil }
        return dictionary
    }

    private func safeString(
        _ value: Any?, maximumLength: Int, disallowSlash: Bool = false
    ) -> String? {
        guard let string = value as? String,
            !string.isEmpty,
            string.count <= maximumLength,
            string == string.trimmingCharacters(in: .whitespacesAndNewlines),
            (!disallowSlash || !string.contains("/")),
            string.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return string
    }

    /// Property-list Booleans and reals also bridge to NSNumber. Accept only
    /// a native integer representation so `true` and `1.5` cannot become the
    /// shutdown state through NSNumber.intValue truncation.
    private func safeState(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(number)
        else { return nil }

        var exactValue: Int64 = 0
        guard CFNumberGetValue(number, .sInt64Type, &exactValue),
            (0...4).contains(exactValue)
        else { return nil }
        return Int(exactValue)
    }

    private static func runtimeLabel(_ identifier: String) -> String? {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else { return nil }
        let suffix = String(identifier.dropFirst(prefix.count))
        let components = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }
        let platform = String(components[0])
        let supportedPlatforms = ["iOS", "watchOS", "tvOS", "visionOS"]
        guard supportedPlatforms.contains(platform) else { return nil }
        let versionComponents = components.dropFirst().map(String.init)
        guard versionComponents.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return platform + " " + versionComponents.joined(separator: ".")
    }
}

/// Measures each direct CoreSimulator device directory. Simulator groups are
/// excluded from Clean All and whole-category cleaning. A caller can clean
/// only an explicit item subset, and SafeDeleter revalidates every device.
public struct SimulatorDeviceDataSource: CacheSource {
    public static let id = CategoryID("simulator-device-data")
    public static let warning =
        "Simulator deletion permanently removes installed apps and data. This cannot be recovered."

    public let displayName = "Simulator Device Data"
    public let includedInCleanAllByDefault = false
    public let isDestructive = true
    public let supportsCleaning = true
    public let allowsWholeCategoryCleaning = false
    public let destructiveWarning: String? = Self.warning

    private static let devicesRelativePath = "Library/Developer/CoreSimulator/Devices"
    private let deviceTypeNames: any SimulatorDeviceTypeNameProviding

    public init() {
        self.deviceTypeNames = SystemSimulatorDeviceTypeNameProvider()
    }

    init(deviceTypeNames: any SimulatorDeviceTypeNameProviding) {
        self.deviceTypeNames = deviceTypeNames
    }

    public func scanRoot(context: ScanContext) -> URL? {
        context.home.appending(path: Self.devicesRelativePath)
    }

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [context.home.appending(path: Self.devicesRelativePath)]
    }

    public func canClean(item: CacheItem) -> Bool {
        item.categoryID == Self.id
            && item.deletionMode == .simulatorDevice
            && item.simulatorMetadata?.isEligibleForDeletion == true
    }

    /// Discovers only real, direct UUID-named directories. It does not follow
    /// symlinks or search below non-device entries.
    public func discover(context: ScanContext) async throws -> [CacheItem] {
        guard let declaredRoot = scanRoot(context: context) else { return [] }
        let root = declaredRoot.cruftCanonical
        let declaredPath = normalizedPath(declaredRoot)
        let rootPath = normalizedPath(root)
        let homePath = normalizedPath(context.home)

        // A different canonical path means a symlink exists in the discovery
        // chain. Refuse it even if the final Devices component is a directory.
        guard rootPath == declaredPath,
            rootPath.hasPrefix(homePath + "/")
        else { return [] }
        guard isRealDirectory(root) else { return [] }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        guard !entries.isEmpty else { return [] }
        let standardNames = deviceTypeNames.standardNamesByIdentifier()

        return entries.compactMap { entry in
            let leafUDID = entry.lastPathComponent
            guard UUID(uuidString: leafUDID) != nil,
                let values = try? entry.resourceValues(forKeys: keys),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { return nil }

            let directory = root.appending(path: leafUDID)
            let metadata = SimulatorDeviceMetadataReader().metadata(
                in: directory, leafUDID: leafUDID, standardNames: standardNames)
            return CacheItem(
                categoryID: Self.id,
                url: directory,
                label: metadata.name ?? leafUDID,
                deletionMode: .simulatorDevice,
                simulatorMetadata: metadata
            )
        }
        .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
