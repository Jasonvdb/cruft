import CruftKit
import CruftKitTestSupport
import Darwin
import Foundation

/// stdout carries only each subcommand's documented output; every
/// diagnostic goes here instead so the CLI stays scriptable.
func printToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Free bytes available to this user on the volume holding `url`, via
/// statfs(2). The before/after delta around a live clean is the ground-truth
/// freed-bytes number — per-file allocated sizes lie under APFS clones.
func volumeAvailableBytes(at url: URL) -> Int64? {
    var status = statfs()
    guard statfs(url.path(percentEncoded: false), &status) == 0 else { return nil }
    return Int64(status.f_bavail) &* Int64(status.f_bsize)
}

/// Whether the effective home IS the real canonical $HOME — live cleans
/// there additionally require the hidden `--really` flag.
func isRealHomeDirectory(_ home: URL) -> Bool {
    CLIReportCore.normalizedPath(home.cruftCanonical)
        == CLIReportCore.normalizedPath(
            FileManager.default.homeDirectoryForCurrentUser.cruftCanonical)
}
