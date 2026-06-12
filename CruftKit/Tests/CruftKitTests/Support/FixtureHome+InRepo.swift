import CruftKitTestSupport
import Foundation

/// In-repo build fixture recipes, built only on the frozen DSL primitives.
/// Paths are relative to the projects root that `ScanContext(home:)`
/// derives by default, so tests construct `ScanContext(home: fixture.root)`
/// and plant projects with these helpers.
extension FixtureHome {
    /// Relative path of the default projects root under the fixture home,
    /// matching `ScanContext`'s default (`Documents/Repositories`).
    var projectsRootPath: String { "Documents/Repositories" }

    /// Absolute URL of `relativePath` resolved under the projects root.
    func projectURL(_ relativePath: String) -> URL {
        url("\(projectsRootPath)/\(relativePath)")
    }

    /// Plants one project directory at `relativePath` under the projects
    /// root. `markers` are the project-defining entries (`*.xcodeproj` /
    /// `*.xcworkspace` are planted as bundle directories with a stub file
    /// inside, everything else as a marker file); `buildDirs` are direct
    /// children planted as directories holding one 4096-byte payload file.
    @discardableResult
    func plantInRepoProject(
        _ relativePath: String,
        markers: [String],
        buildDirs: [String] = []
    ) throws -> URL {
        let project = "\(projectsRootPath)/\(relativePath)"
        for marker in markers {
            if marker.hasSuffix(".xcodeproj") || marker.hasSuffix(".xcworkspace") {
                try plantFile("\(project)/\(marker)/contents.stub")
            } else {
                try plantFile("\(project)/\(marker)")
            }
        }
        for buildDir in buildDirs {
            try plantBuildDir("\(relativePath)/\(buildDir)")
        }
        return projectURL(relativePath)
    }

    /// Plants a non-empty directory at `relativePath` under the projects
    /// root (used both for real build outputs and for decoys that must not
    /// be discovered).
    @discardableResult
    func plantBuildDir(_ relativePath: String) throws -> URL {
        try plantFile("\(projectsRootPath)/\(relativePath)/payload.o")
        return projectURL(relativePath)
    }
}
