import Foundation

extension FixtureHome {
    public static let temporaryDerivedDataFixturePath =
        "private-tmp/Demo-flow-DerivedData"

    @discardableResult
    public func plantTemporaryDerivedDataFixture(
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> URL {
        let root = try plantDir(Self.temporaryDerivedDataFixturePath)
        try plantFile("\(Self.temporaryDerivedDataFixturePath)/Build/result.bin")
        try plantFile("\(Self.temporaryDerivedDataFixturePath)/Logs/build.log")
        try setModificationDateRecursively(modifiedAt, at: root)
        return root
    }

    public func setModificationDateRecursively(_ date: Date, at root: URL) throws {
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [])
        {
            for case let entry as URL in enumerator {
                let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { continue }
                try FileManager.default.setAttributes(
                    [.modificationDate: date],
                    ofItemAtPath: entry.path(percentEncoded: false))
            }
        }
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: root.path(percentEncoded: false))
    }
}
