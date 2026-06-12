import CruftKitTestSupport
import Foundation

/// Fixture recipes for the `xcode-archives` category, built ONLY on the
/// frozen FixtureHome DSL primitives.
extension FixtureHome {
    /// Relative path of the Archives root inside a fixture home.
    static let archivesRootPath = "Library/Developer/Xcode/Archives"

    /// Plants an empty `Library/Developer/Xcode/Archives` directory.
    @discardableResult
    func plantArchivesRoot() throws -> URL {
        try plantDir(Self.archivesRootPath)
    }

    /// Plants `<name>.xcarchive` with the minimal contents Xcode writes
    /// (Info.plist plus a dSYM payload). The bundle lands inside
    /// `Archives/<dateDir>/`, or directly at the Archives root when
    /// `dateDir` is nil. Returns the bundle URL.
    @discardableResult
    func plantXcodeArchiveFixture(name: String, dateDir: String? = "2026-06-01") throws -> URL {
        let parent = dateDir.map { "\(Self.archivesRootPath)/\($0)" } ?? Self.archivesRootPath
        let bundle = "\(parent)/\(name).xcarchive"
        try plantFile("\(bundle)/Info.plist")
        try plantFile("\(bundle)/dSYMs/\(name).app.dSYM/Contents/Resources/DWARF/\(name)")
        try plantFile("\(bundle)/Products/Applications/\(name).app/\(name)")
        return url(bundle)
    }

    /// Plants an empty date directory (`Archives/<dateDir>/`) — Xcode leaves
    /// these behind after the user deletes archives from the Organizer.
    @discardableResult
    func plantEmptyArchiveDateDir(_ dateDir: String) throws -> URL {
        try plantDir("\(Self.archivesRootPath)/\(dateDir)")
    }
}
