import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

/// Thread-safe accumulator for partial emissions (`partial` is `@Sendable`).
private final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ItemSize] = []

    func append(_ value: ItemSize) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [ItemSize] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Test func measuresExactAllocatedBytesAndFileCount() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    // 4096-multiples: APFS allocates exactly for zero-filled block-multiple
    // files, so allocated == logical here.
    try fixture.plantFile("cache/a.bin", bytes: 4096)
    try fixture.plantFile("cache/sub/b.bin", bytes: 8192)
    try fixture.plantFile("cache/sub/deep/c.bin", bytes: 12288)
    try fixture.plantDir("cache/empty")

    let size = try await FoundationMeasurer().measure(fixture.url("cache")) { _ in }
    #expect(size.allocatedBytes == 24576)
    #expect(size.fileCount == 3)
    #expect(size.erroredEntries == 0)
}

@Test func symlinkedDirectoryContributesZeroAndIsNeverFollowed() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    // Destination tree lives OUTSIDE the measured root; if the walker
    // followed the links it would pick up 64 KiB and an extra file.
    try fixture.plantFile("target/big.bin", bytes: 65536)
    try fixture.plantFile("measured/real.bin", bytes: 4096)
    try fixture.plantSymlink(
        at: "measured/dirlink", to: fixture.url("target").path(percentEncoded: false))
    try fixture.plantSymlink(
        at: "measured/filelink", to: fixture.url("target/big.bin").path(percentEncoded: false))

    let size = try await FoundationMeasurer().measure(fixture.url("measured")) { _ in }
    #expect(size.allocatedBytes == 4096)
    #expect(size.fileCount == 1)
    #expect(size.erroredEntries == 0)
}

@Test func missingRootThrows() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    await #expect(throws: MeasurementError.rootMissing(fixture.url("does-not-exist"))) {
        try await FoundationMeasurer().measure(fixture.url("does-not-exist")) { _ in }
    }
}

@Test func cancellationThrowsCancellationErrorPromptly() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    for index in 0..<3000 {
        try fixture.plantFile("cache/d\(index % 30)/f\(index).bin", bytes: 0)
    }

    let root = fixture.url("cache")
    let task = Task {
        try await FoundationMeasurer().measure(root) { _ in }
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
}

@Test func unreadableSubdirectoryIsCountedAndWalkContinues() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantFile("cache/ok.bin", bytes: 4096)
    let locked = try fixture.plantDir("cache/locked")
    try fixture.plantFile("cache/locked/hidden.bin", bytes: 4096)
    let lockedPath = locked.path(percentEncoded: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o000], ofItemAtPath: lockedPath)
    defer {
        // Restore before destroy() (defers run LIFO) so teardown can recurse.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: lockedPath)
    }

    let size = try await FoundationMeasurer().measure(fixture.url("cache")) { _ in }
    #expect(size.erroredEntries > 0)
    #expect(size.allocatedBytes == 4096)
    #expect(size.fileCount == 1)
}

@Test func partialEmissionsAreMonotonicallyNonDecreasing() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    for index in 0..<1500 {
        try fixture.plantFile("cache/d\(index % 10)/f\(index).bin", bytes: 4096)
    }

    let log = PartialLog()
    // Zero interval -> an emission at every 512-entry chunk boundary, which
    // makes the count deterministic (1510 entries => at least 2 boundaries).
    let measurer = FoundationMeasurer(partialInterval: .zero)
    let final = try await measurer.measure(fixture.url("cache")) { log.append($0) }

    let partials = log.snapshot
    #expect(partials.count >= 2)
    var previous = ItemSize()
    for emission in partials {
        #expect(emission.allocatedBytes >= previous.allocatedBytes)
        #expect(emission.fileCount >= previous.fileCount)
        #expect(emission.erroredEntries >= previous.erroredEntries)
        previous = emission
    }
    #expect(final.allocatedBytes >= previous.allocatedBytes)
    #expect(final.fileCount >= previous.fileCount)
    #expect(final.allocatedBytes == Int64(1500 * 4096))
    #expect(final.fileCount == 1500)
}
