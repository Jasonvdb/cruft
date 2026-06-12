# Releasing cruft

Manual flow for now; automation is a welcome contribution.

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
   `Cruft.xcodeproj/project.pbxproj`.
2. Archive with a Developer ID identity:
   ```sh
   xcodebuild -project Cruft.xcodeproj -scheme Cruft -configuration Release \
     archive -archivePath build/Cruft.xcarchive \
     CODE_SIGN_IDENTITY="Developer ID Application"
   ```
3. Export, zip, and notarize:
   ```sh
   ditto -c -k --keepParent build/Cruft.xcarchive/Products/Applications/Cruft.app Cruft.zip
   xcrun notarytool submit Cruft.zip --keychain-profile cruft-notary --wait
   xcrun stapler staple build/Cruft.xcarchive/Products/Applications/Cruft.app
   ```
4. Create the GitHub release with the stapled zip:
   `gh release create vX.Y.Z Cruft.zip --title "cruft X.Y.Z" --generate-notes`
5. Update the Homebrew cask (once it exists) with the new version + sha256.

Checklist before any release: full test suite green on CI,
`./Scripts/check-chokepoint.sh` green, a supervised real-machine clean of at
least one category, and the README category table still matches
`SourceRegistry`.
