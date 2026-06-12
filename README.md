# cruft

> 🚧 Work in progress — not yet usable. Watch this repo for the first release.

A macOS menu bar app that finds the developer build cruft eating your disk —
Xcode DerivedData, stray in-repo `build/` folders, Gradle caches, SwiftPM and
npm/yarn/pnpm caches — and cleans it safely.

**Only things that can be derived again are ever touched.** Simulators, iOS
device support, source code, and anything else you can't get back are off
limits by design, enforced by a single audited deletion choke point
(`SafeDeleter`), a hard denylist, and a CI check that fails the build if any
other code path acquires a file-removal API. A full safety-model write-up
lands here with the first release.

Also ships `cruft-cli` for scripted scans and cleans.

## License

MIT — see [LICENSE](LICENSE).
