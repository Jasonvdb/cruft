import CruftKit
import Foundation

/// Test double for the `ItemDeleting` seam: records every request and
/// deletes nothing. This is what lets cache sources (Phase 2) be developed
/// and tested fully in parallel with the real SafeDeleter (Phase 1).
public actor RecordingDeleter: ItemDeleting {
    public private(set) var requests: [DeletionRequest] = []

    public init() {}

    @discardableResult
    public func delete(_ request: DeletionRequest) async throws -> [URL] {
        requests.append(request)
        return [request.item.url]
    }
}
