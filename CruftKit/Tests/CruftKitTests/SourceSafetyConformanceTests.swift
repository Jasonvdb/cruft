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

/// `cruftCanonical` appends a trailing slash to existing directory URLs;
/// strip it so prefix checks compare like with like (SafeDeleter does the
/// same internally).
private func canonicalPath(_ url: URL) -> String {
    let path = url.cruftCanonical.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
}

@Test func conformance_everyDiscoveredItemSitsUnderAnAllowedRoot() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()
    let context = ScanContext(home: fixture.root)

    for source in SourceRegistry.allSources {
        let roots = source.allowedDeletionRoots(context: context).map(canonicalPath)
        for item in try await source.discover(context: context) {
            let path = canonicalPath(item.url)
            #expect(
                roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                "\(source.id) item escapes allowed roots: \(path)"
            )
        }
    }
}

// The seam where every source meets the real SafeDeleter: every item a
// source discovers must validate with ZERO refusals in .dryRun (catches
// depth-floor edges like ~/.gradle/caches at 2 components below home and
// root-itself-vs-contentsOnly mismatches before any GUI exists).
@Test func conformance_everyDiscoveredItemPassesSafeDeleterDryRun() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()
    let context = ScanContext(home: fixture.root)

    var validatedItems = 0
    for source in SourceRegistry.allSources {
        let deleter = try SafeDeleter(home: context.home, mode: .dryRun)
        let roots = source.allowedDeletionRoots(context: context)
        for item in try await source.discover(context: context) {
            do {
                let urls = try await deleter.delete(
                    DeletionRequest(item: item, allowedRoots: roots))
                #expect(!urls.isEmpty, "\(item.id) validated but deletes nothing")
                validatedItems += 1
            } catch {
                Issue.record("SafeDeleter refused \(item.id): \(error)")
            }
        }
    }
    // The canonical fixture plants all 8 categories — a sudden drop to zero
    // means discovery silently broke, not that the machine is clean.
    let expectedTotal = FixtureHome.canonicalExpectedItemCounts.values.reduce(0, +)
    #expect(validatedItems == expectedTotal)
}

@Test func conformance_canonicalFixtureItemCountsMatch() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()
    let context = ScanContext(home: fixture.root)

    for source in SourceRegistry.allSources {
        let items = try await source.discover(context: context)
        let expected = FixtureHome.canonicalExpectedItemCounts[source.id.rawValue]
        #expect(
            items.count == expected,
            "\(source.id): expected \(String(describing: expected)) items, got \(items.count): \(items.map(\.label))"
        )
    }
}
