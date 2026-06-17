import Foundation

/// Cargo (`target/`) fixture recipes, built only on the frozen DSL
/// primitives and reusing the in-repo projects-root layout. Paths are
/// relative to the projects root that `ScanContext(home:)` derives by
/// default, so tests construct `ScanContext(home: fixture.root)` and plant
/// crates with these helpers.
extension FixtureHome {
    /// Plants a Cargo package at `relativePath` under the projects root: a
    /// `Cargo.toml` marker file plus, when `withTarget` is true, a `target/`
    /// directory holding one 4096-byte payload file. A `Cargo.lock` is added
    /// alongside to match real packages (it is not a marker and must be
    /// ignored). Returns the package URL.
    @discardableResult
    public func plantCargoPackage(
        _ relativePath: String,
        withTarget: Bool = true,
        lock: Bool = true
    ) throws -> URL {
        let pkg = "\(projectsRootPath)/\(relativePath)"
        try plantFile("\(pkg)/Cargo.toml")
        if lock { try plantFile("\(pkg)/Cargo.lock") }
        try plantFile("\(pkg)/src/main.rs")
        if withTarget {
            try plantBuildDir("\(relativePath)/target")
        }
        return projectURL(relativePath)
    }
}
