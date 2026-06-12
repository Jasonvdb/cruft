import Foundation

/// Fixture recipes for XcodeMiscSource and JSCacheSource tests, built ONLY
/// on the frozen FixtureHome DSL primitives. Every recipe returns the URL a
/// source is expected to discover (or, for decoys, the URL that must NEVER
/// be discovered).
extension FixtureHome {
    // MARK: - Xcode misc

    /// Plants `Library/Caches/com.apple.dt.Xcode` with one payload file.
    @discardableResult
    public func plantXcodeCacheFixture() throws -> URL {
        try plantFile("Library/Caches/com.apple.dt.Xcode/fsCachedData/payload.bin")
        return url("Library/Caches/com.apple.dt.Xcode")
    }

    /// Plants `Library/Developer/CoreSimulator/Caches` with one payload file.
    @discardableResult
    public func plantSimulatorCachesFixture() throws -> URL {
        try plantFile("Library/Developer/CoreSimulator/Caches/dyld/payload.bin")
        return url("Library/Developer/CoreSimulator/Caches")
    }

    /// Decoy: a simulator device's data directory under
    /// `CoreSimulator/Devices`. Simulator devices are user data (not
    /// re-derivable) and additionally denylisted in SafeDeleter — no source
    /// may ever discover them or cover them with an allowed root.
    @discardableResult
    public func plantSimulatorDeviceDecoy(
        uuid: String = "8A1B2C3D-0000-4444-8888-CAFEBABED00D"
    ) throws -> URL {
        try plantFile("Library/Developer/CoreSimulator/Devices/\(uuid)/data/Documents/precious.txt")
        return url("Library/Developer/CoreSimulator/Devices/\(uuid)/data")
    }

    // MARK: - JS package caches

    /// Plants `.npm/_cacache` with one payload file.
    @discardableResult
    public func plantNpmCacacheFixture() throws -> URL {
        try plantFile(".npm/_cacache/content-v2/sha512/payload.bin")
        return url(".npm/_cacache")
    }

    /// Decoys around `~/.npm`: the `_logs` directory inside `.npm` and a
    /// `.npmrc` sibling file — configuration and logs, not cache. Returns
    /// the URLs that must never be discovered.
    @discardableResult
    public func plantNpmDecoys() throws -> [URL] {
        try plantFile(".npm/_logs/2026-06-12T00_00_00_000Z-debug-0.log")
        try plantFile(".npmrc")
        return [url(".npm/_logs"), url(".npmrc")]
    }

    /// Plants `Library/Caches/Yarn` with one payload file.
    @discardableResult
    public func plantYarnCacheFixture() throws -> URL {
        try plantFile("Library/Caches/Yarn/v6/payload.bin")
        return url("Library/Caches/Yarn")
    }

    /// Plants `Library/Caches/pnpm` with one payload file.
    @discardableResult
    public func plantPnpmCacheFixture() throws -> URL {
        try plantFile("Library/Caches/pnpm/metadata/registry.npmjs.org/payload.json")
        return url("Library/Caches/pnpm")
    }

    /// Plants `Library/pnpm/store` with one payload file.
    @discardableResult
    public func plantPnpmStoreFixture() throws -> URL {
        try plantFile("Library/pnpm/store/v3/files/00/payload")
        return url("Library/pnpm/store")
    }

    /// Decoy: `Library/pnpm/global` holds globally installed packages —
    /// user-installed state, not cache; never discovered.
    @discardableResult
    public func plantPnpmGlobalDecoy() throws -> URL {
        try plantFile("Library/pnpm/global/5/package.json")
        return url("Library/pnpm/global")
    }
}
