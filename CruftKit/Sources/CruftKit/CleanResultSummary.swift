/// Builds the short success message shown after a clean operation.
public enum CleanResultSummary {
    public static func text(
        freedBytes: Int64,
        deletedItems: Int,
        categoryIDs: [CategoryID],
        formattedBytes: String
    ) -> String {
        let containsOnlySimulatorData = !categoryIDs.isEmpty
            && categoryIDs.allSatisfy { $0 == SimulatorDeviceDataSource.id }

        if freedBytes == 0, deletedItems > 0, containsOnlySimulatorData {
            let noun = deletedItems == 1 ? "simulator" : "simulators"
            return "Deleted \(deletedItems) \(noun) — space update pending"
        }

        let noun = deletedItems == 1 ? "item" : "items"
        return "Freed \(formattedBytes) — \(deletedItems) \(noun)"
    }
}
