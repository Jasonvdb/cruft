import Foundation
import Testing
@testable import CruftKit

// Phase 6: the pure settings logic the app's SettingsStore binds to
// UserDefaults — set algebra, interval clamping, codable round-trip, and
// agreement with CleanPlanner's Clean All membership rule.

@Test func settingsModelDefaults() {
    let model = SettingsModel()
    #expect(model.projectsRootPath == nil)
    #expect(model.cleanAllIncluded.isEmpty)
    #expect(model.cleanAllExcluded.isEmpty)
    #expect(model.launchAtLogin == false)
    #expect(model.rescanIntervalHours == SettingsModel.defaultRescanIntervalHours)
}

@Test(arguments: [
    (0.5, 1.0), (0.0, 1.0), (-3.0, 1.0),
    (25.0, 24.0), (1000.0, 24.0),
    (1.0, 1.0), (4.0, 4.0), (24.0, 24.0),
])
func rescanIntervalClampsToRange(input: Double, expected: Double) {
    var model = SettingsModel()
    model.setRescanIntervalHours(input)
    #expect(model.rescanIntervalHours == expected)
    // The init path clamps identically.
    #expect(SettingsModel(rescanIntervalHours: input).rescanIntervalHours == expected)
}

@Test func rescanIntervalNonFiniteFallsBackToDefault() {
    var model = SettingsModel()
    model.setRescanIntervalHours(.nan)
    #expect(model.rescanIntervalHours == SettingsModel.defaultRescanIntervalHours)
    model.setRescanIntervalHours(.infinity)
    #expect(model.rescanIntervalHours == SettingsModel.defaultRescanIntervalHours)
}

@Test func cleanAllMembershipSetsStayDisjoint() {
    var model = SettingsModel()
    let archives = CategoryID("xcode-archives")

    model.setMembership(.included, for: archives)
    #expect(model.membership(of: archives) == .included)
    #expect(model.cleanAllIncluded == ["xcode-archives"])
    #expect(model.cleanAllExcluded.isEmpty)

    // Flipping to excluded moves it — never present in both sets.
    model.setMembership(.excluded, for: archives)
    #expect(model.membership(of: archives) == .excluded)
    #expect(model.cleanAllIncluded.isEmpty)
    #expect(model.cleanAllExcluded == ["xcode-archives"])

    // Standard clears the override entirely.
    model.setMembership(.standard, for: archives)
    #expect(model.membership(of: archives) == .standard)
    #expect(model.cleanAllIncluded.isEmpty)
    #expect(model.cleanAllExcluded.isEmpty)
}

@Test func conflictingPersistedSetsResolveToExcluded() {
    // A corrupted/hand-edited defaults domain lists a category in both
    // sets: exclusion wins (the safe direction is "not in Clean All").
    let model = SettingsModel(
        cleanAllIncluded: ["derived-data", "gradle"],
        cleanAllExcluded: ["gradle"])
    #expect(model.membership(of: CategoryID("derived-data")) == .included)
    #expect(model.membership(of: CategoryID("gradle")) == .excluded)
}

@Test func isInCleanAllMirrorsCleanPlannerRule() {
    var model = SettingsModel()
    let archives = CategoryID("xcode-archives")
    let derived = CategoryID("derived-data")

    // Destructive default-out: only an explicit include joins Clean All.
    #expect(!model.isInCleanAll(id: archives, isDestructive: true, includedInCleanAllByDefault: false))
    model.setMembership(.included, for: archives)
    #expect(model.isInCleanAll(id: archives, isDestructive: true, includedInCleanAllByDefault: false))

    // Default-in: in until excluded.
    #expect(model.isInCleanAll(id: derived, isDestructive: false, includedInCleanAllByDefault: true))
    model.setMembership(.excluded, for: derived)
    #expect(!model.isInCleanAll(id: derived, isDestructive: false, includedInCleanAllByDefault: true))
}

@Test func cleanAllSetsFeedCleanPlannerCorrectly() {
    // End-to-end agreement: the model's ID sets passed to CleanPlanner
    // produce the membership `isInCleanAll` predicts, including the
    // destructive opt-in path.
    var model = SettingsModel()
    let archives = CategoryID("xcode-archives")
    model.setMembership(.included, for: archives)
    model.setMembership(.excluded, for: CategoryID("gradle"))

    let sources = SourceRegistry.allSources
    let snapshots = sources.map { source in
        CategorySnapshot(
            categoryID: source.id,
            items: [
                MeasuredItem(
                    item: CacheItem(
                        categoryID: source.id,
                        url: URL(filePath: "/tmp/fixture/\(source.id.rawValue)/item"),
                        label: "item"),
                    size: ItemSize(allocatedBytes: 4096, fileCount: 1))
            ],
            updatedAt: Date())
    }
    let plan = CleanPlanner(sources: sources).planCleanAll(
        snapshots: snapshots,
        userIncluded: model.cleanAllIncludedIDs,
        userExcluded: model.cleanAllExcludedIDs)

    let expected = Set(sources.filter {
        model.isInCleanAll(
            id: $0.id,
            isDestructive: $0.isDestructive,
            includedInCleanAllByDefault: $0.includedInCleanAllByDefault)
    }.map(\.id))
    #expect(Set(plan.itemsByCategory.keys) == expected)
    #expect(plan.itemsByCategory.keys.contains(archives))
    #expect(!plan.itemsByCategory.keys.contains(CategoryID("gradle")))
    #expect(plan.warnings.contains(CleanPlanner.destructiveWarning))
}

@Test func codableRoundTripPreservesEverything() throws {
    var model = SettingsModel(
        projectsRootPath: "/Users/example/Code",
        launchAtLogin: true,
        rescanIntervalHours: 8)
    model.setMembership(.included, for: CategoryID("xcode-archives"))
    model.setMembership(.excluded, for: CategoryID("js-cache"))

    let data = try JSONEncoder().encode(model)
    let decoded = try JSONDecoder().decode(SettingsModel.self, from: data)
    #expect(decoded == model)
}

@Test func decodeClampsOutOfRangeIntervalAndResolvesOverlap() throws {
    let json = """
        {"cleanAllIncluded":["gradle","xcode-archives"],
         "cleanAllExcluded":["gradle"],
         "launchAtLogin":false,
         "rescanIntervalHours":48}
        """
    let decoded = try JSONDecoder().decode(SettingsModel.self, from: Data(json.utf8))
    #expect(decoded.rescanIntervalHours == 24)
    #expect(decoded.membership(of: CategoryID("gradle")) == .excluded)
    #expect(decoded.membership(of: CategoryID("xcode-archives")) == .included)
    #expect(decoded.projectsRootPath == nil)
}

@Test func decodeMissingKeysFallsBackToDefaults() throws {
    let decoded = try JSONDecoder().decode(SettingsModel.self, from: Data("{}".utf8))
    #expect(decoded == SettingsModel())
}
