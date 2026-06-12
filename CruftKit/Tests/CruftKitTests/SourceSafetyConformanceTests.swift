import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

// Registry-parameterized conformance suite — the seam where every source
// meets the real SafeDeleter. Skeleton frozen in Phase 0; it gains teeth
// automatically as SourceRegistry fills in (Phase 3) because every test
// iterates the live registry. The Phase 3 gate runs this suite explicitly.

@Test func conformance_discoverOnEmptyHomeReturnsNothingAndDoesNotThrow() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let context = ScanContext(home: fixture.root)

    for source in SourceRegistry.allSources {
        let items = try await source.discover(context: context)
        #expect(items.isEmpty, "\(source.id) reported items in an empty home")
    }
}

@Test func conformance_allowedRootsResolveUnderHome() throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let context = ScanContext(home: fixture.root)

    for source in SourceRegistry.allSources {
        for root in source.allowedDeletionRoots(context: context) {
            let resolved = root.resolvingSymlinksInPath().path(percentEncoded: false)
            #expect(
                resolved.hasPrefix(context.home.path(percentEncoded: false)),
                "\(source.id) allowed root escapes home: \(resolved)"
            )
        }
    }
}

// Phase 3 arms the remaining checks once SafeDeleter (P1) and the populated
// fixture recipes (P2 extension files) are merged:
//  - every discovered item path sits under one of its source's allowed roots
//  - every discovered item passes SafeDeleter .dryRun with zero refusals
//    (catches depth-floor edges like ~/.npm/_cacache/<child> and
//    root-itself-vs-contentsOnly mismatches before any GUI exists)
