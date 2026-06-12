import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private let archivesWarning = "Archives contain release dSYMs and CANNOT be re-derived."

private func snapshot(_ id: String, itemBytes: [Int64]) -> CategorySnapshot {
    let categoryID = CategoryID(id)
    let items = itemBytes.enumerated().map { index, bytes in
        MeasuredItem(
            item: CacheItem(
                categoryID: categoryID,
                url: URL(filePath: "/tmp/fixture/\(id)/cache/item-\(index)"),
                label: "item-\(index)"
            ),
            size: ItemSize(allocatedBytes: bytes, fileCount: 1)
        )
    }
    return CategorySnapshot(categoryID: categoryID, items: items, updatedAt: Date())
}

private let planner = CleanPlanner(sources: SourceRegistry.allSources)

@Test func cleanAllExcludesArchivesByDefaultEvenWithNonzeroSize() {
    let plan = planner.planCleanAll(snapshots: [
        snapshot("derived-data", itemBytes: [8192, 4096]),
        snapshot("xcode-archives", itemBytes: [65536]),
    ])
    #expect(Set(plan.itemsByCategory.keys) == [CategoryID("derived-data")])
    #expect(plan.estimatedBytes == 12288)
    #expect(plan.warnings.isEmpty)
}

@Test func explicitIncludeBringsArchivesInWithDestructiveWarning() {
    let plan = planner.planCleanAll(
        snapshots: [
            snapshot("derived-data", itemBytes: [8192]),
            snapshot("xcode-archives", itemBytes: [65536]),
        ],
        userIncluded: [CategoryID("xcode-archives")]
    )
    #expect(Set(plan.itemsByCategory.keys)
        == [CategoryID("derived-data"), CategoryID("xcode-archives")])
    #expect(plan.estimatedBytes == 8192 + 65536)
    #expect(plan.warnings == [archivesWarning])
}

@Test func userExcludedBeatsIncludedInCleanAllByDefault() {
    let plan = planner.planCleanAll(
        snapshots: [
            snapshot("derived-data", itemBytes: [8192]),
            snapshot("gradle", itemBytes: [4096]),
        ],
        userExcluded: [CategoryID("derived-data")]
    )
    #expect(Set(plan.itemsByCategory.keys) == [CategoryID("gradle")])
    #expect(plan.estimatedBytes == 4096)
}

@Test func estimatedBytesSumsEveryIncludedItem() {
    let plan = planner.planCleanAll(snapshots: [
        snapshot("derived-data", itemBytes: [4096, 8192, 12288]),
        snapshot("gradle", itemBytes: [4096, 4096]),
        snapshot("js-cache", itemBytes: [16384]),
    ])
    #expect(plan.estimatedBytes == 49152)
    #expect(plan.itemsByCategory[CategoryID("derived-data")]?.count == 3)
    #expect(plan.itemsByCategory[CategoryID("gradle")]?.count == 2)
    #expect(plan.itemsByCategory[CategoryID("js-cache")]?.count == 1)
}

@Test func processWarningsPassThroughAndPrecedeDestructiveWarnings() {
    let xcodeWarning = "Xcode is running — cleaning may break in-progress builds."
    let plan = planner.planCleanAll(
        snapshots: [snapshot("xcode-archives", itemBytes: [65536])],
        userIncluded: [CategoryID("xcode-archives")],
        processWarnings: [xcodeWarning]
    )
    #expect(plan.warnings == [xcodeWarning, archivesWarning])
}

@Test func planCategoryCleansDestructiveCategoryWithWarning() {
    let plan = planner.planCategory(
        CategoryID("xcode-archives"),
        snapshots: [
            snapshot("derived-data", itemBytes: [8192]),
            snapshot("xcode-archives", itemBytes: [65536, 4096]),
        ]
    )
    #expect(Set(plan.itemsByCategory.keys) == [CategoryID("xcode-archives")])
    #expect(plan.itemsByCategory[CategoryID("xcode-archives")]?.count == 2)
    #expect(plan.estimatedBytes == 69632)
    #expect(plan.warnings == [archivesWarning])
}

@Test func planCategoryIgnoresCleanAllMembershipFlags() {
    // Archives is includedInCleanAllByDefault == false; per-category clean
    // plans it anyway.
    let archives = SourceRegistry.source(for: CategoryID("xcode-archives"))
    #expect(archives?.includedInCleanAllByDefault == false)
    #expect(archives?.isDestructive == true)

    let plan = planner.planCategory(
        CategoryID("gradle"),
        snapshots: [snapshot("gradle", itemBytes: [4096])],
        processWarnings: ["A Gradle daemon is running."]
    )
    #expect(plan.itemsByCategory[CategoryID("gradle")]?.count == 1)
    #expect(plan.estimatedBytes == 4096)
    #expect(plan.warnings == ["A Gradle daemon is running."])
}

@Test func planCategoryWithNoSnapshotIsEmpty() {
    let plan = planner.planCategory(CategoryID("derived-data"), snapshots: [])
    #expect(plan.itemsByCategory.isEmpty)
    #expect(plan.estimatedBytes == 0)
    #expect(plan.warnings.isEmpty)
}
