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
        if !source.supportsCleaning {
            #expect(
                source.allowedDeletionRoots(context: context).isEmpty,
                "\(source.id) is view only but declares deletion roots"
            )
        }
        for root in source.allowedDeletionRoots(context: context) {
            let resolved = root.resolvingSymlinksInPath().path(percentEncoded: false)
            #expect(
                resolved.hasPrefix(context.home.path(percentEncoded: false)),
                "\(source.id) allowed root escapes home: \(resolved)"
            )
        }
    }
}

@Test func conformance_scanRootsResolveUnderHome() throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let context = ScanContext(home: fixture.root)
    let homePath = canonicalPath(context.home)

    for source in SourceRegistry.allSources {
        let root = try #require(
            source.scanRoot(context: context),
            "\(source.id) does not declare a scan root"
        )
        let resolved = canonicalPath(root)
        #expect(
            resolved == homePath || resolved.hasPrefix(homePath + "/"),
            "\(source.id) scan root escapes home: \(resolved)"
        )
    }
}

/// `cruftCanonical` appends a trailing slash to existing directory URLs;
/// strip it so prefix checks compare like with like (SafeDeleter does the
/// same internally).
private func canonicalPath(_ url: URL) -> String {
    let path = url.cruftCanonical.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
}

@Test func conformance_everyCleanableItemSitsUnderAnAllowedRoot() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()
    let context = ScanContext(home: fixture.root)

    for source in SourceRegistry.allSources {
        let roots = source.allowedDeletionRoots(context: context).map(canonicalPath)
        guard source.supportsCleaning else {
            #expect(roots.isEmpty, "\(source.id) is view only but declares deletion roots")
            continue
        }
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
    var refusedViewOnlyItems = 0
    var refusedIneligibleItems = 0
    for source in SourceRegistry.allSources {
        let roots = source.allowedDeletionRoots(context: context)
        let items = try await source.discover(context: context)
        guard source.supportsCleaning else {
            #expect(roots.isEmpty, "\(source.id) is view only but declares deletion roots")
            let deleter = RecordingDeleter()
            for item in items {
                await #expect(throws: CacheSourceError.cleaningUnsupported(source.id)) {
                    try await source.clean(item: item, context: context, using: deleter)
                }
                refusedViewOnlyItems += 1
            }
            #expect(await deleter.requests.isEmpty, "\(source.id) called the deleter")
            continue
        }

        let deleter = try SafeDeleter(home: context.home, mode: .dryRun)
        for item in items {
            guard source.canClean(item: item) else {
                await #expect(throws: CacheSourceError.itemCleaningUnsupported(source.id, item.id)) {
                    try await source.clean(item: item, context: context, using: deleter)
                }
                refusedIneligibleItems += 1
                continue
            }
            do {
                let urls = try await source.clean(item: item, context: context, using: deleter)
                #expect(!urls.isEmpty, "\(item.id) validated but deletes nothing")
                validatedItems += 1
            } catch {
                Issue.record("SafeDeleter refused \(item.id): \(error)")
            }
        }
    }
    // A sudden drop means discovery or a safety contract silently broke.
    let expectedCleanableTotal = SourceRegistry.allSources
        .filter { $0.supportsCleaning && $0.allowsWholeCategoryCleaning }
        .reduce(0) { $0 + (FixtureHome.canonicalExpectedItemCounts[$1.id.rawValue] ?? 0) }
    let expectedViewOnlyTotal = SourceRegistry.allSources
        .filter { !$0.supportsCleaning }
        .reduce(0) { $0 + (FixtureHome.canonicalExpectedItemCounts[$1.id.rawValue] ?? 0) }
    #expect(validatedItems == expectedCleanableTotal)
    #expect(refusedViewOnlyItems == expectedViewOnlyTotal)
    #expect(refusedIneligibleItems == FixtureHome.canonicalExpectedItemCounts["simulator-device-data"])
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
