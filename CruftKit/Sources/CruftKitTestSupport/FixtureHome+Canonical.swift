import Foundation

/// The ONE canonical fixture composition shared by the conformance suite,
/// the CLI integration tests, and `cruft-cli fixture`. Deterministic: same
/// tree, same byte counts, every time. All payload files are 4096-multiples
/// so allocated-size assertions are stable across APFS block rounding.
///
/// Per-category planted bytes (payload files only — what a scan reports):
/// see `canonicalExpectedBytes`.
extension FixtureHome {
    /// Plants every category's fixtures plus the standard decoys
    /// (CoreSimulator Devices, DeviceSupport, node_modules, .git, hidden
    /// dirs) that must survive any clean and never be discovered.
    public func plantCanonicalFixtureHome() throws {
        // derived-data: two projects + a shared cache (3 items)
        try plantDerivedDataRoot()
        try plantDerivedDataProject("DemoApp-abcdefgh")
        try plantDerivedDataProject("OtherApp-ijklmnop")
        try plantDerivedDataSharedCache("ModuleCache.noindex")
        _ = try plantDerivedDataDecoys()

        // in-repo-build: one Xcode project, one SwiftPM project, one
        // android layout (4 items: build, .build, android/.gradle via
        // android project, android/app/build)
        try plantInRepoProject("DemoApp", markers: ["DemoApp.xcodeproj"], buildDirs: ["build"])
        try plantInRepoProject("SwiftLib", markers: ["Package.swift"], buildDirs: [".build"])
        try plantInRepoProject("Mobile/android", markers: ["build.gradle"], buildDirs: [".gradle"])
        try plantInRepoProject("Mobile/android/app", markers: ["build.gradle"], buildDirs: ["build"])
        try plantBuildDir("NoMarker/build")  // decoy: no project marker

        // cargo-target: one standalone crate, plus a workspace whose root
        // owns target/ while its member crate has a Cargo.toml but no
        // target/ (2 items). A target/ with no Cargo.toml sibling is a decoy.
        try plantCargoPackage("pkresolver")
        try plantCargoPackage("ws")                       // workspace root
        try plantCargoPackage("ws/crates/core", withTarget: false)  // member
        try plantBuildDir("MavenLike/target")             // decoy: no Cargo.toml

        // gradle: caches + daemon (2 items)
        _ = try plantGradleFixture(includeDecoys: true)

        // swiftpm-cache (1 item)
        _ = try plantSwiftPMCacheFixture(includeDecoys: true)

        // xcode-misc: Xcode cache + simulator caches (2 items) + the
        // critical Devices decoy
        _ = try plantXcodeCacheFixture()
        _ = try plantSimulatorCachesFixture()
        _ = try plantSimulatorDeviceDecoy()

        // xcodebuild-mcp: one workspace (1 item) + the config decoys at the
        // XcodeBuildMCP parent level
        _ = try plantXcodeBuildMCPWorkspace("DemoApp-abc123")
        _ = try plantXcodeBuildMCPDecoys()

        // js-cache: all four roots (4 items)
        _ = try plantNpmCacacheFixture()
        _ = try plantNpmDecoys()
        _ = try plantYarnCacheFixture()
        _ = try plantPnpmCacheFixture()
        _ = try plantPnpmStoreFixture()
        _ = try plantPnpmGlobalDecoy()

        // xcode-archives: one dated archive + one root-level, plus the
        // x.xcarchive that plantDerivedDataDecoys plants in the Archives
        // dir (a decoy for derived-data, a real archive here) → 3 items
        _ = try plantXcodeArchiveFixture(name: "DemoApp 1.0", dateDir: "2026-06-01")
        _ = try plantXcodeArchiveFixture(name: "RootArchive", dateDir: nil)
    }

    /// Item counts per category for the canonical tree, used by integration
    /// tests and the Phase 3 gate.
    public static let canonicalExpectedItemCounts: [String: Int] = [
        "derived-data": 3,
        "in-repo-build": 4,
        "cargo-target": 2,
        "gradle": 2,
        "swiftpm-cache": 1,
        "xcode-misc": 2,
        "xcodebuild-mcp": 1,
        "js-cache": 4,
        "xcode-archives": 3,
    ]
}
