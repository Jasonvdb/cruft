import CruftKitTestSupport
import Foundation

/// Fixture recipes for GradleSource and SwiftPMCacheSource, built ONLY on
/// the frozen FixtureHome DSL primitives.
extension FixtureHome {
    /// Plants a realistic `~/.gradle` tree: the two v1 cache roots
    /// (`caches`, `daemon`) with representative children, plus the decoys
    /// that must never be discovered — the `wrapper` distribution dir
    /// (re-downloading Gradle itself is expensive; not in v1) and the
    /// `gradle.properties` configuration file.
    @discardableResult
    func plantGradleFixture(includeDecoys: Bool = true) throws -> (caches: URL, daemon: URL) {
        let caches = try plantDir(".gradle/caches")
        try plantFile(".gradle/caches/modules-2/files-2.1/com.example/lib/1.0/lib-1.0.jar")
        try plantFile(".gradle/caches/8.7/kotlin-dsl/scripts/abc123/classes.bin")
        let daemon = try plantDir(".gradle/daemon")
        try plantFile(".gradle/daemon/8.7/daemon-12345.out.log")
        if includeDecoys {
            try plantFile(".gradle/wrapper/dists/gradle-8.7-bin/abc123/gradle-8.7-bin.zip")
            try plantFile(".gradle/gradle.properties")
        }
        return (caches: caches, daemon: daemon)
    }

    /// Plants `~/Library/Caches/org.swift.swiftpm` with representative
    /// children, plus a sibling decoy cache belonging to another app that
    /// must never be discovered.
    @discardableResult
    func plantSwiftPMCacheFixture(includeDecoys: Bool = true) throws -> URL {
        let root = try plantDir("Library/Caches/org.swift.swiftpm")
        try plantFile("Library/Caches/org.swift.swiftpm/repositories/swift-argument-parser-abc123/HEAD")
        try plantFile("Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/manifest.db")
        if includeDecoys {
            try plantFile("Library/Caches/com.apple.somethingelse/Cache.db")
        }
        return root
    }
}
