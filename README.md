# cruft

A macOS menu bar app that finds the developer build cruft eating your disk —
and cleans it safely.

<img src="docs/screenshot.png" width="360" alt="cruft menu bar popover showing 113.94 GB of reclaimable space across Xcode DerivedData, project build folders, Gradle, SwiftPM, Xcode and JS package caches, with per-category sizes and a Clean All button">

Xcode DerivedData, simulator device data, stray in-repo `build/` folders,
Gradle caches, SwiftPM, and npm/yarn/pnpm caches can quietly grow to **tens or
hundreds of GB**. The built-in macOS storage pane is slow, incomplete, and
lumps in things you should never delete. cruft shows the total in your menu
bar, keeps it fresh in the background without ever making your Mac feel busy,
and cleans only the safe categories with one confirmed click.

**Only things that can be derived again are ever deleted.** Simulator device
data is measured for visibility, but it is never cleaned. iOS device support,
source code, and anything else you cannot get back are off limits by design —
see [Safety model](#safety-model).

> 🚧 Pre-release: fully functional and heavily tested against fixture
> trees, but no notarized binary yet — build from source below. A signed
> release + Homebrew cask are planned.

## What it shows and cleans

| Category | Location | Re-derivable? |
|---|---|---|
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData` (per-project) | ✅ rebuilds on next build |
| Project build folders | `build/`, `.build/`, `.gradle/` next to project markers under your projects root | ✅ rebuilds |
| Gradle caches | `~/.gradle/caches`, `~/.gradle/daemon` | ✅ re-downloads/rebuilds |
| SwiftPM cache | `~/Library/Caches/org.swift.swiftpm` | ✅ re-downloads |
| Xcode caches | `~/Library/Caches/com.apple.dt.Xcode`, CoreSimulator **Caches** (never Devices) | ✅ regenerates |
| Simulator device data | `~/Library/Developer/CoreSimulator/Devices` (per device) | 👁 visibility only — included in totals, never cleaned |
| XcodeBuildMCP workspaces | `~/Library/Developer/XcodeBuildMCP/workspaces` | ✅ rebuilds on next MCP build |
| JS package caches | `~/.npm/_cacache`, Yarn, pnpm caches/store | ✅ re-downloads |
| Xcode Archives | `~/Library/Developer/Xcode/Archives` | ⚠️ **NOT re-derivable** (release dSYMs) — excluded from Clean All by default, explicit per-category clean with a red warning |

Never deleted: CoreSimulator **Devices**, iOS/watchOS DeviceSupport, Android
AVDs, `.git`, iCloud Drive, `node_modules` (v1), Gradle wrapper distributions,
and anything outside your home directory. Simulator device directories appear
in scan totals, but the row, Clean All, and `cruft-cli clean` cannot delete
them.

## Safety model

cruft deletes files, so it is engineered like it.

- **One deletion choke point.** Every byte that leaves the disk goes through
  a single audited type, [`SafeDeleter`](CruftKit/Sources/CruftKit/SafeDeleter.swift).
  A CI check ([`Scripts/check-chokepoint.sh`](Scripts/check-chokepoint.sh))
  fails the build if any other production code acquires a file-removal API.
- **Eight rules, all must pass**, compared on canonical (symlink-resolved)
  paths on both sides: inside your home; home-override backstop (only the
  real `$HOME` or a temp-area test fixture is ever accepted); inside the
  category's allowed roots; a hard **denylist** (`.git`, `Devices`,
  `DeviceSupport`, `.avd`, `UserData`, iCloud's `Mobile Documents`) that
  beats the allowlist; a depth floor; symlinks deleted as links, never
  followed; must exist and be owned by you; and a dry-run mode that runs
  every check without touching anything.
- **Adversarially tested.** The test suite includes named attack fixtures —
  symlinks escaping home, symlinks into `.git`, mis-cased denylist
  components on case-insensitive APFS, `..` traversal, depth-floor edges —
  plus a conformance suite that pushes every cleanable item through the real
  SafeDeleter in dry-run and verifies that view-only items refuse deletion.
- **Nothing is deleted without a confirmation dialog**, which shows exactly
  what will be removed, warns if Xcode or a Gradle daemon is running, and
  requires a second explicit opt-in for the one non-re-derivable category.
- **Honest numbers.** Freed space is measured as the volume's free-space
  delta (`statfs`), not per-file sums — APFS clones can't inflate it.

## Polite by design

Scanning ~100 GB of caches without making your Mac feel slow is most of the
engineering here:

- Sizing is a **pure metadata walk** — payload file contents are never read.
  Simulator discovery can read the small `device.plist` directly in a device
  directory to show its name.
- Scheduled scans run at background QoS, which gets kernel-throttled disk
  I/O; user-initiated scans never run above utility priority.
- A **quiet gate** skips scanning DerivedData while a build is actively
  writing into it; low power mode, thermal pressure, and low battery defer
  scheduled scans.
- Last-known sizes persist, so the menu opens instantly with
  "updated X ago" while fresh numbers stream in — totals never flicker or
  shrink mid-scan.
- Background rescan every 4 h (configurable), refresh-on-open when stale,
  and instant invalidation when something else cleaned a cache externally.

## Install

Build from source (Xcode 16+):

```sh
git clone https://github.com/Jasonvdb/cruft.git
cd cruft
xcodebuild -project Cruft.xcodeproj -scheme Cruft -configuration Release build
```

First scan of your projects folder triggers the standard macOS prompt for
access to `~/Documents` — that's the OS, not us phoning home (cruft has no
network code at all).

## cruft-cli

Everything the app does is scriptable:

```sh
swift run --package-path CruftKit cruft-cli scan --json
swift run --package-path CruftKit cruft-cli clean --category derived-data            # dry run
swift run --package-path CruftKit cruft-cli clean --category derived-data --yes      # delete
```

`clean` is dry-run by default. Deleting from your real home requires an
extra explicit flag beyond `--yes` (it tells you which). The CLI lists
`simulator-device-data` in scan totals but always refuses a clean request for
that category, including dry-run requests.

## Extending

A cache category is one small type conforming to
[`CacheSource`](CruftKit/Sources/CruftKit/CacheSource.swift) (discover items
+ declare allowed deletion roots) plus one registry line. Rust `target/`
dirs, CocoaPods, ccache — PRs welcome; the conformance suite automatically
holds any new source to the same safety rules.

## Development

```sh
swift test --package-path CruftKit        # hermetic (fixture homes in /tmp)
./Scripts/check-chokepoint.sh             # single-deletion-site invariant
swift run --package-path CruftKit cruft-cli fixture /tmp/cruft-fixture   # canonical test tree
```

## License

MIT — see [LICENSE](LICENSE).
