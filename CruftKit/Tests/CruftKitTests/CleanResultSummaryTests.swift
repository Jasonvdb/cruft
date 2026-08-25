import CruftKit
import Testing

@Test func zeroByteSimulatorResultReportsPendingSpaceUpdate() {
    let result = CleanResultSummary.text(
        freedBytes: 0,
        deletedItems: 1,
        categoryIDs: [SimulatorDeviceDataSource.id],
        formattedBytes: "Zero KB")

    #expect(result == "Deleted 1 simulator — space update pending")
}

@Test func zeroByteSimulatorResultUsesPluralNoun() {
    let result = CleanResultSummary.text(
        freedBytes: 0,
        deletedItems: 3,
        categoryIDs: [SimulatorDeviceDataSource.id],
        formattedBytes: "Zero KB")

    #expect(result == "Deleted 3 simulators — space update pending")
}

@Test func measuredSimulatorResultReportsFreedSpace() {
    let result = CleanResultSummary.text(
        freedBytes: 2_000_000_000,
        deletedItems: 1,
        categoryIDs: [SimulatorDeviceDataSource.id],
        formattedBytes: "2 GB")

    #expect(result == "Freed 2 GB — 1 item")
}

@Test func zeroByteMixedResultKeepsGenericSummary() {
    let result = CleanResultSummary.text(
        freedBytes: 0,
        deletedItems: 2,
        categoryIDs: [SimulatorDeviceDataSource.id, DerivedDataSource.id],
        formattedBytes: "Zero KB")

    #expect(result == "Freed Zero KB — 2 items")
}
