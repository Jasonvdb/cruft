import CruftKit
import Foundation

/// FROZEN CORE DSL (contracts v1): generic filesystem-planting primitives
/// shared by every test target and the `cruft-cli fixture` subcommand.
/// Category-specific fixture recipes live in per-agent
/// `FixtureHome+<Category>.swift` extension files — this file stays generic
/// and is never edited from parallel branches.
public struct FixtureHome: Sendable {
    /// Canonical fixture root (`URL.cruftCanonical`) — the same form
    /// SafeDeleter compares against.
    public let root: URL

    /// Creates (or reuses) a fixture home rooted at `root`.
    public init(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.cruftCanonical
    }

    /// Fresh fixture home under the system temporary directory.
    public static func makeTemporary() throws -> FixtureHome {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "cruft-fixture-\(UUID().uuidString.prefix(8))")
        return try FixtureHome(at: dir)
    }

    public func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    public func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path(percentEncoded: false))
    }

    @discardableResult
    public func plantDir(_ relativePath: String) throws -> URL {
        let target = url(relativePath)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// Plants a file of exactly `bytes` zero bytes. Use 4096-multiples so
    /// allocated-size assertions are stable across APFS block rounding.
    @discardableResult
    public func plantFile(_ relativePath: String, bytes: Int = 4096) throws -> URL {
        let target = url(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(count: bytes)
        try data.write(to: target)
        return target
    }

    /// Plants a symlink at `relativePath` pointing to `destination`
    /// (absolute, or relative to the link's directory). Used to build
    /// symlink-attack fixtures.
    @discardableResult
    public func plantSymlink(at relativePath: String, to destination: String) throws -> URL {
        let link = url(relativePath)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false), withDestinationPath: destination)
        return link
    }

    /// Removes the fixture tree. Test-support only — guarded so it can never
    /// remove anything outside the system temp areas or /tmp fixtures, even
    /// if misused. (Production deletion goes through SafeDeleter; this file
    /// is explicitly allowlisted in Scripts/check-chokepoint.sh.)
    public func destroy() throws {
        let path = root.path(percentEncoded: false)
        guard systemTempAreaPrefixes.contains(where: path.hasPrefix) else {
            fatalError("FixtureHome.destroy refused: \(path) is not a temp-area fixture")
        }
        try FileManager.default.removeItem(at: root)
    }
}
