import Foundation
import Testing
@testable import CruftKit

/// Hermetic stand-in for the process-query seam: what is "running" is fixed
/// by the test, never by the machine the tests happen to execute on.
private struct StubQuerier: ProcessQuerying {
    var bundleIDs: Set<String> = []
    var commandLines: [String] = []

    func runningAppBundleIDs() -> Set<String> { bundleIDs }
    func processCommandLines() -> [String] { commandLines }
}

@Test func xcodeRunningWarnsForEveryXcodeCategory() {
    let processGuard = ProcessGuard(querier: StubQuerier(bundleIDs: ["com.apple.dt.Xcode"]))
    for category in [
        "derived-data", "xcode-misc", "xcode-archives", "simulator-device-data",
    ] {
        let warnings = processGuard.warnings(for: [CategoryID(category)])
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("Xcode") == true)
    }
}

@Test func xcodeRunningDoesNotWarnForUnrelatedCategories() {
    let processGuard = ProcessGuard(querier: StubQuerier(bundleIDs: ["com.apple.dt.Xcode"]))
    #expect(processGuard.warnings(for: [CategoryID("js-cache")]).isEmpty)
    #expect(processGuard.warnings(for: [CategoryID("gradle")]).isEmpty)
}

@Test func gradleDaemonWarnsOnlyForGradleCategory() {
    let querier = StubQuerier(commandLines: [
        "/usr/bin/java -Xmx2g org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.5",
    ])
    let processGuard = ProcessGuard(querier: querier)

    let warnings = processGuard.warnings(for: [CategoryID("gradle")])
    #expect(warnings.count == 1)
    #expect(warnings.first?.contains("Gradle") == true)

    #expect(processGuard.warnings(for: [CategoryID("derived-data")]).isEmpty)
}

@Test func quietSystemProducesNoWarnings() {
    let processGuard = ProcessGuard(querier: StubQuerier())
    let everyCategory: Set<CategoryID> = [
        CategoryID("derived-data"), CategoryID("xcode-misc"), CategoryID("xcode-archives"),
        CategoryID("simulator-device-data"), CategoryID("gradle"), CategoryID("js-cache"),
    ]
    #expect(processGuard.warnings(for: everyCategory).isEmpty)
}

/// Non-gating smoke test: the real querier must not crash. Deliberately no
/// assertions on machine state (what is running differs everywhere).
@Test func systemProcessQuerierSmokeTest() {
    let querier = SystemProcessQuerier()
    _ = querier.runningAppBundleIDs()
    _ = querier.processCommandLines()
}
