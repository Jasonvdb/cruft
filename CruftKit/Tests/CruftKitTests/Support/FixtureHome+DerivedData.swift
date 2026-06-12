import CruftKitTestSupport
import Foundation

/// DerivedData fixture recipes, built strictly on the frozen FixtureHome
/// DSL primitives.
extension FixtureHome {
    /// Relative path of the DerivedData root inside a fixture home.
    static let derivedDataPath = "Library/Developer/Xcode/DerivedData"

    /// Plants the DerivedData directory itself, empty.
    @discardableResult
    func plantDerivedDataRoot() throws -> URL {
        try plantDir(Self.derivedDataPath)
    }

    /// Plants one per-project DerivedData subdirectory
    /// ("MockupCreator-abcdef") with a realistic inner layout.
    @discardableResult
    func plantDerivedDataProject(_ name: String) throws -> URL {
        try plantFile("\(Self.derivedDataPath)/\(name)/info.plist")
        try plantFile("\(Self.derivedDataPath)/\(name)/Build/Products/Debug/app.bin")
        return url("\(Self.derivedDataPath)/\(name)")
    }

    /// Plants a shared cache directory that sits beside the per-project
    /// subdirectories ("ModuleCache.noindex", "SymbolCache.noindex").
    @discardableResult
    func plantDerivedDataSharedCache(_ name: String) throws -> URL {
        try plantFile("\(Self.derivedDataPath)/\(name)/A1B2C3/entry.bin")
        return url("\(Self.derivedDataPath)/\(name)")
    }

    /// Plants a non-directory child at the DerivedData root (e.g. a
    /// `.lock` file) that discovery must skip.
    @discardableResult
    func plantDerivedDataRootFile(_ name: String) throws -> URL {
        try plantFile("\(Self.derivedDataPath)/\(name)")
    }

    /// Plants the Xcode/CoreSimulator siblings that sit beside DerivedData
    /// on a real machine but must NEVER be discovered or deleted. Returns
    /// the decoy paths (relative to the fixture root) for both-direction
    /// assertions.
    @discardableResult
    func plantDerivedDataDecoys() throws -> [String] {
        let decoys = [
            "Library/Developer/Xcode/iOS DeviceSupport/whatever",
            "Library/Developer/Xcode/Archives/x.xcarchive",
            "Library/Developer/CoreSimulator/Devices/uuid",
        ]
        try plantFile("\(decoys[0])/Symbols/sym.bin")
        try plantFile("\(decoys[1])/Info.plist")
        try plantFile("\(decoys[2])/device.plist")
        return decoys
    }
}
